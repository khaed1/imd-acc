// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOFT, MockEndpoint} from "./mocks/MockOFT.sol";
import {TestSIMD} from "./mocks/TestSIMD.sol";
import {RemoteStacker} from "../src/multichain/RemoteStacker.sol";
import {StackReceiver, IStakedIMD} from "../src/multichain/StackReceiver.sol";

/// @dev The whole route on one chain: a RemoteStacker (playing Robinhood Chain) sends through the
/// mock OFT, the mock endpoint plays the arrival on Ethereum, and the StackReceiver deposits into
/// the vault copy. Also the invariant: the RemoteStacker's IMD always equals the sum waiting.
contract MultichainHandler is Test {
    RemoteStacker public rs;
    MockOFT public imd;
    MockEndpoint public endpoint;
    StackReceiver public receiver;
    TestSIMD public sImd;
    address[] public traders;
    address public project = address(0x9407);
    uint256 public queued;
    uint256 public delivered;
    uint256 public tips;
    uint256 public flushes;

    constructor(RemoteStacker rs_, MockOFT imd_, MockEndpoint ep, StackReceiver r, TestSIMD v) {
        rs = rs_;
        imd = imd_;
        endpoint = ep;
        receiver = r;
        sImd = v;
        for (uint256 i; i < 6; ++i) {
            traders.push(address(uint160(0xA000 + i)));
        }
        vm.prank(project);
        imd.approve(address(rs), type(uint256).max);
    }

    function credit(uint256 seed, uint96 amount) external {
        address t = traders[seed % traders.length];
        imd.mint(project, amount);
        vm.prank(project);
        queued += rs.credit(t, amount);
    }

    function pass(uint32 seconds_) external {
        vm.warp(block.timestamp + (seconds_ % 2 days));
    }

    function flush(uint256 seed, uint8 count) external {
        uint256 n = 1 + count % traders.length;
        uint256 start = seed % traders.length;
        address[] memory list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = traders[(start + i) % traders.length];
        }
        (uint256 imdOut, uint256 tip,,, uint256 fee) = rs.quoteFlush(list);
        if (imdOut == 0) return;
        vm.deal(address(this), fee);
        bytes32 guid = rs.flush{value: fee}(list);
        tips += tip;
        delivered += imdOut;
        flushes += 1;
        MockOFT.Sent memory s = imd.lastSend();
        endpoint.deliver(
            address(imd),
            address(receiver),
            guid,
            s.guid == guid ? uint64(flushes) : 0,
            30416,
            s.amountLD,
            address(rs),
            s.param.composeMsg,
            5_000_000
        );
    }

    function traderCount() external view returns (uint256) {
        return traders.length;
    }
}

contract MultichainFlowTest is StdInvariant, Test {
    address internal constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    MockOFT internal imd;
    TestSIMD internal sImd;
    MockEndpoint internal endpoint;
    StackReceiver internal receiver;
    RemoteStacker internal rs;
    MultichainHandler internal handler;

    function setUp() public {
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        imd = new MockOFT();
        sImd = new TestSIMD(address(imd), OWNER);
        endpoint = new MockEndpoint();
        receiver =
            new StackReceiver(IERC20(address(imd)), IStakedIMD(address(sImd)), address(endpoint));
        rs = new RemoteStacker(IERC20(address(imd)), address(receiver), address(sImd), 30101);
        handler = new MultichainHandler(rs, imd, endpoint, receiver, sImd);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.credit.selector;
        selectors[1] = handler.pass.selector;
        selectors[2] = handler.flush.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function test_endToEnd_creditFlushDeliver() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        address project = address(0x9407);
        imd.mint(project, 100e18);
        vm.startPrank(project);
        imd.approve(address(rs), type(uint256).max);
        rs.credit(alice, 10e18);
        rs.credit(bob, 20e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 12 hours);
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        (uint256 imdOut, uint256 tip,,, uint256 fee) = rs.quoteFlush(list);
        assertEq(tip, 30e18 * 200 / 10_000);
        assertEq(imdOut, 30e18 - tip);
        address flusher = address(0xF1);
        vm.deal(flusher, fee);
        vm.prank(flusher);
        bytes32 guid = rs.flush{value: fee}(list);
        assertEq(imd.balanceOf(flusher), tip);
        assertEq(imd.balanceOf(address(rs)), 0);
        assertEq(imd.totalSupply(), 100e18 - imdOut, "burned on the source chain");

        MockOFT.Sent memory s = imd.lastSend();
        endpoint.deliver(
            address(imd),
            address(receiver),
            guid,
            1,
            30416,
            s.amountLD,
            address(rs),
            s.param.composeMsg,
            1_000_000
        );
        assertEq(sImd.balanceOf(alice), (10e18 - 10e18 * 200 / 10_000) * 1e6);
        assertEq(sImd.balanceOf(bob), (20e18 - 20e18 * 200 / 10_000) * 1e6);
        assertEq(imd.balanceOf(address(receiver)), 0);
        assertEq(imd.totalSupply(), 100e18, "minted again on Ethereum");
        assertEq(sImd.totalAssets(), imdOut);
    }

    function invariant_remoteStackerHoldsExactlyWhatIsWaiting() public view {
        uint256 sum;
        for (uint256 i; i < handler.traderCount(); ++i) {
            sum += rs.waiting(handler.traders(i));
        }
        assertEq(imd.balanceOf(address(rs)), sum);
        assertEq(rs.totalQueued(), handler.queued());
        assertEq(
            sum + handler.delivered() + handler.tips(), handler.queued(), "every wei accounted"
        );
    }

    function invariant_receiverKeepsNothingAndVaultHoldsDeliveries() public view {
        assertEq(imd.balanceOf(address(receiver)), 0);
        assertEq(sImd.balanceOf(address(receiver)), 0);
        assertEq(receiver.totalDelivered(), handler.delivered());
        assertEq(sImd.totalAssets(), handler.delivered());
    }

    function test_handlerReachesFlushes() public {
        handler.credit(0, 5e18);
        handler.credit(1, 7e18);
        handler.pass(13 hours);
        handler.flush(0, 5);
        assertGt(handler.flushes(), 0);
        assertGt(handler.tips(), 0);
        assertEq(sImd.totalAssets(), handler.delivered());
    }
}
