// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { SentinelVault } from "../src/SentinelVault.sol";
import { MockCallbackProxy } from "./mocks/MockSystem.sol";

/// @notice Local logic test of the Phase 4 vault. Simulates callback delivery
///         exactly the way the destination chain's callback proxy performs it:
///         the proxy is msg.sender, and the first payload argument is the
///         requesting reactive contract's (guardian's) address.
contract VaultTest is Test {
    address internal constant GUARDIAN =
        0x39C0de948f401Fc8359ACC2F2ceF472F57426D6e; // predicted Phase 4 guardian
    address internal constant ATTACKER =
        0x000000000000000000000000000000000000bad1;
    uint256 internal constant INITIAL_POSITION = 1000000;
    uint256 internal constant VERDICT_TX =
        0xd54cfcd35a0a46e2061400d2fc32cbad692a97d372d4734aad3f4b8c021d8259;

    MockCallbackProxy internal proxy;
    SentinelVault internal vault;

    function setUp() public {
        proxy = new MockCallbackProxy();
        vault = new SentinelVault{ value: 1 ether }(
            IPayable(payable(address(proxy))),
            GUARDIAN,
            INITIAL_POSITION
        );
    }

    function test_initial_state() public view {
        assertEq(vault.positionAtRisk(), INITIAL_POSITION);
        assertEq(vault.safeBalance(), 0);
        assertEq(vault.protectionCount(), 0);
        assertEq(vault._CALLBACK_SENDER(), GUARDIAN);
    }

    function test_valid_callback_executes_protection() public {
        vm.prank(address(proxy));
        vault.recordCallback(GUARDIAN, 83, VERDICT_TX);
        assertEq(vault.positionAtRisk(), 0, "position must be fully protected");
        assertEq(vault.safeBalance(), INITIAL_POSITION);
        assertEq(vault.totalProtected(), INITIAL_POSITION);
        assertEq(vault.protectionCount(), 1);
        assertEq(vault.lastRiskScore(), 83);
        assertEq(vault.lastOriginTxHash(), VERDICT_TX);
        assertEq(vault.lastProtectedAmount(), INITIAL_POSITION);
        assertGt(vault.lastProtectionTimestamp(), 0);
    }

    function test_wrong_injected_sender_reverts() public {
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector,
                ATTACKER,
                GUARDIAN
            )
        );
        vault.recordCallback(ATTACKER, 83, VERDICT_TX);
        assertEq(vault.protectionCount(), 0);
        assertEq(vault.positionAtRisk(), INITIAL_POSITION);
    }

    function test_non_proxy_caller_reverts() public {
        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractPayer.NotAuthorized.selector,
                ATTACKER,
                address(proxy)
            )
        );
        vault.recordCallback(GUARDIAN, 83, VERDICT_TX);
        assertEq(vault.protectionCount(), 0);
    }

    function test_low_risk_callback_reverts() public {
        vm.prank(address(proxy));
        vm.expectRevert("risk below protection threshold");
        vault.recordCallback(GUARDIAN, 52, VERDICT_TX);
        assertEq(vault.protectionCount(), 0);
        assertEq(vault.positionAtRisk(), INITIAL_POSITION);
    }

    function test_second_callback_moves_zero() public {
        vm.prank(address(proxy));
        vault.recordCallback(GUARDIAN, 83, VERDICT_TX);
        vm.prank(address(proxy));
        vault.recordCallback(GUARDIAN, 88, VERDICT_TX);
        assertEq(vault.protectionCount(), 2);
        assertEq(vault.lastProtectedAmount(), 0);
        assertEq(vault.safeBalance(), INITIAL_POSITION);
        assertEq(vault.lastRiskScore(), 88);
    }

    function test_deposit_position_owner_only() public {
        vault.depositPosition(500000);
        assertEq(vault.positionAtRisk(), INITIAL_POSITION + 500000);
        vm.prank(ATTACKER);
        vm.expectRevert("not owner");
        vault.depositPosition(1);
    }
}
