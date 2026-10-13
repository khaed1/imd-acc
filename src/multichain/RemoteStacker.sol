// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    ExecutorOptions
} from "./LayerZero.sol";

/// @title RemoteStacker
/// @notice imd/acc's cashback funnel on a chain other than Ethereum (Robinhood Chain first). The sIMD
/// vault exists only on Ethereum, so a project here calls the same `credit(trader, imdAmount)` as on
/// Ethereum, and the IMD waits in this contract, per trader, until anyone `flush`es it: the waiting
/// IMD is sent to Ethereum through IMD's own LayerZero bridge (IMD is an OFT) with the list of
/// traders and amounts, and the StackReceiver there deposits it into the sIMD vault for each trader.
/// `Queued(project, trader, imd)` is emitted at once and is the points record on this chain.
///
/// Whoever flushes pays the bridge fee (in this chain's gas token) and earns a tip in IMD from each
/// trader flushed: 2% of their waiting cashback per 12 hours waited, at most 2%, computed by this
/// contract. The trader always receives at least 98%. imd/acc takes nothing; nobody can withdraw,
/// redirect or freeze anything: no owner, no admin, no pause, no upgrade. The only way out is to the
/// StackReceiver fixed at deployment.
///
/// Smart-contract wallets (a Safe, a smart wallet) may not exist at the same address on Ethereum,
/// so a trader with code is paid plain IMD here at once (`Paid`, no points) unless it has registered
/// an Ethereum address for itself with `setEthereumRecipient`. Plain wallets, including EIP-7702
/// delegated ones, go through the queue.
contract RemoteStacker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice IMD on this chain: a LayerZero OFT that burns here and mints on Ethereum.
    IERC20 public immutable IMD;
    /// @notice The StackReceiver on Ethereum that deposits delivered IMD into the sIMD vault.
    address public immutable RECEIVER;
    /// @notice The Ethereum sIMD vault, named so it can be refused as a trader (shares there could
    /// never move); it is never called from this chain.
    address public immutable VAULT;
    /// @notice LayerZero endpoint id of Ethereum (30101).
    uint32 public immutable DST_EID;

    /// @notice The tip: `TIP_BPS` of the waiting amount after `TIP_PERIOD` of waiting, growing linearly
    /// from zero and capped there.
    uint256 public constant TIP_BPS = 200;
    uint256 public constant TIP_PERIOD = 12 hours;
    uint256 public constant BPS = 10_000;
    /// @notice Most traders in one flush.
    uint256 public constant MAX_FLUSH = 50;
    /// @notice Gas the bridge gives IMD's `lzReceive` on Ethereum: the mint plus queueing the
    /// compose (measured on a mainnet fork: 98k for one trader, 158k for fifty).
    uint128 public constant RECEIVE_GAS = 250_000;
    /// @notice Gas the bridge gives the StackReceiver's `lzCompose`: a base plus a share per trader,
    /// one vault deposit each or a plain transfer if the deposit fails (measured on a mainnet fork:
    /// 225k for one trader, 685k for ten, 3.08M for fifty).
    uint128 public constant COMPOSE_BASE_GAS = 200_000;
    uint128 public constant COMPOSE_GAS_PER_TRADER = 80_000;

    /// @notice IMD waiting for each Ethereum recipient, and the amount-weighted time it arrived.
    mapping(address => uint256) public waiting;
    mapping(address => uint64) public waitingSince;
    /// @notice Where a smart-contract wallet's cashback should go on Ethereum (set by itself).
    mapping(address => address) public ethereumRecipient;
    /// @notice IMD queued by each project, across all traders, and in total (points records).
    mapping(address => uint256) public projectQueued;
    uint256 public totalQueued;
    /// @notice IMD paid as plain IMD on this chain to contract wallets without an Ethereum recipient.
    uint256 public totalPaid;

    /// @notice Emitted once per non-zero credit that joins the queue: the points record.
    /// @param recipient The Ethereum address the cashback is delivered to (the trader, or the
    /// Ethereum recipient a contract wallet registered).
    event Queued(address indexed project, address indexed trader, address recipient, uint256 imd);
    /// @notice A contract wallet without an Ethereum recipient was paid plain IMD here. No points.
    event Paid(address indexed project, address indexed trader, uint256 imd);
    /// @notice Waiting cashback left for Ethereum in one bridge message.
    event Flushed(
        bytes32 indexed guid, address indexed flusher, uint256 imd, uint256 tip, uint256 traders
    );
    /// @notice One recipient's share of a flush.
    event Delivering(bytes32 indexed guid, address indexed recipient, uint256 imd, uint256 tip);
    event EthereumRecipientSet(address indexed wallet, address recipient);

    error ZeroTrader();
    error InvalidTrader();
    error ZeroAddress();
    error NothingToFlush();
    error TooManyTraders();
    error InvalidRecipient();

    /// @dev No external calls: the launch rehearses deployment on an empty chain.
    constructor(IERC20 imd, address receiver, address vault, uint32 dstEid) {
        if (address(imd) == address(0) || receiver == address(0) || vault == address(0)) {
            revert ZeroAddress();
        }
        IMD = imd;
        RECEIVER = receiver;
        VAULT = vault;
        DST_EID = dstEid;
    }

    // ================================================================ credit

    /// @notice Pull `imdAmount` IMD from the caller (the project) as cashback for `trader`. A plain
    /// wallet's cashback waits here for the next flush to Ethereum; a contract wallet's goes to the
    /// Ethereum recipient it registered, or is paid to it here as plain IMD if it registered none.
    /// Returns the amount queued (0 when paid here, or for a zero amount).
    function credit(address trader, uint256 imdAmount) external nonReentrant returns (uint256) {
        if (trader == address(0)) revert ZeroTrader();
        if (
            trader == address(this) || trader == address(IMD) || trader == RECEIVER
                || trader == VAULT
        ) revert InvalidTrader();
        if (imdAmount == 0) return 0;

        IMD.safeTransferFrom(msg.sender, address(this), imdAmount);

        address recipient = trader;
        if (_isContractWallet(trader)) {
            recipient = ethereumRecipient[trader];
            if (recipient == address(0)) {
                totalPaid += imdAmount;
                IMD.safeTransfer(trader, imdAmount);
                emit Paid(msg.sender, trader, imdAmount);
                return 0;
            }
        }

        uint256 before = waiting[recipient];
        // The waiting clock is the amount-weighted arrival time, so new cashback never inherits an
        // old clock and old cashback never loses its waiting time.
        waitingSince[recipient] = uint64(
            (uint256(waitingSince[recipient]) * before + block.timestamp * imdAmount)
                / (before + imdAmount)
        );
        waiting[recipient] = before + imdAmount;
        projectQueued[msg.sender] += imdAmount;
        totalQueued += imdAmount;
        emit Queued(msg.sender, trader, recipient, imdAmount);
        return imdAmount;
    }

    /// @notice A contract wallet names the Ethereum address its cashback is delivered to. Only the
    /// wallet itself can set it; the zero address clears it (cashback is then paid here again).
    function setEthereumRecipient(address recipient) external {
        if (
            recipient == address(this) || recipient == address(IMD) || recipient == RECEIVER
                || recipient == VAULT
        ) revert InvalidRecipient();
        ethereumRecipient[msg.sender] = recipient;
        emit EthereumRecipientSet(msg.sender, recipient);
    }

    /// @dev A trader with code is a contract wallet, except an EIP-7702 delegation (23 bytes
    /// starting 0xef0100), which is a plain wallet that exists on every chain.
    function _isContractWallet(address trader) internal view returns (bool) {
        uint256 size = trader.code.length;
        if (size == 0) return false;
        if (size == 23) {
            bytes memory prefix = new bytes(3);
            assembly ("memory-safe") {
                extcodecopy(trader, add(prefix, 32), 0, 3)
            }
            if (prefix[0] == 0xef && prefix[1] == 0x01 && prefix[2] == 0x00) return false;
        }
        return true;
    }

    // ================================================================ flush

    /// @notice The tip waiting cashback would pay now, in basis points of the amount: 2% per 12
    /// hours waited, at most 2%.
    function tipBps(address recipient) public view returns (uint256) {
        if (waiting[recipient] == 0) return 0;
        uint256 waited = block.timestamp - waitingSince[recipient];
        if (waited >= TIP_PERIOD) return TIP_BPS;
        return TIP_BPS * waited / TIP_PERIOD;
    }

    /// @dev One flush, worked out before anything changes.
    struct Plan {
        address[] to;
        uint256[] amounts;
        uint256[] tips;
        uint256 imd;
        uint256 tip;
    }

    /// @notice What `flush(recipients)` would send and pay: the IMD delivered, the tip in IMD, the
    /// recipients and amounts, and the bridge fee in this chain's gas token.
    function quoteFlush(address[] calldata recipients)
        external
        view
        returns (
            uint256 imd,
            uint256 tip,
            address[] memory to,
            uint256[] memory amounts,
            uint256 nativeFee
        )
    {
        Plan memory plan = _plan(recipients);
        if (plan.imd > 0) {
            nativeFee = IOFT(address(IMD)).quoteSend(_sendParam(plan), false).nativeFee;
        }
        return (plan.imd, plan.tip, plan.to, plan.amounts, nativeFee);
    }

    /// @notice Send the waiting cashback of up to 50 recipients to Ethereum in one bridge message.
    /// The caller pays the bridge fee (`msg.value`, quoted by `quoteFlush`; the excess is refunded
    /// by the endpoint) and receives the tips in IMD. Each delivered amount is rounded down to the
    /// bridge's step (0.000001 IMD); the rest stays waiting with the recipient. A recipient listed
    /// twice, or with nothing waiting, is skipped. If anything fails, nothing changes.
    function flush(address[] calldata recipients)
        external
        payable
        nonReentrant
        returns (bytes32 guid)
    {
        Plan memory plan = _plan(recipients);
        if (plan.imd == 0) revert NothingToFlush();

        for (uint256 i; i < plan.to.length; ++i) {
            address r = plan.to[i];
            uint256 left = waiting[r] - plan.amounts[i] - plan.tips[i];
            waiting[r] = left;
            if (left == 0) waitingSince[r] = 0;
        }

        (MessagingReceipt memory receipt,) = IOFT(address(IMD)).send{value: msg.value}(
            _sendParam(plan), MessagingFee(msg.value, 0), msg.sender
        );
        guid = receipt.guid;
        if (plan.tip > 0) IMD.safeTransfer(msg.sender, plan.tip);

        for (uint256 i; i < plan.to.length; ++i) {
            emit Delivering(guid, plan.to[i], plan.amounts[i], plan.tips[i]);
        }
        emit Flushed(guid, msg.sender, plan.imd, plan.tip, plan.to.length);
    }

    /// @dev Which recipients have something to deliver, how much each, and the tips, without
    /// changing anything.
    function _plan(address[] calldata recipients) internal view returns (Plan memory plan) {
        if (recipients.length > MAX_FLUSH) revert TooManyTraders();
        uint256 step = IOFT(address(IMD)).decimalConversionRate();
        plan.to = new address[](recipients.length);
        plan.amounts = new uint256[](recipients.length);
        plan.tips = new uint256[](recipients.length);
        uint256 n;
        for (uint256 i; i < recipients.length; ++i) {
            address r = recipients[i];
            uint256 w = waiting[r];
            if (w == 0 || _listed(plan.to, n, r)) continue;
            uint256 share = w * tipBps(r) / BPS;
            uint256 amount = (w - share) / step * step; // dust below the bridge step stays waiting
            if (amount == 0) continue;
            plan.to[n] = r;
            plan.amounts[n] = amount;
            plan.tips[n] = share;
            ++n;
            plan.imd += amount;
            plan.tip += share;
        }
        address[] memory to = plan.to;
        uint256[] memory amounts = plan.amounts;
        uint256[] memory tips = plan.tips;
        assembly ("memory-safe") {
            mstore(to, n)
            mstore(amounts, n)
            mstore(tips, n)
        }
    }

    function _listed(address[] memory to, uint256 n, address r) internal pure returns (bool) {
        for (uint256 j; j < n; ++j) {
            if (to[j] == r) return true;
        }
        return false;
    }

    function _sendParam(Plan memory plan) internal view returns (SendParam memory) {
        return SendParam({
            dstEid: DST_EID,
            to: bytes32(uint256(uint160(RECEIVER))),
            amountLD: plan.imd,
            minAmountLD: plan.imd,
            extraOptions: ExecutorOptions.lzReceiveAndCompose(
                RECEIVE_GAS, COMPOSE_BASE_GAS + COMPOSE_GAS_PER_TRADER * uint128(plan.to.length)
            ),
            composeMsg: abi.encode(plan.to, plan.amounts),
            oftCmd: ""
        });
    }
}
