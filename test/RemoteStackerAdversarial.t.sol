// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RemoteStacker} from "src/multichain/RemoteStacker.sol";
import {SendParam} from "src/multichain/LayerZero.sol";
import {RemoteAdversarialOFT} from "./mocks/RemoteAdversarialOFT.sol";

contract RemoteRefundProbe {
    RemoteStacker internal immutable remote;
    bool public rejectRefund;
    uint256 public refunds;
    bytes public creditError;
    bytes public flushError;
    bool public creditSucceeded;
    bool public flushSucceeded;

    constructor(RemoteStacker remote_) {
        remote = remote_;
    }

    function reject(bool value) external {
        rejectRefund = value;
    }

    function execute(address[] calldata list) external payable returns (bytes32) {
        return remote.flush{value: msg.value}(list);
    }

    receive() external payable {
        require(!rejectRefund, "refund rejected");
        ++refunds;
        (creditSucceeded, creditError) =
            address(remote).call(abi.encodeCall(RemoteStacker.credit, (address(this), 0)));
        (flushSucceeded, flushError) =
            address(remote).call(abi.encodeCall(RemoteStacker.flush, (new address[](0))));
    }
}

/// @dev These tests isolate RemoteStacker's integration boundaries; the fixed live IMD is
/// standard ERC20/OFT. Token fault modes test rollback and SafeERC20, not alternative assets.
contract RemoteStackerAdversarialTest is Test {
    uint256 internal constant STEP = 1e12;
    uint256 internal constant PERIOD = 12 hours;
    uint256 internal constant FEE = 0.001 ether;
    address internal constant RECEIVER = 0x1999a54f573dAc75ce8Ef62A555dba418c9B3D10;
    address internal constant VAULT = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    RemoteAdversarialOFT internal imd;
    RemoteStacker internal remote;
    address internal project = makeAddr("adversarial project");
    address internal alice = makeAddr("adversarial alice");
    address internal bob = makeAddr("adversarial bob");
    address internal wallet = makeAddr("adversarial contract wallet");
    address internal flusher = makeAddr("adversarial flusher");

    function setUp() public {
        vm.warp(1_790_000_123);
        imd = new RemoteAdversarialOFT();
        remote = new RemoteStacker(IERC20(address(imd)), RECEIVER, VAULT, 30101);
        imd.mint(project, 1_000_000e18);
        vm.prank(project);
        imd.approve(address(remote), 1_000_000e18);
        vm.etch(wallet, hex"00");
        vm.deal(flusher, 10 ether);
        vm.deal(address(this), 10 ether);
    }

    function _credit(address trader, uint256 amount) internal returns (uint256 result) {
        vm.prank(project);
        result = remote.credit(trader, amount);
    }

    function _list() internal view returns (address[] memory list) {
        list = new address[](2);
        list[0] = alice;
        list[1] = bob;
    }

    function _flush(uint256 value) internal returns (bytes32 guid) {
        vm.prank(flusher);
        guid = remote.flush{value: value}(_list());
    }

    function _seed() internal {
        _credit(alice, 100e18 + STEP - 1);
        vm.warp(block.timestamp + 3 hours);
        _credit(bob, 300e18 + 1);
        vm.warp(block.timestamp + PERIOD);
    }

    /// @dev Include both sides of each transfer, finite allowance, clocks, bridge burn/nonce,
    /// prior packet and ETH. A failure late in flush must roll back all of them.
    function _state() internal view returns (bytes32) {
        bytes32 accounting = keccak256(
            abi.encode(
                remote.totalQueued(),
                remote.totalPaid(),
                remote.projectQueued(project),
                remote.waiting(alice),
                remote.waitingSince(alice),
                remote.waiting(bob),
                remote.waitingSince(bob),
                remote.waiting(wallet),
                remote.waitingSince(wallet)
            )
        );
        bytes32 tokens = keccak256(
            abi.encode(
                imd.totalSupply(),
                imd.balanceOf(project),
                imd.balanceOf(address(remote)),
                imd.balanceOf(alice),
                imd.balanceOf(bob),
                imd.balanceOf(wallet),
                imd.balanceOf(flusher),
                imd.allowance(project, address(remote))
            )
        );
        return keccak256(
            abi.encode(
                accounting,
                tokens,
                imd.nonce(),
                imd.burned(),
                imd.lastSend(),
                imd.lastRefundAddress(),
                address(imd).balance,
                address(remote).balance,
                flusher.balance
            )
        );
    }

    function test_zeroCreditsDoNotCallTokenEmitPointsOrResetAnAgedClock() public {
        _seed();
        imd.setReturns(
            RemoteAdversarialOFT.ReturnMode.Revert, RemoteAdversarialOFT.ReturnMode.Revert
        );
        bytes32 beforeState = _state();
        vm.recordLogs();
        assertEq(_credit(alice, 0), 0);
        assertEq(_credit(wallet, 0), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_state(), beforeState);
        address[5] memory bad = [address(0), address(remote), address(imd), RECEIVER, VAULT];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(
                i == 0 ? RemoteStacker.ZeroTrader.selector : RemoteStacker.InvalidTrader.selector
            );
            vm.prank(project);
            remote.credit(bad[i], 0);
        }
        assertEq(_state(), beforeState);
    }

    function test_falseTransferFromRollsBackFiniteAllowanceAndExistingQueue() public {
        _seed();
        imd.setReturns(
            RemoteAdversarialOFT.ReturnMode.False, RemoteAdversarialOFT.ReturnMode.Normal
        );
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd))
        );
        vm.prank(project);
        remote.credit(alice, 1e18);
        assertEq(_state(), beforeState);
    }

    function test_revertingTransferFromBubblesErrorAndPreservesQueue() public {
        _seed();
        imd.setReturns(
            RemoteAdversarialOFT.ReturnMode.Revert, RemoteAdversarialOFT.ReturnMode.Normal
        );
        bytes32 beforeState = _state();
        vm.expectRevert(RemoteAdversarialOFT.TokenRefused.selector);
        vm.prank(project);
        remote.credit(bob, 1e18);
        assertEq(_state(), beforeState);
    }

    function test_failedPlainPaymentRollsBackPullAllowanceAndTotalPaid() public {
        _seed();
        imd.setReturns(
            RemoteAdversarialOFT.ReturnMode.Normal, RemoteAdversarialOFT.ReturnMode.False
        );
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd))
        );
        vm.prank(project);
        remote.credit(wallet, 7e18);
        assertEq(_state(), beforeState);
        imd.setReturns(
            RemoteAdversarialOFT.ReturnMode.Normal, RemoteAdversarialOFT.ReturnMode.Normal
        );
        assertEq(_credit(wallet, 7e18), 0);
        assertEq(remote.totalPaid(), 7e18);
        assertEq(imd.balanceOf(wallet), 7e18);
        assertEq(remote.totalQueued(), 400e18 + STEP);
    }

    function test_noReturnTokenAcceptedForPullPlainPaymentAndTip() public {
        imd.setReturns(RemoteAdversarialOFT.ReturnMode.Empty, RemoteAdversarialOFT.ReturnMode.Empty);
        assertEq(_credit(alice, 100e18 + 1), 100e18 + 1);
        assertEq(_credit(wallet, 7e18), 0);
        vm.warp(block.timestamp + PERIOD);
        _flush(FEE);
        assertEq(imd.balanceOf(wallet), 7e18);
        assertEq(imd.balanceOf(flusher), 2e18);
        assertEq(imd.burned(), 98e18);
        assertEq(remote.waiting(alice), 1);
        assertEq(imd.balanceOf(address(remote)), 1);
    }

    function test_tipTransferFailureUndoesBurnPacketFeesAndEveryQueueDebit() public {
        _seed();
        // Preserve a real prior packet, not just initially-zero bridge fields.
        _flush(FEE);
        _seed();
        imd.setReturns(
            RemoteAdversarialOFT.ReturnMode.Normal, RemoteAdversarialOFT.ReturnMode.False
        );
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd))
        );
        vm.prank(flusher);
        remote.flush{value: FEE + 0.2 ether}(_list());
        assertEq(_state(), beforeState);
        imd.setReturns(
            RemoteAdversarialOFT.ReturnMode.Normal, RemoteAdversarialOFT.ReturnMode.Normal
        );
        _flush(FEE);
        assertEq(imd.nonce(), 2, "failed send did not consume nonce");
        assertEq(imd.balanceOf(address(remote)), remote.waiting(alice) + remote.waiting(bob));
    }

    function test_bridgeFailureAfterBurnRollsBackThenSameBatchCanBeRetried() public {
        _seed();
        imd.setBridgeFailures(false, true);
        bytes32 beforeState = _state();
        vm.expectRevert(RemoteAdversarialOFT.SendRefusedAfterBurn.selector);
        vm.prank(flusher);
        remote.flush{value: FEE}(_list());
        assertEq(_state(), beforeState);
        imd.setBridgeFailures(false, false);
        _flush(FEE);
        assertEq(imd.nonce(), 1);
        assertEq(imd.burned(), 392e18);
        assertEq(imd.balanceOf(flusher), 8e18);
    }

    function test_quoteFailureBubblesButEmptyAndDustQueuesNeedNoBridgeQuote() public {
        imd.setBridgeFailures(true, false);
        _credit(alice, STEP - 1);
        (uint256 amount, uint256 tip, address[] memory to, uint256[] memory amounts, uint256 fee) =
            remote.quoteFlush(_list());
        assertEq(amount + tip + fee + to.length + amounts.length, 0);
        _credit(bob, 1e18);
        bytes32 beforeState = _state();
        vm.expectRevert(RemoteAdversarialOFT.QuoteRefused.selector);
        remote.quoteFlush(_list());
        assertEq(_state(), beforeState);
        imd.setBridgeFailures(false, false);
        _flush(FEE);
        assertEq(remote.waiting(alice), STEP - 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_reentrancyRejectedAtPullPlainPaymentSendAndTip(uint8 stage, bool nestedFlush)
        public
    {
        stage = uint8(bound(stage, 0, 3));
        _seed();
        RemoteAdversarialOFT.Hook hook = stage == 0
            ? RemoteAdversarialOFT.Hook.Pull
            : stage == 2 ? RemoteAdversarialOFT.Hook.Send : RemoteAdversarialOFT.Hook.Push;
        bytes memory payload = nestedFlush
            ? abi.encodeCall(RemoteStacker.flush, (_list()))
            : abi.encodeCall(RemoteStacker.credit, (bob, 0));
        imd.setHook(hook, address(remote), payload);
        if (stage == 0) _credit(bob, 5e18);
        else if (stage == 1) _credit(wallet, 5e18);
        else _flush(FEE);
        assertEq(imd.callbackCount(), 1, "the callback was actually reached");
        assertFalse(imd.callbackSucceeded(), "nested state change must fail");
        assertEq(
            imd.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(imd.balanceOf(address(remote)), remote.waiting(alice) + remote.waiting(bob));
    }

    function test_refundCallbackCannotCreditOrFlushAndExcessGoesToCaller() public {
        _seed();
        RemoteRefundProbe probe = new RemoteRefundProbe(remote);
        probe.execute{value: FEE + 0.2 ether}(_list());
        assertEq(probe.refunds(), 1);
        assertFalse(probe.creditSucceeded());
        assertFalse(probe.flushSucceeded());
        bytes memory guardError =
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(probe.creditError(), guardError);
        assertEq(probe.flushError(), guardError);
        assertEq(address(probe).balance, 0.2 ether);
        assertEq(imd.balanceOf(address(probe)), 8e18);
        assertEq(imd.lastRefundAddress(), address(probe));
        assertEq(address(remote).balance, 0);
        assertEq(address(imd).balance, FEE);
    }

    function test_rejectedRefundRevertsAtomicallyAndExactFeeStillWorks() public {
        _seed();
        RemoteRefundProbe probe = new RemoteRefundProbe(remote);
        probe.reject(true);
        bytes32 beforeState = _state();
        uint256 senderBalance = address(this).balance;
        vm.expectRevert(RemoteAdversarialOFT.RefundRefused.selector);
        probe.execute{value: FEE + 1}(_list());
        assertEq(_state(), beforeState);
        assertEq(address(this).balance, senderBalance);
        assertEq(address(probe).balance, 0);
        probe.execute{value: FEE}(_list());
        assertEq(imd.balanceOf(address(probe)), 8e18);
        assertEq(imd.nonce(), 1);
    }

    function test_recipientChangesAffectFutureCreditsOnlyAndCannotAlterAnotherWallet() public {
        address secondWallet = makeAddr("second contract wallet");
        vm.etch(secondWallet, hex"00");
        vm.prank(wallet);
        remote.setEthereumRecipient(alice);
        _credit(wallet, 10e18);
        uint256 oldClock = remote.waitingSince(alice);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(secondWallet);
        remote.setEthereumRecipient(bob);
        assertEq(remote.ethereumRecipient(wallet), alice);
        vm.prank(wallet);
        remote.setEthereumRecipient(bob);
        _credit(wallet, 20e18);
        _credit(secondWallet, 30e18);
        vm.prank(wallet);
        remote.setEthereumRecipient(address(0));
        _credit(wallet, 40e18);
        assertEq(remote.waiting(alice), 10e18);
        assertEq(remote.waitingSince(alice), oldClock);
        assertEq(remote.waiting(bob), 50e18);
        assertEq(imd.balanceOf(wallet), 40e18);
        assertEq(remote.totalPaid(), 40e18);
        assertEq(remote.projectQueued(project), 60e18);
        assertEq(remote.waiting(wallet), 0);
        _flush(FEE);
        (address[] memory to, uint256[] memory amounts) =
            abi.decode(imd.lastSend().composeMsg, (address[], uint256[]));
        assertEq(to[0], alice);
        assertEq(to[1], bob);
        assertEq(amounts[0] + amounts[1], imd.burned());
    }

    function test_delegationAndOrdinaryCodeRouteDifferentlyDespiteRegistration() public {
        address delegate = makeAddr("delegation target");
        bytes[5] memory code = [
            abi.encodePacked(hex"ef0100", delegate),
            abi.encodePacked(hex"600100", delegate),
            abi.encodePacked(hex"600100", bytes19(bytes20(delegate))),
            abi.encodePacked(hex"600100", delegate, hex"00"),
            bytes(hex"600100")
        ];
        for (uint256 i; i < code.length; ++i) {
            address trader = makeAddr(string.concat("delegation candidate", vm.toString(i)));
            vm.etch(trader, code[i]);
            if (i == 0) {
                vm.prank(trader);
                remote.setEthereumRecipient(bob);
                assertEq(_credit(trader, 1e18), 1e18);
                assertEq(remote.waiting(trader), 1e18);
                assertEq(remote.waiting(bob), 0);
            } else {
                assertEq(_credit(trader, 1e18), 0);
                assertEq(imd.balanceOf(trader), 1e18);
                assertEq(remote.waiting(trader), 0);
            }
        }
        assertEq(remote.totalPaid(), 4e18);
        assertEq(remote.totalQueued(), 1e18);
    }

    function test_batchLimitCountsRawEntriesEvenWhenEveryEntryIsADuplicate() public {
        _credit(alice, 1e18);
        address[] memory list = new address[](51);
        for (uint256 i; i < list.length; ++i) {
            list[i] = alice;
        }
        bytes32 beforeState = _state();
        vm.expectRevert(RemoteStacker.TooManyTraders.selector);
        remote.quoteFlush(list);
        vm.expectRevert(RemoteStacker.TooManyTraders.selector);
        vm.prank(flusher);
        remote.flush{value: FEE}(list);
        assertEq(_state(), beforeState);
        assembly ("memory-safe") { mstore(list, 50) }
        vm.prank(flusher);
        remote.flush{value: FEE}(list);
        SendParam memory sent = imd.lastSend();
        (address[] memory to,) = abi.decode(sent.composeMsg, (address[], uint256[]));
        assertEq(to.length, 1);
        // A literal 44-byte type-3 option packet: receive=250000, compose(index=0)=280000.
        assertEq(
            sent.extraOptions,
            hex"0003010011010000000000000000000000000003d090010013030000000000000000000000000000000445c0"
        );
        assertEq(imd.nonce(), 1);
        assertEq(imd.burned(), 1e18);
    }

    function test_entireSupplyCanQueueWithExactAllowanceAndExit() public {
        uint256 supply = imd.totalSupply();
        assertEq(imd.balanceOf(project), supply);
        assertEq(_credit(alice, supply), supply);
        assertEq(imd.balanceOf(project), 0);
        assertEq(imd.allowance(project, address(remote)), 0);
        vm.warp(block.timestamp + PERIOD);
        _flush(FEE);
        assertEq(imd.burned(), supply * 98 / 100);
        assertEq(imd.balanceOf(flusher), supply / 50);
        assertEq(imd.balanceOf(address(remote)), 0);
        assertEq(remote.waiting(alice), 0);
        assertEq(remote.waitingSince(alice), 0);
        assertEq(remote.totalQueued(), supply, "historical points survive a full drain");
    }

    function test_tipRequiresBothOneBpsOfAgeAndOneWholeTipStep() public {
        _credit(alice, 10_000 * STEP);
        uint256 start = block.timestamp;
        vm.warp(start + 215);
        (, uint256 tipBefore,,,) = remote.quoteFlush(_list());
        assertEq(tipBefore, 0);
        vm.warp(start + 216);
        (, uint256 tipAt,,,) = remote.quoteFlush(_list());
        assertEq(tipAt, STEP);

        _credit(bob, 49 * STEP + STEP - 1);
        vm.warp(block.timestamp + PERIOD);
        (,, address[] memory to, uint256[] memory amounts,) = remote.quoteFlush(_list());
        assertEq(to[1], bob);
        assertEq(amounts[1], 49 * STEP, "untipped dust cannot fund a tip");
        _flush(FEE);
        assertEq(remote.waiting(bob), STEP - 1);
        uint256 oldTip = imd.balanceOf(flusher);
        _credit(bob, 1);
        vm.warp(block.timestamp + PERIOD);
        _flush(FEE);
        assertEq(imd.balanceOf(flusher), oldTip, "one bridge step cannot pay one tip step");
        assertEq(remote.waiting(bob), 0);
        assertEq(remote.waitingSince(bob), 0);
    }

    /// @dev Metamorphic check: replay the same state with reversed order, duplicates, zero and
    /// empty recipients. Compare actual transfers and clocks, not a second copy of _plan.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_batchPermutationDuplicatesAndEventsPreserveEntitlements(
        uint96 rawAlice,
        uint96 rawBob,
        uint32 elapsed
    ) public {
        uint256 a = bound(rawAlice, STEP, 100_000e18);
        uint256 b = bound(rawBob, STEP, 100_000e18);
        _credit(alice, a);
        vm.warp(block.timestamp + bound(elapsed, 0, 2 days));
        _credit(bob, b);
        vm.warp(block.timestamp + bound(elapsed, 0, 2 days));
        uint256 snapshot = vm.snapshotState();
        _flush(FEE);
        bytes32 economicState = _economicState();
        (, uint256[] memory originalAmounts) =
            abi.decode(imd.lastSend().composeMsg, (address[], uint256[]));
        assertTrue(vm.revertToStateAndDelete(snapshot));

        address[] memory noisy = new address[](6);
        noisy[0] = bob;
        noisy[1] = RECEIVER; // empty queue
        noisy[2] = alice;
        noisy[3] = bob;
        noisy[4] = address(0);
        noisy[5] = alice;
        vm.recordLogs();
        vm.prank(flusher);
        bytes32 guid = remote.flush{value: FEE}(noisy);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_economicState(), economicState);
        (address[] memory to, uint256[] memory amounts) =
            abi.decode(imd.lastSend().composeMsg, (address[], uint256[]));
        assertEq(to.length, 2);
        assertEq(to[0], bob);
        assertEq(to[1], alice);
        assertEq(amounts[0], originalAmounts[1]);
        assertEq(amounts[1], originalAmounts[0]);
        uint256[] memory expectedTips = new uint256[](2);
        expectedTips[0] = b - b % STEP - amounts[0];
        expectedTips[1] = a - a % STEP - amounts[1];
        _assertDeliveryEvents(logs, guid, to, amounts, expectedTips);
    }

    function _economicState() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                imd.balanceOf(flusher),
                imd.balanceOf(address(remote)),
                imd.totalSupply(),
                remote.waiting(alice),
                remote.waitingSince(alice),
                remote.waiting(bob),
                remote.waitingSince(bob),
                remote.totalQueued(),
                remote.projectQueued(project)
            )
        );
    }

    function _assertDeliveryEvents(
        Vm.Log[] memory logs,
        bytes32 guid,
        address[] memory to,
        uint256[] memory amounts,
        uint256[] memory expectedTips
    ) internal view {
        uint256 remoteLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(remote)) continue;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[1], guid);
            if (remoteLogs < to.length) {
                assertEq(
                    logs[i].topics[0], keccak256("Delivering(bytes32,address,uint256,uint256)")
                );
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(to[remoteLogs]))));
                assertEq(logs[i].data, abi.encode(amounts[remoteLogs], expectedTips[remoteLogs]));
            } else {
                assertEq(
                    logs[i].topics[0], keccak256("Flushed(bytes32,address,uint256,uint256,uint256)")
                );
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(flusher))));
                assertEq(
                    logs[i].data,
                    abi.encode(
                        amounts[0] + amounts[1], expectedTips[0] + expectedTips[1], to.length
                    )
                );
            }
            ++remoteLogs;
        }
        assertEq(remoteLogs, to.length + 1, "one delivery per unique recipient, one batch summary");
    }
}
