// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/oracle/OracleAttestation.sol";
import {RegistryRobinhoodBase} from "./RegistryRobinhoodBlocks.t.sol";
import {MintableIMD, MockProject} from "./mocks/MockIntake.sol";

/// @dev A local token fault injector, not a claim about live IMD behavior. Real transfers and
/// allowances run before the reentry attempt, so a test checks accounting as well as the guard.
contract RegistryProbeIMD is ERC20 {
    enum Boundary {
        None,
        Pull,
        Approve,
        Push
    }

    address public registry;
    Boundary public boundary;
    bytes internal payload;
    bool public refused;
    bool public noReturn;
    uint256 public attempts;
    bool public reentrySucceeded;
    bytes4 public reentryError;

    constructor() ERC20("Registry probe IMD", "pIMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(address target, Boundary at, bytes calldata data) external {
        registry = target;
        boundary = at;
        payload = data;
    }

    function setPayoutMode(bool refuse, bool omitReturn) external {
        refused = refuse;
        noReturn = omitReturn;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        bool ok = super.approve(spender, amount);
        _probe(Boundary.Approve);
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _probe(Boundary.Pull);
        return ok;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (msg.sender == registry && refused) return false;
        bool ok = super.transfer(to, amount);
        _probe(Boundary.Push);
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return ok;
    }

    function claimOwnDebt(address to) external {
        ProjectRegistry(registry).claimBond(to);
    }

    function _probe(Boundary at) internal {
        if (msg.sender != registry || boundary != at) return;
        boundary = Boundary.None;
        ++attempts;
        bytes memory reason;
        (reentrySucceeded, reason) = registry.call(payload);
        if (reason.length >= 4) reentryError = bytes4(reason);
    }
}

/// @notice Exercises the external-call boundaries which a normal mintable ERC-20 cannot reach.
contract RegistryRobinhoodExternalCallsTest is RegistryRobinhoodBase {
    RegistryProbeIMD internal token;

    function setUp() public override {
        super.setUp();
        token = new RegistryProbeIMD();
        imd = MintableIMD(address(token));
        reg = new ProjectRegistry(
            address(intake), address(token), REMOTE_STACKER, vm.addr(KEY), 4663, BOND, 7 days
        );
        token.configure(address(reg), RegistryProbeIMD.Boundary.None, "");
        _fund(applicant);
        _fund(challenger);
    }

    function _assertRejectedReentry() internal view {
        assertEq(token.attempts(), 1, "probe did not reach the boundary");
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_feePullCannotReenterAndOpenAnotherApplication() public {
        address other = address(new MockProject());
        token.configure(
            address(reg),
            RegistryProbeIMD.Boundary.Pull,
            abi.encodeCall(
                ProjectRegistry.applyListing,
                (other, "Other", "https://other.example", 25, beneficiary)
            )
        );
        bytes32 id = _apply();
        _assertRejectedReentry();
        assertEq(reg.projectOfIntake(id), project);
        assertEq(uint8(reg.projectOf(other).ask), uint8(ProjectRegistry.Ask.None));
        assertEq(intake.count(), 1, "reentry bought another question");
        assertEq(token.balanceOf(applicant), 1_000e18 - 0.5e18);
        assertEq(token.balanceOf(address(reg)), 0);
        _answer(id, true);
        assertTrue(reg.isListed(project));
    }

    function test_feeApprovalCannotReenterExpiryOfThePartiallyOpenedQuestion() public {
        token.configure(
            address(reg),
            RegistryProbeIMD.Boundary.Approve,
            abi.encodeCall(ProjectRegistry.expire, (project))
        );
        bytes32 id = _apply();
        _assertRejectedReentry();
        assertEq(reg.projectOfIntake(id), project);
        assertEq(reg.projectOf(project).intakeId, id);
        assertEq(token.allowance(address(reg), address(intake)), 0);
        assertEq(token.balanceOf(intake.TREASURY()), 0.5e18);
        assertTrue(intake.fail(id, 1, "body_refused", 200_000));
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
    }

    function test_defendedBondTransferCannotReenterAndReopenTheChallenge() public {
        _answer(_apply(), true);
        bytes32 id = _challenge();
        token.configure(
            address(reg),
            RegistryProbeIMD.Boundary.Push,
            abi.encodeCall(
                ProjectRegistry.challengeForBeneficiary, (project, "Another review.", beneficiary)
            )
        );
        _answer(id, true);
        _assertRejectedReentry();
        assertTrue(reg.isListed(project));
        assertEq(token.balanceOf(beneficiary), BOND);
        assertEq(token.balanceOf(address(reg)), 0);
        assertEq(reg.bondOwed(beneficiary), 0);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
        assertEq(intake.count(), 2);
        assertEq(reg.projectOfIntake(id), address(0));
    }

    function test_debtClaimCannotReenterOrUseAnotherProjectsOpenBond() public {
        // The token is also this project's beneficiary, so its reentry has a real creditor's
        // identity. A callback from an unrelated token address would test only NothingOwed.
        beneficiary = address(token);
        _answer(_apply(), true);
        bytes32 first = _challenge();
        token.setPayoutMode(true, false);
        _answer(first, true);
        assertEq(reg.bondOwed(address(token)), BOND);
        token.setPayoutMode(false, false);

        address firstProject = project;
        project = address(new MockProject());
        beneficiary = makeAddr("second beneficiary");
        _answer(_apply(), true);
        bytes32 second = _challenge();
        assertEq(token.balanceOf(address(reg)), 2 * BOND);
        address recipient = makeAddr("claim recipient");
        token.configure(
            address(reg),
            RegistryProbeIMD.Boundary.Push,
            abi.encodeCall(ProjectRegistry.claimBond, (recipient))
        );
        token.claimOwnDebt(recipient);
        _assertRejectedReentry();
        assertEq(reg.bondOwed(address(token)), 0);
        assertEq(token.balanceOf(recipient), BOND, "one debt paid exactly once");
        assertEq(token.balanceOf(address(reg)), BOND, "other challenge stays collateralized");
        assertEq(reg.projectOfIntake(second), project);
        assertEq(reg.projectOfIntake(first), address(0));
        assertTrue(reg.isListed(firstProject));
        vm.expectRevert(ProjectRegistry.NothingOwed.selector);
        token.claimOwnDebt(recipient);
        _answer(second, false);
        assertFalse(reg.isListed(project));
        assertEq(token.balanceOf(address(reg)), 0);
    }

    function test_emptyTransferReturnPaysBondExactlyOnceWithoutInventingDebt() public {
        _answer(_apply(), true);
        bytes32 id = _challenge();
        token.setPayoutMode(false, true);
        _answer(id, true);
        assertEq(token.balanceOf(beneficiary), BOND);
        assertEq(reg.bondOwed(beneficiary), 0);
        assertEq(token.balanceOf(address(reg)), 0);
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.NothingOwed.selector);
        reg.claimBond(beneficiary);
    }

    function test_emptyTransferReturnCanClaimAPreviouslyRefusedBond() public {
        _answer(_apply(), true);
        bytes32 id = _challenge();
        token.setPayoutMode(true, false);
        _answer(id, false);
        assertFalse(reg.isListed(project));
        assertEq(reg.bondOwed(challenger), BOND);
        token.setPayoutMode(false, true);
        vm.prank(challenger);
        reg.claimBond(beneficiary);
        assertEq(token.balanceOf(beneficiary), BOND);
        assertEq(reg.bondOwed(challenger), 0);
        assertEq(token.balanceOf(address(reg)), 0);
    }
}

contract RegistryRejectingSignerCode {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("contract signature rejected");
    }
}

/// @dev Code on a signer address must not silently disable the fixed key's ECDSA path.
contract RegistryRobinhoodSignerCodeTest is RegistryRobinhoodBase {
    function setUp() public override {
        super.setUp();
        RegistryRejectingSignerCode implementation = new RegistryRejectingSignerCode();
        vm.etch(vm.addr(KEY), address(implementation).code);
    }

    function test_signerWithCodeStillAcceptsItsOwnKeyWithin200k() public {
        bytes32 id = _apply();
        _answer(id, true);
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOfIntake(id), address(0));
    }

    function test_signerWithCodeDoesNotAcceptAnotherKeyOrLoseThePendingBond() public {
        _answer(_apply(), true);
        bytes32 id = _challenge();
        OracleAttestation.Attestation memory a = _attestation(false);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, reg.attestationDigest(a));
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        reg.onOracleResult(id, a, abi.encodePacked(r, s, v));
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOfIntake(id), project);
        assertEq(imd.balanceOf(address(reg)), BOND);
        assertFalse(reg.consumed(a.requestId));
        _answer(id, false);
        assertFalse(reg.isListed(project));
        assertEq(imd.balanceOf(address(reg)), 0);
    }
}
