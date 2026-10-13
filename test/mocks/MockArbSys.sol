// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test-only model of the rollup height, independent of the EVM's parent-chain NUMBER.
contract MockArbSys {
    uint256 public arbBlockNumber;

    function setBlockNumber(uint256 value) external {
        arbBlockNumber = value;
    }
}
