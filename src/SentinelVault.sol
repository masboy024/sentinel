// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title SentinelVault — Phase 4 protection destination (Base Sepolia).
/// @notice A vault holding a mock at-risk position. It receives the SENTINEL
///         protection callback from the Lasna SentinelGuardian (Phase 4
///         instance) through Base Sepolia's official Reactive callback proxy
///         and, on a valid callback, EXECUTES the protection action on-chain:
///         the entire at-risk position is moved into the protected (safe)
///         bucket, and the execution is recorded with the triggering AI risk
///         score and the origin (AI verdict) transaction hash.
///
///         Authentication follows the Reactive callback pattern proven in
///         Phases 1-3: the call must come from the chain's callback proxy
///         (`onlyServiceProvider`), and the network-injected first payload
///         argument must equal the guardian address bound immutably at
///         construction (`onlyCallbackSender`, via `AbstractCallback`).
///         Any other caller reverts. As defense in depth the vault also
///         refuses callbacks whose risk score is below the protection
///         threshold — the guardian only ever sends confirmed-danger scores,
///         so a low score here means the call is not a genuine protection
///         signal.
///
///         Position units are mock units: 1 unit = 1 USD cent of a mock
///         position (the Phase 4 deployment seeds 1,000,000 units = a
///         $10,000 mock position). The ETH balance held by the contract is
///         separate: it pays the callback proxy for callback execution
///         (AbstractPayer debt model), exactly like the Phase 1-3 recorders.
contract SentinelVault is AbstractCallback {
    /// @notice Minimum AI risk score a protection callback must carry.
    ///         Mirrors the guardian's firing threshold (Phase 2 calibration:
    ///         calm 16, volatile ~52, crash 83-89).
    uint256 public constant MIN_PROTECTION_RISK = 80;

    address public owner;

    // --- mock position state ---------------------------------------------------
    uint256 public positionAtRisk; // mock units still exposed to the market
    uint256 public safeBalance; // mock units moved to safety by protection
    uint256 public protectionCount; // protection callbacks executed
    uint256 public totalProtected; // cumulative mock units moved to safety
    uint256 public lastRiskScore; // risk score of the last protection callback
    uint256 public lastOriginTxHash; // AI verdict tx that triggered it
    uint256 public lastProtectedAmount; // units moved by the last protection
    uint256 public lastProtectionTimestamp; // block.timestamp of last protection

    event PositionSeeded(uint256 amount);
    event PositionDeposited(uint256 amount, uint256 positionAtRisk);
    event ProtectionExecuted(
        address indexed reactive,
        uint256 riskScore,
        uint256 amountMoved,
        uint256 indexed originTxHash
    );

    /// @param callbackProxy_ Official Reactive callback proxy on this chain
    ///        (Base Sepolia: 0x476F44b11F5C942c58f4c8E3d0300E5710743585).
    /// @param callbackSender_ Address of the Phase 4 SentinelGuardian on
    ///        Lasna. Bound immutably — the vault must be deployed with the
    ///        guardian's final address (Phase 3 lesson).
    /// @param initialPosition_ Mock position (units) seeded at deployment.
    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        uint256 initialPosition_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) {
        owner = msg.sender;
        positionAtRisk = initialPosition_;
        emit PositionSeeded(initialPosition_);
    }

    /// @notice Add mock position units (owner only; models a user deposit
    ///         into the at-risk strategy).
    function depositPosition(uint256 amount_) external {
        require(msg.sender == owner, "not owner");
        positionAtRisk += amount_;
        emit PositionDeposited(amount_, positionAtRisk);
    }

    /// @notice Protection callback entry point. The guardian's payload uses
    ///         this exact signature (`recordCallback(address,uint256,uint256)`);
    ///         the first argument is overwritten by the network with the
    ///         requesting reactive contract's address. On a valid callback the
    ///         protection action executes immediately: the whole at-risk
    ///         position is moved to the safe bucket.
    function recordCallback(
        address reactive_,
        uint256 riskScore_,
        uint256 originTxHash_
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        require(
            riskScore_ >= MIN_PROTECTION_RISK,
            "risk below protection threshold"
        );
        uint256 amount = positionAtRisk;
        positionAtRisk = 0;
        safeBalance += amount;
        totalProtected += amount;
        protectionCount++;
        lastRiskScore = riskScore_;
        lastOriginTxHash = originTxHash_;
        lastProtectedAmount = amount;
        lastProtectionTimestamp = block.timestamp;
        emit ProtectionExecuted(reactive_, riskScore_, amount, originTxHash_);
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
