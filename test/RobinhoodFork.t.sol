// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RemoteStacker} from "../src/multichain/RemoteStacker.sol";
import {IOFT} from "../src/multichain/LayerZero.sol";

interface ILiveRemoteOFT {
    function endpoint() external view returns (address);
    function peers(uint32 eid) external view returns (bytes32);
    function sharedDecimals() external view returns (uint8);
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
    function totalSupply() external view returns (uint256);
    function owner() external view returns (address);
    function setPeer(uint32 eid, bytes32 peer) external;
}

/// @dev Runs against a fork of Robinhood Chain (chain 4663) with the live IMD OFT and LayerZero
/// endpoint. Set ROBINHOOD_RPC_URL to run it (for example
/// `ROBINHOOD_RPC_URL=https://robinhood-rpc.publicnode.com forge test --mc RobinhoodFork`); without
/// it every test is skipped. A flush sends a real send-and-call through the live token: the IMD is
/// burned here and the endpoint accepts the message and the executor options.
contract RobinhoodForkTest is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant ETH_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant ETH_SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    uint32 internal constant ETH_EID = 30101;
    bytes32 internal constant OFT_SENT =
        keccak256("OFTSent(bytes32,uint32,address,uint256,uint256)");
    bytes32 internal constant PACKET_SENT = keccak256("PacketSent(bytes,bytes,address)");

    RemoteStacker internal rs;
    address internal constant RECEIVER = 0x1999a54f573dAc75ce8Ef62A555dba418c9B3D10;
    address internal project = makeAddr("project");
    address internal flusher = makeAddr("flusher");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        if (block.chainid != 4663) return;
        forked = true;
        rs = new RemoteStacker(IERC20(IMD), RECEIVER, ETH_SIMD, ETH_EID);
        deal(IMD, project, 1_000e18, true);
        vm.prank(project);
        IERC20(IMD).approve(address(rs), type(uint256).max);
        vm.deal(flusher, 1 ether);
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_fork_liveFacts() public onlyFork {
        assertEq(ILiveRemoteOFT(IMD).peers(ETH_EID), bytes32(uint256(uint160(ETH_IMD))), "peered");
        assertEq(ILiveRemoteOFT(IMD).sharedDecimals(), 6);
        assertEq(IOFT(IMD).decimalConversionRate(), 1e12);
        assertEq(
            ILiveRemoteOFT(IMD).enforcedOptions(ETH_EID, 2).length,
            0,
            "no enforced compose options: ours carry the gas"
        );
    }

    function test_fork_flushBurnsHereAndTheEndpointAcceptsTheMessage() public onlyFork {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.startPrank(project);
        rs.credit(alice, 1e18 + 5); // 5 wei of dust stays
        rs.credit(bob, 2e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 6 hours);
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        (uint256 imdOut, uint256 tip,, uint256[] memory amounts, uint256 fee) = rs.quoteFlush(list);
        assertGt(fee, 0, "a real bridge quote");
        assertLt(fee, 0.01 ether, "a sane bridge fee");
        emit log_named_uint("bridge fee for 2 traders, wei", fee);
        uint256 supply = ILiveRemoteOFT(IMD).totalSupply();

        vm.recordLogs();
        vm.prank(flusher);
        bytes32 guid = rs.flush{value: fee}(list);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sent;
        bool packet;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == IMD && logs[i].topics[0] == OFT_SENT) {
                assertEq(logs[i].topics[1], guid);
                (uint32 dstEid, uint256 sentLD, uint256 receivedLD) =
                    abi.decode(logs[i].data, (uint32, uint256, uint256));
                assertEq(dstEid, ETH_EID);
                assertEq(sentLD, imdOut);
                assertEq(receivedLD, imdOut);
                sent = true;
            }
            if (logs[i].topics[0] == PACKET_SENT) packet = true;
        }
        assertTrue(sent, "OFTSent");
        assertTrue(packet, "the endpoint emitted the packet");
        assertEq(ILiveRemoteOFT(IMD).totalSupply(), supply - imdOut, "burned on Robinhood Chain");
        assertEq(IERC20(IMD).balanceOf(flusher), tip, "tip paid");
        assertEq(IERC20(IMD).balanceOf(address(rs)), 5, "only the dust stays");
        assertEq(rs.waiting(alice), 5);
        assertEq(rs.waiting(bob), 0);
        assertEq(amounts[0] + amounts[1], imdOut);
        assertEq(flusher.balance, 1 ether - fee, "fee paid, nothing else");
    }

    function test_fork_fiftyTradersQuoteAndFlush() public onlyFork {
        address[] memory list = new address[](50);
        vm.startPrank(project);
        for (uint256 i; i < 50; ++i) {
            list[i] = address(uint160(0x3000 + i));
            rs.credit(list[i], 1e18);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        (uint256 imdOut, uint256 tip,,, uint256 fee) = rs.quoteFlush(list);
        emit log_named_uint("bridge fee for 50 traders, wei", fee);
        assertLt(fee, 0.05 ether);
        vm.prank(flusher);
        rs.flush{value: fee}(list);
        assertEq(imdOut + tip, 50e18);
        assertEq(IERC20(IMD).balanceOf(address(rs)), 0);
    }

    function test_fork_tooLittleFeeChangesNothing() public onlyFork {
        address alice = makeAddr("alice");
        vm.prank(project);
        rs.credit(alice, 1e18);
        address[] memory list = new address[](1);
        list[0] = alice;
        (,,,, uint256 fee) = rs.quoteFlush(list);
        vm.prank(flusher);
        vm.expectRevert();
        rs.flush{value: fee / 2}(list);
        assertEq(rs.waiting(alice), 1e18);
        assertEq(IERC20(IMD).balanceOf(address(rs)), 1e18);
    }

    /// @dev The bridge-owner trust assumption, exercised only on a local fork. Disabling the
    /// Ethereum peer blocks both quoting and sending; restoring it reopens the fixed route.
    function test_fork_OFTPeerRemovalBlocksTheOnlyExitAtomically() public onlyFork {
        address alice = makeAddr("alice");
        vm.prank(project);
        rs.credit(alice, 1e18);
        uint256 since = rs.waitingSince(alice);
        vm.warp(block.timestamp + 12 hours);
        address[] memory list = new address[](1);
        list[0] = alice;
        (,,,, uint256 fee) = rs.quoteFlush(list);
        bytes32 peer = ILiveRemoteOFT(IMD).peers(ETH_EID);
        address bridgeOwner = ILiveRemoteOFT(IMD).owner();
        assertTrue(bridgeOwner != address(0));
        vm.prank(bridgeOwner);
        ILiveRemoteOFT(IMD).setPeer(ETH_EID, bytes32(0));

        vm.expectRevert(abi.encodeWithSignature("NoPeer(uint32)", ETH_EID));
        rs.quoteFlush(list);
        vm.expectRevert(abi.encodeWithSignature("NoPeer(uint32)", ETH_EID));
        vm.prank(flusher);
        rs.flush{value: fee}(list);
        assertEq(rs.waiting(alice), 1e18);
        assertEq(rs.waitingSince(alice), since);
        assertEq(IERC20(IMD).balanceOf(address(rs)), 1e18);
        assertEq(IERC20(IMD).balanceOf(flusher), 0);
        assertEq(flusher.balance, 1 ether);

        vm.prank(bridgeOwner);
        ILiveRemoteOFT(IMD).setPeer(ETH_EID, peer);
        (,,,, fee) = rs.quoteFlush(list);
        vm.prank(flusher);
        rs.flush{value: fee}(list);
        assertEq(rs.waiting(alice), 0);
        assertEq(IERC20(IMD).balanceOf(address(rs)), 0);
        assertEq(IERC20(IMD).balanceOf(flusher), 1e18 * 200 / 10_000);
    }
}
