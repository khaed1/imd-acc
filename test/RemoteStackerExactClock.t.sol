// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockOFT} from "./mocks/MockOFT.sol";
import {RemoteStacker} from "../src/multichain/RemoteStacker.sol";
import {RemoteProject} from "./RemoteStacker.t.sol";

/// @dev The exact weighted-sum clock (branch `exact-clock`, for RemoteStackers on later chains).
/// Launch #1537's judge showed that rounding the waiting clock up a whole second on every credit
/// compounds: frequent or 1-wei credits could hold a trader's flush tip at zero. The clock is now
/// the exact sum Σ amount × arrival time, and a flush computes the tip amount from the exact waited
/// time, so these are the judge's two shapes, which failed on the deployed code, plus the rule
/// itself checked against a fuzzed sequence of credits.
contract RemoteStackerExactClockTest is Test {
    uint32 internal constant ETH_EID = 30101;
    address internal constant RECEIVER = address(0xACC0);
    address internal constant VAULT = address(0x5A17);
    uint256 internal constant STEP = 1e12;
    uint256 internal constant PERIOD = 12 hours;

    MockOFT internal imd;
    RemoteStacker internal rs;
    RemoteProject internal project;
    RemoteProject internal stranger;
    address internal alice = address(0xA11CE);
    address internal flusher = address(0xF1);

    function setUp() public {
        vm.warp(1_700_000_000);
        imd = new MockOFT();
        rs = new RemoteStacker(IERC20(address(imd)), RECEIVER, VAULT, ETH_EID);
        project = new RemoteProject(rs, IERC20(address(imd)));
        stranger = new RemoteProject(rs, IERC20(address(imd)));
        imd.mint(address(project), 10_000_000e18);
        imd.mint(address(stranger), 1e18);
        vm.deal(flusher, 10 ether);
    }

    function one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    /// @dev The tip a flush pays under the stated rule, from the credits' own amounts and times:
    /// whole steps leave, and 2% × (weighted waited time, capped at 12 hours) / 12 hours of them is
    /// the tip, rounded down to a step.
    function ruleTip(uint256 leaving, uint256 tokenSeconds, uint256 balance)
        internal
        pure
        returns (uint256)
    {
        if (tokenSeconds > PERIOD * balance) tokenSeconds = PERIOD * balance;
        return leaving * 200 * tokenSeconds / (10_000 * PERIOD * balance) / STEP * STEP;
    }

    function flushTip() internal returns (uint256 tip) {
        uint256 before = imd.balanceOf(flusher);
        vm.prank(flusher);
        rs.flush{value: 0.001 ether}(one(alice));
        tip = imd.balanceOf(flusher) - before;
    }

    /// The judge's first shape: 3,600 credits of 1 IMD one second apart. On the deployed code the
    /// clock reached the last credit and the tip was zero; the rule gives about 8.3 bps of 3,600 IMD.
    function test_judge_manyCreditsOneSecondApartKeepTheirWeightedAge() public {
        uint256 start = block.timestamp;
        uint256 tokenSeconds;
        for (uint256 i; i < 3600; ++i) {
            vm.warp(start + i);
            project.credit(alice, 1e18);
        }
        uint256 end = start + 3599;
        for (uint256 i; i < 3600; ++i) {
            tokenSeconds += 1e18 * (end - (start + i));
        }
        // The weighted arrival is start + 1799.5 s: the displayed clock rounds it up once, not 3,600 times.
        assertEq(
            rs.waitingSince(alice), start + 1800, "clock must not drift past the weighted arrival"
        );
        assertEq(rs.tipBps(alice), 8);
        uint256 expected = ruleTip(3600e18, tokenSeconds, 3600e18);
        assertGt(expected, 2.99e18);
        assertEq(flushTip(), expected, "tip from the exact waited time");
    }

    /// The judge's second shape: a stranger's 1-wei credits against a 1,000,000 IMD balance that has
    /// waited 6 hours. On the deployed code each one moved the clock a whole second; here they barely
    /// change the tip at all.
    function test_judge_strangerDustCannotShaveALargeBalancesTip() public {
        project.credit(alice, 1_000_000e18);
        vm.warp(block.timestamp + 6 hours);
        (, uint256 clean,,,) = rs.quoteFlush(one(alice));
        for (uint256 i; i < 3600; ++i) {
            vm.warp(block.timestamp + 1);
            stranger.credit(alice, 1);
        }
        // An hour later, the tip of the 1,000,000 IMD has grown by an hour's worth (about 0.17%
        // of 2%), as if no dust had arrived.
        uint256 tip = flushTip();
        uint256 hourLater = 1_000_000e18 * 200 * (7 hours) / (10_000 * PERIOD) / STEP * STEP;
        assertGt(tip, clean, "the tip kept growing");
        assertApproxEqAbs(
            tip, hourLater, STEP * 2, "3,600 one-wei credits cost the flusher nothing"
        );
    }

    /// Griefing in the open: one 1-wei credit a second for 12 hours against a fresh 100 IMD balance
    /// still lets the tip reach the full 2%.
    function test_dustEverySecondCannotHoldTheTipAtZero() public {
        project.credit(alice, 100e18);
        for (uint256 i; i < 720; ++i) {
            vm.warp(block.timestamp + 60);
            stranger.credit(alice, 1);
        }
        assertEq(
            rs.tipBps(alice),
            199,
            "just under the cap after 12 hours: the dust is 12 hours younger at most"
        );
        vm.warp(block.timestamp + 1);
        assertEq(rs.tipBps(alice), 200);
    }

    /// The rule against any short sequence of credits and waits: the tip a flush pays equals the
    /// stated rule computed from the credits themselves, and never exceeds 2%.
    function testFuzz_tipMatchesTheExactRule(
        uint96[6] memory amounts,
        uint32[6] memory gaps,
        uint32 lastGap
    ) public {
        uint256 balance;
        uint256[6] memory at;
        uint256[6] memory amt;
        uint256 n;
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + uint256(gaps[i]) % (3 days));
            uint256 a = bound(amounts[i], 0, 100_000e18);
            if (a == 0) continue;
            // A balance waiting past 12 hours counts as having waited exactly 12 hours when more arrives.
            if (balance > 0) {
                uint256 aged;
                for (uint256 j; j < n; ++j) {
                    aged += amt[j] * (block.timestamp - at[j]);
                }
                if (aged > PERIOD * balance) {
                    for (uint256 j; j < n; ++j) {
                        at[j] = block.timestamp - PERIOD;
                    }
                }
            }
            project.credit(alice, a);
            at[n] = block.timestamp;
            amt[n] = a;
            ++n;
            balance += a;
        }
        vm.warp(block.timestamp + uint256(lastGap) % (2 days));
        vm.assume(balance >= STEP);
        uint256 tokenSeconds;
        for (uint256 j; j < n; ++j) {
            tokenSeconds += amt[j] * (block.timestamp - at[j]);
        }
        uint256 leaving = balance / STEP * STEP;
        uint256 expected = ruleTip(leaving, tokenSeconds, balance);
        uint256 tip = flushTip();
        assertEq(tip, expected, "tip = the stated rule on the credits themselves");
        assertLe(tip, leaving * 200 / 10_000, "never above 2%");
        assertEq(rs.waiting(alice), balance - leaving, "only sub-step dust stays");
    }
}
