// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RemoteStacker} from "src/multichain/RemoteStacker.sol";
import {MockOFT} from "./mocks/MockOFT.sol";

/// @dev Ghost credits are derived from handler inputs and its recipient registrations; outgoing
/// amounts come from the actual OFT packet. No ghost balance is assigned from remote.waiting().
/// Projects, recipients and flushers are disjoint so each source-chain wei has one owner.
contract RemoteQueueHandler is Test {
    uint256 public constant STEP = 1e12;
    uint256 public constant FUNDING = 1e30;
    uint256 internal constant PERIOD = 12 hours;
    uint256 internal constant FEE = 0.001 ether;
    RemoteStacker public immutable remote;
    MockOFT public immutable imd;
    address[6] public traders;
    address[3] public projects;
    address[2] public flushers;
    address public immutable emptyRecipient;
    mapping(address => address) public registered;
    mapping(address => uint256) public credited;
    mapping(address => uint256) public delivered;
    mapping(address => uint256) public tipped;
    mapping(address => uint256) public plainPaid;
    mapping(address => uint256) public projectCredits;
    mapping(address => uint256) public projectSpent;
    mapping(address => uint256) public flusherTips;
    mapping(address => uint256) public feesSpent;
    uint256 public queued;
    uint256 public paid;
    uint256 public donations;
    uint256 public bridged;
    uint256 public tips;
    uint256 public successfulFlushes;
    uint256 public failedFlushes;
    uint256 public rejectedCredits;
    uint256 public registrations;

    constructor(RemoteStacker remote_, MockOFT imd_) {
        remote = remote_;
        imd = imd_;
        emptyRecipient = makeAddr("invariant empty recipient");
        for (uint256 i; i < 6; ++i) {
            traders[i] = makeAddr(string.concat("invariant trader ", vm.toString(i)));
        }
        // 0..2 are EOAs; 3 is EIP-7702; 4..5 are smart-contract wallets.
        vm.etch(traders[3], abi.encodePacked(hex"ef0100", makeAddr("invariant delegate")));
        vm.etch(traders[4], hex"00");
        vm.etch(traders[5], hex"00");
        for (uint256 i; i < 3; ++i) {
            projects[i] = makeAddr(string.concat("invariant project ", vm.toString(i)));
            imd.mint(projects[i], FUNDING);
            vm.prank(projects[i]);
            imd.approve(address(remote), type(uint256).max);
        }
        for (uint256 i; i < 2; ++i) {
            flushers[i] = makeAddr(string.concat("invariant flusher ", vm.toString(i)));
            vm.deal(flushers[i], 100 ether);
        }
    }

    function owed(address recipient) public view returns (uint256) {
        return credited[recipient] - delivered[recipient] - tipped[recipient];
    }

    /// @dev Mix exact economic boundaries with unrestricted amounts in a feasible IMD range.
    function _amount(uint256 raw, uint8 edge) internal pure returns (uint256) {
        uint256[8] memory edges =
            [uint256(0), 1, STEP - 1, STEP, STEP + 1, 49 * STEP, 50 * STEP, 51 * STEP];
        return edge % 10 < 8 ? edges[edge % 10] : bound(raw, 1, 1_000_000e18);
    }

    function credit(uint256 projectSeed, uint256 traderSeed, uint256 raw, uint8 edge) public {
        address project = projects[projectSeed % 3];
        uint256 index = traderSeed % 6;
        address trader = traders[index];
        address recipient = index < 4 ? trader : registered[trader];
        uint256 amount = _amount(raw, edge);
        uint64[6] memory clocks = _clocks();
        uint256 oldOwed = owed(recipient);
        uint256 oldClock = remote.waitingSince(recipient);

        if (amount > 0) {
            vm.expectEmit(true, true, false, true, address(remote));
            if (recipient == address(0)) emit RemoteStacker.Paid(project, trader, amount);
            else emit RemoteStacker.Queued(project, trader, recipient, amount);
        }
        vm.prank(project);
        uint256 returned = remote.credit(trader, amount);
        projectSpent[project] += amount;
        if (recipient == address(0)) {
            assertEq(returned, 0);
            paid += amount;
            plainPaid[trader] += amount;
        } else {
            assertEq(returned, amount);
            queued += amount;
            projectCredits[project] += amount;
            credited[recipient] += amount;
        }
        for (uint256 i; i < 6; ++i) {
            if (traders[i] != recipient || amount == 0) {
                assertEq(remote.waitingSince(traders[i]), clocks[i], "unrelated clock changed");
            }
        }
        if (recipient != address(0) && amount != 0) {
            uint256 since = remote.waitingSince(recipient);
            assertLe(since, block.timestamp);
            if (oldOwed == 0) {
                assertEq(since, block.timestamp, "fresh queue must start now");
            } else {
                // Work in elapsed token-seconds instead of reproducing the arrival formula.
                uint256 oldAge = block.timestamp - oldClock;
                if (oldAge > PERIOD) oldAge = PERIOD;
                uint256 age = block.timestamp - since;
                uint256 balance = oldOwed + amount;
                assertLe(age * balance, oldAge * oldOwed, "fresh credit acquired old age");
                assertGt((age + 1) * balance, oldAge * oldOwed, "lost more than one second");
            }
        }
    }

    function register(uint256 walletSeed, uint256 recipientSeed) public {
        address wallet = traders[walletSeed % 6];
        uint256 choice = recipientSeed % 7;
        address recipient = choice == 6 ? address(0) : traders[choice];
        uint64[6] memory clocks = _clocks();
        vm.expectEmit(true, false, false, true, address(remote));
        emit RemoteStacker.EthereumRecipientSet(wallet, recipient);
        vm.prank(wallet);
        remote.setEthereumRecipient(recipient);
        registered[wallet] = recipient;
        ++registrations;
        for (uint256 i; i < 6; ++i) {
            assertEq(remote.waitingSince(traders[i]), clocks[i], "registration moved old credit");
        }
    }

    function elapse(uint256 seconds_) public {
        vm.warp(block.timestamp + bound(seconds_, 0, 3 days));
    }

    function donate(uint256 projectSeed, uint96 raw) public {
        address project = projects[projectSeed % 3];
        uint256 amount = bound(raw, 1, 1_000e18);
        uint64[6] memory clocks = _clocks();
        vm.prank(project);
        imd.transfer(address(remote), amount);
        donations += amount;
        projectSpent[project] += amount;
        for (uint256 i; i < 6; ++i) {
            assertEq(remote.waitingSince(traders[i]), clocks[i]);
        }
    }

    function rejectCredit(uint256 projectSeed, uint256 traderSeed, uint96 raw) public {
        address project = projects[projectSeed % 3];
        uint256 amount = bound(raw, 1, 1e18);
        vm.prank(project);
        imd.approve(address(remote), amount - 1);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(remote),
                amount - 1,
                amount
            )
        );
        vm.prank(project);
        remote.credit(traders[traderSeed % 6], amount);
        assertEq(_state(), beforeState, "rejected credit changed custody or points");
        assertEq(imd.allowance(project, address(remote)), amount - 1);
        vm.prank(project);
        imd.approve(address(remote), type(uint256).max);
        ++rejectedCredits;
    }

    function flush(uint256 seed, uint8 count, uint8 flusherSeed) public {
        _flush(_list(seed, count), flushers[flusherSeed % 2]);
    }

    function _list(uint256 seed, uint8 count) internal view returns (address[] memory list) {
        list = new address[](bound(count, 0, 50));
        for (uint256 i; i < list.length; ++i) {
            uint256 choice = uint256(keccak256(abi.encode(seed, i))) % 8;
            list[i] = choice < 6 ? traders[choice] : choice == 6 ? address(0) : emptyRecipient;
        }
    }

    struct Quote {
        uint256 amount;
        uint256 tip;
        address[] to;
        uint256[] amounts;
        uint256 fee;
    }

    function _flush(address[] memory list, address flusher) internal {
        Quote memory q;
        (q.amount, q.tip, q.to, q.amounts, q.fee) = remote.quoteFlush(list);
        bool[6] memory included = _checkMembership(list, q);
        if (q.to.length == 0) {
            assertEq(q.amount + q.tip + q.fee, 0);
            bytes32 beforeState = _state();
            vm.expectRevert(RemoteStacker.NothingToFlush.selector);
            vm.prank(flusher);
            remote.flush{value: FEE}(list);
            assertEq(_state(), beforeState);
            ++failedFlushes;
            return;
        }

        assertEq(q.fee, FEE);
        uint64[6] memory clocks = _clocks();
        uint256 previousSends = imd.sendCount();
        uint256 previousTips = imd.balanceOf(flusher);
        vm.prank(flusher);
        bytes32 guid = remote.flush{value: q.fee + 1 ether}(list);
        assertEq(imd.sendCount(), previousSends + 1, "one packet per flush");
        MockOFT.Sent memory sent = imd.lastSend();
        _checkPacket(sent, guid, q);
        (uint256 actualTotal, uint256 actualTips) = _recordDelivery(sent.param.composeMsg);
        assertEq(actualTotal, q.amount);
        assertEq(actualTips, q.tip);
        assertEq(imd.balanceOf(flusher) - previousTips, actualTips);
        for (uint256 i; i < 6; ++i) {
            uint256 expectedClock = included[i] && owed(traders[i]) == 0 ? 0 : clocks[i];
            assertEq(
                remote.waitingSince(traders[i]), expectedClock, "flush changed a retained clock"
            );
        }
        bridged += actualTotal;
        tips += actualTips;
        flusherTips[flusher] += actualTips;
        feesSpent[flusher] += q.fee;
        ++successfulFlushes;
    }

    function _checkMembership(address[] memory list, Quote memory q)
        internal
        view
        returns (bool[6] memory included)
    {
        // Membership comes from input recipients and independent credit ghosts.
        uint256 expectedCount;
        for (uint256 i; i < list.length; ++i) {
            for (uint256 j; j < 6; ++j) {
                if (list[i] == traders[j] && owed(traders[j]) >= STEP && !included[j]) {
                    included[j] = true;
                    assertEq(q.to[expectedCount++], traders[j], "first-occurrence order");
                }
            }
        }
        assertEq(q.to.length, expectedCount);
        assertEq(q.amounts.length, expectedCount);
    }

    function _checkPacket(MockOFT.Sent memory sent, bytes32 guid, Quote memory q) internal view {
        assertEq(sent.guid, guid);
        assertEq(sent.from, address(remote));
        assertEq(sent.param.composeMsg, abi.encode(q.to, q.amounts), "quote and send disagree");
        assertEq(sent.param.dstEid, 30101);
        assertEq(sent.param.to, bytes32(uint256(uint160(remote.RECEIVER()))));
        assertEq(sent.param.amountLD, q.amount);
        assertEq(sent.param.minAmountLD, q.amount);
        assertEq(sent.amountLD, q.amount);
        assertEq(sent.param.oftCmd.length, 0);
        assertEq(
            sent.param.extraOptions,
            abi.encodePacked(
                uint16(3),
                uint8(1),
                uint16(17),
                uint8(1),
                uint128(250_000),
                uint8(1),
                uint16(19),
                uint8(3),
                uint16(0),
                uint128(200_000 + 80_000 * q.to.length)
            )
        );
    }

    function _recordDelivery(bytes memory message)
        internal
        returns (uint256 actualTotal, uint256 actualTips)
    {
        (address[] memory actualTo, uint256[] memory actualAmounts) =
            abi.decode(message, (address[], uint256[]));
        for (uint256 i; i < actualTo.length; ++i) {
            address recipient = actualTo[i];
            uint256 balance = owed(recipient);
            uint256 leaving = balance - balance % STEP;
            uint256 out = actualAmounts[i];
            assertGt(out, 0);
            assertEq(out % STEP, 0);
            assertLe(out, leaving);
            uint256 tip = leaving - out;
            assertEq(tip % STEP, 0);
            assertLe(tip * 50, leaving, "more than 2% taken from this recipient");
            delivered[recipient] += out;
            tipped[recipient] += tip;
            actualTotal += out;
            actualTips += tip;
            assertEq(
                remote.waiting(recipient), balance % STEP, "only this recipient's dust remains"
            );
        }
    }

    /// @dev Ensure every failed-send action reaches IOFT.send, even if called on an empty state.
    function failFlush(uint256 seed, bool underpay) public {
        uint256 index = seed % 4;
        credit(seed, index, 1e18, 8);
        address[] memory list = new address[](3);
        list[0] = traders[index];
        list[1] = traders[(index + 1) % 6];
        list[2] = traders[index];
        address flusher = flushers[seed % 2];
        if (!underpay) imd.setRefuseSend(true);
        bytes32 beforeState = _state();
        if (underpay) {
            vm.expectRevert(abi.encodeWithSelector(MockOFT.NotEnoughNative.selector, FEE - 1, FEE));
        } else {
            vm.expectRevert(MockOFT.SendRefused.selector);
        }
        vm.prank(flusher);
        remote.flush{value: underpay ? FEE - 1 : FEE}(list);
        assertEq(_state(), beforeState, "failed flush changed balances, clocks, packet or fee");
        imd.setRefuseSend(false);
        ++failedFlushes;
    }

    function _clocks() internal view returns (uint64[6] memory clocks) {
        for (uint256 i; i < 6; ++i) {
            clocks[i] = remote.waitingSince(traders[i]);
        }
    }

    function _state() internal view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                remote.totalQueued(),
                remote.totalPaid(),
                imd.totalSupply(),
                imd.nonce(),
                imd.sendCount(),
                imd.balanceOf(address(remote)),
                address(remote).balance,
                address(imd).balance
            )
        );
        if (imd.sendCount() > 0) digest = keccak256(abi.encode(digest, imd.lastSend()));
        for (uint256 i; i < 6; ++i) {
            address trader = traders[i];
            digest = keccak256(
                abi.encode(
                    digest,
                    remote.waiting(trader),
                    remote.waitingSince(trader),
                    remote.ethereumRecipient(trader),
                    imd.balanceOf(trader)
                )
            );
        }
        for (uint256 i; i < 3; ++i) {
            digest = keccak256(
                abi.encode(digest, remote.projectQueued(projects[i]), imd.balanceOf(projects[i]))
            );
        }
        for (uint256 i; i < 2; ++i) {
            digest = keccak256(abi.encode(digest, imd.balanceOf(flushers[i]), flushers[i].balance));
        }
    }

    /// @dev Used by afterInvariant to prove exit liveness after arbitrary histories.
    function drain() external {
        address[] memory list = new address[](6);
        for (uint256 i; i < 6; ++i) {
            list[i] = traders[i];
        }
        _flush(list, flushers[0]);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RemoteStackerStatefulTest is StdInvariant, Test {
    MockOFT internal imd;
    RemoteStacker internal remote;
    RemoteQueueHandler internal handler;

    function setUp() public {
        vm.warp(1_790_000_123);
        imd = new MockOFT();
        remote = new RemoteStacker(
            IERC20(address(imd)),
            0x1999a54f573dAc75ce8Ef62A555dba418c9B3D10,
            0x9Efa934D9fAd4AE28c998a40195646b965a97247,
            30101
        );
        handler = new RemoteQueueHandler(remote, imd);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.credit.selector;
        selectors[1] = handler.register.selector;
        selectors[2] = handler.elapse.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.rejectCredit.selector;
        selectors[5] = handler.flush.selector;
        selectors[6] = handler.failFlush.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_everyRecipientAndProjectRetainsItsOwnAccounting() public view {
        uint256 sumOwed;
        uint256 sumPaid;
        uint256 sumQueued;
        for (uint256 i; i < 6; ++i) {
            address trader = handler.traders(i);
            uint256 owed = handler.owed(trader);
            assertEq(remote.waiting(trader), owed, "recipient entitlement mismatch");
            assertEq(remote.ethereumRecipient(trader), handler.registered(trader));
            assertEq(imd.balanceOf(trader), handler.plainPaid(trader));
            if (owed == 0) {
                assertEq(remote.waitingSince(trader), 0);
                assertEq(remote.tipBps(trader), 0);
            } else {
                assertGt(remote.waitingSince(trader), 0);
                assertLe(remote.waitingSince(trader), block.timestamp);
                assertLe(remote.tipBps(trader), 200);
            }
            assertLe(
                handler.tipped(trader) * 49,
                handler.delivered(trader),
                "recipient received under 98%"
            );
            sumOwed += owed;
            sumPaid += handler.plainPaid(trader);
        }
        for (uint256 i; i < 3; ++i) {
            address project = handler.projects(i);
            assertEq(remote.projectQueued(project), handler.projectCredits(project));
            assertEq(imd.balanceOf(project) + handler.projectSpent(project), handler.FUNDING());
            sumQueued += handler.projectCredits(project);
        }
        assertEq(remote.totalQueued(), sumQueued);
        assertEq(sumQueued, handler.queued());
        assertEq(remote.totalPaid(), sumPaid);
        assertEq(sumPaid, handler.paid());
        assertEq(sumOwed + handler.bridged() + handler.tips(), sumQueued);
        assertEq(
            imd.balanceOf(address(remote)),
            sumOwed + handler.donations(),
            "unbacked claim or stolen donation"
        );
    }

    function invariant_burnTipsAndNativeFeesMatchActualTransfers() public view {
        assertEq(imd.totalSupply() + handler.bridged(), 3 * handler.FUNDING());
        assertEq(imd.sendCount(), handler.successfulFlushes());
        uint256 totalTips;
        uint256 totalFees;
        for (uint256 i; i < 2; ++i) {
            address flusher = handler.flushers(i);
            assertEq(imd.balanceOf(flusher), handler.flusherTips(flusher));
            assertEq(
                flusher.balance + handler.feesSpent(flusher), 100 ether, "excess ETH not refunded"
            );
            totalTips += handler.flusherTips(flusher);
            totalFees += handler.feesSpent(flusher);
        }
        assertEq(totalTips, handler.tips());
        assertEq(address(imd).balance, totalFees);
        assertEq(address(remote).balance, 0);
        assertEq(remote.waiting(handler.emptyRecipient()), 0);
        assertEq(remote.waiting(address(0)), 0);
    }

    function afterInvariant() public {
        handler.drain();
        for (uint256 i; i < 6; ++i) {
            assertLt(remote.waiting(handler.traders(i)), 1e12);
        }
        invariant_everyRecipientAndProjectRetainsItsOwnAccounting();
        invariant_burnTipsAndNativeFeesMatchActualTransfers();
    }

    function test_handlerReachesRoutingDustDonationsFailuresAndPaidFlushes() public {
        handler.credit(0, 4, 7e18, 8); // plain payment, no points
        handler.register(4, 0);
        handler.credit(1, 4, 100e18, 8); // now queued for trader 0
        handler.register(5, 0);
        handler.credit(2, 5, 200e18, 8); // shared Ethereum recipient
        handler.credit(0, 1, 0, 2); // STEP - 1 dust
        handler.credit(0, 3, 3e18, 8); // EIP-7702 stays in queue
        handler.donate(2, 9e18);
        handler.rejectCredit(0, 4, 1e18);
        handler.failFlush(0, false);
        handler.failFlush(1, true);
        handler.register(4, 6); // clearing must leave trader 0's claim intact
        handler.credit(0, 4, 4e18, 8);
        handler.elapse(12 hours);
        handler.flush(123, 50, 1);
        assertGt(handler.successfulFlushes(), 0);
        assertEq(handler.failedFlushes(), 2);
        assertEq(handler.rejectedCredits(), 1);
        assertGt(handler.tips(), 0);
        assertEq(handler.paid(), 11e18);
        assertGt(handler.donations(), 0);
        assertEq(remote.waiting(handler.traders(1)), 1e12 - 1);
        afterInvariant();
    }
}
