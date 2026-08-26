# Fantasy MEV League

This directory contains the smart contracts and off-chain relayer script for the **Fantasy MEV League**, an isolated add-on to the MEV-Redistributive Liquidity Vault (MRLV).

## Integration Boundary

In accordance with strict integration constraints, **no existing contracts in the MRLV repository were modified to support this feature.** The new system integrates entirely from the *outside*.

### Why Pattern A (Off-chain Relayer) was chosen

We evaluated two potential integration patterns:
*   **Pattern A (Off-chain relayer):** A script listens to public events emitted by the core contracts and reports them to the new League contracts.
*   **Pattern B (Permissionless on-chain replay):** The new League contracts read public state from the core contracts to verify MEV detections.

We selected **Pattern A** because the existing `MEVDetector.sol` and `AnalyticsEmitter.sol` do not store historical detections in public state variables (the detector only temporarily caches the last swap block for reversal checking, but doesn't keep an iterable flag history). 

Since detections are only logged durably in the form of transient events (`MEVDetected` and `SwapProcessed` in `AnalyticsEmitter.sol`), the only technical way to bridge this data to a new contract without modifying the core system is via an off-chain relayer. 

### Off-Chain Relayer (`relayer/index.js`)
A minimal Ethers.js script listens for `MEVDetected` logs from the `AnalyticsEmitter` and calls `reportDetection` on our new `ScoutPointsOracle`. To save gas on-chain, the relayer queries the `MEVScoutLeague` for the list of LPs participating in the current season and passes them in the payload. The Oracle then validates against the `ScoutRoster` that these LPs legitimately staked the flagged trader.

## Contract Architecture

1.  **`MEVScoutLeague.sol`**: The orchestrator. Manages seasons (DRAFTING, ACTIVE, SETTLED), handles MRLV staking entries via `transferFrom`, manages the prize pool, and coordinates payout proportional to points at the end of the season. 
2.  **`ScoutRoster.sol`**: Manages the individual rosters. Tracks up to 3 staked addresses per LP per season. Stakes are immediately locked and immutable once placed.
3.  **`ScoutPointsOracle.sol`**: The receiver of detections. Holds the weight configuration (PriorityFee = 25, Reversal = 30, PriceImpact = 20) and updates the season rosters and an all-time Scout Score leaderboard.
4.  **`interfaces/IExistingEvents.sol`**: A reference interface to provide ABI for the relayer script. Does not interact with existing contracts on-chain.

## Draft Board Mechanics

Because the existing `MEVDetector` doesn't maintain a list of all historical traders on-chain, the Frontend "Draft Board" must index `SwapProcessed` events off-chain to present a list of draftable trader addresses to the LPs. LPs can then select from this list when calling `stakePick`.
