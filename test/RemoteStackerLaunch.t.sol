// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {RemoteStacker} from "../src/multichain/RemoteStacker.sol";

contract RemoteLaunchFactory {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "RemoteStacker deployment failed");
    }
}

/// @dev Exercises this branch's exact manifest through CREATE2 on an empty Robinhood Chain.
contract RemoteStackerLaunchTest is Test {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant RECEIVER = 0x1999a54f573dAc75ce8Ef62A555dba418c9B3D10;
    address internal constant VAULT = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;

    function test_manifestDeploysOnlyRemoteStackerWithoutExternalConstructorCalls() public {
        string memory json = vm.readFile("./launch.json");
        if (
            keccak256(bytes(vm.parseJsonString(json, ".contracts[0].contract")))
                != keccak256("RemoteStacker")
        ) vm.skip(true);
        assertEq(vm.parseJsonString(json, ".kind"), "evm_contracts");
        assertFalse(vm.keyExistsJson(json, ".contracts[1]"), "one application only");
        string[] memory args = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
        assertEq(args.length, 4);
        address imd = vm.parseAddress(args[0]);
        address receiver = vm.parseAddress(args[1]);
        address vault = vm.parseAddress(args[2]);
        uint256 eid = vm.parseUint(args[3]);
        assertEq(imd, IMD);
        assertEq(receiver, RECEIVER);
        assertEq(vault, VAULT);
        assertEq(eid, 30101);
        bytes memory initCode = abi.encodePacked(
            type(RemoteStacker).creationCode, abi.encode(imd, receiver, vault, uint32(eid))
        );
        assertLe(initCode.length, 49_152);

        vm.chainId(4663);
        assertEq(IMD.code.length, 0);
        assertEq(RECEIVER.code.length, 0);
        assertEq(VAULT.code.length, 0);
        RemoteLaunchFactory factory = new RemoteLaunchFactory();
        bytes32 salt = keccak256("RemoteStacker Robinhood rehearsal");
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), address(factory));

        vm.startStateDiffRecording();
        address deployed = factory.deploy(initCode, salt);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 creations;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory access = accesses[i];
            if (access.kind == VmSafe.AccountAccessKind.Create) {
                ++creations;
                assertEq(access.account, predicted, "only RemoteStacker is created");
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
        RemoteStacker remote = RemoteStacker(deployed);
        assertEq(address(remote.IMD()), IMD);
        assertEq(remote.RECEIVER(), RECEIVER);
        assertEq(remote.VAULT(), VAULT);
        assertEq(remote.DST_EID(), 30101);
        assertEq(remote.totalQueued(), 0);
        assertEq(remote.totalPaid(), 0);
        (bool hasOwner,) = deployed.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner);

        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576, "EIP-170");
        emit log_named_uint("RemoteStacker runtime bytes", code.length);
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
