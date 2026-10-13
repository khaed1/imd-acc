// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOFT} from "./mocks/MockOFT.sol";
import {RemoteStacker} from "../src/multichain/RemoteStacker.sol";
import {RemoteTrialVenue, IERC20Min, IRemoteStackerMin} from "./trial/RemoteTrialVenue.sol";

/// @dev A router that reports its active caller, as the Universal Router does.
contract RemoteMsgSenderRouter {
    address public msgSender;

    function buyFor(address user, RemoteTrialVenue v, IERC20Min imd, uint256 amount) external {
        msgSender = user;
        imd.approve(address(v), amount);
        v.buy(amount, 0);
        msgSender = address(0);
    }
}

contract RemoteTrialVenueTest is Test {
    address internal constant RECEIVER = address(0xACC0);
    address internal constant VAULT = address(0x5A17);
    MockOFT internal imd;
    RemoteStacker internal rs;
    RemoteTrialVenue internal venue;
    address internal owner = address(0x0A);
    address internal alice = address(0xA11CE);

    function setUp() public {
        vm.warp(1_700_000_000);
        imd = new MockOFT();
        rs = new RemoteStacker(IERC20(address(imd)), RECEIVER, VAULT, 30101);
        vm.prank(owner);
        venue = new RemoteTrialVenue(
            IERC20Min(address(imd)), IRemoteStackerMin(address(rs)), 300_000, 100_000
        );
        imd.mint(owner, 100e18);
        vm.startPrank(owner);
        imd.approve(address(venue), 100e18);
        venue.seed(100e18);
        vm.stopPrank();
        imd.mint(alice, 10e18);
    }

    function test_wiring() public view {
        assertEq(venue.VAULT(), VAULT);
        assertEq(venue.RECEIVER(), RECEIVER);
        assertEq(venue.owner(), owner);
        assertEq(venue.reserveImd(), 100e18);
        assertEq(venue.reserveTrial(), venue.TRIAL_SUPPLY());
    }

    function test_buyQueuesHalfTheFeeAndBurnsTheOtherHalf() public {
        vm.startPrank(alice);
        imd.approve(address(venue), 10e18);
        venue.buy(10e18, 0);
        vm.stopPrank();
        assertEq(rs.waiting(alice), 0.05e18, "0.5% queued for the trader");
        assertEq(imd.balanceOf(venue.BURN()), 0.05e18, "0.5% burned");
        assertEq(rs.projectQueued(address(venue)), 0.05e18);
        assertGt(venue.balanceOf(alice), 0);
    }

    function test_sellQueuesHalfTheFeeToo() public {
        vm.startPrank(alice);
        imd.approve(address(venue), 10e18);
        uint256 trial = venue.buy(10e18, 0);
        venue.sell(trial / 2, 0);
        vm.stopPrank();
        assertGt(rs.waiting(alice), 0.05e18);
        assertEq(imd.balanceOf(address(rs)), rs.waiting(alice));
    }

    function test_routerCallerResolvesToItsActiveCaller() public {
        RemoteMsgSenderRouter router = new RemoteMsgSenderRouter();
        imd.mint(address(router), 4e18);
        router.buyFor(alice, venue, IERC20Min(address(imd)), 4e18);
        assertEq(rs.waiting(alice), 0.02e18, "credited to the router's active caller");
        assertEq(rs.waiting(address(router)), 0);
    }

    function test_unknownContractCallerGetsNoCashbackItIsBurned() public {
        imd.mint(address(this), 4e18);
        imd.approve(address(venue), 4e18);
        venue.buy(4e18, 0); // this contract has code and no msgSender()
        assertEq(rs.waiting(address(this)), 0);
        assertEq(imd.balanceOf(venue.BURN()), 0.04e18, "the whole fee burned");
    }

    function test_failedCreditPaysPlainImd() public {
        vm.prank(address(venue));
        imd.approve(address(rs), 0); // the RemoteStacker's pull then fails
        vm.startPrank(alice);
        imd.approve(address(venue), 4e18);
        venue.buy(4e18, 0);
        vm.stopPrank();
        assertEq(rs.waiting(alice), 0);
        assertEq(imd.balanceOf(alice), 10e18 - 4e18 + 0.02e18, "plain IMD to the trader");
    }

    function test_gasIsCheckedBeforeTheCredit() public {
        vm.startPrank(alice);
        imd.approve(address(venue), 1e18);
        vm.expectRevert(bytes("imd/acc: insufficient gas"));
        venue.buy{gas: 350_000}(1e18, 0);
        vm.stopPrank();
    }

    function test_invalidTradersNeverResolve() public view {
        assertEq(venue.resolveTrader(address(rs)), address(0));
        assertEq(venue.resolveTrader(address(imd)), address(0));
        assertEq(venue.resolveTrader(VAULT), address(0));
        assertEq(venue.resolveTrader(RECEIVER), address(0));
        assertEq(venue.resolveTrader(address(venue)), address(0));
        assertEq(venue.resolveTrader(alice), alice);
    }

    function test_ownerCanOnlySeedOnce() public {
        vm.prank(owner);
        vm.expectRevert(RemoteTrialVenue.AlreadySeeded.selector);
        venue.seed(1);
        vm.prank(alice);
        vm.expectRevert(RemoteTrialVenue.NotOwner.selector);
        venue.seed(1);
    }

    function test_registryReadsTheOwner() public view {
        (bool ok, bytes memory ret) = address(venue).staticcall(abi.encodeWithSignature("owner()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), owner);
    }
}
