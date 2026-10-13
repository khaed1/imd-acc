// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {StackReceiver} from "src/multichain/StackReceiver.sol";

contract ReceiverLaunchFactory {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "receiver deployment failed");
    }
}

/// @dev Strict receiver-only rehearsal when the active manifest launches a StackReceiver.
/// Other launch branches retain their own manifest checks in DeploymentTest.
contract StackReceiverLaunchTest is Test {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant EXISTING_STACKER = 0x06909F672301F28A810f78cfe7a754851269F4F0;
    address internal constant EXISTING_REGISTRY = 0x7F53FA1543c682bb5DE3f50c2Cf3D1842Ae57faA;

    modifier onlyReceiverLaunch() {
        string memory json = vm.readFile("./launch.json");
        if (
            keccak256(bytes(vm.parseJsonString(json, ".contracts[0].contract")))
                != keccak256("StackReceiver")
        ) vm.skip(true);
        _;
    }

    function _initCodeFromManifest() internal view returns (bytes memory) {
        string memory json = vm.readFile("./launch.json");
        assertEq(vm.parseJsonString(json, ".kind"), "evm_contracts");
        assertEq(vm.parseJsonString(json, ".contracts[0].contract"), "StackReceiver");
        assertFalse(vm.keyExistsJson(json, ".contracts[1]"), "deploy only the receiver");
        string[] memory args = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
        assertEq(args.length, 3, "no owner or post-deployment configuration");
        address imd = vm.parseAddress(args[0]);
        address simd = vm.parseAddress(args[1]);
        address endpoint = vm.parseAddress(args[2]);
        assertEq(imd, IMD);
        assertEq(simd, SIMD);
        assertEq(endpoint, ENDPOINT);
        return abi.encodePacked(type(StackReceiver).creationCode, abi.encode(imd, simd, endpoint));
    }

    function test_manifestPinsExactlyTheMainnetReceiver() public onlyReceiverLaunch {
        _initCodeFromManifest();
    }

    function test_manifestFactoryDeploysOneContractWithNoExternalConstructorCalls()
        public
        onlyReceiverLaunch
    {
        vm.chainId(1);
        bytes memory initCode = _initCodeFromManifest();
        assertLe(initCode.length, 49_152);
        assertEq(IMD.code.length, 0);
        assertEq(SIMD.code.length, 0);
        assertEq(ENDPOINT.code.length, 0);
        ReceiverLaunchFactory factory = new ReceiverLaunchFactory();
        bytes32 salt = keccak256("StackReceiver mainnet rehearsal");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(initCode))
                    )
                )
            )
        );

        vm.startStateDiffRecording();
        address deployed = factory.deploy(initCode, salt);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 creations;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory access = accesses[i];
            assertTrue(
                access.account != EXISTING_STACKER && access.account != EXISTING_REGISTRY,
                "live application touched"
            );
            if (access.kind == VmSafe.AccountAccessKind.Create) {
                ++creations;
                assertEq(access.account, predicted, "only the receiver is created");
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
        assertLe(deployed.code.length, 24_576);
        assertGt(deployed.code.length, 0);
        StackReceiver receiver = StackReceiver(deployed);
        assertEq(address(receiver.IMD()), IMD);
        assertEq(address(receiver.SIMD()), SIMD);
        assertEq(receiver.ENDPOINT(), ENDPOINT);
        assertEq(receiver.totalDelivered(), 0);
        (bool hasOwner,) = deployed.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(hasOwner);
    }
}
