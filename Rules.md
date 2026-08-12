# Rules.md — AI Development Rules
**Source of truth:** `MRLV_Architecture.md`. These are engineering guardrails for any AI agent (or human) modifying or extending this project. Where the source does not specify a rule, this document says so rather than inventing one.

---

## General Rules

- Understand the existing architecture (`Architecture.md` in this set, and `MRLV_Architecture.md` itself) before changing any contract or service.
- Follow the documented separation of concerns: `MRLVHook.sol` dispatches only, it must never absorb business logic from the specialist modules (Part 3, design goal).
- Do not introduce new detection signals, fee tiers, or reward formulas without explicit instruction — the four MEV signals (Part 5.1), three fee tiers (Part 6.1), and LPScore formula (Part 7.2) are specified precisely; do not "improve" them silently.
- Preserve existing behavior unless a task explicitly requires changing it.
- Any new component not named in `MRLV_Architecture.md` (e.g., a new contract, a new dashboard page, a new external integration) must be clearly flagged as an addition, not presented as sourced.

## Technology Rules

- **Required/implied stack:** Solidity + Uniswap v4 `IHooks`/`PoolManager` (on-chain); React + wagmi/viem + TanStack Query (frontend); PostgreSQL (database); Foundry (contract testing, per Week 1–2 testing tasks in Part 15).
- **Approved external services:** Chainlink Price Feeds, an unnamed Volatility Oracle, an EigenPhi-style MEV data source (backend-only), Tenderly, OpenZeppelin Defender, The Graph (future/optional).
- **Do not introduce alternative oracle providers, alternative L2s beyond Arbitrum/Base, or alternative hosting providers beyond AWS/GCP + Vercel** without explicit instruction — these are the only providers named in the source (Part 14).
- **Pattern to follow:** every fund-affecting on-chain action uses pull-payment, not push-payment (Part 3.5) — this is a strict rule, not a style preference; do not implement automatic reward pushes.
- **Dependency rule:** no library or framework beyond what's named above should be introduced without checking whether the source already implies an equivalent — if uncertain, flag it rather than choosing silently.

## Code Organization Rules

- Contract names and their responsibilities are fixed as specified in Part 3.1: `MRLVHook.sol`, `MEVDetector.sol`, `DynamicFeeManager.sol`, `RewardVault.sol`, `LoyaltyManager.sol`, `MRLVToken.sol`, `Governance.sol`, `AnalyticsEmitter.sol`. Do not merge these into fewer files or rename them.
- Business logic for detection belongs in `MEVDetector.sol`, never in `MRLVHook.sol`.
- Fee computation belongs in `DynamicFeeManager.sol`, never inline in the hook or in `MEVDetector.sol`.
- All events belong in `AnalyticsEmitter.sol` — no other contract should define its own event schema that bypasses this central emitter (Part 3.9).
- Off-chain, the Indexer/Event Processor is the only writer to PostgreSQL — frontend or API code must never write directly to the database from user input.
- Exact folder/file layout beyond contract and service names is `Not specified` — see `Architecture.md`, Section 5. Propose a structure and label it clearly as proposed rather than sourced.
- Naming conventions beyond the contract/function names explicitly given in the source are `Not specified`.

## Architecture Rules

- The hook must remain a thin dispatcher — this is a stated design goal (Part 3, intro), not a suggestion.
- Detection, accounting (fees/rewards), and rewards distribution must stay in separate contracts (Design Principle 5, end of source document).
- No heavy computation on-chain; rolling averages and analytics are off-chain-fed or off-chain-consumed (Design Principle 2).
- Use transient storage (EIP-1153) for all block-level MEV tracking; do not substitute persistent storage for this purpose (Design Principle 4).
- Events + indexer are the only mechanism for historical/analytics data — the hook must never accumulate an on-chain history array (Design Principle 3).
- Async/custom swap-curve hooks must be avoided — stick to vanilla curves with fee hooks only (stated in the underlying research's security best-practices table, carried into the architecture's conservative design stance).

## UI/UX Rules

- Any dollar figure or reward amount a user can act on (claim, vote, withdraw) must be fetched live from the contract at action time — dashboard/aggregate figures are for browsing/context only (Part 10.2). Do not wire a claim button to a cached backend value.
- Claim/vote/liquidity flows must never be routed through the backend for signing or custody — the wallet signs and broadcasts directly (Part 10.2).
- The current dynamic fee must be surfaced to the trader before they sign a swap (Part 2.2) — do not hide fee changes behind a post-signature confirmation only.
- Flagged-address displays (MEV Analytics Dashboard) show addresses only, never personal data (Part 10.1).
- Specific component library conventions, design tokens, and styling framework are `Not specified` — see `Design.md`.

## Error Handling Rules

- Malformed or unrecognized `hookData` must cause a safe revert, never a silent fallback into unintended logic (Part 12).
- A high MEV risk score must never cause a swap to revert or block — only the fee may change (Part 5.2, FR-002 in `PRD.md`). Do not implement blocking behavior for any detection signal.
- `afterSwap` must assert `NonzeroDeltaCount == 0` before returning (Part 12) — any change to swap settlement logic must preserve this invariant.
- The Event Processor must be idempotent on `tx_hash` to safely handle redelivery/reorgs (Part 9.1) — do not write event-processing code that assumes each event is delivered exactly once.
- The Indexer must wait for a confirmation buffer before writing a row as "final" (Part 9.1) — exact confirmation count is `Not specified`; do not invent a specific number without flagging it as an assumption.
- Logging requirements and user-facing error message conventions beyond the above are `Not specified`.

## Security Rules

- Every `MRLVHook` callback must be restricted with `onlyPoolManager` — never trust `msg.sender` beyond the canonical `PoolManager` singleton (Part 3.2).
- Every specialist-module function callable by the hook must be restricted with an equivalent `onlyHook` (or more specific: `onlyOracleRelayer`, `onlyRewardVault`, `onlyLoyaltyManager`) modifier (Parts 3.3–3.9).
- `RewardVault.claim()` must use checks-effects-interactions ordering plus a reentrancy guard, and must remain pull-based (Parts 3.5, 12).
- `DynamicFeeManager`'s `HARD_CAP` (3%) must remain a hard-coded constant, not a governance-settable variable (Parts 3.4, 6.3).
- Fee changes must remain rate-limited to ≤3× the previous applied fee per block, independent of risk score jumps (Parts 6.3–6.4).
- `Governance.execute()` must only be able to call a whitelisted set of target contracts/functions — never arbitrary calls (Part 3.8).
- Every executed governance proposal must pass through a timelock delay before execution (Part 3.8) — do not add an execution path that bypasses this.
- Oracle reads (Chainlink, Volatility Oracle) must include staleness checks and must never be the sole input to a fund-moving decision — only to bounded parameters like a reward multiplier (Part 12).
- Transient storage keys must be namespaced by `(poolId, address, block.number)` to avoid cross-pool/cross-block collisions (Part 12).
- Loyalty NFTs must remain non-transferable (soulbound) — do not implement `transfer()`/`safeTransferFrom()` without the override-to-revert behavior (Part 7.4).
- Secrets/API-key management conventions are `Not specified` — do not hardcode credentials; flag this gap if implementation requires a decision.

## Testing Rules

- Per-signal unit tests are required for each MEV detection signal (priority fee, reversal, price impact, JIT), using forked mainnet fee data where applicable (Part 15, Week 1).
- Fuzz tests are required on `computeFee()` boundary conditions (Part 15, Week 1).
- Integration tests are required for multi-LP, multi-epoch distribution scenarios (Part 15, Week 2).
- Reentrancy tests are required on `RewardVault.claim()` (Part 15, Week 2).
- A Sybil-splitting test is required: verify many small wallets vs. one large wallet yields no aggregate score advantage (Part 15, Week 2).
- Boundary tests are explicitly called out for JIT/exit-penalty windows (e.g., the 7-day threshold) due to known off-by-one audit findings (Part 3.6).
- Testing tools: Foundry (unit/fuzz/integration), Slither (static analysis self-audit pass) (Part 15, Week 3).
- End-to-end scripted demo scenario testing is required before submission: seeded pool, normal swaps, a scripted "attack" wallet, visible fee escalation and reward redistribution (Part 15, Week 3).
- Gas profiling report is a stated Week 3 deliverable (Part 15).
- Test organization conventions (file naming, directory structure) are `Not specified`.

## Performance Rules

- `beforeSwap` reads must remain O(1) and bounded — this is explicitly called out as critical because it runs on every swap regardless of risk (Part 4.2). Do not introduce unbounded loops or per-swap historical scans into `beforeSwap`.
- Reward distribution must remain epoch-batched, not per-swap, to amortize storage-write cost (Part 13, "Batch operations").
- Use packed structs where safe to reduce storage slot usage (Part 13).
- Use custom errors instead of string-based `require`/`revert` (Part 13).
- Specific gas budgets/targets (e.g., max gas per `beforeSwap` call) are `Not specified`.

## Dependency Rules

- Before adding any new library, verify it isn't already implied by the named stack above.
- Do not add a new oracle, indexing service, or hosting provider without flagging that this goes beyond what `MRLV_Architecture.md` specifies.
- ORM, CI/CD, and package-manager choices are `Not specified` — pick pragmatically for a 3-week build but do not present the choice as sourced from the architecture document.

## AI Behavior Rules

- Read `PRD.md` before implementing a feature, to confirm it's in scope (see `PRD.md` Section 9 — Scope).
- Read `Architecture.md` before touching any contract or service boundary.
- Read this file (`Rules.md`) before writing or modifying security-relevant code.
- Read `Phases.md` before starting new work, to confirm dependencies for the current phase are met.
- Read `Design.md` before implementing any UI component.
- Do not modify the on-chain/off-chain architectural split (Part 2) without explicit justification tied to a real constraint discovered during implementation.
- Do not create speculative functionality beyond what's in `PRD.md`'s In Scope section — stretch/future items must stay clearly separated (see `PRD.md` Section 9).
- When a requirement is ambiguous or two source statements appear to conflict, ask for clarification rather than guessing — see the Contradictions/Ambiguities note in the final project summary.
- Keep changes focused on the requested task; do not opportunistically refactor unrelated modules.
- Any invented detail (a specific gas number, a specific timelock duration, a specific confirmation count, etc.) must be clearly flagged as an assumption in code comments or PR descriptions, not presented as a spec requirement.
