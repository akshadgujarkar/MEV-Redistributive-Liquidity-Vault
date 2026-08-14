// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";

contract DynamicFeeManagerTest is Test {
    DynamicFeeManager public feeManager;
    address public governance = address(0x1);
    address public hook = address(0x2);
    address public unauthorized = address(0x3);

    bytes32 public constant TEST_POOL_ID = keccak256("TEST_POOL");

    function setUp() public {
        feeManager = new DynamicFeeManager(governance, hook);
    }

    function test_Tier1NormalFee() public view {
        // Score < 30 -> 3000 (0.30%)
        assertEq(feeManager.calculateRawFee(0), 3000);
        assertEq(feeManager.calculateRawFee(15), 3000);
        assertEq(feeManager.calculateRawFee(29), 3000);
    }

    function test_Tier2SuspiciousFee() public view {
        // 30 <= Score < 70 -> 6000 (0.60%)
        assertEq(feeManager.calculateRawFee(30), 6000);
        assertEq(feeManager.calculateRawFee(50), 6000);
        assertEq(feeManager.calculateRawFee(69), 6000);
    }

    function test_Tier3HighRiskFee() public view {
        // Score >= 70 -> Linear 10000 (1%) to 30000 (3%)
        assertEq(feeManager.calculateRawFee(70), 10000);
        assertEq(feeManager.calculateRawFee(85), 20000);
        assertEq(feeManager.calculateRawFee(100), 30000);
    }

    function test_ExactBoundaryScores() public view {
        // Test exact boundaries: 29, 30, 69, 70, 100
        assertEq(feeManager.calculateRawFee(29), 3000, "Boundary 29 failed");
        assertEq(feeManager.calculateRawFee(30), 6000, "Boundary 30 failed");
        assertEq(feeManager.calculateRawFee(69), 6000, "Boundary 69 failed");
        assertEq(feeManager.calculateRawFee(70), 10000, "Boundary 70 failed");
        assertEq(feeManager.calculateRawFee(100), 30000, "Boundary 100 failed");
    }

    function test_HardCapExceededInput() public view {
        // Scores > 100 must still return hard cap 30000 (3%)
        assertEq(feeManager.calculateRawFee(101), 30000);
        assertEq(feeManager.calculateRawFee(500), 30000);
        assertEq(feeManager.calculateRawFee(type(uint256).max), 30000);
    }

    function test_RateLimitingSpike() public {
        vm.startPrank(hook);

        // First swap: prev fee is 0 (baseline 3000), max allowed is 3000 * 3 = 9000
        // Proposed score 100 -> raw fee 30000, clamped to 9000
        uint24 fee1 = feeManager.computeFee(TEST_POOL_ID, 100);
        assertEq(fee1, 9000, "First swap fee spike should be rate-limited to 3x baseline");

        // Second swap: prev fee is 9000, max allowed is 9000 * 3 = 27000
        // Proposed score 100 -> raw fee 30000, clamped to 27000
        uint24 fee2 = feeManager.computeFee(TEST_POOL_ID, 100);
        assertEq(fee2, 27000, "Second swap fee spike should be rate-limited to 3x previous fee");

        // Third swap: prev fee is 27000, max allowed is 27000 * 3 = 81000, but hard cap is 30000
        uint24 fee3 = feeManager.computeFee(TEST_POOL_ID, 100);
        assertEq(fee3, 30000, "Third swap fee should reach hard cap 30000");

        vm.stopPrank();
    }

    function test_ComputeFeeOnlyHook() public {
        vm.prank(unauthorized);
        vm.expectRevert(DynamicFeeManager.NotHook.selector);
        feeManager.computeFee(TEST_POOL_ID, 50);
    }

    function testFuzz_CalculateRawFee(uint256 riskScore) public view {
        uint24 fee = feeManager.calculateRawFee(riskScore);
        assertTrue(fee <= feeManager.HARD_CAP(), "Fee exceeded HARD_CAP");
        if (riskScore < 30) {
            assertEq(fee, 3000);
        } else if (riskScore < 70) {
            assertEq(fee, 6000);
        } else {
            assertTrue(fee >= 10000 && fee <= 30000);
        }
    }

    function testFuzz_ApplyRateLimit(uint24 rawFee, uint24 prevFee) public view {
        uint24 fee = feeManager.applyRateLimit(rawFee, prevFee);
        assertTrue(fee <= feeManager.HARD_CAP(), "Rate-limited fee exceeded HARD_CAP");

        uint24 baseline = prevFee == 0 ? feeManager.BASE_FEE() : prevFee;
        uint256 maxAllowed = uint256(baseline) * uint256(feeManager.maxFeeMultiplier());
        if (maxAllowed > feeManager.HARD_CAP()) {
            maxAllowed = feeManager.HARD_CAP();
        }

        assertTrue(fee <= uint24(maxAllowed), "Fee exceeded rate limit maxAllowed");
    }
}
