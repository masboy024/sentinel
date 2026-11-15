// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

/// @title AIOracle — Phase 2 on-chain record of SENTINEL AI verdicts (Ethereum Sepolia).
/// @notice The off-chain AI runner posts one verdict per evaluated price window. Each
///         verdict commits to the exact input window (inputHash), the model's risk
///         score (0-100), the regime code (0 = calm, 1 = volatile, 2 = crash-risk) and
///         the latest price in the window, so anyone can verify the model's behaviour
///         on-chain and reproduce it off-chain from the PriceEmitter event history.
///         Only the designated runner address may submit. In Phase 3 the reactive
///         contract on Lasna subscribes to `VerdictPosted`.
contract AIOracle {
    struct Verdict {
        bytes32 inputHash; // hash of the price window the model consumed
        uint8 riskScore; // 0-100
        uint8 regime; // 0 = calm, 1 = volatile, 2 = crash-risk
        uint256 price; // latest price in the evaluated window
        uint256 timestamp; // block timestamp when the verdict was posted
    }

    event VerdictPosted(
        uint256 indexed index,
        bytes32 inputHash,
        uint8 riskScore,
        uint8 regime,
        uint256 price,
        uint256 timestamp
    );

    /// @notice The only address allowed to submit verdicts (the AI runner's wallet).
    address public immutable runner;

    Verdict[] private _verdicts;

    constructor(address runner_) {
        runner = runner_;
    }

    /// @notice Post one AI verdict. Callable only by the runner.
    function submitVerdict(bytes32 inputHash_, uint8 riskScore_, uint8 regime_, uint256 price_) external {
        require(msg.sender == runner, "AIOracle: only runner");
        require(riskScore_ <= 100, "AIOracle: score > 100");
        require(regime_ <= 2, "AIOracle: bad regime");
        _verdicts.push(Verdict(inputHash_, riskScore_, regime_, price_, block.timestamp));
        emit VerdictPosted(_verdicts.length - 1, inputHash_, riskScore_, regime_, price_, block.timestamp);
    }

    function verdictCount() external view returns (uint256) {
        return _verdicts.length;
    }

    function getVerdict(uint256 index_)
        external
        view
        returns (bytes32 inputHash, uint8 riskScore, uint8 regime, uint256 price, uint256 timestamp)
    {
        Verdict storage v = _verdicts[index_];
        return (v.inputHash, v.riskScore, v.regime, v.price, v.timestamp);
    }

    function latestVerdict()
        external
        view
        returns (bytes32 inputHash, uint8 riskScore, uint8 regime, uint256 price, uint256 timestamp)
    {
        require(_verdicts.length > 0, "AIOracle: no verdicts");
        Verdict storage v = _verdicts[_verdicts.length - 1];
        return (v.inputHash, v.riskScore, v.regime, v.price, v.timestamp);
    }
}
