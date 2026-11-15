// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title SentinelReactive — Phase 1 skeleton reactive contract (Reactive Lasna).
/// @notice Subscribes to `Ping` events from OriginEmitter on the origin chain.
///         On each event it records the reaction on Lasna and, once a recipient
///         is set, requests a callback to the destination chain via the system
///         contract (`requestCallbackV_1_0`), following the official Omni pattern.
contract SentinelReactive is AbstractReactive {
    /// @notice keccak256("Ping(address,uint256,uint256)")
    uint256 private constant PING_TOPIC_0 =
        0x112d2e583fa63f0db88f80b06e471fea138fb541483952119ece7a75e1bb426c;

    uint64 private constant CALLBACK_GAS_LIMIT = 1000000;

    uint256 private immutable _destinationChainId;
    address public owner;
    address public recipient;

    uint256 public reactionCount;
    uint256 public lastValue;
    uint256 public lastOriginTxHash;

    event ReactionRecorded(uint256 indexed originTxHash, uint256 value);
    event CallbackRequested(uint256 value, uint256 originTxHash);
    event RecipientSet(address recipient);

    /// @param originChainId_ Chain where OriginEmitter lives.
    /// @param originContract_ Address of OriginEmitter.
    /// @param destinationChainId_ Chain where the callback recipient lives.
    constructor(
        uint256 originChainId_,
        address originContract_,
        uint256 destinationChainId_
    ) payable {
        _destinationChainId = destinationChainId_;
        owner = msg.sender;

        SYSTEM.subscribe(
            originChainId_,
            originContract_,
            PING_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Set the destination-chain callback recipient (deploy-order step 3,
    ///         per the official docs: reactive first, recipient second, setter last).
    function setRecipient(address recipient_) external {
        require(msg.sender == owner, "not owner");
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        // Ping(address indexed sender, uint256 value, uint256 timestamp):
        // one indexed parameter -> LOG2, data = abi.encode(value, timestamp).
        if (log_.topic0 != PING_TOPIC_0) {
            return;
        }
        (uint256 value, ) = abi.decode(log_.data, (uint256, uint256));

        reactionCount++;
        lastValue = value;
        lastOriginTxHash = log_.txHash;
        emit ReactionRecorded(log_.txHash, value);

        address recipient_ = recipient;
        if (recipient_ != address(0)) {
            // First payload argument is reserved: the network overwrites it
            // with this contract's address so the recipient can authenticate.
            bytes memory payload = abi.encodeWithSignature(
                "recordCallback(address,uint256,uint256)",
                address(0),
                value,
                log_.txHash
            );

            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: _destinationChainId,
                    recipient: recipient_,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );
            emit CallbackRequested(value, log_.txHash);
        }
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
