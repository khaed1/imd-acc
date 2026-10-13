// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StackReceiver, IStakedIMD} from "src/multichain/StackReceiver.sol";
import {StackReceiverFixture} from "./helpers/StackReceiverFixture.sol";
import {TestSIMD} from "./mocks/TestSIMD.sol";
import {QueuedComposeEndpoint} from "./mocks/QueuedComposeEndpoint.sol";

/// @dev Dependency fault injection only: the live vault has no such callback. Going through
/// the endpoint with a different queued message exercises nonReentrant beyond NotEndpoint.
contract ComposeCallbackVault is TestSIMD {
    bool public armed;
    bool public nestedSucceeded;
    bytes public nestedResult;
    address private endpoint;
    bytes private callback;

    constructor(address asset_) TestSIMD(asset_, msg.sender) {}

    function arm(address endpoint_, bytes memory callback_) external {
        endpoint = endpoint_;
        callback = callback_;
        armed = true;
    }

    function deposit(uint256 assets, address trader) public override returns (uint256) {
        if (armed) {
            armed = false;
            (nestedSucceeded, nestedResult) = endpoint.call(callback);
        }
        return super.deposit(assets, trader);
    }
}

contract StackReceiverAdversarialTest is StackReceiverFixture {
    function test_pendingArrivalsCanBeComposedOutOfOrderAndOnlyOnce() public {
        imd.mint(address(receiver), 7e18);
        bytes memory first = _queue(keccak256("first"), 3e18, _pair(3e18, 0));
        bytes memory second = _queue(keccak256("second"), 2e18, _pair(0, 2e18));
        assertEq(imd.balanceOf(address(receiver)), 12e18);
        assertEq(receiver.totalDelivered(), 0, "arrival alone is not delivery");

        _compose(keccak256("second"), second);
        assertEq(imd.balanceOf(address(receiver)), 10e18);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 2e24);
        assertEq(_queueHash(keccak256("first")), keccak256(first));

        bytes32 beforeReplay = _state(keccak256("first"));
        vm.expectRevert(QueuedComposeEndpoint.MessageNotQueued.selector);
        _compose(keccak256("second"), second);
        assertEq(_state(keccak256("first")), beforeReplay);

        _compose(keccak256("first"), first);
        assertEq(imd.balanceOf(address(receiver)), 7e18, "only unsolicited IMD remains");
        assertEq(vault.balanceOf(alice), 3e24);
        assertEq(receiver.totalDelivered(), 5e18);
        assertEq(receiver.deliveredFrom(RH_EID), 5e18);
    }

    function test_forgedComposeCannotSpendAPendingArrival() public {
        bytes32 guid = keccak256("honest");
        bytes memory honest = _queue(guid, 5e18, _pair(5e18, 0));
        bytes memory forged = _packet(1, RH_EID, 5e18, bytes32(0), _pair(0, 5e18));
        bytes32 beforeAttack = _state(guid);

        // Even with the genuine amount and guid, an executor cannot replace the committed list.
        vm.expectRevert(QueuedComposeEndpoint.MessageNotQueued.selector);
        _compose(guid, forged);
        assertEq(_state(guid), beforeAttack);

        // Anyone can queue their own compose; the receiver must reject its non-IMD namespace.
        endpoint.sendCompose(address(receiver), guid, 0, forged);
        vm.expectRevert(StackReceiver.NotIMD.selector);
        endpoint.lzCompose(address(this), address(receiver), guid, 0, forged, "");
        assertEq(_state(guid), beforeAttack);
        assertEq(
            endpoint.composeQueue(address(this), address(receiver), guid, 0), keccak256(forged)
        );

        // Naming IMD as `from` is insufficient unless the actual caller is the endpoint.
        vm.expectRevert(StackReceiver.NotEndpoint.selector);
        receiver.lzCompose(address(imd), guid, forged, address(endpoint), "");
        assertEq(_state(guid), beforeAttack);
        _compose(guid, honest);
        assertEq(vault.balanceOf(alice), 5e24);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_overlistedMessageCannotUseAnotherMessagesReserve() public {
        bytes32 badGuid = keccak256("overlisted");
        bytes memory bad = _queue(badGuid, 1e18, _pair(1e18, 5e18));
        bytes memory good = _queue(keccak256("unrelated"), 5e18, _pair(5e18, 0));
        bytes32 beforeBad = _state(badGuid);
        vm.expectRevert(abi.encodeWithSelector(StackReceiver.AmountMismatch.selector, 6e18, 1e18));
        _compose(badGuid, bad);
        assertEq(_state(badGuid), beforeBad);
        _compose(keccak256("unrelated"), good);
        assertEq(imd.balanceOf(address(receiver)), 1e18);
        assertEq(vault.balanceOf(alice), 5e24);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(receiver.totalDelivered(), 5e18);
        assertEq(_queueHash(badGuid), keccak256(bad), "bad sender only strands its own funds");
    }

    function test_sumOverflowRevertsBeforeApprovalOrDelivery() public {
        bytes32 guid = keccak256("overflow");
        bytes memory message = _queue(guid, 1e12, _pair(type(uint256).max, 1));
        bytes32 beforeCompose = _state(guid);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        _compose(guid, message);
        assertEq(_state(guid), beforeCompose);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_shortOFTHeaderIsAtomic(uint8 rawLength) public {
        uint256 length = bound(rawLength, 0, 75);
        bytes32 guid = keccak256("short header");
        bytes memory truncated = new bytes(length);
        _arrive(guid, 1e12, truncated);
        bytes32 beforeCompose = _state(guid);
        vm.expectRevert();
        _compose(guid, truncated);
        assertEq(_state(guid), beforeCompose);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_truncatedListIsAtomic(uint16 rawLength) public {
        bytes memory payload = _pair(1e12, 2e12);
        uint256 length = bound(rawLength, 0, payload.length - 1);
        bytes memory truncated = new bytes(length);
        for (uint256 i; i < length; ++i) {
            truncated[i] = payload[i];
        }
        bytes32 guid = keccak256("truncated list");
        bytes memory message = _queue(guid, 3e12, truncated);
        bytes32 beforeCompose = _state(guid);
        vm.expectRevert();
        _compose(guid, message);
        assertEq(_state(guid), beforeCompose);
    }

    function test_nonCanonicalAddressInListIsRejectedAtomically() public {
        bytes memory payload = _pair(1e12, 2e12);
        // address[] starts at payload offset 64; its first element is at offset 96.
        // Set a high byte outside uint160, preserving the low-byte trader address.
        payload[96] = bytes1(uint8(1));
        bytes32 guid = keccak256("dirty address");
        bytes memory message = _queue(guid, 3e12, payload);
        bytes32 beforeCompose = _state(guid);
        vm.expectRevert();
        _compose(guid, message);
        assertEq(_state(guid), beforeCompose);
    }

    function test_failedApprovalLeavesFirstDeliveryRetryable() public {
        bytes32 guid = keccak256("approval failure");
        bytes memory message = _queue(guid, 5e18, _pair(3e18, 2e18));
        bytes32 beforeCompose = _state(guid);
        vm.mockCall(address(imd), abi.encodeWithSelector(imd.approve.selector), abi.encode(false));
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd))
        );
        _compose(guid, message);
        assertEq(_state(guid), beforeCompose);

        vm.clearMockedCalls();
        _compose(guid, message);
        assertEq(imd.allowance(address(receiver), address(vault)), type(uint256).max);
        assertEq(vault.balanceOf(alice), 3e24);
        assertEq(vault.balanceOf(bob), 2e24);
        assertEq(receiver.totalDelivered(), 5e18);
    }

    function test_lateTransferFailureRollsBackEarlierDepositAndCanRetry() public {
        bytes32 guid = keccak256("late failure");
        bytes memory message = _queue(guid, 5e18, _pair(3e18, 2e18));
        imd.mint(address(receiver), 7e18);
        bytes32 beforeCompose = _state(guid);
        // Alice's deposit succeeds before Bob hits the fallback and its transfer fails.
        vm.mockCallRevert(address(vault), abi.encodeCall(vault.deposit, (2e18, bob)), "refused");
        vm.mockCall(address(imd), abi.encodeCall(imd.transfer, (bob, 2e18)), abi.encode(false));
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd))
        );
        _compose(guid, message);
        assertEq(_state(guid), beforeCompose, "including Alice's already executed deposit");

        vm.clearMockedCalls();
        _compose(guid, message);
        assertEq(imd.balanceOf(address(receiver)), 7e18);
        assertEq(vault.balanceOf(alice), 3e24);
        assertEq(vault.balanceOf(bob), 2e24);
        assertEq(receiver.totalDelivered(), 5e18);
        assertEq(_queueHash(guid), endpoint.RECEIVED());
    }

    function test_initializationIsLazyAndApprovalIsNotRepeated() public {
        bytes32 firstGuid = keccak256("initialize");
        bytes memory first = _queue(firstGuid, 1e18, _pair(1e18, 0));
        vm.mockCallRevert(address(vault), abi.encodeCall(vault.asset, ()), "asset unavailable");
        bytes32 beforeCompose = _state(firstGuid);
        vm.expectRevert(bytes("asset unavailable"));
        _compose(firstGuid, first);
        assertEq(_state(firstGuid), beforeCompose);
        vm.clearMockedCalls();
        _compose(firstGuid, first);

        // A second compose must not repeat the receiver's external asset check or approval.
        vm.mockCallRevert(address(vault), abi.encodeCall(vault.asset, ()), "repeat asset check");
        vm.mockCallRevert(
            address(imd), abi.encodeWithSelector(imd.approve.selector), "repeat approval"
        );
        bytes memory second = _queue(keccak256("already initialized"), 2e18, _pair(0, 2e18));
        _compose(keccak256("already initialized"), second);
        assertEq(vault.balanceOf(alice), 1e24);
        assertEq(vault.balanceOf(bob), 2e24);
        assertEq(receiver.totalDelivered(), 3e18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_headerFieldsPreserveAmountSourceAndBeneficiaries(
        uint64 nonce,
        uint32 eid,
        bytes32 composeFrom,
        bytes32 guid,
        uint64 rawAmount
    ) public {
        uint256 amount = bound(uint256(rawAmount), 1, type(uint64).max) * BRIDGE_STEP;
        bytes memory message = _packet(nonce, eid, amount, composeFrom, _pair(amount, 0));
        _arrive(guid, amount, message);
        vm.expectEmit(true, true, true, true, address(receiver));
        emit StackReceiver.Delivered(guid, eid, alice, amount, amount * 1e6);
        _compose(guid, message);
        assertEq(vault.balanceOf(alice), amount * 1e6);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.balanceOf(executor), 0);
        assertEq(receiver.deliveredFrom(eid), amount);
        assertEq(receiver.totalDelivered(), amount);
        assertEq(imd.balanceOf(address(receiver)), 0);
    }

    function test_maximumSharedDecimalArrivalCanBeDelivered() public {
        uint256 amount = uint256(type(uint64).max) * BRIDGE_STEP;
        bytes memory message = _queue(keccak256("max SD"), amount, _pair(amount, 0));
        _compose(keccak256("max SD"), message);
        assertEq(vault.balanceOf(alice), amount * 1e6);
        assertEq(vault.totalAssets(), amount);
        assertEq(receiver.totalDelivered(), amount);
        assertEq(imd.balanceOf(address(receiver)), 0);
    }

    function test_oneWeiAllocationAndDuplicateTradersPreserveEveryWei() public {
        address[] memory traders = new address[](4);
        uint256[] memory amounts = new uint256[](4);
        traders[0] = alice;
        traders[1] = bob;
        traders[2] = alice;
        traders[3] = carol;
        amounts[0] = 1;
        amounts[1] = 0;
        amounts[2] = BRIDGE_STEP - 1;
        amounts[3] = 0;
        bytes memory message =
            _queue(keccak256("duplicates"), BRIDGE_STEP, abi.encode(traders, amounts));
        _compose(keccak256("duplicates"), message);
        assertEq(vault.balanceOf(alice), BRIDGE_STEP * 1e6);
        assertEq(vault.lastDepositBlock(bob), 0, "zero entries do not stamp the hold");
        assertEq(vault.lastDepositBlock(carol), 0);
        assertEq(receiver.totalDelivered(), BRIDGE_STEP);
        assertEq(imd.balanceOf(address(receiver)), 0);
    }

    function test_zeroArrivalDoesNotConsumeUnrelatedFundsOrStampTraders() public {
        imd.mint(address(receiver), 7e18);
        bytes memory message = _queue(keccak256("zero"), 0, _pair(0, 0));
        _compose(keccak256("zero"), message);
        assertEq(imd.balanceOf(address(receiver)), 7e18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.lastDepositBlock(alice), 0);
        assertEq(vault.lastDepositBlock(bob), 0);
        assertEq(receiver.totalDelivered(), 0);
        assertEq(_queueHash(keccak256("zero")), endpoint.RECEIVED());
    }

    function test_nestedAuthenticatedComposeIsBlockedAndStillRetryable() public {
        ComposeCallbackVault callbackVault = new ComposeCallbackVault(address(imd));
        vault = callbackVault;
        receiver =
            new StackReceiver(IERC20(address(imd)), IStakedIMD(address(vault)), address(endpoint));
        bytes32 firstGuid = keccak256("outer");
        bytes32 secondGuid = keccak256("nested");
        bytes memory first = _queue(firstGuid, 3e18, _pair(3e18, 0));
        bytes memory second = _queue(secondGuid, 2e18, _pair(0, 2e18));
        callbackVault.arm(
            address(endpoint),
            abi.encodeCall(
                endpoint.lzCompose,
                (address(imd), address(receiver), secondGuid, 0, second, bytes(""))
            )
        );
        _compose(firstGuid, first);
        assertFalse(callbackVault.nestedSucceeded());
        assertEq(
            callbackVault.nestedResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(receiver.totalDelivered(), 3e18);
        assertEq(imd.balanceOf(address(receiver)), 2e18);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(_queueHash(secondGuid), keccak256(second));

        _compose(secondGuid, second);
        assertEq(vault.balanceOf(bob), 2e24);
        assertEq(receiver.totalDelivered(), 5e18);
        assertEq(imd.balanceOf(address(receiver)), 0);
    }
}
