// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StackReceiver, IStakedIMD} from "../src/multichain/StackReceiver.sol";
import {RemoteStacker} from "../src/multichain/RemoteStacker.sol";

/// @dev The parts of the live LayerZero endpoint and IMD OFT these tests use.
interface ILiveEndpoint {
    function eid() external view returns (uint32);
    function sendCompose(address to, bytes32 guid, uint16 index, bytes calldata message) external;
    function lzCompose(
        address from,
        address to,
        bytes32 guid,
        uint16 index,
        bytes calldata message,
        bytes calldata extraData
    ) external payable;
    function composeQueue(address from, address to, bytes32 guid, uint16 index)
        external
        view
        returns (bytes32);
}

struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

interface ILiveOFT {
    function endpoint() external view returns (address);
    function peers(uint32 eid) external view returns (bytes32);
    function decimalConversionRate() external view returns (uint256);
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

interface ILiveVault {
    function balanceOf(address) external view returns (uint256);
    function paused() external view returns (bool);
    function convertToAssets(uint256) external view returns (uint256);
}

/// @dev Runs against a fork of Ethereum mainnet with the live IMD OFT, sIMD vault and LayerZero
/// endpoint. Set ETH_RPC_URL to run it; without it every test is skipped. It plays the arrival of
/// a bridge message from Robinhood Chain exactly as the live contracts do: the endpoint calls IMD's
/// `lzReceive` (mint plus queueing the compose), then an executor calls the endpoint's `lzCompose`,
/// which hands the compose to the StackReceiver.
contract StackReceiverMainnetForkTest is Test {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant RH_IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint32 internal constant RH_EID = 30416;
    uint32 internal constant ETH_EID = 30101;
    bytes32 internal constant OFT_RECEIVED =
        keccak256("OFTReceived(bytes32,uint32,address,uint256)");

    /// @dev The RemoteStacker's bridge gas budget, checked here against the live contracts.
    uint128 internal RECEIVE_GAS;
    uint128 internal COMPOSE_BASE_GAS;
    uint128 internal COMPOSE_GAS_PER_TRADER;

    StackReceiver internal receiver;
    address internal remote = makeAddr("remoteStacker"); // the RemoteStacker on Robinhood Chain
    address internal executor = makeAddr("executor");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        if (block.chainid != 1) return;
        forked = true;
        receiver = new StackReceiver(IERC20(IMD), IStakedIMD(SIMD), ENDPOINT);
        RemoteStacker budget = new RemoteStacker(IERC20(IMD), address(receiver), SIMD, RH_EID);
        RECEIVE_GAS = budget.RECEIVE_GAS();
        COMPOSE_BASE_GAS = budget.COMPOSE_BASE_GAS();
        COMPOSE_GAS_PER_TRADER = budget.COMPOSE_GAS_PER_TRADER();
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_fork_liveFacts() public onlyFork {
        assertEq(ILiveEndpoint(ENDPOINT).eid(), ETH_EID);
        assertEq(ILiveOFT(IMD).endpoint(), ENDPOINT);
        assertEq(ILiveOFT(IMD).peers(RH_EID), bytes32(uint256(uint160(RH_IMD))), "peered");
        assertEq(ILiveOFT(IMD).decimalConversionRate(), 1e12, "0.000001 IMD bridge step");
        assertFalse(ILiveVault(SIMD).paused());
    }

    /// @dev One arrival with `n` traders, through the live IMD and endpoint. Returns the gas IMD's
    /// lzReceive used (mint plus queueing the compose) and the gas the compose delivery used.
    function arrive(uint256 n, uint256 each, uint64 nonce)
        internal
        returns (uint256 receiveGas, uint256 composeGas, address[] memory traders)
    {
        traders = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            traders[i] = address(uint160(uint256(keccak256(abi.encode("trader", nonce, i)))));
            amounts[i] = each;
        }
        uint256 total = each * n;
        bytes memory composeMsg = abi.encode(traders, amounts);
        // The OFT message as the Robinhood Chain IMD builds it: sendTo | amountSD | composeFrom | msg.
        bytes memory oftMessage = abi.encodePacked(
            bytes32(uint256(uint160(address(receiver)))),
            uint64(total / 1e12),
            bytes32(uint256(uint160(remote))),
            composeMsg
        );
        bytes32 guid = keccak256(abi.encode("guid", nonce));
        Origin memory origin = Origin(RH_EID, bytes32(uint256(uint160(RH_IMD))), nonce);

        vm.prank(ENDPOINT);
        uint256 g = gasleft();
        ILiveOFT(IMD).lzReceive(origin, guid, oftMessage, executor, "");
        receiveGas = g - gasleft();
        assertEq(IERC20(IMD).balanceOf(address(receiver)), total, "minted to the receiver");
        assertTrue(
            ILiveEndpoint(ENDPOINT).composeQueue(IMD, address(receiver), guid, 0) != bytes32(0),
            "compose queued"
        );

        bytes memory composed =
            abi.encodePacked(nonce, RH_EID, total, bytes32(uint256(uint160(remote))), composeMsg);
        vm.prank(executor);
        g = gasleft();
        ILiveEndpoint(ENDPOINT).lzCompose(IMD, address(receiver), guid, 0, composed, "");
        composeGas = g - gasleft();
        assertEq(IERC20(IMD).balanceOf(address(receiver)), 0, "nothing kept");
    }

    function test_fork_arrivalDepositsForEveryTrader() public onlyFork {
        (uint256 receiveGas, uint256 composeGas, address[] memory traders) = arrive(2, 3e18, 1);
        for (uint256 i; i < traders.length; ++i) {
            uint256 shares = ILiveVault(SIMD).balanceOf(traders[i]);
            assertGt(shares, 0, "shares to the trader");
            assertApproxEqAbs(
                ILiveVault(SIMD).convertToAssets(shares), 3e18, 1e6, "worth the cashback"
            );
        }
        assertEq(receiver.totalDelivered(), 6e18);
        assertEq(receiver.deliveredFrom(RH_EID), 6e18);
        emit log_named_uint("IMD lzReceive gas (mint + compose queued)", receiveGas);
        emit log_named_uint("compose delivery gas, 2 traders", composeGas);
        assertLt(receiveGas, RECEIVE_GAS);
    }

    function test_fork_gasBudgetCoversOneTenAndFiftyTraders() public onlyFork {
        uint128 base = COMPOSE_BASE_GAS;
        uint128 per = COMPOSE_GAS_PER_TRADER;
        uint256[3] memory sizes = [uint256(1), 10, 50];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 n = sizes[k];
            (uint256 receiveGas, uint256 composeGas,) = arrive(n, 1e18, uint64(10 + k));
            emit log_named_uint("traders", n);
            emit log_named_uint("  lzReceive gas", receiveGas);
            emit log_named_uint("  lzCompose gas", composeGas);
            assertLt(receiveGas, RECEIVE_GAS, "RECEIVE_GAS covers the mint and the compose queue");
            assertLt(composeGas * 10 / 12, base + per * n, "the compose budget keeps a 20% margin");
        }
    }

    function test_fork_composeIsDeliveredOnceAndOnlyFromTheEndpoint() public onlyFork {
        (,, address[] memory traders) = arrive(1, 2e18, 99);
        bytes32 guid = keccak256(abi.encode("guid", uint64(99)));
        bytes memory composed = abi.encodePacked(
            uint64(99),
            RH_EID,
            uint256(2e18),
            bytes32(uint256(uint160(remote))),
            abi.encode(traders, _one(2e18))
        );
        // The endpoint cleared the queue entry: a second delivery is refused by the endpoint.
        vm.prank(executor);
        vm.expectRevert();
        ILiveEndpoint(ENDPOINT).lzCompose(IMD, address(receiver), guid, 0, composed, "");
        // And nobody can call the receiver directly.
        vm.expectRevert(StackReceiver.NotEndpoint.selector);
        receiver.lzCompose(IMD, guid, composed, executor, "");
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }
}
