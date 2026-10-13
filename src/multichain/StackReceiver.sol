// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILayerZeroComposer, OFTComposeMsg} from "./LayerZero.sol";
import {IStakedIMD} from "../Stacker.sol";

/// @title StackReceiver
/// @notice The Ethereum end of imd/acc's multichain route. A RemoteStacker on another chain sends
/// waiting cashback here through IMD's own LayerZero bridge (IMD is an OFT) as a send-and-call: the
/// IMD is minted to this contract and the endpoint then calls `lzCompose` with the list of traders
/// and amounts. This contract deposits each amount into the sIMD vault for its trader; if a deposit
/// fails, that trader is paid plain IMD instead. It keeps no IMD after a delivery.
///
/// It trusts only the endpoint and the IMD token: the endpoint calls `lzCompose` only for a compose
/// the IMD token queued on arrival, and the amount in the message is written by the token. Whoever
/// sent the message pays out only the IMD that came with it, and only if the listed amounts add up to
/// it; a sender that lies about its own list can only lose its own IMD. No owner, no admin, no pause,
/// no upgrade; nothing here can be withdrawn by anyone.
contract StackReceiver is ILayerZeroComposer, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using OFTComposeMsg for bytes;

    /// @notice IMD on Ethereum (the OFT whose composes this contract accepts).
    IERC20 public immutable IMD;
    /// @notice The staked-IMD ERC-4626 vault that receives every deposit.
    IStakedIMD public immutable SIMD;
    /// @notice The LayerZero endpoint on Ethereum, the only caller of `lzCompose`.
    address public immutable ENDPOINT;
    bool private _vaultReady;

    /// @notice IMD delivered through this contract, per source endpoint id and in total.
    mapping(uint32 => uint256) public deliveredFrom;
    uint256 public totalDelivered;

    /// @notice One trader's cashback deposited into the vault: the shares went to the trader.
    event Delivered(
        bytes32 indexed guid,
        uint32 indexed srcEid,
        address indexed trader,
        uint256 imd,
        uint256 shares
    );
    /// @notice The vault refused the deposit, so the trader was paid plain IMD.
    event DeliveredPlain(
        bytes32 indexed guid, uint32 indexed srcEid, address indexed trader, uint256 imd
    );

    error ZeroAddress();
    error NotEndpoint();
    error NotIMD();
    error BadList();
    error AmountMismatch(uint256 listed, uint256 received);
    error AssetMismatch(address vaultAsset, address imd);
    error ZeroShares();

    /// @dev No external calls: the launch rehearses deployment on an empty chain. The first
    /// delivery checks the vault and approves it.
    constructor(IERC20 imd, IStakedIMD sImd, address endpoint) {
        if (address(imd) == address(0) || address(sImd) == address(0) || endpoint == address(0)) {
            revert ZeroAddress();
        }
        IMD = imd;
        SIMD = sImd;
        ENDPOINT = endpoint;
    }

    /// @notice Called by the endpoint after the bridged IMD was minted here: deposits each listed
    /// amount for its trader. The compose payload is `abi.encode(address[] traders, uint256[] amounts)`
    /// and the amounts must add up to the IMD that arrived.
    function lzCompose(address from, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        override
        nonReentrant
    {
        if (msg.sender != ENDPOINT) revert NotEndpoint();
        if (from != address(IMD)) revert NotIMD();
        (address[] memory traders, uint256[] memory amounts) =
            abi.decode(message.composeMsg(), (address[], uint256[]));
        uint256 received = message.amountLD();
        _check(traders, amounts, received);
        _prepareVault();
        _deliver(guid, message.srcEid(), traders, amounts);
        deliveredFrom[message.srcEid()] += received;
        totalDelivered += received;
    }

    function _check(address[] memory traders, uint256[] memory amounts, uint256 received)
        internal
        pure
    {
        if (traders.length != amounts.length || traders.length == 0) revert BadList();
        uint256 sum;
        for (uint256 i; i < amounts.length; ++i) {
            sum += amounts[i];
        }
        if (sum != received) revert AmountMismatch(sum, received);
    }

    /// @dev The first delivery checks the live vault and approves it, as the Stacker does.
    function _prepareVault() internal {
        if (_vaultReady) return;
        address vaultAsset = SIMD.asset();
        if (vaultAsset != address(IMD)) revert AssetMismatch(vaultAsset, address(IMD));
        _vaultReady = true;
        IMD.forceApprove(address(SIMD), type(uint256).max);
    }

    function _deliver(
        bytes32 guid,
        uint32 srcEid,
        address[] memory traders,
        uint256[] memory amounts
    ) internal {
        for (uint256 i; i < traders.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            // A deposit the vault refuses (paused, zero shares) must not hold the whole delivery:
            // that trader gets plain IMD.
            try SIMD.deposit(amount, traders[i]) returns (uint256 shares) {
                if (shares == 0) revert ZeroShares(); // caught below: plain IMD instead
                emit Delivered(guid, srcEid, traders[i], amount, shares);
            } catch {
                IMD.safeTransfer(traders[i], amount);
                emit DeliveredPlain(guid, srcEid, traders[i], amount);
            }
        }
    }
}
