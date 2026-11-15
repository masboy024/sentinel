// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

/// @title PriceEmitter — Phase 2 price event source (Ethereum Sepolia).
/// @notice Stands in for a DEX pool / price feed: anyone can publish a price for the
///         tracked mock asset, and every publication emits a `PriceUpdated` event that
///         off-chain consumers (the SENTINEL AI runner) poll. In Phase 3 the reactive
///         contract on Lasna will subscribe to this same event signature.
contract PriceEmitter {
    /// @notice topic0 = keccak256("PriceUpdated(address,uint256,uint256)")
    event PriceUpdated(address indexed asset, uint256 price, uint256 timestamp);

    /// @notice The mock asset whose price is tracked (set once at deployment).
    address public immutable asset;

    uint256 public lastPrice;
    uint256 public updateCount;

    constructor(address asset_) {
        asset = asset_;
    }

    /// @notice Publish a new price (integer, USD cents in the demo scenarios).
    function publishPrice(uint256 price_) external {
        lastPrice = price_;
        updateCount++;
        emit PriceUpdated(asset, price_, block.timestamp);
    }
}
