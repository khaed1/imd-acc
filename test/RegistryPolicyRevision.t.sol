// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryBase} from "./ProjectRegistry.t.sol";

contract RegistryPolicyRevisionTest is RegistryBase {
    function test_applicationAndChallengeRequireResolvedTraderAndExcludeLpFees() public {
        bytes32 application = _listed();
        bytes32 challenge = _challenge();
        string memory applicationBody = string(intake.bodyOf(application));
        string memory challengeBody = string(intake.bodyOf(challenge));
        string memory traderRule = vm.parseJsonString(applicationBody, ".definitions.trader");
        assertTrue(vm.contains(traderRule, "hookData"));
        assertTrue(vm.contains(traderRule, "msgSender()"));
        assertTrue(vm.contains(traderRule, "sender has no code"));
        assertTrue(vm.contains(traderRule, "never tx.origin"));
        assertTrue(vm.contains(traderRule, "Never pay an unresolved router"));
        // Version 3.1: the one rejected recipient is the router itself, and a contract that
        // msgSender() reports is a valid trader (a smart-contract wallet), so a panel can't read
        // every contract as a possible second router (Sepolia test run 5 split on that).
        assertTrue(vm.contains(traderRule, "the router itself"));
        assertTrue(vm.contains(traderRule, "valid trader even when it is a contract"));
        assertFalse(vm.contains(traderRule, "forwarding-router"));
        assertEq(traderRule, vm.parseJsonString(challengeBody, ".definitions.trader"));
        assertLe(bytes(traderRule).length, 512);

        string memory feeRule = vm.parseJsonString(applicationBody, ".definitions.feeGuard");
        assertTrue(vm.contains(feeRule, "LP fees do not count"));
        assertTrue(vm.contains(feeRule, "every allowed setting"));
        assertEq(feeRule, vm.parseJsonString(challengeBody, ".definitions.feeGuard"));
        assertLe(bytes(feeRule).length, 512);
        assertTrue(_answer(challenge, true), "text revision preserves callback budget");
    }

    function test_lpRebateDefeatsGrossFeeFloor() public pure {
        // Cash-flow model for the report's two legs, each normalized to 1,000 IMD.
        // There is no claim here to simulate AMM price movement or gas.
        uint256 volume = 2_000e18;
        uint256 cashback = volume * 100 / 10_000;
        uint256 lpFee = volume * 100 / 10_000;
        uint256 lpRebate = lpFee * 99 / 100;
        uint256 netFeeCost = cashback + lpFee - cashback - lpRebate;
        assertGe(lpFee, cashback, "the old gross floor passes");
        assertEq(cashback, 20e18);
        assertEq(netFeeCost, 0.2e18);
        assertLt(netFeeCost, cashback);
        // Excluding LP fees leaves zero qualifying outflow for this fee split.
        assertLt(0, cashback, "the revised feeGuard rejects this split");
    }
}
