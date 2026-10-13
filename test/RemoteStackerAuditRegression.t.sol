// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RemoteStacker} from "../src/multichain/RemoteStacker.sol";
import {MockOFT} from "./mocks/MockOFT.sol";

contract RemoteStackerAuditRegressionTest is Test {
    address internal constant ETH_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant ETH_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant RECEIVER = 0x1999a54f573dAc75ce8Ef62A555dba418c9B3D10;
    address internal constant VAULT = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    uint256 internal constant PERIOD = 12 hours;
    uint256 internal constant STEP = 1e12;

    MockOFT internal imd;
    RemoteStacker internal remote;
    address internal trader = makeAddr("trader");
    address internal project = makeAddr("project");
    address internal flusher = makeAddr("flusher");

    function setUp() public {
        vm.warp(1_700_000_000);
        imd = new MockOFT();
        remote = new RemoteStacker(IERC20(address(imd)), RECEIVER, VAULT, 30101);
        vm.prank(project);
        imd.approve(address(remote), type(uint256).max);
        vm.deal(flusher, 1 ether);
    }

    function _credit(uint256 amount) internal {
        imd.mint(project, amount);
        vm.prank(project);
        assertEq(remote.credit(trader, amount), amount);
    }

    function _recipients() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = trader;
    }

    // Imported finding 3a8e5fe6: these addresses have no code on the source chain,
    // but neither can recover sIMD shares on Ethereum.
    function test_credit_refusesEthereumTokenAndEndpointBeforePullingFunds() public {
        assertEq(ETH_IMD.code.length, 0);
        assertEq(ETH_ENDPOINT.code.length, 0);
        imd.mint(project, 2e18);
        address[2] memory bad = [ETH_IMD, ETH_ENDPOINT];
        vm.recordLogs();
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(RemoteStacker.InvalidTrader.selector);
            vm.prank(project);
            remote.credit(bad[i], 1e18);
            vm.expectRevert(RemoteStacker.InvalidTrader.selector);
            vm.prank(project);
            remote.credit(bad[i], 0);
            assertEq(remote.waiting(bad[i]), 0);
            assertEq(remote.waitingSince(bad[i]), 0);
        }
        assertEq(vm.getRecordedLogs().length, 0, "no points or payments");
        assertEq(remote.projectQueued(project), 0);
        assertEq(remote.totalQueued(), 0);
        assertEq(remote.totalPaid(), 0);
        assertEq(imd.balanceOf(project), 2e18);
        assertEq(imd.balanceOf(address(remote)), 0);
    }

    function test_setEthereumRecipient_refusesEthereumTokenAndEndpoint() public {
        address wallet = makeAddr("contractWallet");
        vm.etch(wallet, hex"00");
        vm.prank(wallet);
        remote.setEthereumRecipient(trader);
        address[2] memory bad = [ETH_IMD, ETH_ENDPOINT];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(RemoteStacker.InvalidRecipient.selector);
            vm.prank(wallet);
            remote.setEthereumRecipient(bad[i]);
            assertEq(remote.ethereumRecipient(wallet), trader);
        }
        imd.mint(project, 1e18);
        vm.prank(project);
        remote.credit(wallet, 1e18);
        assertEq(remote.waiting(trader), 1e18, "the prior valid recipient is preserved");
        vm.prank(wallet);
        remote.setEthereumRecipient(address(0));
        assertEq(remote.ethereumRecipient(wallet), address(0), "clearing remains allowed");
    }

    // Imported finding aaed61fe: the exact clock shift is less than a second.
    // Rounding it down used to tip the entire fresh credit at the capped rate.
    function test_clockRounding_smallFreshCreditCannotInheritTheFullTip() public {
        _credit(1_000_000e18);
        uint256 start = block.timestamp;
        vm.warp(start + PERIOD);
        (, uint256 beforeTip,,,) = remote.quoteFlush(_recipients());
        assertEq(beforeTip, 20_000e18);
        _credit(1e15);
        (, uint256 tip,,, uint256 fee) = remote.quoteFlush(_recipients());
        assertLe(tip, beforeTip, "fresh cashback cannot increase the capped old tip");
        assertEq(remote.waitingSince(trader), start + 1, "round toward the trader");
        vm.prank(flusher);
        remote.flush{value: fee}(_recipients());
        assertEq(imd.balanceOf(flusher), tip);
        assertEq(imd.lastSend().amountLD + tip, 1_000_000e18 + 1e15);
        assertEq(remote.waiting(trader), 0);
        assertEq(remote.waitingSince(trader), 0);
        _credit(STEP);
        assertEq(remote.waitingSince(trader), block.timestamp, "a drained queue starts fresh");
        assertEq(remote.tipBps(trader), 0);
    }

    function test_clockRounding_uncappedBalanceAlsoFavorsTrader() public {
        _credit(1_000_000e18);
        uint256 start = block.timestamp;
        vm.warp(start + 6 hours);
        (, uint256 beforeTip,,,) = remote.quoteFlush(_recipients());
        assertEq(beforeTip, 10_000e18);
        _credit(1e15);
        (, uint256 tip,,,) = remote.quoteFlush(_recipients());
        assertLe(tip, beforeTip);
        assertEq(remote.waitingSince(trader), start + 1);
    }

    function testFuzz_clockRounding_doesNotChargeForFreshAge(
        uint96 oldAmount,
        uint96 freshAmount,
        uint32 elapsed
    ) public {
        uint256 old = bound(oldAmount, 1, 1_000_000e18);
        uint256 fresh = bound(freshAmount, 1, 1_000_000e18);
        uint256 age = bound(elapsed, 0, 30 days);
        _credit(old);
        uint256 start = block.timestamp;
        vm.warp(start + age);
        _credit(fresh);

        uint256 cappedAge = age > PERIOD ? PERIOD : age;
        uint256 since = remote.waitingSince(trader);
        uint256 total = old + fresh;
        uint256 weightedArrival = (block.timestamp - cappedAge) * old + block.timestamp * fresh;
        assertLe(since, block.timestamp, "clock must not move into the future");
        assertGe(since * total, weightedArrival, "never round arrival down");
        assertLt((since - 1) * total, weightedArrival, "no more than one second of rounding");
        (, uint256 tip,,,) = remote.quoteFlush(_recipients());
        assertLe(tip, old * cappedAge * 200 / PERIOD / 10_000, "only old age earns a tip");
        assertEq(remote.waiting(trader), total);
        assertEq(imd.balanceOf(address(remote)), total);
    }

    // Imported informational finding b5a69a21: the OFT controls the sole exit.
    // Its refusal rolls back every balance; RemoteStacker cannot bypass it.
    function test_bridgeRefusal_preservesCustodyAndContinuesAcceptingCredits() public {
        _credit(3e18 + 7);
        uint256 since = remote.waitingSince(trader);
        vm.warp(block.timestamp + PERIOD);
        imd.setRefuseSend(true);
        vm.expectRevert(MockOFT.SendRefused.selector);
        vm.prank(flusher);
        remote.flush{value: 0.001 ether}(_recipients());
        assertEq(remote.waiting(trader), 3e18 + 7);
        assertEq(remote.waitingSince(trader), since);
        assertEq(imd.balanceOf(address(remote)), 3e18 + 7);
        assertEq(imd.balanceOf(flusher), 0);
        assertEq(flusher.balance, 1 ether);
        assertEq(imd.sendCount(), 0);
        _credit(1e18);
        vm.expectRevert(MockOFT.SendRefused.selector);
        vm.prank(flusher);
        remote.flush{value: 0.001 ether}(_recipients());
        assertEq(remote.waiting(trader), 4e18 + 7);
        assertEq(remote.totalQueued(), 4e18 + 7);
        imd.setRefuseSend(false);
        (uint256 delivered, uint256 tip,,, uint256 fee) = remote.quoteFlush(_recipients());
        vm.prank(flusher);
        remote.flush{value: fee}(_recipients());
        assertEq(delivered + tip + remote.waiting(trader), 4e18 + 7);
        assertEq(remote.waiting(trader), 7);
        assertEq(imd.balanceOf(address(remote)), 7);
        assertEq(imd.balanceOf(flusher), tip);
    }
}
