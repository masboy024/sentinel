// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { OriginEmitter } from "../src/OriginEmitter.sol";
import { SentinelReactive } from "../src/SentinelReactive.sol";
import { CallbackRecorder } from "../src/CallbackRecorder.sol";
import { MockSystem, MockCallbackProxy } from "./mocks/MockSystem.sol";

/// @notice Local end-to-end logic test of the Phase 1 skeleton loop:
///         origin event -> react() on the "reactive" contract -> callback
///         request recorded by the mock system contract -> simulated proxy
///         delivery -> destination contract records the callback.
///         On real testnet the system contract and the network play the roles
///         of MockSystem / the delivery prank here.
contract SkeletonLoopTest is Test {
    address internal constant SYSTEM_ADDR =
        0x8888888888888888888888888888888888888888;
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant PING_TOPIC_0 =
        0x112d2e583fa63f0db88f80b06e471fea138fb541483952119ece7a75e1bb426c;

    MockSystem internal system;
    MockCallbackProxy internal proxy;
    OriginEmitter internal origin;
    SentinelReactive internal reactive;
    CallbackRecorder internal recorder;

    function setUp() public {
        MockSystem mock = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        system = MockSystem(SYSTEM_ADDR);

        proxy = new MockCallbackProxy();
        origin = new OriginEmitter();
        reactive = new SentinelReactive{ value: 1 ether }(
            SEPOLIA,
            address(origin),
            SEPOLIA
        );
        recorder = new CallbackRecorder{ value: 1 ether }(
            IPayable(payable(address(proxy))),
            address(reactive)
        );
        reactive.setRecipient(address(recorder));
    }

    function _pingLog(
        uint256 value_,
        uint256 txHash_
    ) internal view returns (IReactive.LogRecord memory log) {
        log.chainId = SEPOLIA;
        log.contractAddress = address(origin);
        log.topic0 = PING_TOPIC_0;
        log.topic1 = uint256(uint160(address(this)));
        log.data = abi.encode(value_, uint256(1700000000));
        log.blockNumber = 12345;
        log.opCode = 2; // LOG2: topic0 + one indexed parameter
        log.txHash = txHash_;
        log.logIndex = 0;
    }

    function test_subscription_registered() public view {
        assertEq(system.subscribeCount(), 1);
        assertEq(system.lastSubChainId(), SEPOLIA);
        assertEq(system.lastSubContract(), address(origin));
        assertEq(system.lastSubTopic0(), PING_TOPIC_0);
    }

    function test_full_loop() public {
        // 1. Origin emits (simulated by feeding the matching log record).
        origin.ping(42);
        assertEq(origin.pingCount(), 1);

        // 2. System contract delivers the log to react().
        vm.prank(SYSTEM_ADDR);
        reactive.react(_pingLog(42, 0xdeadbeef));

        assertEq(reactive.reactionCount(), 1);
        assertEq(reactive.lastValue(), 42);
        assertEq(reactive.lastOriginTxHash(), 0xdeadbeef);

        // 3. A callback was requested with the right routing + payload.
        assertEq(system.callbackCount(), 1);
        assertEq(system.lastCallbackChainId(), SEPOLIA);
        assertEq(system.lastCallbackRecipient(), address(recorder));
        bytes memory expectedPayload = abi.encodeWithSignature(
            "recordCallback(address,uint256,uint256)",
            address(0),
            uint256(42),
            uint256(0xdeadbeef)
        );
        assertEq(system.lastCallbackPayload(), expectedPayload);

        // 4. Proxy delivers on the destination chain; the network injects the
        //    reactive contract's address as the first argument.
        vm.prank(address(proxy));
        recorder.recordCallback(address(reactive), 42, 0xdeadbeef);

        assertEq(recorder.callbackCount(), 1);
        assertEq(recorder.lastValue(), 42);
        assertEq(recorder.lastOriginTxHash(), 0xdeadbeef);
    }

    function test_react_rejects_strangers() public {
        vm.expectRevert();
        reactive.react(_pingLog(1, 0x1));
    }

    function test_callback_rejects_wrong_caller() public {
        vm.expectRevert();
        recorder.recordCallback(address(reactive), 1, 0x1);
    }

    function test_callback_rejects_wrong_reactive_sender() public {
        vm.prank(address(proxy));
        vm.expectRevert();
        recorder.recordCallback(address(0xB0B), 1, 0x1);
    }
}
