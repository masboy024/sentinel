// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title CallbackRecorder — Phase 1 skeleton destination contract (Ethereum Sepolia).
/// @notice Receives callbacks from SentinelReactive through the chain's official
///         callback proxy and records each execution on-chain, so the full loop
///         (origin event -> reaction -> callback) is provable from event logs.
contract CallbackRecorder is AbstractCallback {
    event CallbackRecorded(
        address indexed reactive,
        uint256 value,
        uint256 originTxHash
    );

    uint256 public callbackCount;
    uint256 public lastValue;
    uint256 public lastOriginTxHash;

    /// @param callbackProxy_ Official callback proxy on this chain
    ///        (Ethereum Sepolia: 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4).
    /// @param callbackSender_ Address of SentinelReactive on Lasna.
    constructor(
        IPayable callbackProxy_,
        address callbackSender_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) {}

    /// @notice Callback entry point. The first argument is injected by the
    ///         network (address of the requesting reactive contract).
    function recordCallback(
        address reactive_,
        uint256 value_,
        uint256 originTxHash_
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        callbackCount++;
        lastValue = value_;
        lastOriginTxHash = originTxHash_;
        emit CallbackRecorded(reactive_, value_, originTxHash_);
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
