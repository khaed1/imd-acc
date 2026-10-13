// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    IOFT,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    ILayerZeroComposer
} from "../../src/multichain/LayerZero.sol";

/// @dev A test double for IMD's LayerZero OFT: burns on `send` like the real one, removes dust
/// below the shared-decimal step, charges a fixed native fee, and records the last send so a test
/// can play the destination side (`MockEndpoint.deliver`). Mintable by anyone.
contract MockOFT is ERC20, IOFT {
    uint256 public constant override decimalConversionRate = 1e12; // 18 local, 6 shared decimals
    uint256 public nativeFee = 0.001 ether;
    bool public refuseSend;
    uint64 public nonce;

    struct Sent {
        bytes32 guid;
        address from;
        SendParam param;
        uint256 amountLD;
        uint256 paid;
    }

    Sent[] public sends;

    error SlippageExceeded(uint256 amountLD, uint256 minAmountLD);
    error NotEnoughNative(uint256 paid, uint256 needed);
    error SendRefused();

    constructor() ERC20("Mock IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setNativeFee(uint256 fee) external {
        nativeFee = fee;
    }

    function setRefuseSend(bool refuse) external {
        refuseSend = refuse;
    }

    function sendCount() external view returns (uint256) {
        return sends.length;
    }

    function lastSend() external view returns (Sent memory) {
        return sends[sends.length - 1];
    }

    function removeDust(uint256 amountLD) public pure returns (uint256) {
        return amountLD / decimalConversionRate * decimalConversionRate;
    }

    function quoteSend(SendParam calldata p, bool)
        external
        view
        override
        returns (MessagingFee memory)
    {
        uint256 amount = removeDust(p.amountLD);
        if (amount < p.minAmountLD) revert SlippageExceeded(amount, p.minAmountLD);
        return MessagingFee(nativeFee, 0);
    }

    function send(SendParam calldata p, MessagingFee calldata fee, address refundAddress)
        external
        payable
        override
        returns (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt)
    {
        if (refuseSend) revert SendRefused();
        uint256 amount = removeDust(p.amountLD);
        if (amount < p.minAmountLD) revert SlippageExceeded(amount, p.minAmountLD);
        if (msg.value < nativeFee || fee.nativeFee < nativeFee) {
            revert NotEnoughNative(msg.value, nativeFee);
        }
        _burn(msg.sender, amount);
        nonce += 1;
        bytes32 guid = keccak256(abi.encode(nonce, p.dstEid, msg.sender, amount));
        sends.push(Sent(guid, msg.sender, p, amount, msg.value));
        if (msg.value > nativeFee) {
            (bool ok,) = refundAddress.call{value: msg.value - nativeFee}("");
            ok; // the real endpoint refunds too; a failed refund is the refund address's problem
        }
        receipt = MessagingReceipt(guid, nonce, MessagingFee(nativeFee, 0));
        oftReceipt = OFTReceipt(amount, amount);
    }
}

/// @dev The destination side: mints the bridged amount to the recipient on the "Ethereum" token
/// (any MockOFT or mintable token) and calls `lzCompose` the way the real endpoint does, with the
/// compose message the real OFT would build (nonce, srcEid, amountLD, composeFrom, composeMsg).
contract MockEndpoint {
    function deliver(
        address oft,
        address to,
        bytes32 guid,
        uint64 nonce_,
        uint32 srcEid,
        uint256 amountLD,
        address composeFrom,
        bytes memory composeMsg,
        uint256 gas
    ) external {
        MockOFT(oft).mint(to, amountLD);
        bytes memory message = abi.encodePacked(
            nonce_, srcEid, amountLD, bytes32(uint256(uint160(composeFrom))), composeMsg
        );
        ILayerZeroComposer(to).lzCompose{gas: gas}(oft, guid, message, address(this), "");
    }

    /// @dev Calls `lzCompose` with an arbitrary message, for tests of the checks.
    function compose(address from, address to, bytes32 guid, bytes memory message) external {
        ILayerZeroComposer(to).lzCompose(from, guid, message, address(this), "");
    }

    /// @dev The encoded OFT compose message, for tests that build their own.
    function encode(
        uint64 nonce_,
        uint32 srcEid,
        uint256 amountLD,
        address composeFrom,
        bytes memory composeMsg
    ) external pure returns (bytes memory) {
        return abi.encodePacked(
            nonce_, srcEid, amountLD, bytes32(uint256(uint160(composeFrom))), composeMsg
        );
    }
}
