// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

/// @title OriginEmitter — Phase 1 skeleton origin contract (Ethereum Sepolia).
/// @notice Emits a simple `Ping` event that the reactive contract on Lasna subscribes to.
///         In later phases this role is played by SENTINEL's MockPool (price events).
contract OriginEmitter {
    /// @notice topic0 = 0x112d2e583fa63f0db88f80b06e471fea138fb541483952119ece7a75e1bb426c
    event Ping(address indexed sender, uint256 value, uint256 timestamp);

    uint256 public pingCount;
    uint256 public lastValue;

    /// @notice Emit a Ping event carrying an arbitrary value.
    function ping(uint256 value_) external {
        pingCount++;
        lastValue = value_;
        emit Ping(msg.sender, value_, block.timestamp);
    }
}
