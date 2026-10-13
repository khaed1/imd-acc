// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RemoteStacker} from "src/multichain/RemoteStacker.sol";
import {RemoteRefundProbe} from "./RemoteStackerAdversarial.t.sol";

/// @dev Optional live integration at the brief's Robinhood Chain block. Source:
/// https://robinhood-rpc.publicnode.com (ROBINHOOD_RPC_URL supplies the chosen provider).
/// The endpoint's native refund invokes the flusher after IMD has burned; this callback is
/// exercised with the real OFT/endpoint, not merely the fault-injection token.
contract RemoteStackerRefundForkTest is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant RECEIVER = 0x1999a54f573dAc75ce8Ef62A555dba418c9B3D10;
    address internal constant VAULT = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    RemoteStacker internal remote;
    RemoteRefundProbe internal flusher;
    address internal project = makeAddr("fork refund project");
    address internal trader = makeAddr("fork refund trader");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc); // the public RPC serves no historical state, so the latest block
        assertEq(block.chainid, 4663, "ROBINHOOD_RPC_URL is not Robinhood Chain");
        forked = true;
        remote = new RemoteStacker(IERC20(IMD), RECEIVER, VAULT, 30101);
        flusher = new RemoteRefundProbe(remote);
        deal(IMD, project, 100e18 + 17, true);
        vm.startPrank(project);
        IERC20(IMD).approve(address(remote), 100e18 + 17);
        remote.credit(trader, 100e18 + 17);
        vm.stopPrank();
        vm.warp(block.timestamp + 12 hours);
        vm.deal(address(this), 10 ether);
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function _list() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = trader;
    }

    function test_liveEndpointRefundCannotReenterCreditOrFlush() public onlyFork {
        (uint256 amount, uint256 tip,,, uint256 fee) = remote.quoteFlush(_list());
        uint256 supply = IERC20(IMD).totalSupply();
        uint256 payerBalance = address(this).balance;
        flusher.execute{value: fee + 0.2 ether}(_list());
        assertEq(flusher.refunds(), 1, "live endpoint executed refund callback");
        assertFalse(flusher.creditSucceeded());
        assertFalse(flusher.flushSucceeded());
        bytes memory guardError =
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(flusher.creditError(), guardError);
        assertEq(flusher.flushError(), guardError);
        assertEq(address(flusher).balance, 0.2 ether);
        assertEq(address(this).balance, payerBalance - fee - 0.2 ether);
        assertEq(IERC20(IMD).balanceOf(address(flusher)), tip);
        assertEq(tip, 2e18);
        assertEq(IERC20(IMD).totalSupply(), supply - amount);
        assertEq(remote.waiting(trader), 17);
        assertEq(IERC20(IMD).balanceOf(address(remote)), 17);
        assertEq(address(remote).balance, 0);
    }

    function test_liveEndpointRejectedRefundRollsBackBurnAndCanRetryExactFee() public onlyFork {
        (uint256 amount, uint256 tip,,, uint256 fee) = remote.quoteFlush(_list());
        flusher.reject(true);
        uint256 supply = IERC20(IMD).totalSupply();
        uint256 since = remote.waitingSince(trader);
        uint256 payerBalance = address(this).balance;
        vm.expectRevert();
        flusher.execute{value: fee + 1}(_list());
        assertEq(IERC20(IMD).totalSupply(), supply);
        assertEq(remote.waiting(trader), 100e18 + 17);
        assertEq(remote.waitingSince(trader), since);
        assertEq(IERC20(IMD).balanceOf(address(remote)), 100e18 + 17);
        assertEq(IERC20(IMD).balanceOf(address(flusher)), 0);
        assertEq(address(this).balance, payerBalance);
        assertEq(address(flusher).balance, 0);
        assertEq(remote.totalQueued(), 100e18 + 17);
        assertEq(remote.projectQueued(project), 100e18 + 17);
        flusher.execute{value: fee}(_list());
        assertEq(IERC20(IMD).totalSupply(), supply - amount);
        assertEq(IERC20(IMD).balanceOf(address(flusher)), tip);
        assertEq(remote.waiting(trader), 17);
        assertEq(address(this).balance, payerBalance - fee);
    }
}
