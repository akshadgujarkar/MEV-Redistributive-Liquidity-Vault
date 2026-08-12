# Design.md — UI/UX Design System
**Source of truth:** `MRLV_Architecture.md`. The source document is a backend/protocol architecture specification and contains very little explicit visual design detail. Most sections below are marked `Not specified` accordingly — this is expected and correct per the accuracy rules, not a gap in this document. Where a UX *behavior* (not visual style) is stated, it is documented and treated as a hard requirement.

---

## 1. Design Philosophy

Not explicitly stated as a design philosophy. The following is derived (**Inference**) from the product's stated goals in Part 10 and the transparency emphasis in Part 2.2:
- The frontend should make protocol state legible and trustworthy — every dashboard exists to make an abstract on-chain mechanism (MEV detection → fee capture → redistribution) visible and verifiable to a non-technical LP or trader.
- Transparency is a first-class UX goal: the MEV Analytics Dashboard is explicitly described as a "public, real-time view" and "transparency layer" (Part 2.2).

## 2. Brand/Visual Identity

- **Brand personality:** `Not specified`.
- **Visual direction / mood:** `Not specified`.
- **Design principles (stated, functional rather than visual):**
  - Never show a user-actionable dollar figure that isn't live-verified against the contract at action time (Part 10.2) — a design/content rule, not a visual one.
  - Loyalty tiers (Bronze/Silver/Gold) should be visually distinct and demoable — described as "high visual impact, easy to demo" (Part 7.4) — but no specific visual treatment (colors, icon style) is given.

## 3. Color System

**Not specified.** No color tokens, hex values, or palette guidance appear anywhere in `MRLV_Architecture.md`.

| Token | Value | Usage |
|---|---|---|
| Primary | Not specified | — |
| Secondary | Not specified | — |
| Background | Not specified | — |
| Surface | Not specified | — |
| Text | Not specified | — |
| Muted text | Not specified | — |
| Border | Not specified | — |
| Success | Not specified | — |
| Warning | Not specified | — |
| Error | Not specified | — |
| Info | Not specified | — |
| Risk-band indicator colors (Normal/Suspicious/High-risk) | Not specified | **Inference**: the three risk bands (Part 5.1) and three fee tiers (Part 6.1) are natural candidates for a consistent color-coding scheme (e.g., low/medium/high severity), but no actual colors are specified in the source — do not assign specific hex values without explicit instruction. |

## 4. Typography

**Not specified.** No font families, weights, sizes, line heights, or letter spacing appear in the source.

## 5. Spacing

**Not specified.** No spacing scale or tokens appear in the source.

## 6. Layout

- **Container widths / grid / breakpoints:** `Not specified`.
- **Page structure:** Five pages are named with defined *content*, not layout (Part 10.1): Landing Page, LP Dashboard, MEV Analytics Dashboard, Governance Dashboard, Pool Explorer.
- **Responsive behavior:** `Not specified`.

## 7. Components

The source names functional content requirements per page/component but not visual specifications. Documented at the level of detail given:

### Trader Interface
- **Requirement:** standard swap UI that surfaces the current dynamic fee tier before the trader signs (Part 2.2, 10.1).
- **Visual spec:** Not specified.

### LP Dashboard
- **Requirement:** shows current liquidity, LPScore trend, loyalty tier + NFT badge, claimable rewards with a claim action (Part 10.1).
- **Behavioral rule:** claim button triggers a direct wallet contract call, never routed through the backend (Part 10.1, 10.2).
- **Visual spec:** Not specified.

### MEV Analytics Dashboard
- **Requirement:** shows MEV detected over time (by risk band), fees captured vs. redistributed, per-pool resilience score, and a flagged-address list (addresses only, no personal data) (Part 10.1).
- **Visual spec:** Not specified.

### Governance Dashboard
- **Requirement:** shows active proposals, a voting UI (direct contract call), and veMRLV lock/voting-power management (Part 10.1).
- **Visual spec:** Not specified.

### Pool Explorer
- **Requirement:** searchable pool list showing TVL, current dynamic fee, and a historical fee-band distribution chart (Part 10.1).
- **Visual spec:** Not specified.

### Loyalty NFT Badge
- **Requirement:** visual representation of Bronze/Silver/Gold tier, described as high-visual-impact and demo-friendly (Part 7.4); on-chain tier metadata plus off-chain (IPFS)-hosted art per tier, refreshed automatically on tier change.
- **Visual spec:** Not specified — no art direction, badge shape, or icon style given.

### Standard components (buttons, inputs, forms, cards, navigation, modals, tables, lists, alerts, notifications, loading/empty/error states)
**Not specified.** None of these are described visually anywhere in the source.

## 8. Responsive Design

**Not specified.** No mobile/tablet/desktop/large-screen behavior is described.

## 9. Accessibility

**Not specified.** No keyboard navigation, focus-state, contrast, semantic-HTML, screen-reader, form-accessibility, or motion guidance appears in the source.

## 10. Interaction Design

Only functional/behavioral interaction rules are stated; visual interaction states (hover/focus/active/disabled styling) are not.

- **Live fee preview:** the trader must see the current dynamic fee before signing — implies a pre-signature state showing fee value, likely updating as it changes (Part 2.2). Exact visual/interaction treatment: `Not specified`.
- **Claim/vote/withdraw:** trigger a wallet signature flow directly; no backend-mediated loading state is implied beyond what a wallet provider (e.g., MetaMask) natively shows. Custom loading/success/error state design: `Not specified`.
- **Reward estimate vs. confirmed:** the Reward Calculation Service explicitly serves "estimated, pending on-chain confirmation" figures (Part 9.1) — this implies the UI should visually or textually distinguish estimated vs. confirmed reward amounts, though no specific treatment (badge, label wording, color) is specified. **Inference flagged.**
- Hover/focus/active/disabled/loading/success/error/transition styling: `Not specified`.

## 11. UX Principles

- **Feedback/transparency:** every fee change emits an event and is described as "auditable off-chain in real time" (Part 6.4) — the UX should make fee changes visible and traceable, though no specific mechanism (toast, banner, live ticker) is specified beyond the general "live ticker" mention for the Landing Page counter (Part 10.1, "live 'MEV redirected to LPs' counter").
- **Validation:** `Not specified` beyond the general rule that user-actionable figures must be live-verified against the contract (Part 10.2).
- **Errors:** `Not specified` — no error-state copy, iconography, or recovery-flow guidance given.
- **Loading states:** `Not specified`.
- **Empty states:** `Not specified` (e.g., what an LP Dashboard shows for a wallet with no positions is not addressed).
- **Confirmation:** `Not specified` (e.g., whether claim/vote actions show a confirmation step before wallet signature).
- **Navigation:** Not specified beyond the five named pages; no navigation hierarchy, menu structure, or wayfinding pattern is given.
- **User guidance:** `Not specified` (no onboarding flow, tooltip strategy, or first-time-user guidance described).

---

## Summary Note for Implementers

This document intentionally contains a high proportion of `Not specified` entries. `MRLV_Architecture.md` is a protocol/systems architecture document, not a design spec — it defines *what data* each screen must show and *which actions must go directly through the wallet*, but makes no visual design decisions. Any visual system (colors, type, spacing, component library, accessibility implementation) must be established as a separate, explicit design decision — clearly documented as new, not inferred from the architecture source — before or during implementation.
