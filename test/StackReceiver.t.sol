// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOFT, MockEndpoint} from "./mocks/MockOFT.sol";
import {TestSIMD} from "./mocks/TestSIMD.sol";
import {StackReceiver, IStakedIMD} from "../src/multichain/StackReceiver.sol";

contract StackReceiverTest is Test {
    address internal constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    uint32 internal constant RH_EID = 30416;
    uint256 internal constant SHARES_PER_IMD = 1e6;

    MockOFT internal imd; // plays IMD on Ethereum: the endpoint mock mints into it on arrival
    TestSIMD internal sImd;
    MockEndpoint internal endpoint;
    StackReceiver internal receiver;
    address internal remote = address(0x4E);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        imd = new MockOFT();
        sImd = new TestSIMD(address(imd), OWNER);
        endpoint = new MockEndpoint();
        receiver =
            new StackReceiver(IERC20(address(imd)), IStakedIMD(address(sImd)), address(endpoint));
    }

    function list(address a, uint256 x, address b, uint256 y) internal pure returns (bytes memory) {
        address[] memory t = new address[](2);
        uint256[] memory n = new uint256[](2);
        t[0] = a;
        t[1] = b;
        n[0] = x;
        n[1] = y;
        return abi.encode(t, n);
    }

    function deliver(uint256 amount, bytes memory composeMsg) internal {
        endpoint.deliver(
            address(imd),
            address(receiver),
            bytes32(uint256(1)),
            1,
            RH_EID,
            amount,
            remote,
            composeMsg,
            1_000_000
        );
    }

    function test_constructor_wiringWithoutExternalCalls() public {
        vm.expectRevert(StackReceiver.ZeroAddress.selector);
        new StackReceiver(IERC20(address(0)), IStakedIMD(address(sImd)), address(endpoint));
        vm.expectRevert(StackReceiver.ZeroAddress.selector);
        new StackReceiver(IERC20(address(imd)), IStakedIMD(address(0)), address(endpoint));
        vm.expectRevert(StackReceiver.ZeroAddress.selector);
        new StackReceiver(IERC20(address(imd)), IStakedIMD(address(sImd)), address(0));
        StackReceiver r = new StackReceiver(
            IERC20(address(0xDEAD1)), IStakedIMD(address(0xDEAD2)), address(0xDEAD3)
        );
        assertEq(address(r.IMD()), address(0xDEAD1));
        assertEq(address(r.SIMD()), address(0xDEAD2));
        assertEq(r.ENDPOINT(), address(0xDEAD3));
    }

    function test_delivery_depositsForEachTraderAndKeepsNothing() public {
        vm.expectEmit(true, true, true, true);
        emit StackReceiver.Delivered(
            bytes32(uint256(1)), RH_EID, alice, 3e18, 3e18 * SHARES_PER_IMD
        );
        vm.expectEmit(true, true, true, true);
        emit StackReceiver.Delivered(bytes32(uint256(1)), RH_EID, bob, 2e18, 2e18 * SHARES_PER_IMD);
        deliver(5e18, list(alice, 3e18, bob, 2e18));
        assertEq(sImd.balanceOf(alice), 3e18 * SHARES_PER_IMD);
        assertEq(sImd.balanceOf(bob), 2e18 * SHARES_PER_IMD);
        assertEq(imd.balanceOf(address(receiver)), 0);
        assertEq(sImd.balanceOf(address(receiver)), 0);
        assertEq(receiver.totalDelivered(), 5e18);
        assertEq(receiver.deliveredFrom(RH_EID), 5e18);
        assertEq(imd.allowance(address(receiver), address(sImd)), type(uint256).max);
        // The vault's one-block hold applies to the trader, as with any deposit.
        vm.prank(alice);
        vm.expectRevert();
        sImd.redeem(1, alice, alice);
        vm.roll(block.number + 1);
        vm.prank(alice);
        sImd.redeem(3e18 * SHARES_PER_IMD, alice, alice);
        assertEq(imd.balanceOf(alice), 3e18);
    }

    function test_delivery_onlyFromTheEndpointAndOnlyForIMD() public {
        bytes memory message = endpoint.encode(1, RH_EID, 1e18, remote, list(alice, 1e18, bob, 0));
        imd.mint(address(receiver), 1e18);
        vm.expectRevert(StackReceiver.NotEndpoint.selector);
        receiver.lzCompose(address(imd), bytes32(0), message, address(this), "");
        vm.expectRevert(StackReceiver.NotIMD.selector);
        endpoint.compose(address(0xBAD), address(receiver), bytes32(0), message);
        assertEq(sImd.balanceOf(alice), 0);
        endpoint.compose(address(imd), address(receiver), bytes32(0), message);
        assertEq(sImd.balanceOf(alice), 1e18 * SHARES_PER_IMD);
    }

    function test_delivery_listMustAddUpToTheAmountReceived() public {
        imd.mint(address(receiver), 1e18);
        bytes memory more = endpoint.encode(1, RH_EID, 1e18, remote, list(alice, 1e18, bob, 1));
        vm.expectRevert(
            abi.encodeWithSelector(StackReceiver.AmountMismatch.selector, 1e18 + 1, 1e18)
        );
        endpoint.compose(address(imd), address(receiver), bytes32(0), more);
        bytes memory less = endpoint.encode(1, RH_EID, 1e18, remote, list(alice, 1e18 - 1, bob, 0));
        vm.expectRevert(
            abi.encodeWithSelector(StackReceiver.AmountMismatch.selector, 1e18 - 1, 1e18)
        );
        endpoint.compose(address(imd), address(receiver), bytes32(0), less);
        address[] memory t = new address[](1);
        uint256[] memory n = new uint256[](2);
        bytes memory uneven = endpoint.encode(1, RH_EID, 0, remote, abi.encode(t, n));
        vm.expectRevert(StackReceiver.BadList.selector);
        endpoint.compose(address(imd), address(receiver), bytes32(0), uneven);
        bytes memory empty =
            endpoint.encode(1, RH_EID, 0, remote, abi.encode(new address[](0), new uint256[](0)));
        vm.expectRevert(StackReceiver.BadList.selector);
        endpoint.compose(address(imd), address(receiver), bytes32(0), empty);
        bytes memory garbage = endpoint.encode(1, RH_EID, 1e18, remote, hex"deadbeef");
        vm.expectRevert();
        endpoint.compose(address(imd), address(receiver), bytes32(0), garbage);
        assertEq(imd.balanceOf(address(receiver)), 1e18, "nothing moved");
    }

    function test_delivery_pausedVaultPaysPlainIMD() public {
        vm.prank(OWNER);
        sImd.setPaused(true);
        vm.expectEmit(true, true, true, true);
        emit StackReceiver.DeliveredPlain(bytes32(uint256(1)), RH_EID, alice, 3e18);
        deliver(5e18, list(alice, 3e18, bob, 2e18));
        assertEq(imd.balanceOf(alice), 3e18);
        assertEq(imd.balanceOf(bob), 2e18);
        assertEq(sImd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(address(receiver)), 0);
        assertEq(receiver.totalDelivered(), 5e18);
        // Unpaused later: deposits again, the approval set on the first delivery still there.
        vm.prank(OWNER);
        sImd.setPaused(false);
        deliver(1e18, list(alice, 1e18, bob, 0));
        assertEq(sImd.balanceOf(alice), 1e18 * SHARES_PER_IMD);
    }

    function test_delivery_zeroAmountEntryIsSkipped() public {
        deliver(1e18, list(alice, 0, bob, 1e18));
        assertEq(sImd.balanceOf(alice), 0);
        assertEq(sImd.balanceOf(bob), 1e18 * SHARES_PER_IMD);
    }

    function test_delivery_assetMismatchRefusesTheFirstDelivery() public {
        MockOFT other = new MockOFT();
        StackReceiver r =
            new StackReceiver(IERC20(address(other)), IStakedIMD(address(sImd)), address(endpoint));
        other.mint(address(r), 1e18);
        bytes memory message = endpoint.encode(1, RH_EID, 1e18, remote, list(alice, 1e18, bob, 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                StackReceiver.AssetMismatch.selector, address(imd), address(other)
            )
        );
        endpoint.compose(address(other), address(r), bytes32(0), message);
    }

    function test_delivery_strayIMDIsNeverSpent() public {
        imd.mint(address(receiver), 7e18); // a plain bridge send with no compose, or a mistake
        deliver(1e18, list(alice, 1e18, bob, 0));
        assertEq(imd.balanceOf(address(receiver)), 7e18);
    }

    /// @dev Reproduces the asset movement behind audit b9d7d08ba346: returning zero is not a revert.
    function test_vault_zeroShareDepositStillConsumesAssets() public {
        imd.mint(address(sImd), 3e24);
        assertEq(sImd.previewDeposit(3e18), 0);
        imd.mint(address(this), 3e18);
        imd.approve(address(sImd), 3e18);
        assertEq(sImd.deposit(3e18, alice), 0);
        assertEq(imd.balanceOf(address(this)), 0, "vault consumed the deposit");
        assertEq(imd.balanceOf(address(sImd)), 3e24 + 3e18);
        assertEq(sImd.balanceOf(alice), 0, "no shares minted");
    }

    function test_delivery_zeroSharesPaysPlainIMDWithoutDepositing() public {
        // The real Solady rounding path, with no mocked preview or deposit return value.
        imd.mint(address(sImd), 3e24);
        imd.mint(address(receiver), 7e18); // unsolicited IMD must not fund the fallback
        assertEq(sImd.previewDeposit(3e18), 0);
        assertEq(sImd.previewDeposit(2e18), 0);
        vm.expectEmit(true, true, true, true, address(receiver));
        emit StackReceiver.DeliveredPlain(bytes32(uint256(1)), RH_EID, alice, 3e18);
        vm.expectEmit(true, true, true, true, address(receiver));
        emit StackReceiver.DeliveredPlain(bytes32(uint256(1)), RH_EID, bob, 2e18);
        deliver(5e18, list(alice, 3e18, bob, 2e18));
        assertEq(imd.balanceOf(alice), 3e18);
        assertEq(imd.balanceOf(bob), 2e18);
        assertEq(imd.balanceOf(address(receiver)), 7e18);
        assertEq(imd.balanceOf(address(sImd)), 3e24, "no zero-share deposit attempted");
        assertEq(sImd.totalSupply(), 0);
        assertEq(receiver.totalDelivered(), 5e18);
        assertEq(receiver.deliveredFrom(RH_EID), 5e18);
    }

    function testFuzz_delivery_mixedZeroAndPositiveShares(
        uint96 plainRaw,
        uint96 stakedRaw,
        bool plainFirst
    ) public {
        uint256 plain = bound(uint256(plainRaw), 1, 2e12);
        uint256 staked = bound(uint256(stakedRaw), 2e12 + 1, 1e18);
        imd.mint(address(sImd), 2e18);
        assertEq(sImd.previewDeposit(plain), 0);
        uint256 shares = sImd.previewDeposit(staked);
        assertGt(shares, 0);
        bytes memory payload =
            plainFirst ? list(alice, plain, bob, staked) : list(bob, staked, alice, plain);
        if (plainFirst) {
            vm.expectEmit(true, true, true, true, address(receiver));
            emit StackReceiver.DeliveredPlain(bytes32(uint256(1)), RH_EID, alice, plain);
            vm.expectEmit(true, true, true, true, address(receiver));
            emit StackReceiver.Delivered(bytes32(uint256(1)), RH_EID, bob, staked, shares);
        } else {
            vm.expectEmit(true, true, true, true, address(receiver));
            emit StackReceiver.Delivered(bytes32(uint256(1)), RH_EID, bob, staked, shares);
            vm.expectEmit(true, true, true, true, address(receiver));
            emit StackReceiver.DeliveredPlain(bytes32(uint256(1)), RH_EID, alice, plain);
        }
        deliver(plain + staked, payload);
        assertEq(imd.balanceOf(alice), plain);
        assertEq(sImd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(sImd.balanceOf(bob), shares);
        assertEq(imd.balanceOf(address(sImd)), 2e18 + staked);
        assertEq(imd.balanceOf(address(receiver)), 0);
        assertEq(receiver.totalDelivered(), plain + staked);
        assertEq(receiver.deliveredFrom(RH_EID), plain + staked);
    }

    function test_delivery_revertingPreviewPaysOnlyThatTraderPlainIMD() public {
        vm.mockCallRevert(
            address(sImd), abi.encodeWithSelector(sImd.previewDeposit.selector, 3e18), "no preview"
        );
        vm.expectEmit(true, true, true, true, address(receiver));
        emit StackReceiver.DeliveredPlain(bytes32(uint256(1)), RH_EID, alice, 3e18);
        vm.expectEmit(true, true, true, true, address(receiver));
        emit StackReceiver.Delivered(bytes32(uint256(1)), RH_EID, bob, 2e18, 2e24);
        deliver(5e18, list(alice, 3e18, bob, 2e18));
        assertEq(imd.balanceOf(alice), 3e18);
        assertEq(sImd.balanceOf(alice), 0);
        assertEq(sImd.balanceOf(bob), 2e24);
        assertEq(imd.balanceOf(address(sImd)), 2e18);
        assertEq(imd.balanceOf(address(receiver)), 0);
        assertEq(receiver.totalDelivered(), 5e18);
        assertEq(receiver.deliveredFrom(RH_EID), 5e18);
    }

    function test_delivery_revertingDepositPaysOnlyThatTraderPlainIMD() public {
        assertGt(sImd.previewDeposit(3e18), 0);
        vm.mockCallRevert(
            address(sImd), abi.encodeWithSelector(sImd.deposit.selector, 3e18, alice), "no deposit"
        );
        vm.expectEmit(true, true, true, true, address(receiver));
        emit StackReceiver.DeliveredPlain(bytes32(uint256(1)), RH_EID, alice, 3e18);
        vm.expectEmit(true, true, true, true, address(receiver));
        emit StackReceiver.Delivered(bytes32(uint256(1)), RH_EID, bob, 2e18, 2e24);
        deliver(5e18, list(alice, 3e18, bob, 2e18));
        assertEq(imd.balanceOf(alice), 3e18);
        assertEq(sImd.balanceOf(alice), 0);
        assertEq(sImd.balanceOf(bob), 2e24);
        assertEq(imd.balanceOf(address(sImd)), 2e18);
        assertEq(imd.balanceOf(address(receiver)), 0);
        assertEq(receiver.totalDelivered(), 5e18);
        assertEq(receiver.deliveredFrom(RH_EID), 5e18);
    }

    function test_delivery_inconsistentPreviewRollsBackInsteadOfSpendingOtherFunds() public {
        imd.mint(address(sImd), 3e24);
        imd.mint(address(receiver), 12e18); // 5 IMD arrived; 7 IMD is unrelated
        bytes memory message =
            endpoint.encode(1, RH_EID, 5e18, remote, list(alice, 3e18, bob, 2e18));
        // A nonconforming vault: preview claims positive shares but the actual deposit mints zero.
        vm.mockCall(
            address(sImd), abi.encodeWithSelector(sImd.previewDeposit.selector, 3e18), abi.encode(1)
        );
        vm.expectRevert(StackReceiver.ZeroShares.selector);
        endpoint.compose(address(imd), address(receiver), bytes32(uint256(1)), message);
        assertEq(imd.balanceOf(address(receiver)), 12e18);
        assertEq(imd.balanceOf(address(sImd)), 3e24);
        assertEq(imd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(bob), 0);
        assertEq(sImd.totalSupply(), 0);
        assertEq(receiver.totalDelivered(), 0);
        assertEq(receiver.deliveredFrom(RH_EID), 0);
        assertEq(imd.allowance(address(receiver), address(sImd)), 0);

        vm.clearMockedCalls();
        endpoint.compose(address(imd), address(receiver), bytes32(uint256(1)), message);
        assertEq(imd.balanceOf(alice), 3e18);
        assertEq(imd.balanceOf(bob), 2e18);
        assertEq(imd.balanceOf(address(receiver)), 7e18);
        assertEq(receiver.totalDelivered(), 5e18);
    }

    /// @dev Audit 9b5ea0014338: the payable LayerZero ABI must not trap an executor's ETH.
    function test_delivery_rejectsNativeValueAndCanRetryWithoutIt() public {
        bytes memory message =
            endpoint.encode(1, RH_EID, 5e18, remote, list(alice, 3e18, bob, 2e18));
        imd.mint(address(receiver), 5e18);
        vm.deal(address(endpoint), 1);
        vm.expectRevert(StackReceiver.UnexpectedValue.selector);
        vm.prank(address(endpoint));
        receiver.lzCompose{value: 1}(address(imd), bytes32(uint256(1)), message, address(this), "");
        assertEq(address(receiver).balance, 0);
        assertEq(address(endpoint).balance, 1, "value returned to caller");
        assertEq(imd.balanceOf(address(receiver)), 5e18, "arrival preserved for retry");
        assertEq(sImd.totalSupply(), 0);
        assertEq(receiver.totalDelivered(), 0);
        assertEq(receiver.deliveredFrom(RH_EID), 0);
        assertEq(imd.allowance(address(receiver), address(sImd)), 0);

        endpoint.compose(address(imd), address(receiver), bytes32(uint256(1)), message);
        assertEq(sImd.balanceOf(alice), 3e24);
        assertEq(sImd.balanceOf(bob), 2e24);
        assertEq(imd.balanceOf(address(receiver)), 0);
        assertEq(receiver.totalDelivered(), 5e18);
        assertEq(receiver.deliveredFrom(RH_EID), 5e18);
    }

    function testFuzz_delivery_sumExactlyDelivered(uint96 x, uint96 y) public {
        vm.assume(x > 0 && y > 0);
        deliver(uint256(x) + y, list(alice, x, bob, y));
        assertEq(sImd.balanceOf(alice), uint256(x) * SHARES_PER_IMD);
        assertEq(sImd.balanceOf(bob), uint256(y) * SHARES_PER_IMD);
        assertEq(imd.balanceOf(address(receiver)), 0);
    }
}
