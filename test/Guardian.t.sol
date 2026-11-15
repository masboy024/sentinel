// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { PriceEmitter } from "../src/PriceEmitter.sol";
import { AIOracle } from "../src/AIOracle.sol";
import { SentinelGuardian } from "../src/SentinelGuardian.sol";
import { CallbackRecorder } from "../src/CallbackRecorder.sol";
import { MockSystem, MockCallbackProxy } from "./mocks/MockSystem.sol";

/// @notice Local logic test of the Phase 3 reactive brain. Feeds the guardian
///         the exact price/verdict arc the (unmodified) Phase 2 AI produces
///         for the Phase 3 on-chain sequence — calm leg, crash leg, volatile
///         leg — as predicted by the offline model simulation, and checks the
///         protection latch: 0 callbacks on calm, exactly 1 on crash, latch
///         reset on recovery, no second fire on the post-reset crash blip.
contract GuardianTest is Test {
    address internal constant SYSTEM_ADDR =
        0x8888888888888888888888888888888888888888;
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant PRICE_TOPIC_0 =
        0xb556fac599c3c70efb9ab1fa725ecace6c81cc48d1455f886607def065f3e0c0;
    uint256 internal constant VERDICT_TOPIC_0 =
        0x4f036d86e3b3f59a011343fdb8e54e5e816c50b114e3da8fa015b56451fb3825;
    address internal constant ASSET =
        0x0000000000000000000000000000000000001000;

    MockSystem internal system;
    MockCallbackProxy internal proxy;
    PriceEmitter internal emitter;
    AIOracle internal oracle;
    SentinelGuardian internal guardian;
    CallbackRecorder internal recorder;

    uint256 internal _txSeq;

    function setUp() public {
        MockSystem mock = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        system = MockSystem(SYSTEM_ADDR);

        proxy = new MockCallbackProxy();
        emitter = new PriceEmitter(ASSET);
        oracle = new AIOracle(address(this));
        guardian = new SentinelGuardian{ value: 1 ether }(
            SEPOLIA,
            address(emitter),
            address(oracle),
            SEPOLIA
        );
        recorder = new CallbackRecorder{ value: 1 ether }(
            IPayable(payable(address(proxy))),
            address(guardian)
        );
        guardian.setRecipient(address(recorder));
    }

    // --- log feeding helpers ---------------------------------------------------

    function _nextTx() internal returns (uint256) {
        _txSeq++;
        return 0xAA0000 + _txSeq;
    }

    function _feedPrice(uint256 price_) internal {
        IReactive.LogRecord memory log;
        log.chainId = SEPOLIA;
        log.contractAddress = address(emitter);
        log.topic0 = PRICE_TOPIC_0;
        log.topic1 = uint256(uint160(ASSET));
        log.data = abi.encode(price_, uint256(1700000000));
        log.opCode = 2;
        log.txHash = _nextTx();
        vm.prank(SYSTEM_ADDR);
        guardian.react(log);
    }

    function _feedVerdict(uint8 risk_, uint8 regime_, uint256 price_) internal returns (uint256 txHash_) {
        txHash_ = _nextTx();
        IReactive.LogRecord memory log;
        log.chainId = SEPOLIA;
        log.contractAddress = address(oracle);
        log.topic0 = VERDICT_TOPIC_0;
        log.topic1 = guardian.verdictCount(); // verdict index
        log.data = abi.encode(bytes32(0), risk_, regime_, price_, uint256(1700000000));
        log.opCode = 2;
        log.txHash = txHash_;
        vm.prank(SYSTEM_ADDR);
        guardian.react(log);
    }

    function _step(uint256 price_, uint8 risk_, uint8 regime_) internal returns (uint256) {
        _feedPrice(price_);
        return _feedVerdict(risk_, regime_, price_);
    }

    // --- tests -------------------------------------------------------------------

    function test_subscriptions_registered() public view {
        assertEq(system.subscribeCount(), 2);
    }

    function test_crash_verdict_without_drop_does_not_fire() public {
        _step(200000, 88, 2); // crash verdict, but price is at the peak
        assertEq(guardian.protectionCount(), 0);
        assertEq(system.callbackCount(), 0);
        assertFalse(guardian.dangerLatched());
    }

    function test_volatile_verdict_with_drop_does_not_fire() public {
        _feedPrice(200330);
        _step(100000, 52, 1); // -50% drop, but verdict is only volatile
        assertEq(guardian.protectionCount(), 0);
        assertEq(system.callbackCount(), 0);
    }

    function test_full_arc_calm_crash_volatile() public {
        // ---- Leg A: calm (transition verdicts from the volatile->calm window
        //      slide are volatile 41-70, ending calm 16) -> NO callback.
        _step(200000, 41, 1);
        _step(200120, 69, 1);
        _step(200060, 69, 1);
        _step(200210, 69, 1);
        _step(200150, 69, 1);
        _step(200090, 69, 1);
        _step(200240, 69, 1);
        _step(200180, 69, 1);
        _step(200260, 68, 1);
        _step(200200, 69, 1);
        _step(200140, 68, 1);
        _step(200290, 68, 1);
        _step(200230, 69, 1);
        _step(200310, 68, 1);
        _step(200250, 70, 1);
        _step(200330, 16, 0);
        assertEq(guardian.protectionCount(), 0, "calm leg must not fire");
        assertEq(system.callbackCount(), 0);
        assertEq(guardian.referencePrice(), 200330);

        // ---- Leg B: crash. First confirmed-danger verdict is risk 83 at
        //      price 140000 (-30.1% from peak) -> exactly ONE callback.
        _step(196000, 28, 0);
        _step(190500, 41, 1);
        _step(184000, 52, 1);
        _step(176500, 59, 1);
        _step(168000, 63, 1);
        _step(159000, 71, 1);
        _step(149500, 77, 1);
        uint256 triggerTx = _step(140000, 83, 2);
        assertEq(guardian.protectionCount(), 1, "crash must fire exactly once");
        assertEq(system.callbackCount(), 1);
        assertTrue(guardian.dangerLatched());
        // Payload: recordCallback(address, riskScore=83, verdictTxHash).
        bytes memory expectedPayload = abi.encodeWithSignature(
            "recordCallback(address,uint256,uint256)",
            address(0),
            uint256(83),
            triggerTx
        );
        assertEq(system.lastCallbackPayload(), expectedPayload);
        assertEq(system.lastCallbackRecipient(), address(recorder));
        // Remaining crash verdicts are latched: no more callbacks.
        _step(131000, 86, 2);
        _step(123500, 87, 2);
        _step(117000, 88, 2);
        _step(111500, 89, 2);
        _step(107000, 88, 2);
        _step(103000, 88, 2);
        _step(99500, 88, 2);
        _step(96000, 88, 2);
        assertEq(guardian.protectionCount(), 1, "latched: still one callback");
        assertEq(system.callbackCount(), 1);

        // Simulated proxy delivery to the recorder.
        vm.prank(address(proxy));
        recorder.recordCallback(address(guardian), 83, triggerTx);
        assertEq(recorder.callbackCount(), 1);
        assertEq(recorder.lastValue(), 83);

        // ---- Leg C: volatile/recovery. Danger verdicts while latched do not
        //      fire; the first non-danger verdict (84/volatile at 100000)
        //      resets the latch; the following crash blip (84/crash at 97000)
        //      must NOT fire again: measured from the re-anchored reference
        //      (100000) the drop is only 3%.
        _step(98500, 87, 2);
        _step(95500, 88, 2);
        _step(99000, 87, 2);
        _step(96000, 88, 2);
        assertTrue(guardian.dangerLatched(), "still latched during danger verdicts");
        _step(100000, 84, 1); // non-danger -> latch reset
        assertFalse(guardian.dangerLatched(), "latch must reset on non-danger verdict");
        _step(97000, 84, 2); // crash blip, only -3% from re-anchored reference
        assertEq(guardian.protectionCount(), 1, "post-reset blip must not fire");
        _step(99500, 77, 1);
        _step(96500, 74, 1);
        _step(100500, 61, 1);
        _step(97500, 61, 1);
        _step(99000, 54, 1);
        _step(96000, 55, 1);
        _step(98500, 50, 1);
        _step(95500, 52, 1);
        _step(99000, 50, 1);
        _step(97500, 52, 1);
        assertEq(guardian.protectionCount(), 1);
        assertEq(system.callbackCount(), 1);
        assertEq(recorder.callbackCount(), 1);
        assertEq(guardian.priceCount(), 48);
        assertEq(guardian.verdictCount(), 48);
    }
}
