// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";

/// @dev Local rehearsal only: no live factory, key, broadcast or initialization call.
contract RegistryLaunchFactoryProbe {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "registry constructor failed");
    }
}

contract RegistryRobinhoodLaunchTest is Test {
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant REMOTE_STACKER = 0x4De07c2fa46D5d6ED9CEB3f38ec56d3461b3E898;
    address internal constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    /// @dev The manifest check applies to the `robinhood` branch only: `main`'s manifest is the
    /// StackReceiver's and `sepolia`'s a registry on chain 1, so the test skips there.
    modifier onlyRobinhoodRegistryManifest() {
        string memory json = vm.readFile("./launch.json");
        if (
            keccak256(bytes(vm.parseJsonString(json, ".contracts[0].contract")))
                    != keccak256("ProjectRegistry")
                || vm.parseUint(vm.parseJsonStringArray(json, ".contracts[0].constructorArgs")[4])
                    != 4663
        ) vm.skip(true);
        _;
    }

    function test_manifestDeploysOnlyRegistryOnEmptyRobinhoodChain()
        public
        onlyRobinhoodRegistryManifest
    {
        string memory json = vm.readFile("./launch.json");
        assertEq(vm.parseJsonString(json, ".kind"), "evm_contracts");
        assertEq(vm.parseJsonString(json, ".contracts[0].contract"), "ProjectRegistry");
        assertFalse(vm.keyExistsJson(json, ".contracts[1]"), "only the registry is deployed");
        string[] memory args = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
        assertEq(args.length, 7);
        assertEq(vm.parseAddress(args[0]), INTAKE);
        assertEq(vm.parseAddress(args[1]), IMD);
        assertEq(vm.parseAddress(args[2]), REMOTE_STACKER);
        assertEq(vm.parseAddress(args[3]), SIGNER);
        assertEq(vm.parseUint(args[4]), 4663);
        assertEq(vm.parseUint(args[5]), 20e18);
        assertEq(vm.parseUint(args[6]), 604800);
        bytes memory initCode = abi.encodePacked(
            type(ProjectRegistry).creationCode,
            abi.encode(
                vm.parseAddress(args[0]),
                vm.parseAddress(args[1]),
                vm.parseAddress(args[2]),
                vm.parseAddress(args[3]),
                vm.parseUint(args[4]),
                vm.parseUint(args[5]),
                uint64(vm.parseUint(args[6]))
            )
        );
        assertLe(initCode.length, 49_152, "EIP-3860 initcode limit");
        vm.chainId(4663);
        assertEq(INTAKE.code.length, 0);
        assertEq(IMD.code.length, 0);
        assertEq(REMOTE_STACKER.code.length, 0);
        assertEq(SIGNER.code.length, 0);
        assertEq(address(0x64).code.length, 0, "no ArbSys implementation needed to deploy");
        RegistryLaunchFactoryProbe factory = new RegistryLaunchFactoryProbe();
        bytes32 salt = keccak256("ProjectRegistry Robinhood rehearsal");
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), address(factory));

        vm.startStateDiffRecording();
        address deployed = factory.deploy(initCode, salt);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 creations;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory access = accesses[i];
            if (access.kind == VmSafe.AccountAccessKind.Create) {
                ++creations;
                assertEq(access.account, predicted, "only ProjectRegistry is created");
                assertEq(access.value, 0);
            }
            if (access.accessor == deployed) {
                assertTrue(
                    access.kind != VmSafe.AccountAccessKind.Call
                        && access.kind != VmSafe.AccountAccessKind.StaticCall
                        && access.kind != VmSafe.AccountAccessKind.DelegateCall
                        && access.kind != VmSafe.AccountAccessKind.CallCode
                        && access.kind != VmSafe.AccountAccessKind.Create
                        && access.kind != VmSafe.AccountAccessKind.SelfDestruct,
                    "constructor performs an external operation"
                );
            }
        }
        assertEq(creations, 1);
        assertEq(deployed, predicted);
        assertEq(vm.getNonce(deployed), 1, "no child contracts");
        assertEq(vm.getNonce(address(factory)), 2);
        assertEq(deployed.balance, 0);
        ProjectRegistry reg = ProjectRegistry(deployed);
        assertEq(address(reg.intake()), INTAKE);
        assertEq(address(reg.oracleAsset()), IMD);
        assertEq(reg.stacker(), REMOTE_STACKER);
        assertEq(reg.oracleSigner(), SIGNER);
        assertEq(reg.questionChainId(), 4663);
        assertEq(reg.challengeBond(), 20e18);
        assertEq(reg.challengeCooldown(), 604800);
        assertEq(reg.onOracleResult.selector, bytes4(0x510379c7));
        assertEq(reg.onOracleFailure.selector, bytes4(0xa7980e31));
        (bool hasOwner,) = deployed.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner);

        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "EIP-170 runtime limit");
        emit log_named_uint("ProjectRegistry runtime bytes", code.length);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
