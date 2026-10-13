// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestIMD} from "./mocks/TestIMD.sol";
import {TestSIMD} from "./mocks/TestSIMD.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {StackReceiver} from "../src/multichain/StackReceiver.sol";
import {RemoteStacker} from "../src/multichain/RemoteStacker.sol";

/// @dev Rehearses a launch: the manifest deploys exactly one Stacker, wired to a known IMD and vault
/// pair (Ethereum mainnet on `main`, the live Sepolia test pair on the `sepolia` branch); the
/// constructor passes on an empty chain (the launch's rehearsal, where neither address has code);
/// and the runtime meets the launch's limits (EIP-170 size, no DELEGATECALL / CALLCODE /
/// SELFDESTRUCT).
contract DeploymentTest is Test {
    address internal constant MAINNET_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant MAINNET_SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    /// @dev Sepolia test run #1129: TestIMD (with a faucet) and TestSIMD (a StakedIMD copy whose
    /// owner can pause it).
    address internal constant SEPOLIA_TEST_IMD = 0x2B69099E59b05901faA1DD164fabf098bf831E82;
    address internal constant SEPOLIA_TEST_SIMD = 0xF9e2EEc3B610ec6781f7438aC5Fb4bc049d81Cc1;
    /// @dev IdentityMD: the Intake v2 (same address on every chain), Sepolia's test IMD it is paid
    /// in, and the oracle signer.
    address internal constant INTAKE_V2 = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant SEPOLIA_ORACLE_IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    address internal constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    /// @dev Sepolia test run 2 (launch #1294): the live Stacker on the test pair, which PLEA's hook
    /// credits through. Test run 3 deploys only a registry wired to it.
    address internal constant SEPOLIA_STACKER = 0x0457276D7b036818B3EddC1A4A3FCeda61e9314d;
    /// @dev The mainnet Stacker (launch #1409), which the mainnet registry names.
    address internal constant MAINNET_STACKER = 0x06909F672301F28A810f78cfe7a754851269F4F0;
    /// @dev The multichain route: LayerZero's endpoint on Ethereum (eid 30101) and IMD on Robinhood
    /// Chain (the same OFT over IMD's bridge).
    address internal constant ETH_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant ROBINHOOD_IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant MAINNET_RECEIVER = 0x1999a54f573dAc75ce8Ef62A555dba418c9B3D10;
    uint32 internal constant ETH_EID = 30101;

    /// @dev main: the Stacker alone, on mainnet. sepolia: either the Stacker on the test pair, then
    /// the ProjectRegistry wired to it (test run 2), or the ProjectRegistry alone, wired to test
    /// run 2's live Stacker (test run 3); both with Intake v2, the test IMD, the oracle signer and
    /// the agreed Sepolia bond and cooldown.
    function test_launchManifest_knownShape() public view {
        string memory json = vm.readFile("./launch.json");
        assertEq(vm.parseJsonString(json, ".kind"), "evm_contracts");
        assertFalse(vm.keyExistsJson(json, ".contracts[2]"), "at most two contracts");

        bytes32 first = keccak256(bytes(vm.parseJsonString(json, ".contracts[0].contract")));
        if (first == keccak256("StackReceiver")) {
            // main: the Ethereum end of the multichain route, on the live IMD, vault and endpoint.
            assertFalse(vm.keyExistsJson(json, ".contracts[1]"), "the receiver alone");
            string[] memory a = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
            assertEq(a.length, 3);
            assertEq(vm.parseAddress(a[0]), MAINNET_IMD, "IMD");
            assertEq(vm.parseAddress(a[1]), MAINNET_SIMD, "sIMD vault");
            assertEq(vm.parseAddress(a[2]), ETH_ENDPOINT, "LayerZero endpoint");
            return;
        }
        if (first == keccak256("RemoteStacker")) {
            // robinhood: the Robinhood Chain end, on its IMD, naming the live StackReceiver.
            assertFalse(vm.keyExistsJson(json, ".contracts[1]"), "the RemoteStacker alone");
            string[] memory a = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
            assertEq(a.length, 4);
            assertEq(vm.parseAddress(a[0]), ROBINHOOD_IMD, "IMD on Robinhood Chain");
            assertEq(vm.parseAddress(a[1]), MAINNET_RECEIVER, "the live StackReceiver on Ethereum");
            assertEq(vm.parseAddress(a[2]), MAINNET_SIMD, "the Ethereum vault, refused as trader");
            assertEq(vm.parseUint(a[3]), ETH_EID, "Ethereum's endpoint id");
            return;
        }
        if (first == keccak256("ProjectRegistry")) {
            assertFalse(vm.keyExistsJson(json, ".contracts[1]"), "the registry alone");
            string[] memory a = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
            if (vm.parseAddress(a[1]) == MAINNET_IMD) {
                _mainnetRegistryArgs(a);
                return;
            }
            string[] memory reg = _sepoliaRegistryArgs(json, ".contracts[0].constructorArgs");
            assertEq(vm.parseAddress(reg[2]), SEPOLIA_STACKER, "test run 2's live Stacker");
            return;
        }

        assertEq(vm.parseJsonString(json, ".contracts[0].contract"), "Stacker");
        string[] memory args = vm.parseJsonStringArray(json, ".contracts[0].constructorArgs");
        assertEq(args.length, 2);
        address imd = vm.parseAddress(args[0]);
        address vault = vm.parseAddress(args[1]);
        bool mainnet = imd == MAINNET_IMD && vault == MAINNET_SIMD;
        bool sepoliaTest = imd == SEPOLIA_TEST_IMD && vault == SEPOLIA_TEST_SIMD;
        assertTrue(mainnet || sepoliaTest, "IMD and vault are a known pair, in that order");

        if (!vm.keyExistsJson(json, ".contracts[1]")) return;
        assertTrue(sepoliaTest, "the registry ships on Sepolia first");
        assertEq(vm.parseJsonString(json, ".contracts[1].contract"), "ProjectRegistry");
        string[] memory r = _sepoliaRegistryArgs(json, ".contracts[1].constructorArgs");
        assertEq(r[2], "$contract:Stacker", "the Stacker of this launch");
    }

    /// @dev The mainnet registry: paid in IMD, naming the live mainnet Stacker, with the agreed
    /// mainnet bond and cooldown.
    function _mainnetRegistryArgs(string[] memory r) internal pure {
        assertEq(r.length, 7);
        assertEq(vm.parseAddress(r[0]), INTAKE_V2, "intake");
        assertEq(vm.parseAddress(r[1]), MAINNET_IMD, "oracle asset: IMD");
        assertEq(vm.parseAddress(r[2]), MAINNET_STACKER, "the live mainnet Stacker");
        assertEq(vm.parseAddress(r[3]), ORACLE_SIGNER, "oracle signer");
        assertEq(vm.parseUint(r[4]), 1, "questions filed under chain 1");
        assertEq(vm.parseUint(r[5]), 20e18, "agreed mainnet bond: 20 IMD");
        assertEq(vm.parseUint(r[6]), 7 days, "agreed mainnet cooldown: 7 days");
    }

    /// @dev Checks a Sepolia registry's arguments except the Stacker (index 2), left to the caller.
    function _sepoliaRegistryArgs(string memory json, string memory key)
        internal
        pure
        returns (string[] memory r)
    {
        r = vm.parseJsonStringArray(json, key);
        assertEq(r.length, 7);
        assertEq(vm.parseAddress(r[0]), INTAKE_V2, "intake");
        assertEq(vm.parseAddress(r[1]), SEPOLIA_ORACLE_IMD, "oracle asset");
        assertEq(vm.parseAddress(r[3]), ORACLE_SIGNER, "oracle signer");
        assertEq(vm.parseUint(r[4]), 1, "questions filed under chain 1");
        assertEq(vm.parseUint(r[5]), 5e18, "agreed Sepolia bond: 5 test IMD");
        assertEq(vm.parseUint(r[6]), 1 hours, "agreed Sepolia cooldown: 1 hour");
    }

    function test_registry_emptyChainRehearsal_constructorPasses() public {
        assertEq(INTAKE_V2.code.length, 0);
        vm.prank(makeAddr("factory"));
        ProjectRegistry reg = new ProjectRegistry(
            INTAKE_V2, SEPOLIA_ORACLE_IMD, makeAddr("stacker"), ORACLE_SIGNER, 1, 5e18, 1 hours
        );
        assertEq(address(reg.intake()), INTAKE_V2);
        assertEq(reg.oracleSigner(), ORACLE_SIGNER);
        _checkRuntime(address(reg));
    }

    function test_multichain_emptyChainRehearsal_constructorsPass() public {
        assertEq(ETH_ENDPOINT.code.length, 0);
        vm.prank(makeAddr("factory"));
        StackReceiver receiver =
            new StackReceiver(IERC20(MAINNET_IMD), IStakedIMD(MAINNET_SIMD), ETH_ENDPOINT);
        assertEq(address(receiver.IMD()), MAINNET_IMD);
        assertEq(address(receiver.SIMD()), MAINNET_SIMD);
        assertEq(receiver.ENDPOINT(), ETH_ENDPOINT);
        assertEq(receiver.totalDelivered(), 0);
        _checkRuntime(address(receiver));

        assertEq(ROBINHOOD_IMD.code.length, 0);
        vm.prank(makeAddr("factory"));
        RemoteStacker remote =
            new RemoteStacker(IERC20(ROBINHOOD_IMD), address(receiver), MAINNET_SIMD, ETH_EID);
        assertEq(address(remote.IMD()), ROBINHOOD_IMD);
        assertEq(remote.RECEIVER(), address(receiver));
        assertEq(remote.VAULT(), MAINNET_SIMD);
        assertEq(remote.DST_EID(), ETH_EID);
        assertEq(remote.totalQueued(), 0);
        _checkRuntime(address(remote));
    }

    function test_emptyChainRehearsal_constructorPasses() public {
        // No fork: neither mainnet address has code here, as in the launch's rehearsal.
        assertEq(MAINNET_SIMD.code.length, 0);
        vm.prank(makeAddr("factory"));
        Stacker stacker = new Stacker(IERC20(MAINNET_IMD), IStakedIMD(MAINNET_SIMD));
        assertEq(address(stacker.IMD()), MAINNET_IMD);
        assertEq(address(stacker.SIMD()), MAINNET_SIMD);
        assertEq(stacker.totalStacked(), 0);
    }

    function test_runtimeSizeAndNoEscapeOpcodes() public {
        TestIMD imd = new TestIMD();
        TestSIMD sImd = new TestSIMD(address(imd), address(this));
        _checkRuntime(address(new Stacker(IERC20(address(imd)), IStakedIMD(address(sImd)))));
        _checkRuntime(address(new Stacker(IERC20(MAINNET_IMD), IStakedIMD(MAINNET_SIMD))));
    }

    function _checkRuntime(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0, "missing runtime");
        assertLe(code.length, 24_576, "exceeds EIP-170");
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
