# Phase 1 Change Notes: Cross-Transaction MEV Detection

This document records the design choices, assumptions, gas cost implications, and storage growth trade-offs associated with transitioning the reversal (sandwich) and JIT liquidity signals to persistent storage.

## 1. Gas Cost Comparison

The gas benchmark test (`test_beforeSwapGasBenchmark`) measures the gas consumption of `beforeSwap` under normal swap circumstances (no MEV flags triggered) before and after the persistent storage changes.

| Scenario | Gas Consumption | Description |
| --- | --- | --- |
| **Before Change** (Transient Storage) | **125,563 gas** | Uses `TSTORE`/`TLOAD` for JIT and reversal tracking. |
| **After Change** (Persistent Storage) | **149,448 gas** | Uses `SSTORE`/`SLOAD` for persistent history. |
| **Difference / Overhead** | **+23,885 gas** | Additional gas cost due to cold writing/updating storage. |

### Gas Optimization Strategy
To minimize gas overhead:
- We packed `TradeRecord` into a single 256-bit storage slot:
  - `bool lastZeroForOne` (8 bits)
  - `uint32 lastSwapBlock` (32 bits)
  - `bool hasTraded` (8 bits)
  - Total size = 48 bits, which fits comfortably within a single 32-byte (256-bit) slot. This ensures updating trade history only requires a single cold write (`SSTORE`).

---

## 2. Configured Parameters and Assumptions

We selected the following default configurations for the rolling windows:

- **`reversalWindowBlocks`**: Initialized to **10 blocks** (~2 minutes on Ethereum L1). This defines the maximum block distance allowed between opposite-direction swaps by a trader to trigger the reversal score (+30).
- **`jitWindowBlocks`**: Initialized to **10 blocks**. This defines the maximum block distance allowed between a liquidity addition and a swap by the same address to trigger the JIT score (+40).

Both parameters are exposed via governance setter functions (`setReversalWindowBlocks` and `setJitWindowBlocks`) to allow adjustments on live networks.

---

## 3. Storage Design & Trade-offs

### Storage Growth
Unlike transient storage which is cleared at the end of the block/transaction automatically, persistent storage mappings (`tradeHistory` and `lastAddLiquidityBlock`) persist indefinitely.
- **Limitation:** There is no automatic expiry or cleanup mechanism for inactive traders/LPs. The storage will grow unbounded relative to the number of unique user address and pool ID pairs.

### First-Swap Behavior
- **False Negative Intentional:** A trader's very first swap in a pool cannot trigger the reversal signal since `record.hasTraded` is initialized to `false`. This prevents false positives on initial trades.

### Lookback Boundary
- Swaps or JIT actions spaced further than the block window (e.g. 11 blocks apart with a 10-block window) will not be flagged. This boundary is necessary to bound detection limits and prevent false positives over very long periods.
