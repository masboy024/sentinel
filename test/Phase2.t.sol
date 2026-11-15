// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {PriceEmitter} from "../src/PriceEmitter.sol";
import {AIOracle} from "../src/AIOracle.sol";

contract Phase2Test is Test {
    address internal constant ASSET = address(0x1000);
    address internal runner = address(0xBEEF);
    address internal stranger = address(0xCAFE);

    PriceEmitter internal emitter;
    AIOracle internal oracle;

    function setUp() public {
        emitter = new PriceEmitter(ASSET);
        oracle = new AIOracle(runner);
    }

    function test_publishPriceEmitsAndStores() public {
        vm.expectEmit(true, false, false, true, address(emitter));
        emit PriceEmitter.PriceUpdated(ASSET, 200000, block.timestamp);
        emitter.publishPrice(200000);
        assertEq(emitter.lastPrice(), 200000);
        assertEq(emitter.updateCount(), 1);
    }

    function test_runnerCanSubmitVerdict() public {
        vm.prank(runner);
        oracle.submitVerdict(bytes32(uint256(7)), 88, 2, 96000);
        assertEq(oracle.verdictCount(), 1);
        (bytes32 h, uint8 score, uint8 regime, uint256 price,) = oracle.latestVerdict();
        assertEq(h, bytes32(uint256(7)));
        assertEq(score, 88);
        assertEq(regime, 2);
        assertEq(price, 96000);
    }

    function test_strangerCannotSubmit() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("AIOracle: only runner"));
        oracle.submitVerdict(bytes32(uint256(1)), 10, 0, 200000);
    }

    function test_scoreAbove100Reverts() public {
        vm.prank(runner);
        vm.expectRevert(bytes("AIOracle: score > 100"));
        oracle.submitVerdict(bytes32(uint256(1)), 101, 0, 200000);
    }

    function test_badRegimeReverts() public {
        vm.prank(runner);
        vm.expectRevert(bytes("AIOracle: bad regime"));
        oracle.submitVerdict(bytes32(uint256(1)), 10, 3, 200000);
    }
}
