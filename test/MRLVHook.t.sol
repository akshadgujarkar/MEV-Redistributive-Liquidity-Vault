// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {MRLVHook} from "../src/MRLVHook.sol";
import {MEVDetector} from "../src/MEVDetector.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {AnalyticsEmitter} from "../src/AnalyticsEmitter.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

contract MockPoolManager {
    bool public unlocked;

    function modifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory,
        bytes calldata
    ) external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlocked = true;
        bytes memory result = MRLVHook(payable(msg.sender)).unlockCallback(data);
        unlocked = false;
        return result;
    }

    function sync(Currency) external {}
    function settle() external payable returns (uint256) { return 0; }
    function take(Currency, address, uint256) external {}
}

contract MRLVHookTest is Test {
    MRLVHook public hook;
    MEVDetector public detector;
    DynamicFeeManager public feeManager;
    AnalyticsEmitter public analytics;
    MockPoolManager public mockPoolManager;

    address public governance = address(0xBEEF);
    address public oracleRelayer = address(0xCEEF);
    address public poolManagerAddr;
    address public unauthorized = address(0xDEAD);

    function setUp() public {
        mockPoolManager = new MockPoolManager();
        poolManagerAddr = address(mockPoolManager);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );

        detector = new MEVDetector(governance, address(this), oracleRelayer);
        feeManager = new DynamicFeeManager(governance, address(this));
        analytics = new AnalyticsEmitter(governance);

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddr),
            detector,
            feeManager,
            analytics,
            governance
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(MRLVHook).creationCode,
            constructorArgs
        );

        hook = new MRLVHook{salt: salt}(
            IPoolManager(poolManagerAddr),
            detector,
            feeManager,
            analytics,
            governance
        );
        require(address(hook) == hookAddr, "Hook address mismatch");

        vm.startPrank(governance);
        detector.setHook(address(hook));
        feeManager.setHook(address(hook));
        analytics.setHook(address(hook));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  onlyPoolManager ACCESS CONTROL
    // ═══════════════════════════════════════════════════════════════════

    function test_beforeInitialize_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(unauthorized, key, 0);
    }

    function test_afterInitialize_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterInitialize(unauthorized, key, 0, 0);
    }

    function test_beforeSwap_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(unauthorized, key, params, "");
    }

    function test_afterSwap_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        BalanceDelta delta;
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterSwap(unauthorized, key, params, delta, "");
    }

    function test_beforeAddLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeAddLiquidity(unauthorized, key, params, "");
    }

    function test_afterAddLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});
        BalanceDelta delta;
        BalanceDelta feesAccrued;
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterAddLiquidity(unauthorized, key, params, delta, feesAccrued, "");
    }

    function test_beforeRemoveLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(unauthorized, key, params, "");
    }

    function test_afterRemoveLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory params = ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0});
        BalanceDelta delta;
        BalanceDelta feesAccrued;
        vm.prank(unauthorized);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterRemoveLiquidity(unauthorized, key, params, delta, feesAccrued, "");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    CIRCUIT BREAKER (PAUSE/UNPAUSE)
    // ═══════════════════════════════════════════════════════════════════

    function test_pause_onlyGovernance() public {
        vm.prank(unauthorized);
        vm.expectRevert(MRLVHook.NotGovernance.selector);
        hook.pause();
    }

    function test_unpause_onlyGovernance() public {
        vm.prank(governance);
        hook.pause();

        vm.prank(unauthorized);
        vm.expectRevert(MRLVHook.NotGovernance.selector);
        hook.unpause();
    }

    function test_pauseAndUnpause() public {
        vm.prank(governance);
        hook.pause();
        assertTrue(hook.paused());

        vm.prank(governance);
        hook.unpause();
        assertFalse(hook.paused());
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    INVALID HOOKDATA
    // ═══════════════════════════════════════════════════════════════════

    function test_beforeSwap_invalidHookData_reverts() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        bytes memory badData = hex"DEADBEEF";

        vm.prank(poolManagerAddr);
        vm.expectRevert(MRLVHook.InvalidHookData.selector);
        hook.beforeSwap(address(this), key, params, badData);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    GOVERNANCE TRANSFER
    // ═══════════════════════════════════════════════════════════════════

    function test_transferGovernance() public {
        address newGov = address(0xCAFE);
        vm.prank(governance);
        hook.transferGovernance(newGov);
        assertEq(hook.governance(), newGov);
    }

    function test_transferGovernance_revertsForNonGovernance() public {
        vm.prank(unauthorized);
        vm.expectRevert(MRLVHook.NotGovernance.selector);
        hook.transferGovernance(unauthorized);
    }

    // ═══════════════════════════════════════════════════════════════════
    //              PAUSED beforeSwap PASSTHROUGH TEST
    // ═══════════════════════════════════════════════════════════════════

    function test_pausedBeforeSwap_returnsBaseFee() public {
        vm.prank(governance);
        hook.pause();

        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(poolManagerAddr);
        (bytes4 selector_, , uint24 feeOverride) = hook.beforeSwap(address(this), key, params, "");

        assertEq(selector_, hook.beforeSwap.selector);
        uint24 expectedFee = LPFeeLibrary.OVERRIDE_FEE_FLAG | feeManager.BASE_FEE();
        assertEq(feeOverride, expectedFee, "Paused hook should return base fee");
    }

    function test_beforeSwapGasBenchmark() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(poolManagerAddr);
        uint256 gasStart = gasleft();
        hook.beforeSwap(address(this), key, params, "");
        uint256 gasUsed = gasStart - gasleft();
        emit log_named_uint("Baseline Gas used by beforeSwap", gasUsed);
    }

    // ═══════════════════════════════════════════════════════════════════
    //              LIQUIDITY MATURATION & ESCROW ENFORCEMENT
    // ═══════════════════════════════════════════════════════════════════

    function test_beforeAddLiquidity_revertsForDirectAddWithoutEscrow() public {
        PoolKey memory key = _makePoolKey();
        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});

        vm.prank(poolManagerAddr);
        vm.expectRevert(MRLVHook.PositionNotMature.selector);
        hook.beforeAddLiquidity(address(0xAA), key, lpParams, "");
    }

    function test_beforeSwap_succeedsWithImmatureLiquidity() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(poolManagerAddr);
        (bytes4 selector_,,) = hook.beforeSwap(address(0xBB), key, params, "");
        assertEq(selector_, hook.beforeSwap.selector, "beforeSwap should succeed");
    }

    function test_beforeSwap_noLiquidity_succeeds() public {
        PoolKey memory key = _makePoolKey();
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        vm.prank(poolManagerAddr);
        (bytes4 selector_,,) = hook.beforeSwap(address(0xCC), key, params, "");
        assertEq(selector_, hook.beforeSwap.selector, "beforeSwap with no LP should succeed");
    }

    // ═══════════════════════════════════════════════════════════════════
    //             PENDING LIQUIDITY ESCROW & MATURITY TESTS
    // ═══════════════════════════════════════════════════════════════════

    function test_depositPendingLiquidity_EscrowsTokensAndRecordsPending() public {
        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();
        address alice = address(0xAA);

        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});

        vm.startPrank(alice);
        token0.approve(address(hook), 500 ether);
        token1.approve(address(hook), 500 ether);

        bytes32 posKey = hook.depositPendingLiquidity(key, lpParams, 100 ether, 200 ether);
        vm.stopPrank();

        assertEq(token0.balanceOf(address(hook)), 100 ether, "Hook should escrow token0");
        assertEq(token1.balanceOf(address(hook)), 200 ether, "Hook should escrow token1");

        (bool isPending, bool isMature, uint256 remaining, uint128 liq, address owner) =
            hook.getPendingPositionStatus(posKey);

        assertTrue(isPending, "Position should be pending");
        assertFalse(isMature, "Position should be immature initially");
        assertEq(remaining, 5, "Remaining blocks should be 5");
        assertEq(liq, 1000, "Liquidity should match deposit");
        assertEq(owner, alice, "Owner should be Alice");
    }

    function test_activateLiquidity_RevertsBeforeMaturity() public {
        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();
        address alice = address(0xAA);

        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});

        vm.startPrank(alice);
        token0.approve(address(hook), 500 ether);
        token1.approve(address(hook), 500 ether);

        bytes32 posKey = hook.depositPendingLiquidity(key, lpParams, 100 ether, 200 ether);
        vm.stopPrank();

        // Advance 2 blocks (< maturity 5)
        vm.roll(block.number + 2);

        vm.expectRevert(MRLVHook.PositionNotMature.selector);
        hook.activateLiquidity(posKey);
    }

    function test_activateLiquidity_SucceedsAfterMaturity() public {
        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();
        address alice = address(0xAA);

        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});

        vm.startPrank(alice);
        token0.approve(address(hook), 500 ether);
        token1.approve(address(hook), 500 ether);

        bytes32 posKey = hook.depositPendingLiquidity(key, lpParams, 100 ether, 200 ether);
        vm.stopPrank();

        // Advance 5 blocks (>= maturity 5)
        vm.roll(block.number + 5);

        bool activated = hook.activateLiquidity(posKey);
        assertTrue(activated, "Activation should succeed");

        (bool isPending, bool isMature, uint256 remaining,,) = hook.getPendingPositionStatus(posKey);
        assertFalse(isPending, "Position is no longer pending after activation");
        assertTrue(isMature, "Position is mature");
        assertEq(remaining, 0, "Remaining blocks should be 0");
    }

    function test_lazyActivation_OnSwap() public {
        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();
        address alice = address(0xAA);

        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});

        vm.startPrank(alice);
        token0.approve(address(hook), 500 ether);
        token1.approve(address(hook), 500 ether);

        bytes32 posKey = hook.depositPendingLiquidity(key, lpParams, 100 ether, 200 ether);
        vm.stopPrank();

        // Advance 6 blocks (mature)
        vm.roll(block.number + 6);

        // Perform swap
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
        vm.prank(poolManagerAddr);
        hook.beforeSwap(address(0xBB), key, params, "");

        // Verify lazy activation executed automatically during beforeSwap
        (bool isPending, bool isMature,,,)= hook.getPendingPositionStatus(posKey);
        assertFalse(isPending, "Lazy activation should activate mature position on swap");
        assertTrue(isMature, "Position should be mature");
    }

    function test_withdrawPendingLiquidity_ReturnsEscrowedTokens() public {
        MockERC20 token0 = new MockERC20();
        MockERC20 token1 = new MockERC20();
        address alice = address(0xAA);

        token0.mint(alice, 1000 ether);
        token1.mint(alice, 1000 ether);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0});

        vm.startPrank(alice);
        token0.approve(address(hook), 500 ether);
        token1.approve(address(hook), 500 ether);

        bytes32 posKey = hook.depositPendingLiquidity(key, lpParams, 100 ether, 200 ether);

        // Withdraw before maturity
        bool withdrawn = hook.withdrawPendingLiquidity(posKey, key);
        vm.stopPrank();

        assertTrue(withdrawn, "Withdrawal should succeed");
        assertEq(token0.balanceOf(alice), 1000 ether, "Alice should receive 100% token0 back");
        assertEq(token1.balanceOf(alice), 1000 ether, "Alice should receive 100% token1 back");
        assertEq(token0.balanceOf(address(hook)), 0, "Hook should have 0 token0 left");
    }

    // ═══════════════════════════════════════════════════════════════════
    //                    HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _makePoolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x100)),
            currency1: Currency.wrap(address(0x200)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }
}

contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
