// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";
import {OracleAttestation} from "src/oracle/OracleAttestation.sol";
import {MockIntake, MockProject} from "./mocks/MockIntake.sol";
import {MockArbSys} from "./mocks/MockArbSys.sol";
import {BlocklistIMD} from "./RegistryBondOwed.t.sol";

/// @dev Independent obligations and recipient balances, including bonds which could not be paid.
/// Only the external token's recipient restrictions are simulated. Registry state is never
/// written with cheatcodes, and expected payouts are not inferred from observed balance deltas.
contract RobinhoodBondHandler is Test {
    uint256 internal constant KEY = 0xA11CE; // Local oracle double, never a deployment key.
    uint256 public constant BOND = 20e18;
    uint256 public constant INITIAL = 1_000_000e18;
    uint256 public constant ACTORS = 5;
    uint256 public constant PROJECTS = 3;
    MockArbSys internal constant ARBSYS = MockArbSys(address(0x64));

    struct Model {
        bool listed;
        bool completed;
        bool pinRequired;
        ProjectRegistry.Ask ask;
        address beneficiary;
        address asker;
        bytes32 id;
        uint16 rate;
        uint64 askedAt;
        uint64 fromBlock;
        uint64 toBlock;
        uint64 challengeOpenAt;
        uint64 handoffOpenAt;
    }

    ProjectRegistry public immutable registry;
    MockIntake public immutable intake;
    BlocklistIMD public immutable token;
    address[5] public actors;
    address[3] public projects;
    Model[3] internal model;
    mapping(address => uint256) public funds;
    mapping(address => uint256) public debt;
    mapping(address => bool) public blocked;
    bool public falseReturn;
    uint256 public price = 0.5e18;
    uint64 public height = 87_459_018;
    uint256 public fees;
    uint256 public donations;
    uint256 public openBonds;
    uint256 public bondsPosted;
    uint256 public bondsReleased;
    uint256 public applications;
    uint256 public challenges;
    uint256 public deferredPayments;
    uint256 public successfulClaims;
    uint256 public refusedClaims;
    uint256 public missedCallbacks;
    uint256 public expired;
    uint256 public failures;
    uint256 public handoffs;
    uint256 public retiredAsks;

    bytes32[] internal requestHistory;
    mapping(bytes32 => address) internal activeRequest;
    bytes32[3] internal lastClosed;
    bytes32[] internal oracleHistory;
    mapping(bytes32 => bool) internal usedOracleId;
    uint256 internal nonce;

    constructor(ProjectRegistry registry_, MockIntake intake_, BlocklistIMD token_) {
        registry = registry_;
        intake = intake_;
        token = token_;
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = makeAddr(string.concat("Robinhood bond actor ", vm.toString(i)));
            token.mint(actors[i], INITIAL);
            funds[actors[i]] = INITIAL;
        }
        for (uint256 i; i < PROJECTS; ++i) {
            projects[i] = address(new MockProject());
        }
    }

    function ask(uint256 projectSeed, uint256 payerSeed, uint256 beneficiarySeed, uint16 rateSeed)
        public
    {
        uint256 index = projectSeed % PROJECTS;
        Model storage m = model[index];
        if (m.ask != ProjectRegistry.Ask.None) return;
        if (m.listed && block.timestamp < m.challengeOpenAt) vm.warp(m.challengeOpenAt);
        address payer = actors[payerSeed % ACTORS];
        address beneficiary = actors[beneficiarySeed % ACTORS];
        uint16 rate = uint16(bound(rateSeed, 25, 100));

        if (price == 0) {
            vm.prank(payer);
            vm.expectRevert(ProjectRegistry.OracleUnavailable.selector);
            if (m.listed) {
                registry.challengeForBeneficiary(projects[index], "Review the fees.", m.beneficiary);
            } else {
                registry.applyListing(
                    projects[index], "Venue", "https://venue.example", rate, beneficiary
                );
            }
            ++retiredAsks;
            return;
        }

        uint256 amount = price + (m.listed ? BOND : 0);
        assertGe(funds[payer], amount, "harness funding exhausted");
        vm.startPrank(payer);
        token.approve(address(registry), amount);
        bytes32 id;
        if (m.listed) {
            id = registry.challengeForBeneficiary(
                projects[index], "Review the fees.", m.beneficiary
            );
        } else {
            id = registry.applyListing(
                projects[index], "Venue", "https://venue.example", rate, beneficiary
            );
        }
        vm.stopPrank();

        funds[payer] -= amount;
        fees += price;
        if (m.listed) {
            m.ask = ProjectRegistry.Ask.Challenge;
            openBonds += BOND;
            bondsPosted += BOND;
            ++challenges;
        } else {
            m.ask = ProjectRegistry.Ask.Apply;
            m.beneficiary = beneficiary;
            m.rate = rate;
            ++applications;
        }
        m.asker = payer;
        m.askedAt = uint64(block.timestamp);
        m.id = id;
        m.completed = false;
        assertNotEq(id, bytes32(0));
        assertEq(activeRequest[id], address(0), "Intake reused an open id");
        activeRequest[id] = projects[index];
        requestHistory.push(id);
    }

    /// @dev 0=yes, 1=no, 2=refused, 3=disagreed, 4=silent completion, 5=out of gas.
    /// Missed or late callbacks remain open until a separate expire action recovers them.
    function settle(uint256 projectSeed, uint8 outcomeSeed) public {
        uint256 index = projectSeed % PROJECTS;
        Model storage m = model[index];
        if (m.ask == ProjectRegistry.Ask.None || m.completed) return;
        uint256 outcome = outcomeSeed % 6;
        m.completed = true;
        if (outcome == 4) {
            intake.completeSilently(m.id);
            ++missedCallbacks;
            return;
        }
        if (outcome == 2 || outcome == 3) {
            assertTrue(
                intake.fail(
                    m.id,
                    outcome == 2 ? 1 : 2,
                    outcome == 2 ? bytes32("body_refused") : bytes32("disagreed"),
                    200_000
                ),
                "failure callback must clear even a blocked recipient"
            );
            if (m.ask == ProjectRegistry.Ask.Challenge) _pay(m.asker);
            _close(index);
            ++failures;
            return;
        }

        OracleAttestation.Attestation memory a = _attestation(outcome == 0);
        oracleHistory.push(a.requestId);
        bool delivered = intake.deliver(m.id, a, _sign(a), outcome == 5 ? 5_000 : 200_000);
        if (outcome == 5 || block.timestamp > uint256(m.askedAt) + 1 days) {
            assertFalse(delivered, "late or starved callback accepted");
            ++missedCallbacks;
            return;
        }
        assertTrue(delivered, "valid callback must settle within 200k");
        usedOracleId[a.requestId] = true;
        if (m.ask == ProjectRegistry.Ask.Apply) {
            if (outcome == 0) {
                m.listed = true;
                m.fromBlock = height;
                m.toBlock = 0;
                m.challengeOpenAt = uint64(block.timestamp + 7 days);
            }
        } else if (outcome == 0) {
            _pay(m.beneficiary);
        } else {
            m.listed = false;
            m.toBlock = height;
            _pay(m.asker);
        }
        _close(index);
    }

    function expire(uint256 projectSeed, uint256 callerSeed, bool afterDeadline) public {
        uint256 index = projectSeed % PROJECTS;
        Model storage m = model[index];
        if (m.ask == ProjectRegistry.Ask.None) return;
        uint256 deadline = uint256(m.askedAt) + 1 days;
        if (afterDeadline && block.timestamp <= deadline) vm.warp(deadline + 1);
        vm.prank(actors[callerSeed % ACTORS]);
        if (!m.completed && block.timestamp <= deadline) {
            vm.expectRevert(ProjectRegistry.NotStale.selector);
            registry.expire(projects[index]);
            return;
        }
        registry.expire(projects[index]);
        if (m.ask == ProjectRegistry.Ask.Challenge) _pay(m.asker);
        _close(index);
        ++expired;
    }

    function restrictRecipient(uint256 actorSeed, bool restricted, bool returnsFalse) public {
        address actor = actors[actorSeed % ACTORS];
        token.setBlocked(actor, restricted);
        token.setReturnFalse(returnsFalse);
        blocked[actor] = restricted;
        falseReturn = returnsFalse;
    }

    function claim(uint256 actorSeed, uint256 recipientSeed) public {
        address actor = actors[actorSeed % ACTORS];
        address recipient = actors[recipientSeed % ACTORS];
        uint256 amount = debt[actor];
        vm.prank(actor);
        if (amount == 0) {
            vm.expectRevert(ProjectRegistry.NothingOwed.selector);
            registry.claimBond(recipient);
            ++refusedClaims;
        } else if (blocked[recipient]) {
            if (falseReturn) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        SafeERC20.SafeERC20FailedOperation.selector, address(token)
                    )
                );
            } else {
                vm.expectRevert(bytes("blocked"));
            }
            registry.claimBond(recipient);
            ++refusedClaims;
        } else {
            registry.claimBond(recipient);
            debt[actor] = 0;
            funds[recipient] += amount;
            bondsReleased += amount;
            ++successfulClaims;
        }
    }

    function invalidClaim(uint256 actorSeed, bool toRegistry) public {
        vm.prank(actors[actorSeed % ACTORS]);
        vm.expectRevert(
            toRegistry
                ? ProjectRegistry.InvalidBeneficiary.selector
                : ProjectRegistry.ZeroAddress.selector
        );
        registry.claimBond(toRegistry ? address(registry) : address(0));
    }

    function handoff(uint256 projectSeed, uint256 recipientSeed) public {
        uint256 index = projectSeed % PROJECTS;
        Model storage m = model[index];
        address recipient = actors[recipientSeed % ACTORS];
        vm.prank(m.beneficiary == address(0) ? actors[0] : m.beneficiary);
        if (!m.listed) {
            vm.expectRevert(ProjectRegistry.NotListed.selector);
        } else if (m.ask != ProjectRegistry.Ask.None) {
            vm.expectRevert(ProjectRegistry.AskOpen.selector);
        } else if (recipient != m.beneficiary && block.timestamp < m.handoffOpenAt) {
            vm.expectRevert(
                abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, m.handoffOpenAt)
            );
        } else {
            registry.setBeneficiary(projects[index], recipient);
            if (recipient != m.beneficiary) {
                m.pinRequired = true;
                m.handoffOpenAt = uint64(block.timestamp + 1 days);
                ++handoffs;
            }
            m.beneficiary = recipient;
            return;
        }
        registry.setBeneficiary(projects[index], recipient);
    }

    function replayClosed(uint256 projectSeed) public {
        bytes32 id = lastClosed[projectSeed % PROJECTS];
        if (id == bytes32(0)) return;
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory signature = _sign(a);
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, id));
        registry.onOracleResult(id, a, signature);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, id));
        registry.onOracleFailure(id, 2, "disagreed", 0, 0, "");
        vm.stopPrank();
        assertFalse(registry.consumed(a.requestId), "replayed callback consumed a new oracle id");
    }

    function donate(uint256 actorSeed, uint96 amountSeed) public {
        address actor = actors[actorSeed % ACTORS];
        uint256 amount = bound(amountSeed, 0, 1e18);
        vm.prank(actor);
        token.transfer(address(registry), amount);
        funds[actor] -= amount;
        donations += amount;
    }

    function reprice(uint96 priceSeed) public {
        price = bound(priceSeed, 0, 2e18);
        intake.setPrice(price);
    }

    function advance(uint32 secondsSeed, uint16 rollupSeed, uint8 parentSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 8 days));
        height += uint64(bound(rollupSeed, 1, 10_000));
        ARBSYS.setBlockNumber(height);
        // Distinct rollup blocks may share one parent block.
        vm.roll(block.number + bound(parentSeed, 0, 100));
    }

    function _pay(address recipient) internal {
        openBonds -= BOND;
        if (blocked[recipient]) {
            debt[recipient] += BOND;
            ++deferredPayments;
        } else {
            funds[recipient] += BOND;
            bondsReleased += BOND;
        }
    }

    function _close(uint256 index) internal {
        Model storage m = model[index];
        delete activeRequest[m.id];
        lastClosed[index] = m.id;
        m.ask = ProjectRegistry.Ask.None;
        m.asker = address(0);
        m.id = bytes32(0);
        m.completed = false;
    }

    function _attestation(bool yes) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(++nonce << 128);
        a.chainId = 4663;
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, registry.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function assertLedger() public view {
        uint256 owed;
        uint256 actorFunds;
        for (uint256 i; i < ACTORS; ++i) {
            address actor = actors[i];
            assertEq(token.balanceOf(actor), funds[actor], "wrong payout or fee payer");
            assertEq(registry.bondOwed(actor), debt[actor], "wrong debt creditor or amount");
            assertEq(token.allowance(actor, address(registry)), 0, "exact allowance not spent");
            owed += debt[actor];
            actorFunds += funds[actor];
        }
        assertEq(token.balanceOf(address(registry)), openBonds + owed + donations, "bond backing");
        assertEq(bondsPosted, bondsReleased + openBonds + owed, "a bond lost or paid twice");
        assertEq(token.balanceOf(intake.TREASURY()), fees, "only live question prices are spent");
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(address(registry), address(intake)), 0, "Intake can draw bonds");
        assertEq(actorFunds + openBonds + owed + donations + fees, ACTORS * INITIAL);
        assertEq(token.totalSupply(), ACTORS * INITIAL, "supply changed during campaign");
        assertEq(intake.count(), applications + challenges);
    }

    function assertLifecycle() public view {
        uint256 pendingBonds;
        for (uint256 i; i < PROJECTS; ++i) {
            Model storage m = model[i];
            ProjectRegistry.Project memory p = registry.projectOf(projects[i]);
            assertEq(p.listed, m.listed, "listing differs from signed outcomes");
            assertEq(uint8(p.ask), uint8(m.ask), "pending state");
            assertEq(p.beneficiary, m.beneficiary);
            assertEq(p.asker, m.asker);
            assertEq(p.intakeId, m.id);
            assertEq(p.rateBps, m.rate);
            assertEq(p.askedAt, m.askedAt);
            assertEq(p.fromBlock, m.fromBlock, "wrong rollup listing height");
            assertEq(p.toBlock, m.toBlock, "wrong rollup delisting height");
            assertEq(p.challengeOpenAt, m.challengeOpenAt, "defense restarted cooldown");
            assertEq(registry.handoffOpenAt(projects[i]), m.handoffOpenAt);
            assertEq(registry.beneficiaryPinRequired(projects[i]), m.pinRequired);
            if (m.ask == ProjectRegistry.Ask.Challenge) pendingBonds += BOND;
        }
        assertEq(pendingBonds, openBonds);
        for (uint256 i; i < requestHistory.length; ++i) {
            bytes32 id = requestHistory[i];
            assertEq(
                registry.projectOfIntake(id),
                activeRequest[id],
                "request index leaked across projects"
            );
        }
        for (uint256 i; i < oracleHistory.length; ++i) {
            bytes32 id = oracleHistory[i];
            assertEq(registry.consumed(id), usedOracleId[id], "oracle replay state");
        }
    }
}

/// @notice Tests the Robinhood settings with offline token/Intake/ArbSys doubles. The existing
/// manifest rehearsal separately verifies the actual signer and dependency addresses.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RegistryRobinhoodBondInvariantTest is StdInvariant, Test {
    ProjectRegistry internal registry;
    BlocklistIMD internal token;
    MockIntake internal intake;
    RobinhoodBondHandler internal handler;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        vm.roll(26_180_000);
        MockArbSys implementation = new MockArbSys();
        vm.etch(address(0x64), address(implementation).code);
        MockArbSys(address(0x64)).setBlockNumber(87_459_018);
        token = new BlocklistIMD();
        intake = new MockIntake();
        registry = new ProjectRegistry(
            address(intake),
            address(token),
            0x4De07c2fa46D5d6ED9CEB3f38ec56d3461b3E898,
            vm.addr(0xA11CE),
            4663,
            20e18,
            7 days
        );
        handler = new RobinhoodBondHandler(registry, intake, token);

        // Start with concurrent value-bearing requests and one deferred bond; an invariant
        // cannot pass just because it never got past an application or never created any debt.
        for (uint256 i; i < 3; ++i) {
            handler.ask(i, i, i + 1, 50);
            handler.settle(i, 0);
        }
        for (uint256 i; i < 3; ++i) {
            handler.ask(i, 4, 0, 50);
        }
        handler.restrictRecipient(1, true, false);
        handler.settle(0, 0);
        _check();

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.ask.selector;
        selectors[1] = handler.settle.selector;
        selectors[2] = handler.expire.selector;
        selectors[3] = handler.restrictRecipient.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.invalidClaim.selector;
        selectors[6] = handler.handoff.selector;
        selectors[7] = handler.replayClosed.selector;
        selectors[8] = handler.donate.selector;
        selectors[9] = handler.reprice.selector;
        selectors[10] = handler.advance.selector;
        selectors[11] = handler.ask.selector; // Requests get extra weight after settlements.
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_bondsRemainBackedAndBelongToTheirCreditors() public view {
        handler.assertLedger();
    }

    function invariant_questionsStayIsolatedAndPeriodsUseRollupBlocks() public view {
        handler.assertLifecycle();
    }

    /// @dev Close every pending question and withdraw all debts after every random sequence.
    /// Claims must remain possible after recipients are unblocked, including after failed claims.
    function afterInvariant() public {
        for (uint256 i; i < 3; ++i) {
            handler.expire(i, (i + 1) % 5, true);
        }
        for (uint256 i; i < 5; ++i) {
            handler.restrictRecipient(i, false, false);
        }
        for (uint256 i; i < 5; ++i) {
            handler.claim(i, i);
        }
        _check();
        assertEq(handler.openBonds(), 0);
        assertEq(
            token.balanceOf(address(registry)), handler.donations(), "unclaimable bond remains"
        );
    }

    function test_repeatedDeferredBondsAccumulateAndOneClaimCannotSpendOtherBonds() public {
        address creditor = handler.actors(1);
        handler.claim(1, 1); // Reverting token: the original debt must survive.
        _check();
        handler.restrictRecipient(1, true, true);
        handler.claim(1, 1); // False-returning token must restore the same debt.
        _check();
        handler.ask(0, 0, 0, 50);
        handler.settle(0, 0);
        _check();
        assertEq(registry.bondOwed(creditor), 40e18);
        assertEq(handler.openBonds(), 40e18, "two unrelated challenges remain funded");

        handler.handoff(0, 2);
        handler.invalidClaim(1, true);
        handler.invalidClaim(1, false);
        handler.claim(2, 2); // New beneficiary cannot take the previous beneficiary's debt.
        _check();
        assertEq(registry.bondOwed(creditor), 40e18);
        handler.claim(1, 3); // Original creditor may redirect the entire accrued amount.
        _check();
        assertEq(registry.bondOwed(creditor), 0);
        assertEq(token.balanceOf(address(registry)), 40e18);
        handler.claim(1, 3); // Cannot claim twice.
        handler.replayClosed(0);
        _check();
        afterInvariant();
    }

    function test_failedAndMissingCallbacksRefundOnlyTheChallengerDespiteInterleaving() public {
        handler.restrictRecipient(4, true, false);
        handler.settle(1, 2); // Refused challenge; debt to its challenger, never beneficiary.
        _check();
        handler.settle(2, 5); // OOG result: still open, Intake has already completed it.
        _check();
        assertEq(handler.openBonds(), 20e18);
        handler.expire(2, 0, false); // Any unrelated actor may recover it immediately.
        _check();
        assertEq(registry.bondOwed(handler.actors(4)), 40e18);
        assertTrue(registry.isListed(handler.projects(1)));
        assertTrue(registry.isListed(handler.projects(2)));
        handler.claim(4, 0);
        handler.replayClosed(1);
        handler.replayClosed(2);
        _check();
        afterInvariant();
    }

    function test_handlerExercisesEverySettlementAndFeeRetirementWithoutVacuity() public {
        handler.settle(1, 1); // Delist and refund.
        handler.settle(2, 3); // Panel disagreement and refund.
        _check();
        handler.ask(1, 0, 2, 25);
        handler.settle(1, 1); // Application rejection.
        handler.ask(1, 0, 2, 100);
        handler.settle(1, 4); // Silent completion.
        handler.expire(1, 3, false);
        _check();
        handler.ask(1, 0, 2, 100);
        handler.advance(1 days + 1, 10, 0);
        handler.settle(1, 0); // Correct signature still cannot list after the deadline.
        handler.expire(1, 3, false);
        _check();
        handler.reprice(0);
        handler.ask(1, 0, 2, 50); // Retired action cannot consume any prior bond or donation.
        handler.ask(0, 0, 0, 50);
        handler.donate(3, 1);
        _check();
        handler.reprice(1); // One-wei live price, independent of the fixed 20 IMD bond.
        handler.ask(1, 0, 2, 50);
        handler.settle(1, 0);
        handler.handoff(1, 3);
        handler.handoff(1, 4); // Second handoff within a day is refused.
        _check();
        assertGt(handler.failures(), 0);
        assertGt(handler.missedCallbacks(), 0);
        assertGt(handler.expired(), 0);
        assertGt(handler.deferredPayments(), 0);
        assertGt(handler.retiredAsks(), 0);
        assertGt(handler.handoffs(), 0);
        afterInvariant();
    }

    function _check() internal view {
        handler.assertLedger();
        handler.assertLifecycle();
    }
}
