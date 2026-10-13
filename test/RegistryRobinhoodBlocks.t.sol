// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {MockIntake, MintableIMD, MockProject} from "./mocks/MockIntake.sol";
import {MockArbSys} from "./mocks/MockArbSys.sol";
import {BlocklistIMD} from "./RegistryBondOwed.t.sol";

abstract contract RegistryRobinhoodBase is Test {
    uint256 internal constant KEY = 0xA11CE;
    uint256 internal constant BOND = 20e18;
    uint256 internal constant PARENT_BLOCK = 26_183_281;
    uint64 internal constant LISTING_BLOCK = 87_470_000;
    uint64 internal constant DELISTING_BLOCK = 87_600_000;
    address internal constant REMOTE_STACKER = 0x4De07c2fa46D5d6ED9CEB3f38ec56d3461b3E898;
    MockArbSys internal constant ARBSYS = MockArbSys(address(0x64));

    MockIntake internal intake;
    MintableIMD internal imd;
    ProjectRegistry internal reg;
    address internal project;
    address internal applicant = makeAddr("applicant");
    address internal challenger = makeAddr("challenger");
    address internal beneficiary = makeAddr("beneficiary");
    uint256 internal uuid;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.roll(PARENT_BLOCK);
        vm.warp(1_800_000_000);
        MockArbSys model = new MockArbSys();
        vm.etch(address(ARBSYS), address(model).code);
        ARBSYS.setBlockNumber(LISTING_BLOCK);
        intake = new MockIntake();
        imd = new MintableIMD();
        reg = new ProjectRegistry(
            address(intake), address(imd), REMOTE_STACKER, vm.addr(KEY), 4663, BOND, 7 days
        );
        project = address(new MockProject());
        _fund(applicant);
        _fund(challenger);
    }

    function _fund(address who) internal {
        imd.mint(who, 1_000e18);
        vm.prank(who);
        imd.approve(address(reg), type(uint256).max);
    }

    function _apply() internal returns (bytes32 id) {
        vm.prank(applicant);
        return reg.applyListing(project, "Venue", "https://venue.example/source", 50, beneficiary);
    }

    function _challenge() internal returns (bytes32 id) {
        vm.warp(reg.projectOf(project).challengeOpenAt);
        vm.prank(challenger);
        return reg.challengeForBeneficiary(project, "Review every rule.", beneficiary);
    }

    function _attestation(bool yes) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(++uuid << 128);
        a.chainId = reg.questionChainId();
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, reg.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _answer(bytes32 id, bool yes) internal {
        OracleAttestation.Attestation memory a = _attestation(yes);
        assertTrue(intake.deliver(id, a, _sign(a), 200_000), "callback delivered within 200k");
    }

    function _listedAt(ProjectRegistry.Project memory p, uint64 creditBlock)
        internal
        pure
        returns (bool)
    {
        // The snapshot builder's half-open interval predicate, over credit log block numbers.
        return creditBlock >= p.fromBlock && (p.toBlock == 0 || creditBlock < p.toBlock);
    }
}

/// @dev Audit d118fc17bdae: NUMBER is the parent height on Robinhood, while RPC/logs use L2.
contract RegistryRobinhoodBlocksTest is RegistryRobinhoodBase {
    function test_robinhoodQuestionNamesLiveRemoteStackerWithoutCallingIt() public {
        vm.startStateDiffRecording();
        bytes32 id = _apply();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account == REMOTE_STACKER) {
                assertTrue(
                    accesses[i].kind != VmSafe.AccountAccessKind.Call
                        && accesses[i].kind != VmSafe.AccountAccessKind.StaticCall,
                    "RemoteStacker must only be named in the question"
                );
            }
        }
        string memory body = string(intake.bodyOf(id));
        assertEq(vm.parseJsonUint(body, ".chainId"), 4663);
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), 4663);
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(reg));
        assertEq(vm.parseJsonUint(body, ".panelSize"), 15);
        assertEq(vm.parseJsonUint(body, ".quorum"), 11);
        assertTrue(
            vm.contains(
                vm.parseJsonString(body, ".question"),
                "Stacker 0x4de07c2fa46d5d6ed9ceb3f38ec56d3461b3e898 on chain 4663"
            )
        );
        string[] memory rules = vm.parseJsonKeys(body, ".definitions");
        assertEq(rules.length, 8);
        for (uint256 i; i < rules.length; ++i) {
            assertLe(
                bytes(vm.parseJsonString(body, string.concat(".definitions.", rules[i]))).length,
                512
            );
        }
        assertEq(imd.balanceOf(intake.TREASURY()), 0.5e18);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_listingAndDelistingUseRollupBlocksInStorageAndEvents() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        vm.expectEmit(address(reg));
        emit ProjectRegistry.Listed(project, 50, beneficiary, LISTING_BLOCK, a.requestId);
        assertTrue(intake.deliver(id, a, _sign(a), 200_000));
        ProjectRegistry.Project memory p = reg.projectOf(project);
        assertEq(p.fromBlock, LISTING_BLOCK);
        assertEq(p.toBlock, 0);
        assertFalse(_listedAt(p, 87_400_000), "no pre-listing credits");
        assertFalse(_listedAt(p, LISTING_BLOCK - 1));
        assertTrue(_listedAt(p, LISTING_BLOCK), "inclusive listing boundary");

        id = _challenge();
        vm.roll(PARENT_BLOCK + 50_000);
        ARBSYS.setBlockNumber(DELISTING_BLOCK);
        a = _attestation(false);
        vm.expectEmit(address(reg));
        emit ProjectRegistry.Delisted(project, DELISTING_BLOCK, a.requestId);
        assertTrue(intake.deliver(id, a, _sign(a), 200_000));
        p = reg.projectOf(project);
        assertEq(p.fromBlock, LISTING_BLOCK);
        assertEq(p.toBlock, DELISTING_BLOCK);
        assertFalse(p.listed);
        assertTrue(_listedAt(p, LISTING_BLOCK), "earned points survive delisting");
        assertTrue(_listedAt(p, DELISTING_BLOCK - 1));
        assertFalse(_listedAt(p, DELISTING_BLOCK), "exclusive delisting boundary");
        assertFalse(_listedAt(p, DELISTING_BLOCK + 1));
        assertEq(imd.balanceOf(address(reg)), 0, "bond returned");
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
    }

    function test_distinctRollupTransitionsWithinOneParentBlock() public {
        _answer(_apply(), true);
        bytes32 id = _challenge();
        vm.roll(PARENT_BLOCK + 50_000);
        ARBSYS.setBlockNumber(DELISTING_BLOCK);
        _answer(id, false);
        uint64 endedAt = reg.projectOf(project).toBlock;

        // A relisting in the next L2 block need not advance the parent's NUMBER opcode.
        ARBSYS.setBlockNumber(DELISTING_BLOCK + 1);
        _answer(_apply(), true);
        assertEq(block.number, PARENT_BLOCK + 50_000);
        assertEq(endedAt, DELISTING_BLOCK);
        assertEq(reg.projectOf(project).fromBlock, DELISTING_BLOCK + 1);
        assertGt(reg.projectOf(project).fromBlock, endedAt);
        assertEq(reg.projectOf(project).toBlock, 0);
    }

    function testFuzz_periodExcludesEarlierCreditsAndRetainsEarnedOnDelisting(
        uint32 startSeed,
        uint32 spanSeed,
        uint32 offsetSeed
    ) public {
        uint64 start = uint64(bound(startSeed, 80_000_000, 100_000_000));
        uint64 end = start + uint64(bound(spanSeed, 1, 10_000_000));
        uint64 earnedAt = uint64(bound(offsetSeed, start, end - 1));
        ARBSYS.setBlockNumber(start);
        _answer(_apply(), true);
        ProjectRegistry.Project memory p = reg.projectOf(project);
        assertFalse(_listedAt(p, start - 1));
        assertTrue(_listedAt(p, earnedAt));
        bytes32 id = _challenge();
        ARBSYS.setBlockNumber(end);
        _answer(id, false);
        p = reg.projectOf(project);
        assertTrue(_listedAt(p, earnedAt), "delisting preserves historical points");
        assertFalse(_listedAt(p, end));
        assertFalse(_listedAt(p, start - 1));
    }

    function test_mainnetAndSepoliaUseNumberEvenWhenQuestionChainIsRobinhood() public {
        vm.mockCallRevert(
            address(ARBSYS), abi.encodeWithSignature("arbBlockNumber()"), "unavailable"
        );
        uint256[2] memory chains = [uint256(1), uint256(11155111)];
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            project = address(new MockProject());
            _answer(_apply(), true);
            assertEq(reg.projectOf(project).fromBlock, block.number);
            bytes32 id = _challenge();
            vm.roll(block.number + 5);
            _answer(id, false);
            assertEq(reg.projectOf(project).toBlock, block.number);
        }
    }

    function test_blockSourceUsesExecutionChainRatherThanQuestionChain() public {
        reg = new ProjectRegistry(
            address(intake), address(imd), REMOTE_STACKER, vm.addr(KEY), 1, BOND, 7 days
        );
        _fund(applicant);
        _answer(_apply(), true);
        assertEq(reg.projectOf(project).fromBlock, LISTING_BLOCK);
    }

    function test_unavailableArbSysCannotSilentlyUseParentHeight() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        vm.mockCallRevert(
            address(ARBSYS), abi.encodeWithSignature("arbBlockNumber()"), "unavailable"
        );
        assertFalse(intake.deliver(id, a, _sign(a), 200_000));
        assertFalse(reg.isListed(project));
        assertEq(reg.projectOf(project).fromBlock, 0);
        assertEq(reg.projectOfIntake(id), project, "failed callback is atomic");
        assertFalse(reg.consumed(a.requestId));
        reg.expire(project); // The Intake marked it completed even though delivery failed.
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
    }

    function test_malformedArbSysCannotEraseAnExistingListingOrBond() public {
        _answer(_apply(), true);
        bytes32 id = _challenge();
        OracleAttestation.Attestation memory a = _attestation(false);
        vm.mockCall(address(ARBSYS), abi.encodeWithSignature("arbBlockNumber()"), hex"01");
        assertFalse(intake.deliver(id, a, _sign(a), 200_000));
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOf(project).fromBlock, LISTING_BLOCK);
        assertEq(reg.projectOf(project).toBlock, 0);
        assertEq(imd.balanceOf(address(reg)), BOND);
        assertFalse(reg.consumed(a.requestId));
        reg.expire(project);
        assertTrue(reg.isListed(project));
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
    }

    function test_rejectionDefenseAndFailureDoNotReadArbSys() public {
        _fund(beneficiary);
        _answer(_apply(), true);
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        vm.warp(openAt);
        vm.mockCallRevert(
            address(ARBSYS), abi.encodeWithSignature("arbBlockNumber()"), "unavailable"
        );

        // The accepted self-challenge limit is unchanged: one slot, one fee per defense.
        uint256 before = imd.balanceOf(beneficiary);
        vm.prank(beneficiary);
        bytes32 id = reg.challengeForBeneficiary(project, "Review every rule.", beneficiary);
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.challengeForBeneficiary(project, "Review the fee guard.", beneficiary);
        _answer(id, true);
        assertEq(imd.balanceOf(beneficiary), before - 0.5e18);
        assertEq(reg.projectOf(project).challengeOpenAt, openAt);
        assertEq(reg.projectOf(project).fromBlock, LISTING_BLOCK);
        id = _challenge();
        assertTrue(intake.fail(id, 2, "disagreed", 200_000));
        assertEq(reg.projectOf(project).fromBlock, LISTING_BLOCK);
        assertEq(reg.projectOf(project).toBlock, 0);
        assertTrue(reg.isListed(project));

        project = address(new MockProject());
        _answer(_apply(), false);
        assertFalse(reg.isListed(project));
        assertEq(reg.projectOf(project).fromBlock, 0);
    }
}

/// @dev Prepare the signed callback in setUp: all registry, token and ArbSys state is cold when
/// the test starts, as it is when the real Intake delivers an answer in a later transaction.
abstract contract RegistryRobinhoodColdBase is RegistryRobinhoodBase {
    bytes32 internal pending;
    OracleAttestation.Attestation internal answer;
    bytes internal signature;

    function _prepare(bytes32 id, bool yes) internal {
        pending = id;
        answer = _attestation(yes);
        signature = _sign(answer);
    }
}

contract RegistryRobinhoodColdListingTest is RegistryRobinhoodColdBase {
    function setUp() public override {
        super.setUp();
        _prepare(_apply(), true);
    }

    function test_coldRobinhoodListingFits200k() public {
        assertTrue(intake.deliver(pending, answer, signature, 200_000));
        assertEq(reg.projectOf(project).fromBlock, LISTING_BLOCK);
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOfIntake(pending), address(0));
    }
}

contract RegistryRobinhoodColdDelistingTest is RegistryRobinhoodColdBase {
    function setUp() public override {
        super.setUp();
        _answer(_apply(), true);
        _prepare(_challenge(), false);
        ARBSYS.setBlockNumber(DELISTING_BLOCK);
    }

    function test_coldRobinhoodDelistingAndBondReturnFit200k() public {
        assertTrue(intake.deliver(pending, answer, signature, 200_000));
        assertEq(reg.projectOf(project).toBlock, DELISTING_BLOCK);
        assertEq(reg.projectOf(project).fromBlock, LISTING_BLOCK);
        assertFalse(reg.isListed(project));
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
    }
}

contract RegistryRobinhoodColdOwedBondTest is RegistryRobinhoodColdBase {
    function setUp() public override {
        super.setUp();
        BlocklistIMD token = new BlocklistIMD();
        imd = MintableIMD(address(token));
        reg = new ProjectRegistry(
            address(intake), address(imd), REMOTE_STACKER, vm.addr(KEY), 4663, BOND, 7 days
        );
        _fund(applicant);
        _fund(challenger);
        _answer(_apply(), true);
        _prepare(_challenge(), false);
        token.setBlocked(challenger, true);
        ARBSYS.setBlockNumber(DELISTING_BLOCK);
    }

    function test_coldRobinhoodDelistingRecordsOwedBondWithin200kAndRefusesSelfClaim() public {
        assertTrue(intake.deliver(pending, answer, signature, 200_000));
        assertFalse(reg.isListed(project));
        assertEq(reg.projectOf(project).toBlock, DELISTING_BLOCK);
        assertEq(reg.bondOwed(challenger), BOND);
        assertEq(imd.balanceOf(address(reg)), BOND);
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.InvalidBeneficiary.selector);
        reg.claimBond(address(reg));
        assertEq(reg.bondOwed(challenger), BOND);
        vm.prank(challenger);
        reg.claimBond(beneficiary);
        assertEq(imd.balanceOf(beneficiary), BOND);
        assertEq(reg.bondOwed(challenger), 0);
        assertEq(imd.balanceOf(address(reg)), 0);
    }
}
