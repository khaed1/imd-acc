// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILayerZeroComposer} from "src/multichain/LayerZero.sol";

/// @dev Local model of the EndpointV2 compose queue only. This is not a model of bridge
/// verification or OFT mint authorization. Tests separately mint an arrival, then queue it as
/// the OFT, matching the two transactions exercised by StackReceiverMainnetFork.t.sol.
/// The queue is namespaced by the token that calls sendCompose. Consumed entries stay marked,
/// and a reverting receiver rolls back consumption, allowing an executor to retry.
contract QueuedComposeEndpoint {
    bytes32 public constant RECEIVED = bytes32(uint256(1));
    mapping(address => mapping(address => mapping(bytes32 => mapping(uint16 => bytes32)))) public
        composeQueue;

    error AlreadyQueued();
    error MessageNotQueued();

    function sendCompose(address to, bytes32 guid, uint16 index, bytes calldata message) external {
        if (composeQueue[msg.sender][to][guid][index] != bytes32(0)) revert AlreadyQueued();
        composeQueue[msg.sender][to][guid][index] = keccak256(message);
    }

    function lzCompose(
        address from,
        address to,
        bytes32 guid,
        uint16 index,
        bytes calldata message,
        bytes calldata extraData
    ) external payable {
        if (composeQueue[from][to][guid][index] != keccak256(message)) {
            revert MessageNotQueued();
        }
        composeQueue[from][to][guid][index] = RECEIVED;
        ILayerZeroComposer(to).lzCompose{value: msg.value}(
            from, guid, message, msg.sender, extraData
        );
    }
}
