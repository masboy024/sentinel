// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title MockSystem — test double for the Reactive system contract.
/// @notice Etched at 0x8888888888888888888888888888888888888888 in tests so the
///         real AbstractReactive code paths run against it. Only the selectors
///         our contracts actually call are implemented.
contract MockSystem {
    uint256 public subscribeCount;
    uint256 public lastSubChainId;
    address public lastSubContract;
    uint256 public lastSubTopic0;

    uint256 public callbackCount;
    uint256 public lastCallbackChainId;
    address public lastCallbackRecipient;
    uint64 public lastCallbackGasLimit;
    bytes public lastCallbackPayload;

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256,
        uint256,
        uint256
    ) external {
        subscribeCount++;
        lastSubChainId = chainId_;
        lastSubContract = contract_;
        lastSubTopic0 = topic0_;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(
        ISystemContract.CallbackConfiguration_V_1_0 memory config_
    ) external {
        callbackCount++;
        lastCallbackChainId = config_.chainId;
        lastCallbackRecipient = config_.recipient;
        lastCallbackGasLimit = config_.gasLimit;
        lastCallbackPayload = config_.payload;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
}

/// @title MockCallbackProxy — stands in for the destination-chain callback proxy.
/// @notice AbstractCallback only stores it and checks msg.sender against it;
///         `debt()` exists because AbstractPayer references it.
contract MockCallbackProxy {
    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function pay(uint256) external pure returns (bool) {
        return true;
    }
}
