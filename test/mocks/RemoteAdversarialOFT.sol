// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt
} from "src/multichain/LayerZero.sol";

/// @dev Fault injection at RemoteStacker's external-call boundaries. Normal mode models the
/// fixed IMD OFT's burn, shared decimals and native refund. Other modes test defensive handling,
/// not a claim that the deployed IMD has ERC20 callbacks or unusual return values.
contract RemoteAdversarialOFT is ERC20, IOFT {
    enum ReturnMode {
        Normal,
        Empty,
        False,
        Revert
    }
    enum Hook {
        None,
        Pull,
        Push,
        Send
    }

    uint256 public constant decimalConversionRate = 1e12;
    uint256 public constant nativeFee = 0.001 ether;
    ReturnMode public pullMode;
    ReturnMode public pushMode;
    Hook public hook;
    address public callbackTarget;
    bytes public callbackData;
    uint256 public callbackCount;
    bool public callbackSucceeded;
    bytes public callbackResult;
    bool public refuseQuote;
    bool public refuseAfterBurn;
    uint64 public nonce;
    uint256 public burned;
    address public lastRefundAddress;
    SendParam private lastParam;

    error TokenRefused();
    error QuoteRefused();
    error SendRefusedAfterBurn();
    error Underpaid();
    error RefundRefused();

    constructor() ERC20("Remote fault-injection IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReturns(ReturnMode pull, ReturnMode push) external {
        pullMode = pull;
        pushMode = push;
    }

    function setHook(Hook at, address target, bytes calldata data) external {
        hook = at;
        callbackTarget = target;
        callbackData = data;
        callbackCount = 0;
        delete callbackResult;
        callbackSucceeded = false;
    }

    function setBridgeFailures(bool quoteFailure, bool sendFailure) external {
        refuseQuote = quoteFailure;
        refuseAfterBurn = sendFailure;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        _callback(Hook.Pull);
        return _return(pullMode);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        _callback(Hook.Push);
        return _return(pushMode);
    }

    function _return(ReturnMode mode) private pure returns (bool) {
        if (mode == ReturnMode.Revert) revert TokenRefused();
        if (mode == ReturnMode.Empty) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return mode != ReturnMode.False;
    }

    function _callback(Hook at) private {
        if (hook != at) return;
        // Disarm before the call so removing the production reentrancy guard produces an
        // observable successful nested call, rather than an artificial recursion/OOG failure.
        hook = Hook.None;
        ++callbackCount;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
    }

    function lastSend() external view returns (SendParam memory) {
        return lastParam;
    }

    function quoteSend(SendParam calldata, bool payInLzToken)
        external
        view
        returns (MessagingFee memory)
    {
        require(!payInLzToken, "native only");
        if (refuseQuote) revert QuoteRefused();
        return MessagingFee(nativeFee, 0);
    }

    function send(SendParam calldata p, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        if (msg.value < nativeFee || fee.nativeFee != msg.value || fee.lzTokenFee != 0) {
            revert Underpaid();
        }
        require(p.amountLD % decimalConversionRate == 0, "unrounded send");
        require(p.minAmountLD == p.amountLD, "slippage");
        _burn(msg.sender, p.amountLD);
        burned += p.amountLD;
        ++nonce;
        lastParam = p;
        lastRefundAddress = refundAddress;
        _callback(Hook.Send);
        if (refuseAfterBurn) revert SendRefusedAfterBurn();
        if (msg.value > nativeFee) {
            (bool ok,) = refundAddress.call{value: msg.value - nativeFee}("");
            if (!ok) revert RefundRefused();
        }
        bytes32 guid = keccak256(abi.encode(msg.sender, nonce, p));
        return (
            MessagingReceipt(guid, nonce, MessagingFee(nativeFee, 0)),
            OFTReceipt(p.amountLD, p.amountLD)
        );
    }
}
