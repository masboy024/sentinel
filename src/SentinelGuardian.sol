// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title SentinelGuardian — Phase 3 reactive brain (Reactive Lasna).
/// @notice Subscribes to BOTH Sepolia event sources of the SENTINEL system:
///         `PriceUpdated` from the Phase 2 PriceEmitter (the raw price signal)
///         and `VerdictPosted` from the Phase 2 AIOracle (the local AI's
///         verdicts). It keeps the last known price plus the last AI verdict
///         and requests the protection callback ONLY when danger is confirmed
///         by both signals at once:
///           - latest verdict regime == 2 (crash-risk) AND riskScore >= 80, and
///           - the price stream has fallen >= 10% from the reference peak
///             tracked since the last reset.
///         A calm or merely volatile verdict never fires it. A latch allows
///         exactly ONE callback per danger episode; the latch resets only
///         after a subsequent non-danger verdict (regime != 2 or risk < 80).
contract SentinelGuardian is AbstractReactive {
    /// @notice keccak256("PriceUpdated(address,uint256,uint256)")
    uint256 private constant PRICE_TOPIC_0 =
        0xb556fac599c3c70efb9ab1fa725ecace6c81cc48d1455f886607def065f3e0c0;
    /// @notice keccak256("VerdictPosted(uint256,bytes32,uint8,uint8,uint256,uint256)")
    uint256 private constant VERDICT_TOPIC_0 =
        0x4f036d86e3b3f59a011343fdb8e54e5e816c50b114e3da8fa015b56451fb3825;

    uint64 private constant CALLBACK_GAS_LIMIT = 1000000;

    /// @notice AI danger calibration (Phase 2 arc: calm 16, volatile ~52,
    ///         crash 83-89 — a threshold of 80 separates crash-risk cleanly).
    uint8 private constant RISK_THRESHOLD = 80;
    uint8 private constant REGIME_CRASH = 2;
    /// @notice Minimum fall from the reference peak, in percent, that must
    ///         accompany a crash-risk verdict before protection fires.
    uint256 private constant DROP_PCT = 10;

    uint256 private immutable _destinationChainId;
    address private immutable _priceEmitter;
    address private immutable _aiOracle;

    address public owner;
    address public recipient;

    // --- combined signal state -------------------------------------------------
    uint256 public lastPrice; // latest price from the PriceEmitter stream
    uint256 public referencePrice; // running peak since the last reset
    uint8 public lastRiskScore; // latest AI verdict risk score (0-100)
    uint8 public lastRegime; // latest AI verdict regime (0 calm, 1 volatile, 2 crash)
    uint256 public lastVerdictPrice; // price attached to the latest verdict
    uint256 public lastVerdictTxHash; // origin tx of the latest verdict

    uint256 public priceCount; // PriceUpdated reactions
    uint256 public verdictCount; // VerdictPosted reactions
    uint256 public protectionCount; // protection callbacks requested
    bool public dangerLatched; // true while a danger episode is latched

    event PriceTracked(uint256 price, uint256 referencePrice);
    event VerdictTracked(uint8 riskScore, uint8 regime, uint256 price, bool dangerLatched);
    event ProtectionTriggered(uint8 indexed riskScore, uint256 price, uint256 indexed verdictTxHash);
    event LatchReset(uint8 riskScore, uint8 regime, uint256 referencePrice);
    event RecipientSet(address recipient);

    /// @param originChainId_ Chain where PriceEmitter and AIOracle live (Sepolia).
    /// @param priceEmitter_ Address of the Phase 2 PriceEmitter.
    /// @param aiOracle_ Address of the Phase 2 AIOracle.
    /// @param destinationChainId_ Chain where the callback recipient lives.
    constructor(
        uint256 originChainId_,
        address priceEmitter_,
        address aiOracle_,
        uint256 destinationChainId_
    ) payable {
        _destinationChainId = destinationChainId_;
        _priceEmitter = priceEmitter_;
        _aiOracle = aiOracle_;
        owner = msg.sender;

        SYSTEM.subscribe(
            originChainId_,
            priceEmitter_,
            PRICE_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            originChainId_,
            aiOracle_,
            VERDICT_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Set the destination-chain callback recipient (deploy-order step:
    ///         reactive first, recipient second, setter last — as in Phase 1).
    function setRecipient(address recipient_) external {
        require(msg.sender == owner, "not owner");
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 == PRICE_TOPIC_0 && log_.contractAddress == _priceEmitter) {
            _onPrice(log_);
        } else if (log_.topic0 == VERDICT_TOPIC_0 && log_.contractAddress == _aiOracle) {
            _onVerdict(log_);
        }
    }

    /// @notice Price stream: track the latest price and the running peak that
    ///         serves as the reference for the price-drop condition.
    function _onPrice(LogRecord calldata log_) internal {
        // PriceUpdated(address indexed asset, uint256 price, uint256 timestamp):
        // data = abi.encode(price, timestamp).
        (uint256 price, ) = abi.decode(log_.data, (uint256, uint256));
        lastPrice = price;
        priceCount++;
        if (!dangerLatched && price > referencePrice) {
            referencePrice = price;
        }
        emit PriceTracked(price, referencePrice);
    }

    /// @notice AI verdict stream: update the verdict state, maintain the
    ///         danger latch, and fire the protection callback exactly once
    ///         per confirmed danger episode.
    function _onVerdict(LogRecord calldata log_) internal {
        // VerdictPosted(uint256 indexed index, bytes32 inputHash, uint8 riskScore,
        // uint8 regime, uint256 price, uint256 timestamp):
        // data = abi.encode(inputHash, riskScore, regime, price, timestamp).
        (, uint8 risk, uint8 regime, uint256 price, ) =
            abi.decode(log_.data, (bytes32, uint8, uint8, uint256, uint256));

        lastRiskScore = risk;
        lastRegime = regime;
        lastVerdictPrice = price;
        lastVerdictTxHash = log_.txHash;
        verdictCount++;

        bool danger = regime == REGIME_CRASH && risk >= RISK_THRESHOLD;

        if (dangerLatched) {
            // One callback per episode: stay latched until a non-danger
            // verdict proves the episode is over.
            if (!danger) {
                dangerLatched = false;
                // Re-anchor the reference at the price level where the
                // episode ended (revision after the full-arc test: with the
                // stale pre-crash peak, a shallow post-reset crash blip —
                // risk 84 at -3% from the recovery level — fired a second
                // callback). A new episode is measured from here.
                referencePrice = lastPrice;
                emit LatchReset(risk, regime, referencePrice);
            }
        } else if (danger && _dropConfirmed() && recipient != address(0)) {
            dangerLatched = true;
            protectionCount++;

            // First payload argument is reserved: the network overwrites it
            // with this contract's address so the recipient can authenticate.
            // Payload value = the triggering risk score.
            bytes memory payload = abi.encodeWithSignature(
                "recordCallback(address,uint256,uint256)",
                address(0),
                uint256(risk),
                log_.txHash
            );
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: _destinationChainId,
                    recipient: recipient,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );
            emit ProtectionTriggered(risk, lastPrice, log_.txHash);
        }

        emit VerdictTracked(risk, regime, price, dangerLatched);
    }

    /// @notice Price-drop condition from the price stream: the latest price
    ///         has fallen at least DROP_PCT from the reference peak.
    function _dropConfirmed() internal view returns (bool) {
        return referencePrice > 0 &&
            lastPrice * 100 <= referencePrice * (100 - DROP_PCT);
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
