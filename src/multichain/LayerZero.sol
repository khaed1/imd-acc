// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The parts of LayerZero v2 and the OFT standard that imd/acc's multichain contracts use,
/// copied field for field from `@layerzerolabs/oft-evm` (IOFT.sol) and `@layerzerolabs/lz-evm-protocol-v2`
/// (ILayerZeroEndpointV2.sol, ILayerZeroComposer.sol), so this repository vendors no LayerZero package.
/// IMD on every chain is a standard OFT (`oftVersion()` 0x02e49c2c, 1): the token burns on the source
/// chain, mints on the destination, and can carry a compose message that the destination endpoint
/// hands to the recipient contract in a separate transaction (`lzCompose`).

struct SendParam {
    uint32 dstEid; // destination endpoint id
    bytes32 to; // recipient, left-padded address
    uint256 amountLD; // amount to send, local decimals
    uint256 minAmountLD; // minimum to receive, local decimals
    bytes extraOptions; // executor options (gas for lzReceive and lzCompose)
    bytes composeMsg; // the compose payload; non-empty means send-and-call
    bytes oftCmd; // unused by the default OFT
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

interface IOFT {
    function quoteSend(SendParam calldata sendParam, bool payInLzToken)
        external
        view
        returns (MessagingFee memory);
    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory);
    /// @dev 10 ** (localDecimals - sharedDecimals): amounts cross the bridge in steps of this size.
    function decimalConversionRate() external view returns (uint256);
}

/// @dev What the destination endpoint calls on the contract named as the OFT send's recipient.
interface ILayerZeroComposer {
    function lzCompose(
        address from,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

/// @dev The compose message the OFT builds on arrival: nonce (8) | srcEid (4) | amountLD (32) |
/// composeFrom (32, the sender on the source chain) | composeMsg (the sender's payload).
library OFTComposeMsg {
    uint256 internal constant SRC_EID_OFFSET = 8;
    uint256 internal constant AMOUNT_LD_OFFSET = 12;
    uint256 internal constant COMPOSE_FROM_OFFSET = 44;
    uint256 internal constant COMPOSE_MSG_OFFSET = 76;

    function srcEid(bytes calldata m) internal pure returns (uint32) {
        return uint32(bytes4(m[SRC_EID_OFFSET:AMOUNT_LD_OFFSET]));
    }

    function amountLD(bytes calldata m) internal pure returns (uint256) {
        return uint256(bytes32(m[AMOUNT_LD_OFFSET:COMPOSE_FROM_OFFSET]));
    }

    function composeFrom(bytes calldata m) internal pure returns (bytes32) {
        return bytes32(m[COMPOSE_FROM_OFFSET:COMPOSE_MSG_OFFSET]);
    }

    function composeMsg(bytes calldata m) internal pure returns (bytes calldata) {
        return m[COMPOSE_MSG_OFFSET:];
    }
}

/// @dev Executor options, type 3 (`OptionsBuilder` in `@layerzerolabs/oapp-evm`): the gas the
/// executor gives the OFT's `lzReceive` and the recipient's `lzCompose` on the destination chain.
library ExecutorOptions {
    uint16 internal constant TYPE_3 = 3;
    uint8 internal constant WORKER_ID = 1;
    uint8 internal constant OPTION_TYPE_LZRECEIVE = 1;
    uint8 internal constant OPTION_TYPE_LZCOMPOSE = 3;

    function lzReceiveAndCompose(uint128 receiveGas, uint128 composeGas)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            TYPE_3,
            WORKER_ID,
            uint16(17), // 1 + 16
            OPTION_TYPE_LZRECEIVE,
            receiveGas,
            WORKER_ID,
            uint16(19), // 1 + 2 + 16
            OPTION_TYPE_LZCOMPOSE,
            uint16(0), // compose index
            composeGas
        );
    }
}
