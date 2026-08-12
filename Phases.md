# Phases.md — Implementation Roadmap
**Source of truth:** `MRLV_Architecture.md`, Part 15 (3-Week Implementation Roadmap), cross-referenced with dependency order implied by Parts 3–4 (contracts must exist before the flows that call them) and Part 15's own sequencing. Phase boundaries below follow the source's own week-by-week structure rather than the generic 14-step template, because the source defines an explicit, different ordering.

---

## Phase 1 — Core Hook, Detection & Fees (Week 1)

### Objective
Stand up the on-chain foundation: a working hook wired to `PoolManager`, MEV detection signals, and the dynamic fee engine.

### Features/Tasks
- [ ] Deploy Uniswap v4 `PoolManager` locally (Anvil) and mine a valid hook address via CREATE2.
- [ ] Build `MRLVHook.sol` skeleton with all seven `IHooks` callbacks wired (even as stubs initially).
- [ ] Implement `MEVDetector.sol`: priority-fee-anomaly signal (transient-storage/rolling-average comparison).
- [ ] Implement `MEVDetector.sol`: same-block-reversal signal (transient storage).
- [ ] Implement `MEVDetector.sol`: JIT-pattern signal (transient storage flag set from `beforeAddLiquidity`).
- [ ] Implement `MEVDetector.sol`: large-price-impact signal.
- [ ] Implement `DynamicFeeManager.sol`: tiered fee computation (0.30% / 0.60% / 1–3% linear).
- [ ] Implement `DynamicFeeManager.sol`: hard cap (3%) and per-block rate limiting (≤3× previous fee).
- [ ] Wire `MRLVHook.beforeSwap` to call `MEVDetector` then `DynamicFeeManager` and return the fee override.

### Dependencies
- None — this is the first phase. Requires only the Uniswap v4 template/`PoolManager` reference and Foundry setup.

### Expected Deliverables
- A hook deployed on local Anvil that scores swaps and applies a tiered, capped, rate-limited fee.
- Per-signal Foundry unit tests passing.
- Fuzz tests on `computeFee()` boundary conditions passing.
- Testnet (Sepolia) deployment of `PoolManager` + hook.

### Validation
- Manually trigger each of the four signals independently and confirm the correct point value and resulting fee tier.
- Confirm a swap never reverts due to risk score alone (Part 5.2, FR-002).
- Confirm fee never exceeds the 3% hard cap even with a maximal-score input.
- Confirm fee cannot jump more than 3× the previous applied fee in one block.

### Definition of Done
All four detection signals implemented and unit-tested; fee computation matches the Part 6.2 formula exactly; testnet deployment live; no persistent-storage writes occur on the normal (score <30) swap path (Part 13).

---

## Phase 2 — Reward System, Loyalty & NFTs (Week 2)

### Objective
Build the value-capture and redistribution layer on top of the Phase 1 detection/fee engine: escrow captured surcharges, score LPs, and issue loyalty NFTs.

### Features/Tasks
- [ ] Implement `RewardVault.sol`: `deposit()` (called from `afterSwap`, splits optional insurance-pool cut).
- [ ] Implement `RewardVault.sol`: `distribute()` (epoch-batched, pulls LPScores from `LoyaltyManager`).
- [ ] Implement `RewardVault.sol`: `claim()` (pull-based, CEI-ordered, reentrancy-guarded).
- [ ] Implement `LoyaltyManager.sol`: tenure tracking (`firstDepositBlock`, `liquidityAmount`).
- [ ] Implement `LoyaltyManager.sol`: `computeLPScore()` per the Part 7.2 formula.
- [ ] Implement `LoyaltyManager.sol`: JIT-pattern exclusion from tenure credit.
- [ ] Implement `LoyaltyManager.sol`: exit-penalty logic (forfeits accrued rewards only, never principal, on early withdrawal).
- [ ] Implement `MRLVToken.sol` (ERC-20, `mint()` restricted to `RewardVault`, `lock()`/`withdraw()`/`votingPowerOf()`).
- [ ] Implement soulbound loyalty NFT contract (ERC-721, transfer functions overridden to revert).
- [ ] Wire `LoyaltyManager.mintOrUpgradeLoyaltyNFT()` to fire on tier threshold crossing.
- [ ] Wire `MRLVHook`'s liquidity callbacks (`beforeAddLiquidity` through `afterRemoveLiquidity`) to `LoyaltyManager`.

### Dependencies
- Phase 1 complete: hook must already call `afterSwap` with a known surcharge amount to deposit.
- `AnalyticsEmitter.sol` should exist by this point (can be built in parallel with Phase 1, since it has no dependency on detection/fee logic beyond being called from the hook).

### Expected Deliverables
- Full reward stack deployed to testnet, wired to the Week 1 hook.
- Integration tests covering multi-LP, multi-epoch distribution.
- Reentrancy tests on `claim()` passing.
- Sybil-splitting test passing (many small wallets vs. one large wallet — no aggregate score advantage).
- Soulbound NFTs minting/upgrading correctly at Bronze/Silver/Gold thresholds.

### Validation
- Simulate a flash-loaned same-block add+swap+remove and confirm zero tenure credit and a JIT flag.
- Simulate an early withdrawal and confirm only accrued (not principal) rewards are forfeited.
- Attempt to transfer a loyalty NFT and confirm it reverts.
- Confirm `claim()` cannot be reentered.

### Definition of Done
All reward, loyalty, and NFT logic implemented, tested, and deployed to testnet; boundary tests for the early-withdrawal window pass; no double-distribution possible within a single epoch.

---

## Phase 3 — Dashboards, Analytics, Testing & Demo (Week 3)

### Objective
Build the off-chain data pipeline and frontend dashboards, then harden and rehearse the full system for submission.

### Features/Tasks
- [ ] Build the Indexer: WebSocket subscription to `AnalyticsEmitter` events with a confirmation-buffer/reorg-safety mechanism.
- [ ] Build the Event Processor: idempotent normalization into the PostgreSQL schema (Part 8 tables).
- [ ] Stand up PostgreSQL with the eight tables from Part 8.
- [ ] Build the Backend API Gateway with the four route groups (`/pools`, `/lp/:address`, `/mev/analytics`, `/governance/*`).
- [ ] Implement SIWE-based Auth Service.
- [ ] Implement the Analytics Service (hourly/daily rollups).
- [ ] Build the **LP Dashboard** (highest-priority demo surface): liquidity, claimable rewards, LPScore trend, loyalty tier/NFT.
- [ ] Build the **MEV Analytics Dashboard** (second-priority demo surface): MEV detected over time, fees captured vs. redistributed, resilience score, flagged addresses.
- [ ] Build the Governance Dashboard, as time permits.
- [ ] Wire claim/vote/liquidity actions to sign and broadcast directly from the user's wallet (never via backend).
- [ ] Run gas profiling across all contracts.
- [ ] Run a self-audit pass (Slither + Foundry invariant tests).
- [ ] Build and rehearse the end-to-end scripted demo: seed a pool, run normal swaps, run a scripted "attack" wallet, show fee escalation and reward redistribution live.
- [ ] Deploy frontend to Vercel; deploy contracts + seeded demo pool to public testnet.
- [ ] Assemble the submission package (repo, deck, video walkthrough) for the Uniswap Hook Incubator.

### Dependencies
- Phase 1 (`AnalyticsEmitter` events must exist and be firing correctly) and Phase 2 (reward/loyalty events must be available to index) both complete.

### Expected Deliverables
- Public testnet deployment with a seeded demo pool.
- Deployed frontend (LP Dashboard + MEV Analytics Dashboard functional at minimum).
- Gas profiling report.
- Self-audit findings addressed or documented.
- Recorded demo video + submission package.

### Validation
- Run the scripted demo scenario at least once end-to-end on the actual testnet deployment (not just local Anvil).
- Confirm dashboard figures match on-chain state for a known test wallet.
- Confirm no claim/vote/withdraw action is ever routed through the backend.

### Definition of Done
LP Dashboard and MEV Analytics Dashboard are functional and demo-ready; the full swap→detect→fee→capture→redistribute→claim loop is demonstrable live on testnet; submission package assembled.

---

## Stretch Goals (Only If Ahead of Schedule)

Explicitly marked in the source (Part 15) as optional, not part of the core 3-week critical path:

- [ ] Cross-Pool MEV Blacklist / reputation system (`crossPoolFlagCount` in `MEVDetector.sol`).
- [ ] Volatility-scaled reward multiplier (Volatility Oracle integration into `DynamicFeeManager`).
- [ ] Auto-compounding ERC-4626 reward vault wrapper.

These must not be started before the Phase 1–3 core deliverables above are complete and demo-ready — this ordering is explicit in the source ("if ahead of schedule").

---

## Notes on Ordering

The generic 14-step dependency-aware progression (foundation → config → core architecture → data layer → auth → backend → frontend → features → integration → error handling → testing → performance/accessibility → deployment → polish) is **not** what the source specifies. `MRLV_Architecture.md` instead sequences by **value-chain layer within a fixed 3-week window**: detection/fees first (nothing else can be tested without a fee to observe), then the reward/loyalty layer that consumes those fees, then the off-chain/frontend layer that visualizes both. This document follows the source's explicit ordering rather than forcing the generic template, per the instruction that the actual project architecture takes precedence.
