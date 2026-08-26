# MRVL Protocol — Frontend Feature Specification

## 1. PRIMARY GOAL
This document serves as the complete product, UX, and data specification for a future dummy frontend for the **MRVL (MEV-Redistributive Liquidity Vault)** protocol. The purpose is to trace every meaningful smart contract mechanism in the MRVL repository to a frontend representation, and define the necessary dummy data structures to visually demonstrate these capabilities to users and investors without requiring live blockchain connectivity.

---

## 4. CONTRACT INVENTORY

### MRLVHook.sol
*   **Purpose**: The central Uniswap v4 Hook dispatcher. Manages liquidity escrow, intercepts swaps to calculate MEV risk and dynamic fees, and routes surcharges.
*   **State Variables**:
    *   `paused` (bool): Circuit breaker. Frontend: Protocol Status (Active/Paused).
    *   `pendingPositions` (mapping): Tracks user liquidity in escrow waiting for maturity. Frontend: "Pending Liquidity" list.
    *   `_swapContext` (mapping): Transient swap data.
*   **Functions**:
    *   `depositPendingLiquidity`: Escrows LP tokens.
    *   `activateLiquidity`: Moves mature escrowed liquidity to the active pool.
    *   `withdrawPendingLiquidity`: Cancels pending liquidity.
*   **Events**: `LiquidityPending`, `LiquidityActivated`, `LiquidityWithdrawnPending`.
*   **Errors**: `PositionNotMature`, `PositionAlreadyActivated`, `ZeroLiquidity`.

### MEVDetector.sol
*   **Purpose**: Calculates a risk score (0-100) for swaps based on heuristics.
*   **State Variables**:
    *   `liquidityMaturityBlocks` (uint32): Blocks required for liquidity maturity (default 5). Frontend: Displayed in Liquidity Escrow section.
    *   `rollingPriorityFeeAvg`, `priceImpactThreshold`: Heuristic baselines.
*   **Functions**:
    *   `scoreSwap`: Aggregates MEV signals (+25 priority fee, +30 reversal, +20 price impact).
*   **Events**: `RollingPriorityFeeAvgUpdated`, `LiquidityMaturityBlocksUpdated`.

### DynamicFeeManager.sol
*   **Purpose**: Computes the dynamic fee applied to swaps based on the MEV risk score.
*   **State Variables**:
    *   `BASE_FEE` (0.3%), `HARD_CAP` (3%). Frontend: Displayed in fee analytics.
    *   `maxFeeMultiplier` (uint24): Rate limit for fee jumps.
*   **Functions**:
    *   `computeFee`: Returns the overridden fee.

### RewardVault.sol
*   **Purpose**: Escrows MEV surcharges and distributes them to loyal LPs.
*   **State Variables**:
    *   `claimable` (mapping): Accrued rewards per user. Frontend: "Claimable MRLV" balance.
    *   `poolDistributable` (mapping): Captured surcharges pending distribution.
    *   `penaltyReserves`: Surcharges from early exit penalties.
*   **Functions**:
    *   `distribute`: Epoch-based pro-rata distribution to LPs.
    *   `claim`: User claims their MRLV.
    *   `applyExitPenalty`: Slashes 50% of accrued rewards for early exit.
*   **Events**: `Deposited`, `Distributed`, `Claimed`, `ExitPenaltyApplied`.

### LoyaltyManager.sol
*   **Purpose**: Tracks LP tenure, tiers, and calculates the `LPScore` for reward distribution.
*   **State Variables**:
    *   `earlyWithdrawWindow` (7 days). Frontend: "Time left until penalty-free withdrawal".
    *   `silverThresholdBlocks` (30 days), `goldThresholdBlocks` (90 days).
*   **Functions**:
    *   `refreshTiers`: Upgrades tiers if thresholds met.
    *   `computeLPScores`: Heavy calculation normalizing LP contribution, duration, and consistency.
*   **Events**: `TierUpgraded`, `ExitPenaltyApplied`.

### LoyaltyNFT.sol
*   **Purpose**: Soulbound NFT representing the user's loyalty tier (Bronze, Silver, Gold).
*   **Functions**:
    *   `tokenURI`: Returns badge metadata. Frontend: Displays the actual badge image/icon based on tier.

### MRLVToken.sol
*   **Purpose**: ERC-20 reward and governance token.
*   **Functions**:
    *   `lock`, `withdraw`: Users lock tokens to gain voting power (veMRLV style). Frontend: Governance/Locking portal.

### AnalyticsEmitter.sol
*   **Purpose**: Centralized event emission for indexers.
*   **Events**: `SwapProcessed`, `MEVDetected`. Frontend: Populates the "Recent MEV Activity" feed.

---

## 5. UNISWAP V4 HOOK ANALYSIS

| Hook Callback | Actual Contract Behavior | Protocol Feature | User Impact | Frontend Representation | Dummy Data |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `beforeInitialize` | Allowed, no custom logic | Pool Creation | Standard | N/A | N/A |
| `afterInitialize` | Allowed, no custom logic | Pool Creation | Standard | N/A | N/A |
| `beforeSwap` | 1. Auto-activates mature liquidity.<br>2. Calculates MEV risk score.<br>3. Computes dynamic fee. | Just-In-Time (JIT) Liquidity Protection, Dynamic Swap Fees | Swaps may face higher fees if deemed malicious | "MEV Risk Analysis" breakdown on swap screen, Dynamic Fee indicator | `SwapContext` with `riskScore` and `appliedFee` |
| `afterSwap` | 1. Emits analytics.<br>2. Calculates surcharge (if risk >= 30).<br>3. Deposits surcharge to RewardVault. | MEV Redistribution | Benign traders pay normal fee; Malicious pay surcharge which goes to LPs | Live "MEV Captured" feed, Vault TVL increases | `feeSurcharge`, `poolCapturedTotal` updates |
| `beforeAddLiquidity` | Rejects direct liquidity additions unless `_isActivating` flag is set. | Liquidity Escrow / JIT Protection | LPs cannot instantly provide liquidity to capture immediate fees | Liquidity must be deposited into "Pending Escrow" first, shown in UI | `pendingPositions` objects with countdown blocks |
| `afterAddLiquidity` | Allowed, returns delta | Position State | Standard | N/A | N/A |
| `beforeRemoveLiquidity` | Calls `LoyaltyManager.onRemoveLiquidity` to process potential early exit penalties. | Sustainable Liquidity / Loyalty | LPs withdrawing < 7 days face a 50% reward penalty | Warning modal on liquidity removal | `earlyWithdrawWindow`, `ExitPenaltyApplied` events |
| `afterRemoveLiquidity` | Allowed, returns delta | Position State | Standard | N/A | N/A |

---

## 6. IDENTIFY THE ACTUAL MRVL FEATURES

### Liquidity
*   **Pending Liquidity Escrow**: LPs deposit funds into a waiting period (default 5 blocks) before they enter the active pool to prevent JIT liquidity attacks.
*   **Manual/Auto Activation**: Liquidity is activated either manually by the user or lazily during swaps.
*   **Early Exit Penalties**: Removing liquidity before the 7-day window results in a 50% slash to accrued claimable rewards.

### Swap & MEV Protection
*   **MEV Risk Scoring**: Swaps are scored (0-100) based on priority fees, block reversals, and large price impacts.
*   **Dynamic Swap Fees**: Fees scale from 0.3% up to 3% based on the risk score. Rate limits apply to fee jumps.
*   **Surcharge Capture**: Any fee collected above the base 0.3% is diverted to the RewardVault.

### Sustainable Liquidity
*   **Loyalty Tiers (Bronze, Silver, Gold)**: Based on tenure (0 days, 30 days, 90 days).
*   **Soulbound Loyalty NFTs**: Visual representation of the LP's tier.
*   **Weighted Reward Distribution**: Captured MEV is distributed pro-rata based on an `LPScore` (accounting for amount, duration, consistency, and tier multiplier).

### Governance
*   **MRLV Token Locking**: Users lock MRLV to gain voting power.

---

## 7. FEATURE STATUS

| Feature | Status |
| :--- | :--- |
| Pending Liquidity Escrow | **IMPLEMENTED** |
| MEV Risk Scoring | **IMPLEMENTED** |
| Dynamic Fees | **IMPLEMENTED** |
| Surcharge Capture to Vault | **IMPLEMENTED** |
| Loyalty Tiers (Bronze, Silver, Gold) | **IMPLEMENTED** |
| Soulbound Loyalty NFTs | **IMPLEMENTED** |
| Pro-Rata Reward Distribution | **IMPLEMENTED** |
| Early Exit Reward Slashing | **IMPLEMENTED** |
| MRLV Token Locking (Voting) | **IMPLEMENTED** |

---

## 8. CONTRACT FEATURE → FRONTEND FEATURE MAPPING

| # | Contract | Function / Variable | Actual Behavior | Frontend Feature | Frontend Section | Dummy Data Required | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | `MRLVHook` | `pendingPositions` | Holds LP funds until maturity blocks pass | **Pending Positions List** | Liquidity Dashboard | `mockPendingPositions` | IMPLEMENTED |
| 2 | `MRLVHook` | `activateLiquidity` | Moves mature funds to active pool | **Activate Button** | Liquidity Dashboard | UI State (Loading/Success) | IMPLEMENTED |
| 3 | `MEVDetector` | `scoreSwap()` | Scores swap 0-100 | **Risk Score Indicator** | Swap Interface | `mockSwapQuote` | IMPLEMENTED |
| 4 | `DynamicFeeManager` | `computeFee()` | Adjusts fee 0.3% - 3.0% | **Dynamic Fee Breakdown** | Swap Interface | `mockDynamicFee` | IMPLEMENTED |
| 5 | `LoyaltyManager` | `earlyWithdrawWindow` | Enforces 7-day minimum holding | **Early Exit Warning Modal** | Remove Liquidity | `mockWithdrawalPenalty` | IMPLEMENTED |
| 6 | `LoyaltyManager` | `refreshTiers()` | Upgrades Bronze->Silver->Gold | **Tier Badge & Progress Bar** | LP Dashboard | `mockLoyaltyTiers` | IMPLEMENTED |
| 7 | `RewardVault` | `claimable` | Stores user's share of MEV fees | **Claim Rewards Panel** | Rewards Dashboard | `mockClaimableRewards` | IMPLEMENTED |
| 8 | `MRLVToken` | `lock()` | Locks token for voting power | **Locking Portal** | Governance | `mockLockedTokens` | IMPLEMENTED |

---

## 11. DUMMY DATA SPECIFICATION FOR EVERY FEATURE

### Feature: Pending Liquidity Escrow
*   **Contract Source**: `MRLVHook.depositPendingLiquidity`, `pendingPositions`
*   **What The User Should See**: A list of their deposits that are "Warming up" and cannot yet earn fees. A countdown of blocks remaining.
*   **What The Investor Should Understand**: MRVL prevents MEV bots from doing Just-In-Time (JIT) liquidity provisioning by enforcing a mandatory delay.
*   **Dummy Data Object**:
    ```json
    {
      "posKey": "0x123...abc",
      "pool": "USDC/ETH",
      "amount0": "5000",
      "amount1": "1.5",
      "status": "MATURING",
      "blocksRemaining": 3,
      "estimatedTime": "36 seconds"
    }
    ```
*   **Data Classification**: ON-CHAIN

### Feature: MEV Risk & Dynamic Fee
*   **Contract Source**: `MEVDetector.scoreSwap`, `DynamicFeeManager.calculateRawFee`
*   **What The User Should See**: When swapping, if their trade looks like MEV (e.g., high priority fee, high price impact), the fee visibly increases.
*   **What The Investor Should Understand**: The protocol taxes malicious MEV actors heavily while keeping base fees low for retail users.
*   **Dummy Data Object**:
    ```json
    {
      "riskScore": 45,
      "signals": ["High Priority Fee (+25)", "Large Price Impact (+20)"],
      "baseFee": "0.3%",
      "appliedFee": "0.9%",
      "surchargeToVault": "0.6%"
    }
    ```
*   **Data Classification**: MOCK / ILLUSTRATIVE

### Feature: Loyalty Tiers & Rewards
*   **Contract Source**: `LoyaltyManager.userPositions`, `LoyaltyNFT.tokenTier`, `RewardVault.claimable`
*   **What The User Should See**: A shiny badge (Bronze, Silver, Gold), a progress bar to the next tier, and their accrued MRLV rewards.
*   **What The Investor Should Understand**: Long-term liquidity is incentivized, and "sticky" liquidity earns a higher multiplier of the captured MEV.
*   **Dummy Data Object**:
    ```json
    {
      "currentTier": "Silver",
      "multiplier": "2x",
      "daysActive": 45,
      "daysToGold": 45,
      "accruedRewards": "1,240 MRLV",
      "penaltyActive": false
    }
    ```
*   **Data Classification**: DERIVED / INDEXER-DERIVED

---

## 12. COMPLETE DUMMY DATA MODEL

### `mockPools`
*   **Purpose**: Represents active MRVL-enabled Uniswap v4 pools.
*   **Fields**: `poolId` (string), `token0` (string), `token1` (string), `tvl` (number), `baseFee` (string), `mevCaptured24h` (number).
*   **Used In**: Dashboard, Swap, Pool lists.

### `mockPendingPositions`
*   **Purpose**: Represents user's escrowed liquidity.
*   **Fields**: `id` (string), `amountUSD` (number), `blocksRemaining` (number), `status` (Enum: PENDING, MATURE, ACTIVATED).
*   **Used In**: Liquidity Dashboard.

### `mockRecentMEVEvents`
*   **Purpose**: Feed of recently taxed malicious transactions.
*   **Fields**: `txHash` (string), `trader` (string), `riskScore` (number), `feeTaxed` (number), `timestamp` (string).
*   **Used In**: Analytics Dashboard.

### `mockUserProfile`
*   **Purpose**: Represents the connected user's state across the protocol.
*   **Fields**: `loyaltyTier` (Enum), `votingPower` (number), `lockedMRLV` (number), `totalClaimable` (number).
*   **Used In**: Top navigation, Rewards page, Governance page.

---

## 13. DUMMY DATA MUST COVER ALL STATES

**Swap Interface States:**
*   **Normal State**: Low risk score (<30), 0.3% fee applied.
*   **Warning State (MEV Detected)**: High risk score (>70). UI turns red/orange, warning the user of a high dynamic fee (e.g., 2.5%) due to suspicious patterns.

**Liquidity Management States:**
*   **Pending State**: Deposit made, timer counting down (e.g., "Matures in 4 blocks").
*   **Mature State**: Timer at 0, "Activate" button becomes clickable.
*   **Early Exit State**: Attempting to withdraw before 7 days triggers a strict modal: "WARNING: You will forfeit 50% of your accrued rewards (620 MRLV)."

---

## 14. DASHBOARD SPECIFICATION

| Metric | Contract Source | Calculation | Dummy Value | Data Classification | Investor Meaning |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Total MEV Captured** | `RewardVault.totalCaptured` | Sum of all fee surcharges | `$1,248,500` | INDEXER REQUIRED | The protocol successfully taxes bots and generates revenue. |
| **Average Dynamic Fee** | `DynamicFeeManager` | Average applied fee over 24h | `0.45%` | INDEXER REQUIRED | Fees dynamically adapt. |
| **Gold Tier LPs** | `LoyaltyManager` | Count of NFTs with tier = 2 | `342` | INDEXER REQUIRED | High retention and sustainable liquidity. |
| **Penalty Reserves** | `RewardVault.penaltyReserves` | Tokens forfeited by early exits | `45,200 MRLV` | ON-CHAIN | Mercenary capital is penalized, benefiting loyal LPs. |

---

## 15. SWAP FEATURE SPECIFICATION

### Input Data
*   Token In, Token Out, Amount.

### Output Data
*   `Expected Output`: calculated normally.
*   `MRVL Risk Assessment`: Visual component showing the current transaction's evaluation by `MEVDetector`.
*   `Applied Fee`: The actual fee (Base Fee + Surcharge).

### Dummy Swap Object
```json
{
  "pool": "USDC/ETH",
  "amountIn": 10000,
  "expectedOut": 3.2,
  "priceImpact": 1.5,
  "mrvlRiskScore": 85,
  "feeBreakdown": {
    "baseFee": 30,
    "surcharge": 220,
    "totalApplied": 250
  },
  "status": "QUOTE_READY"
}
```

---

## 16. LIQUIDITY FEATURE SPECIFICATION

### Add Liquidity
*   **Inputs**: Token amounts, Tick ranges.
*   **Expected Result**: Liquidity enters `pendingPositions` in `MRLVHook.sol`.
*   **UI Representation**: A success screen explaining that the liquidity is in escrow for ~1 minute (5 blocks) to prevent JIT attacks.

### Remove Liquidity
*   **Inputs**: Position ID, amount to remove.
*   **Restrictions**: Checks `LoyaltyManager.earlyWithdrawWindow` (block.number - startBlock).
*   **UI Representation**: If removing before 7 days, a red confirmation modal appears warning of the 50% reward penalty via `RewardVault.applyExitPenalty`.

---

## 17. MEV PROTECTION REPRESENTATION

*   **Threat**: JIT (Just-In-Time) Liquidity Attacks.
*   **MRVL Contract Mechanism**: `MRLVHook._beforeAddLiquidity` blocks direct additions. `liquidityMaturityBlocks` enforces a delay.
*   **Frontend Representation**: Visual timeline showing "Deposit -> Escrow (5 blocks) -> Active Pool".
*   **Investor Explanation**: Bots cannot mint liquidity immediately before a large swap and burn it immediately after to steal fees, because all liquidity must "warm up".

*   **Threat**: Toxic Order Flow / Arbitrage.
*   **MRVL Contract Mechanism**: `MEVDetector` scores high priority fees and reversals. `DynamicFeeManager` spikes the fee to 3.0%.
*   **Frontend Representation**: Live feed showing "Bot Tx Intercepted: Fee raised to 3.0%. Surcharge routed to Vault."
*   **Investor Explanation**: MRVL turns toxic MEV into yield for passive LPs.

---

## 18. SUSTAINABLE LIQUIDITY REPRESENTATION

*   **Metric**: Loyalty Tier Distribution.
*   **Contract Source**: `LoyaltyManager` / `LoyaltyNFT`.
*   **Visual Representation**: A donut chart showing the percentage of LPs in Bronze, Silver, and Gold tiers.
*   **Investor Interpretation**: A high percentage of Gold LPs proves that the protocol's incentives are successfully creating "sticky", long-term, sustainable liquidity.

---

## 19. PROTOCOL ANALYTICS

### Chart: MEV Value Redistributed Over Time
*   **Purpose**: Prove the core thesis.
*   **Data Fields**: Date, Surcharge Amount (USD).
*   **Contract Source**: `AnalyticsEmitter.FeeCaptured` events, indexed over time.
*   **Time Range**: 30 Days.
*   **Investor Meaning**: The vault is consistently generating auxiliary yield for LPs above standard trading fees.

---

## 20. ACTIVITY / EVENT REPRESENTATION

| Event | What happened | Frontend Display |
| :--- | :--- | :--- |
| `LiquidityPending` | LP deposited funds | "Alice queued $10k liquidity (Maturing)" |
| `LiquidityActivated` | LP funds entered pool | "Alice's $10k liquidity activated" |
| `MEVDetected` | Bot swap was taxed | "MEV Tx Taxed: $450 routed to Vault" |
| `TierUpgraded` | LP hit 30 or 90 days | "Bob upgraded to Gold Loyalty Tier" |
| `ExitPenaltyApplied`| LP left early, slashed | "Mercenary LP penalized: 500 MRLV returned to Vault" |

---

## 21. ERROR REPRESENTATION

| Contract Error | Trigger | Meaning | User-Facing Message |
| :--- | :--- | :--- | :--- |
| `PositionNotMature()` | Clicking "Activate" too early | The escrow period hasn't finished. | "Your liquidity is still warming up. Please wait 3 more blocks." |
| `ZeroLiquidity()` | Adding 0 tokens | Invalid input. | "Please enter an amount greater than 0." |
| `HookIsPaused()` | Swapping during circuit break | Governance paused the hook. | "The protocol is temporarily paused by governance." |

---

## 22. PROTOCOL / HOOK STATUS

*   **Hook Address**: (Mock Address)
*   **Status**: ACTIVE
*   **Current Escrow Requirement**: 5 Blocks
*   **Base Fee**: 0.3%
*   **Max Dynamic Fee**: 3.0%
*   **Early Exit Window**: 7 Days
*   **Silver / Gold Thresholds**: 30 Days / 90 Days

---

## 23. INVESTOR EXPERIENCE

1.  **What is MRVL?** A Uniswap v4 Hook.
2.  **What problem does it solve?** LPs lose money to MEV bots (LVR) and JIT liquidity.
3.  **How does it solve it?** It taxes MEV transactions with dynamic fees and forces liquidity into a waiting period.
4.  **How does MRVL protect liquidity?** It routes the captured MEV taxes into a Reward Vault explicitly for LPs.
5.  **What does sustainable liquidity mean here?** LPs get NFTs and multipliers for staying longer, and lose rewards if they leave before 7 days.
6.  **Measurable proof**: Dashboard shows "MEV Captured" and "Gold Tier Retention".

---

## 24. SCREEN / SECTION SPECIFICATION

### 1. The MEV Dashboard (Home)
*   **Purpose**: High-level protocol metrics.
*   **Protocol Features**: Dynamic Fees, Surcharge Capture.
*   **Metrics**: Total Volume, Total MEV Captured, Average APY boost from MEV.

### 2. Swap & MEV Analysis
*   **Purpose**: Trading interface.
*   **Protocol Features**: MEVDetector, DynamicFeeManager.
*   **States**: Normal Trade vs. MEV Warning.

### 3. Liquidity & Loyalty Portal
*   **Purpose**: LP Management.
*   **Protocol Features**: Pending Escrow, Early Exit Penalties, Loyalty Tiers.
*   **Metrics**: User's Tier, Time to next tier, Accrued Rewards.
*   **User Actions**: Add Liquidity (goes to pending), Activate Liquidity, Remove Liquidity.

### 4. Governance (veMRLV)
*   **Purpose**: MRLV Token utility.
*   **Protocol Features**: `MRLVToken.lock`.
*   **User Actions**: Lock tokens, View Voting Power.

---

## 25. FEATURE COVERAGE CHECK

| Contract Feature | Represented in Dummy Frontend? | Where Represented | Dummy Dataset | Status |
| :--- | :--- | :--- | :--- | :--- |
| Escrow/Maturity | YES | Liquidity Portal | `mockPendingPositions` | IMPLEMENTED |
| MEV Scoring | YES | Swap Interface | `mockSwapQuote` | IMPLEMENTED |
| Dynamic Fees | YES | Swap Interface | `mockDynamicFee` | IMPLEMENTED |
| Vault Distribution | YES | Rewards Portal | `mockClaimableRewards`| IMPLEMENTED |
| Loyalty Tiers/NFTs | YES | Liquidity Portal | `mockUserProfile` | IMPLEMENTED |
| Early Exit Penalty | YES | Remove Liquidity Modal| `mockWithdrawalPenalty`| IMPLEMENTED |
| Token Locking | YES | Governance Portal | `mockLockedTokens` | IMPLEMENTED |

---

## 26. REAL VS DUMMY DATA

| Feature | Contract Source | Can Be Read On-Chain? | Requires Indexer? | Dummy Data Needed? |
| :--- | :--- | :--- | :--- | :--- |
| Pending Positions | `MRLVHook.getPendingPositionStatus` | YES | NO | YES |
| MEV Tax Events | `AnalyticsEmitter.MEVDetected` | YES (via logs) | YES | YES |
| LP Loyalty Tier | `LoyaltyNFT.tokenTier` | YES | NO | YES |
| Total Vault TVL | `RewardVault.totalCaptured` | YES | NO | YES |
| Historical LP APY | N/A | NO | YES | YES (Illustrative) |

---

## 27. IMPLEMENTATION GAPS

*   **Historical LP Scores**: The `LoyaltyManager.computeLPScores` function is computationally heavy and requires an array of addresses. A real frontend would require an off-chain indexer to maintain a list of all active LPs in a pool to pass into this function, or to pre-calculate the scores off-chain.
*   **Insurance Pool Payouts**: The `RewardVault` mints a percentage of surcharges to an `insurancePool`, but the frontend has no context on how that insurance pool operates or pays out, as the contract for it is not present in the repository.
*   **Hook Data Decoding**: The `beforeSwap` hook accepts `hookData`, but the current `MEVDetector` does not heavily decode or utilize this payload beyond passing it. Frontend dummy representations should assume standard swaps for now.
*   **Governance Execution**: While `MRLVToken` supports locking for voting power, there is no actual `Governor` contract in the repository to execute proposals. The Governance portal will be purely illustrative of "Voting Power".
