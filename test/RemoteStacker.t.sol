// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOFT} from "./mocks/MockOFT.sol";
import {RemoteStacker} from "../src/multichain/RemoteStacker.sol";
import {SendParam} from "../src/multichain/LayerZero.sol";

/// @dev A smart-contract wallet (a Safe stand-in): has code, may register an Ethereum recipient.
contract ContractWallet {
    function register(RemoteStacker r, address to) external {
        r.setEthereumRecipient(to);
    }
}

/// @dev A project that credits through the RemoteStacker (holds IMD, approved it once).
contract RemoteProject {
    RemoteStacker public immutable r;

    constructor(RemoteStacker r_, IERC20 imd) {
        r = r_;
        imd.approve(address(r_), type(uint256).max);
    }

    function credit(address trader, uint256 amount) external returns (uint256) {
        return r.credit(trader, amount);
    }
}

contract RemoteStackerTest is Test {
    uint32 internal constant ETH_EID = 30101;
    address internal constant RECEIVER = address(0xACC0);
    address internal constant VAULT = address(0x5A17);
    uint256 internal constant STEP = 1e12;

    MockOFT internal imd;
    RemoteStacker internal rs;
    RemoteProject internal project;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal flusher = address(0xF1);

    function setUp() public {
        vm.warp(1_700_000_000);
        imd = new MockOFT();
        rs = new RemoteStacker(IERC20(address(imd)), RECEIVER, VAULT, ETH_EID);
        project = new RemoteProject(rs, IERC20(address(imd)));
        imd.mint(address(project), 1_000_000e18);
        vm.deal(flusher, 10 ether);
    }

    function one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    // ------------------------------------------------------------ constructor

    function test_constructor_wiringWithoutExternalCalls() public {
        vm.expectRevert(RemoteStacker.ZeroAddress.selector);
        new RemoteStacker(IERC20(address(0)), RECEIVER, VAULT, ETH_EID);
        vm.expectRevert(RemoteStacker.ZeroAddress.selector);
        new RemoteStacker(IERC20(address(imd)), address(0), VAULT, ETH_EID);
        vm.expectRevert(RemoteStacker.ZeroAddress.selector);
        new RemoteStacker(IERC20(address(imd)), RECEIVER, address(0), ETH_EID);
        // Deploys with a token address that has no code: the launch's empty-chain rehearsal.
        RemoteStacker r = new RemoteStacker(IERC20(address(0xDEAD1)), RECEIVER, VAULT, ETH_EID);
        assertEq(address(r.IMD()), address(0xDEAD1));
        assertEq(r.RECEIVER(), RECEIVER);
        assertEq(r.VAULT(), VAULT);
        assertEq(r.DST_EID(), ETH_EID);
    }

    // ------------------------------------------------------------ credit

    function test_credit_queuesForPlainWallet() public {
        vm.expectEmit(true, true, true, true);
        emit RemoteStacker.Queued(address(project), alice, alice, 5e18);
        assertEq(project.credit(alice, 5e18), 5e18);
        assertEq(rs.waiting(alice), 5e18);
        assertEq(rs.waitingSince(alice), block.timestamp);
        assertEq(rs.projectQueued(address(project)), 5e18);
        assertEq(rs.totalQueued(), 5e18);
        assertEq(imd.balanceOf(address(rs)), 5e18);
    }

    function test_credit_rejectsInvalidTraders() public {
        vm.expectRevert(RemoteStacker.ZeroTrader.selector);
        project.credit(address(0), 1e18);
        address[4] memory bad = [address(rs), address(imd), RECEIVER, VAULT];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(RemoteStacker.InvalidTrader.selector);
            project.credit(bad[i], 1e18);
        }
    }

    function test_credit_zeroAmountMovesNothing() public {
        assertEq(project.credit(alice, 0), 0);
        assertEq(rs.waiting(alice), 0);
        assertEq(imd.balanceOf(address(rs)), 0);
    }

    function test_credit_shortAllowanceOrBalanceReverts() public {
        address poor = address(0x900);
        vm.prank(poor);
        imd.approve(address(rs), 1e18);
        vm.prank(poor);
        vm.expectRevert();
        rs.credit(alice, 1e18);
        imd.mint(poor, 1e18);
        vm.prank(poor);
        vm.expectRevert();
        rs.credit(alice, 2e18);
    }

    function test_credit_clockIsAmountWeighted() public {
        project.credit(alice, 1e18);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 12 hours);
        project.credit(alice, 3e18); // three quarters of the balance arrived 12 hours later
        assertEq(rs.waiting(alice), 4e18);
        assertEq(rs.waitingSince(alice), t0 + 9 hours);
        // waited 3 hours on average now: tip 2% * 3/12 = 0.5%
        assertEq(rs.tipBps(alice), 50);
        vm.warp(t0 + 21 hours); // 12 hours since the weighted arrival: the cap
        assertEq(rs.tipBps(alice), 200);
    }

    function test_credit_contractWalletPaidPlainUnlessRegistered() public {
        ContractWallet w = new ContractWallet();
        vm.expectEmit(true, true, true, true);
        emit RemoteStacker.Paid(address(project), address(w), 2e18);
        assertEq(project.credit(address(w), 2e18), 0);
        assertEq(imd.balanceOf(address(w)), 2e18);
        assertEq(rs.waiting(address(w)), 0);
        assertEq(rs.totalPaid(), 2e18);
        assertEq(rs.totalQueued(), 0);

        w.register(rs, bob);
        assertEq(rs.ethereumRecipient(address(w)), bob);
        vm.expectEmit(true, true, true, true);
        emit RemoteStacker.Queued(address(project), address(w), bob, 3e18);
        assertEq(project.credit(address(w), 3e18), 3e18);
        assertEq(rs.waiting(bob), 3e18);
        assertEq(rs.waiting(address(w)), 0);

        w.register(rs, address(0)); // cleared: paid here again
        assertEq(project.credit(address(w), 1e18), 0);
        assertEq(imd.balanceOf(address(w)), 3e18);
    }

    function test_setEthereumRecipient_refusesInvalidAndIsPerCaller() public {
        address[4] memory bad = [address(rs), address(imd), RECEIVER, VAULT];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(RemoteStacker.InvalidRecipient.selector);
            rs.setEthereumRecipient(bad[i]);
        }
        vm.prank(alice);
        rs.setEthereumRecipient(bob);
        assertEq(rs.ethereumRecipient(alice), bob);
        assertEq(rs.ethereumRecipient(bob), address(0));
        // A plain wallet's registration is ignored: it exists on Ethereum itself.
        project.credit(alice, 1e18);
        assertEq(rs.waiting(alice), 1e18);
        assertEq(rs.waiting(bob), 0);
    }

    function test_credit_eip7702WalletGoesThroughTheQueue() public {
        address delegated = address(0x7702);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        assertEq(delegated.code.length, 23);
        assertEq(project.credit(delegated, 1e18), 1e18);
        assertEq(rs.waiting(delegated), 1e18);
        // 23 bytes of code that are not a delegation designator: a contract wallet.
        address odd = address(0x0DD);
        vm.etch(odd, abi.encodePacked(hex"600100", address(0xBEEF)));
        assertEq(project.credit(odd, 1e18), 0);
        assertEq(imd.balanceOf(odd), 1e18);
    }

    // ------------------------------------------------------------ tips

    function test_tip_growsLinearlyAndCapsAtTwoPercent() public {
        project.credit(alice, 100e18);
        assertEq(rs.tipBps(alice), 0);
        vm.warp(block.timestamp + 3 hours);
        assertEq(rs.tipBps(alice), 50);
        vm.warp(block.timestamp + 3 hours);
        assertEq(rs.tipBps(alice), 100);
        vm.warp(block.timestamp + 6 hours);
        assertEq(rs.tipBps(alice), 200);
        vm.warp(block.timestamp + 10 days);
        assertEq(rs.tipBps(alice), 200);
        assertEq(rs.tipBps(bob), 0);
    }

    function testFuzz_tip_neverAboveTwoPercent(uint64 waited, uint96 amount) public {
        amount = uint96(bound(amount, 1, 1_000e18));
        project.credit(alice, amount);
        vm.warp(block.timestamp + waited);
        uint256 bps = rs.tipBps(alice);
        assertLe(bps, 200);
        assertEq(bps, waited >= 12 hours ? 200 : uint256(200) * waited / 12 hours);
    }

    // ------------------------------------------------------------ flush

    function test_flush_sendsRoundedAmountsPaysTipAndRefundsExcess() public {
        project.credit(alice, 10e18 + 7); // 7 wei of dust below the bridge step
        project.credit(bob, 4e18);
        vm.warp(block.timestamp + 6 hours); // tip 1%
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        (uint256 imdOut, uint256 tip, address[] memory to, uint256[] memory amounts, uint256 fee) =
            rs.quoteFlush(list);
        uint256 aliceTip = uint256(10e18 + 7) * 100 / 10_000;
        uint256 bobTip = 4e18 * 100 / 10_000;
        uint256 aliceOut = (uint256(10e18 + 7) - aliceTip) / STEP * STEP;
        uint256 bobOut = (4e18 - bobTip) / STEP * STEP;
        assertEq(imdOut, aliceOut + bobOut);
        assertEq(tip, aliceTip + bobTip);
        assertEq(to.length, 2);
        assertEq(amounts[0], aliceOut);
        assertEq(amounts[1], bobOut);
        assertEq(fee, imd.nativeFee());

        uint256 flusherEth = flusher.balance;
        vm.prank(flusher);
        bytes32 guid = rs.flush{value: fee + 0.5 ether}(list);
        assertEq(flusher.balance, flusherEth - fee, "excess native refunded");
        assertEq(imd.balanceOf(flusher), tip, "tip paid in IMD");
        assertEq(rs.waiting(alice), uint256(10e18 + 7) - aliceTip - aliceOut, "dust stays");
        assertEq(rs.waiting(bob), 4e18 - bobTip - bobOut);
        assertEq(imd.balanceOf(address(rs)), rs.waiting(alice) + rs.waiting(bob));

        MockOFT.Sent memory s = imd.lastSend();
        assertEq(s.guid, guid);
        assertEq(s.from, address(rs));
        assertEq(s.amountLD, imdOut);
        assertEq(s.param.dstEid, ETH_EID);
        assertEq(s.param.to, bytes32(uint256(uint160(RECEIVER))));
        assertEq(s.param.minAmountLD, imdOut);
        (address[] memory t, uint256[] memory a) =
            abi.decode(s.param.composeMsg, (address[], uint256[]));
        assertEq(t.length, 2);
        assertEq(t[0], alice);
        assertEq(a[0], aliceOut);
        assertEq(t[1], bob);
        assertEq(a[1], bobOut);
        // Options: type 3, lzReceive 250k, lzCompose index 0 with the base plus two traders' gas.
        bytes memory expected = abi.encodePacked(
            uint16(3),
            uint8(1),
            uint16(17),
            uint8(1),
            uint128(250_000),
            uint8(1),
            uint16(19),
            uint8(3),
            uint16(0),
            uint128(200_000 + 2 * 80_000)
        );
        assertEq(s.param.extraOptions, expected);
        assertEq(s.param.oftCmd, "");
    }

    function test_flush_skipsEmptyAndDuplicateAndDustOnlyRecipients() public {
        project.credit(alice, 3e18);
        project.credit(bob, 5); // below the bridge step: nothing to deliver
        address[] memory list = new address[](4);
        list[0] = alice;
        list[1] = address(0xEEE);
        list[2] = alice;
        list[3] = bob;
        (uint256 imdOut,, address[] memory to,,) = rs.quoteFlush(list);
        assertEq(to.length, 1);
        assertEq(to[0], alice);
        assertEq(imdOut, 3e18);
        vm.prank(flusher);
        rs.flush{value: 0.001 ether}(list);
        assertEq(rs.waiting(alice), 0);
        assertEq(rs.waitingSince(alice), 0);
        assertEq(rs.waiting(bob), 5);
        assertEq(imd.balanceOf(address(rs)), 5);
    }

    function test_flush_nothingToFlushReverts() public {
        vm.prank(flusher);
        vm.expectRevert(RemoteStacker.NothingToFlush.selector);
        rs.flush{value: 0.001 ether}(one(alice));
        project.credit(alice, 5);
        vm.prank(flusher);
        vm.expectRevert(RemoteStacker.NothingToFlush.selector);
        rs.flush{value: 0.001 ether}(one(alice));
        (uint256 imdOut, uint256 tip,,, uint256 fee) = rs.quoteFlush(one(alice));
        assertEq(imdOut + tip + fee, 0);
    }

    function test_flush_atMostFiftyRecipients() public {
        address[] memory list = new address[](51);
        for (uint256 i; i < 51; ++i) {
            list[i] = address(uint160(0x1000 + i));
        }
        vm.expectRevert(RemoteStacker.TooManyTraders.selector);
        rs.quoteFlush(list);
        vm.prank(flusher);
        vm.expectRevert(RemoteStacker.TooManyTraders.selector);
        rs.flush{value: 0.001 ether}(list);
    }

    function test_flush_isAtomic_sendFailureChangesNothing() public {
        project.credit(alice, 3e18);
        vm.warp(block.timestamp + 1 days);
        imd.setRefuseSend(true);
        vm.prank(flusher);
        vm.expectRevert(MockOFT.SendRefused.selector);
        rs.flush{value: 0.001 ether}(one(alice));
        assertEq(rs.waiting(alice), 3e18);
        assertEq(imd.balanceOf(flusher), 0);
        imd.setRefuseSend(false);
        // Too little native fee: the bridge refuses, nothing changes.
        vm.prank(flusher);
        vm.expectRevert();
        rs.flush{value: 0.0001 ether}(one(alice));
        assertEq(rs.waiting(alice), 3e18);
        assertEq(imd.balanceOf(address(rs)), 3e18);
    }

    function test_flush_traderCanFlushThemselvesAtOnce() public {
        project.credit(alice, 3e18);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        rs.flush{value: 0.001 ether}(one(alice));
        assertEq(rs.waiting(alice), 0);
        assertEq(imd.balanceOf(alice), 0, "no tip at once");
        assertEq(imd.lastSend().amountLD, 3e18);
    }

    function test_flush_fiftyRecipients() public {
        address[] memory list = new address[](50);
        for (uint256 i; i < 50; ++i) {
            list[i] = address(uint160(0x2000 + i));
            project.credit(list[i], (i + 1) * 1e18);
        }
        vm.warp(block.timestamp + 12 hours);
        (uint256 imdOut, uint256 tip, address[] memory to,,) = rs.quoteFlush(list);
        assertEq(to.length, 50);
        assertEq(imdOut + tip, 1275e18);
        assertEq(tip, 1275e18 * 200 / 10_000);
        vm.prank(flusher);
        rs.flush{value: 0.001 ether}(list);
        assertEq(imd.balanceOf(address(rs)), 0);
        assertEq(imd.balanceOf(flusher), tip);
        bytes memory opts = imd.lastSend().param.extraOptions;
        bytes memory expected = abi.encodePacked(
            uint16(3),
            uint8(1),
            uint16(17),
            uint8(1),
            uint128(250_000),
            uint8(1),
            uint16(19),
            uint8(3),
            uint16(0),
            uint128(200_000 + 50 * 80_000)
        );
        assertEq(opts, expected);
    }

    function testFuzz_flush_conservesEveryWei(uint96 a, uint96 b, uint32 waited) public {
        a = uint96(bound(a, 1, 10_000e18));
        b = uint96(bound(b, 1, 10_000e18));
        project.credit(alice, a);
        project.credit(bob, b);
        vm.warp(block.timestamp + waited);
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        (uint256 imdOut, uint256 tip,,,) = rs.quoteFlush(list);
        if (imdOut == 0) return;
        vm.prank(flusher);
        rs.flush{value: 0.001 ether}(list);
        assertEq(imd.balanceOf(address(rs)), rs.waiting(alice) + rs.waiting(bob));
        assertEq(rs.waiting(alice) + rs.waiting(bob) + imdOut + tip, uint256(a) + b);
        assertEq(imdOut % STEP, 0);
        assertLe(tip, (uint256(a) + b) * 200 / 10_000);
        assertEq(imd.balanceOf(flusher), tip);
    }
}
