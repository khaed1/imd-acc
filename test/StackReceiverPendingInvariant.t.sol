// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StackReceiver, IStakedIMD} from "src/multichain/StackReceiver.sol";
import {MockOFT} from "./mocks/MockOFT.sol";
import {TestSIMD} from "./mocks/TestSIMD.sol";
import {QueuedComposeEndpoint} from "./mocks/QueuedComposeEndpoint.sol";

/// @dev Arrivals and execution are different actions. Ghost obligations come from funded
/// packets, not receiver counters or payout events. This campaign keeps the vault exchange
/// rate at its initial 1e6 shares/wei; donation-driven rounding is covered in StackReceiver.t.sol.
contract ReceiverPendingHandler is Test {
    struct Packet {
        bytes32 guid;
        uint32 eid;
        uint256 amount;
        bytes message;
        address[] traders;
        uint256[] amounts;
        bool delivered;
    }

    MockOFT public immutable imd;
    TestSIMD public immutable vault;
    QueuedComposeEndpoint public immutable endpoint;
    StackReceiver public immutable receiver;
    Packet[] private packets;
    address[6] public actors;

    uint256 public arrived;
    uint256 public pending;
    uint256 public stray;
    uint256 public delivered;
    uint256 public deposited;
    uint256 public plain;
    mapping(uint32 => uint256) public deliveredBySource;
    mapping(address => uint256) public expectedShares;
    mapping(address => uint256) public expectedPlain;

    uint256 public successfulComposes;
    uint256 public rejectedComposes;
    uint256 public replayAttempts;
    uint256 public stakedEntries;
    uint256 public plainEntries;

    constructor() {
        imd = new MockOFT();
        vault = new TestSIMD(address(imd), address(this));
        endpoint = new QueuedComposeEndpoint();
        receiver =
            new StackReceiver(IERC20(address(imd)), IStakedIMD(address(vault)), address(endpoint));
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("pending actor ", vm.toString(i)));
        }
    }

    function source(uint256 seed) public pure returns (uint32) {
        // Robinhood plus synthetic boundary EIDs: the receiver does not maintain a source allowlist.
        return seed % 3 == 0 ? uint32(30416) : seed % 3 == 1 ? uint32(0) : type(uint32).max;
    }

    function arrive(uint256 seed, uint64 units, uint8 rawCount, uint8 eidSeed) public {
        uint256 count = bound(rawCount, 1, 6);
        uint256 amount = uint256(units) * 1e12;
        address[] memory traders = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 remaining = amount;
        for (uint256 i; i < count; ++i) {
            uint256 pick = uint256(keccak256(abi.encode(seed, i)));
            traders[i] = actors[pick % actors.length];
            // Splitting a bridge-quantized total into arbitrary wei exercises zeros, duplicates
            // and tiny entries without inventing an arrival the OFT could not encode.
            amounts[i] = i + 1 == count ? remaining : pick % (remaining + 1);
            remaining -= amounts[i];
        }
        uint64 nonce = uint64(packets.length + 1);
        uint32 eid = source(eidSeed);
        bytes32 guid = keccak256(abi.encode("pending arrival", nonce, eid));
        bytes memory message =
            abi.encodePacked(nonce, eid, amount, bytes32(seed), abi.encode(traders, amounts));
        imd.mint(address(receiver), amount);
        vm.prank(address(imd));
        endpoint.sendCompose(address(receiver), guid, 0, message);
        packets.push(Packet(guid, eid, amount, message, traders, amounts, false));
        arrived += amount;
        pending += amount;
    }

    function donate(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, 1e24);
        imd.mint(address(receiver), amount);
        stray += amount;
    }

    function pause(bool paused) public {
        vault.setPaused(paused);
    }

    function compose(uint256 seed, uint8 refuseMask) public {
        if (packets.length == 0) return;
        Packet storage p = packets[seed % packets.length];
        if (p.delivered) {
            bytes32 beforeReplay = _state();
            vm.expectRevert(QueuedComposeEndpoint.MessageNotQueued.selector);
            endpoint.lzCompose(address(imd), address(receiver), p.guid, 0, p.message, "");
            assertEq(_state(), beforeReplay, "replay changed balances or counters");
            ++replayAttempts;
            return;
        }
        bool paused = vault.paused();
        for (uint256 i; i < p.traders.length; ++i) {
            if (_refused(p.traders[i], refuseMask)) {
                vm.mockCallRevert(
                    address(vault),
                    abi.encodeCall(vault.deposit, (p.amounts[i], p.traders[i])),
                    "recipient refused"
                );
            }
        }
        uint256 beforeBalance = imd.balanceOf(address(receiver));
        endpoint.lzCompose(address(imd), address(receiver), p.guid, 0, p.message, "");
        vm.clearMockedCalls();
        assertEq(
            beforeBalance - imd.balanceOf(address(receiver)),
            p.amount,
            "spent another arrival or retained this one"
        );
        for (uint256 i; i < p.traders.length; ++i) {
            uint256 amount = p.amounts[i];
            if (amount == 0) continue;
            address trader = p.traders[i];
            if (paused || _refused(trader, refuseMask)) {
                expectedPlain[trader] += amount;
                plain += amount;
                ++plainEntries;
            } else {
                expectedShares[trader] += amount * 1e6;
                deposited += amount;
                ++stakedEntries;
            }
        }
        p.delivered = true;
        pending -= p.amount;
        delivered += p.amount;
        deliveredBySource[p.eid] += p.amount;
        ++successfulComposes;
    }

    /// @dev These calls reach the receiver (not just the queue). Failed calls leave a real
    /// funded packet available to a later compose action. No unexpected revert is swallowed.
    function reject(uint256 seed, uint8 rawMode) public {
        if (packets.length == 0) return;
        Packet storage p = packets[seed % packets.length];
        if (p.delivered) return;
        bytes32 beforeRejected = _state();
        bytes32 beforeQueue = endpoint.composeQueue(address(imd), address(receiver), p.guid, 0);
        uint256 mode = rawMode % 3;
        if (mode == 0) {
            vm.expectRevert(StackReceiver.NotEndpoint.selector);
            receiver.lzCompose(address(imd), p.guid, p.message, address(endpoint), "");
        } else if (mode == 1) {
            vm.deal(address(this), 1);
            vm.expectRevert(StackReceiver.UnexpectedValue.selector);
            endpoint.lzCompose{value: 1}(address(imd), address(receiver), p.guid, 0, p.message, "");
        } else {
            // This sender pays for a separate invalid message, with a list overstating the
            // funded amount by one wei. Other queued messages and donations must stay intact.
            address[] memory traders = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            traders[0] = actors[0];
            amounts[0] = 1;
            bytes memory bad = abi.encodePacked(
                uint64(1), p.eid, uint256(0), bytes32(0), abi.encode(traders, amounts)
            );
            bytes32 badGuid = keccak256(abi.encode("bad list", rejectedComposes));
            vm.prank(address(imd));
            endpoint.sendCompose(address(receiver), badGuid, 0, bad);
            vm.expectRevert(abi.encodeWithSelector(StackReceiver.AmountMismatch.selector, 1, 0));
            endpoint.lzCompose(address(imd), address(receiver), badGuid, 0, bad, "");
            assertEq(
                endpoint.composeQueue(address(imd), address(receiver), badGuid, 0), keccak256(bad)
            );
        }
        assertEq(_state(), beforeRejected, "failed message changed economic state");
        assertEq(endpoint.composeQueue(address(imd), address(receiver), p.guid, 0), beforeQueue);
        ++rejectedComposes;
    }

    function _refused(address trader, uint8 mask) internal view returns (bool) {
        for (uint256 i; i < actors.length; ++i) {
            if (actors[i] == trader) return uint256(mask) & (uint256(1) << i) != 0;
        }
        revert("untracked actor");
    }

    function _state() internal view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                imd.balanceOf(address(receiver)),
                imd.balanceOf(address(vault)),
                vault.totalSupply(),
                receiver.totalDelivered(),
                receiver.deliveredFrom(source(0)),
                receiver.deliveredFrom(source(1)),
                receiver.deliveredFrom(source(2)),
                imd.allowance(address(receiver), address(vault))
            )
        );
        for (uint256 i; i < actors.length; ++i) {
            result = keccak256(
                abi.encode(
                    result,
                    imd.balanceOf(actors[i]),
                    vault.balanceOf(actors[i]),
                    vault.lastDepositBlock(actors[i])
                )
            );
        }
    }

    function packetCount() external view returns (uint256) {
        return packets.length;
    }

    function assertQueues() external view {
        uint256 stillPending;
        for (uint256 i; i < packets.length; ++i) {
            Packet storage p = packets[i];
            bytes32 expected = p.delivered ? endpoint.RECEIVED() : keccak256(p.message);
            assertEq(endpoint.composeQueue(address(imd), address(receiver), p.guid, 0), expected);
            if (!p.delivered) stillPending += p.amount;
        }
        assertEq(stillPending, pending);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StackReceiverPendingInvariantTest is StdInvariant, Test {
    ReceiverPendingHandler internal handler;
    StackReceiver internal receiver;
    TestSIMD internal vault;
    MockOFT internal imd;

    function setUp() public {
        vm.roll(1_000);
        handler = new ReceiverPendingHandler();
        receiver = handler.receiver();
        vault = handler.vault();
        imd = handler.imd();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.arrive.selector;
        selectors[1] = handler.compose.selector;
        selectors[2] = handler.reject.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.pause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        // Always begin with two independently deliverable packets, not an empty inert system.
        handler.arrive(11, 7e6, 3, 0);
        handler.arrive(23, 5e6, 4, 1);
    }

    function invariant_pendingAndUnsolicitedIMDAreFullyBacked() public view {
        assertEq(imd.balanceOf(address(receiver)), handler.pending() + handler.stray());
        assertEq(handler.arrived(), handler.pending() + handler.delivered());
        assertEq(imd.balanceOf(address(vault)), handler.deposited());
        assertEq(handler.delivered(), handler.deposited() + handler.plain());
        assertEq(imd.totalSupply(), handler.arrived() + handler.stray());
        handler.assertQueues();
    }

    function invariant_eachTraderReceivesOnlyTheirFundedAllocation() public view {
        uint256 allPlain;
        uint256 allShares;
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            uint256 shares = vault.balanceOf(actor);
            uint256 amount = imd.balanceOf(actor);
            assertEq(shares, handler.expectedShares(actor), "wrong trader or share amount");
            assertEq(amount, handler.expectedPlain(actor), "wrong plain IMD payout");
            allPlain += amount;
            allShares += shares;
        }
        assertEq(allPlain, handler.plain());
        assertEq(allShares, vault.totalSupply());
        assertEq(vault.balanceOf(address(receiver)), 0);
        assertEq(imd.balanceOf(address(handler)), 0, "executor receives no cashback");
    }

    function invariant_countersCountOnlySuccessfulDeliveryOncePerSource() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint32 eid = handler.source(i);
            assertEq(receiver.deliveredFrom(eid), handler.deliveredBySource(eid));
            sum += receiver.deliveredFrom(eid);
        }
        assertEq(sum, receiver.totalDelivered());
        assertEq(receiver.totalDelivered(), handler.delivered());
        assertEq(address(receiver).balance, 0);
    }

    function test_handlerReachesRetriesMixedPayoutsReplayAndOutOfOrderDelivery() public {
        handler.donate(7e18);
        handler.reject(1, 0);
        handler.reject(1, 1);
        handler.reject(1, 2);
        handler.compose(1, 0); // second arrival executes first
        handler.compose(1, 0); // replay with another arrival still funded
        handler.pause(true);
        handler.compose(0, 0);
        handler.pause(false);
        handler.arrive(99, 11e6, 6, 2);
        uint256 plainBefore = handler.plainEntries();
        uint256 stakedBefore = handler.stakedEntries();
        handler.compose(2, 0x15); // per-recipient failures in a single batch
        assertEq(handler.successfulComposes(), 3);
        assertEq(handler.rejectedComposes(), 3);
        assertEq(handler.replayAttempts(), 1);
        assertGt(handler.plainEntries(), plainBefore, "last batch reaches plain fallback");
        assertGt(handler.stakedEntries(), stakedBefore, "last batch also reaches staking");
        assertEq(handler.pending(), 0);
        invariant_pendingAndUnsolicitedIMDAreFullyBacked();
        invariant_eachTraderReceivesOnlyTheirFundedAllocation();
        invariant_countersCountOnlySuccessfulDeliveryOncePerSource();
    }
}
