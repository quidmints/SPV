# Family-plan LP — a group co-owning ONE self-hosted SGX liquidity provider

## What it is (and what it is NOT)
The **family plan** lets several people (a "family" / small DAO of up to some `n`
contributors) **pool into ONE LP position** and co-own it under an **n-of-m
multisig** — self-custody as a group, no trust in the hop, and no single member,
host, or box able to run off with the pot. Think "AT&T family plan": one shared
plan, several owners, lower per-head overhead.

It is **NOT** the operator multisig. Both are now **Gnosis Safes** (same
mechanism), but they are two different **principals**:

| | **Operator Safe** | **Family Safe (n-of-m)** (this doc) |
|---|---|---|
| Principal | The **foundation** — the deployer/operator of the Solidity contracts and foundation-run infra | A group of **outside LPs** |
| Governs | Provisioning / migrating / upgrading **our** enclaves | The **LPs' own pooled funds + channel** |
| Mechanism | Gnosis Safe (n-of-m), EIP-712, signed in the Safe UI | Gnosis Safe (n-of-m), EIP-712, signed in members' browser wallets |
| Keys | Foundation operators' wallets | The family members' wallets |
| Relationship | Foundation-internal | Independent of the foundation |

Both use the **same in-enclave verification primitive** — k-of-n secp256k1 /
EIP-712 owner signatures checked against the Safe's owner-set + threshold — just
**pinned to a different Safe** per principal. (This replaces the original baked-in
`ed25519 OPERATOR_PUBKEYS` / `MigrationAuth` scheme in `quid_hop::migration`;
see "Operator Safe" below.)

## Operator Safe (the foundation's msig) — replaces the baked ed25519 scheme
The operator authority (who may **provision / migrate / upgrade** our enclaves)
becomes a **Gnosis Safe**, replacing the original `ed25519 OPERATOR_PUBKEYS[3]` /
`MIGRATION_THRESHOLD=2` / `MigrationAuth` baked into `quid_hop::migration`. Why:
- **No CLI, no bespoke keygen** — operators sign authorizations via the standard
  Safe{Wallet} UI with their own wallets (consistent with the no-CLI direction).
- **Pin the Safe ADDRESS, not raw keys** — operators can add/remove/rotate
  members in the Safe **without rebuilding the enclave**. The old scheme baked the
  operator pubkeys into MRENCLAVE, so changing operators changed MRENCLAVE and
  forced re-attestation. Pinning the address decouples this.
- **One primitive** — operator and family verify identically in-enclave (k-of-n
  EIP-712 owner sigs vs a Safe), just a different pinned Safe.

Migration auth is the **most security-critical** action (whoever can authorize a
migration can export the sealed seed to an enclave they control = the key's
security). So the operator Safe must be a robust n-of-m, and the enclave must
learn the Safe's **current** owner-set trust-minimizedly. That is the one open
fork:

- **(A) EVM state proof of the pinned Safe (recommended).** The enclave verifies
  a Merkle-Patricia storage proof of the Safe's owners+threshold against a trusted
  recent block hash, then checks k-of-n EIP-712 owner sigs. Trust-minimized AND
  rotation-friendly; no trust in the RPC's honesty. More implementation.
- **(B) Sealed owner-set snapshot.** Pin owners+threshold in sealed config at
  provisioning; owner rotation = an operator-authorized config update. Fully
  self-contained (no RPC), strictly better than baking into MRENCLAVE; rotation is
  a deliberate step rather than automatic.
- **(C) Plain RPC read of owners.** Simplest, but the enclave would trust the
  RPC's honesty about the owner-set → a lying RPC could forge operator auth.
  **Rejected** for an action this sensitive.

Recommendation: **(A)** as the target, **(B)** as a pragmatic interim (both beat
the current baked-keys scheme).

**Same fork applies to the FAMILY Safe owner-set** (not just the operator Safe):
the enclave verifies family `FamilyAuth`s against the family Safe's owners, so it
needs that owner-set by the same means. Target **(A)** — an EVM state proof of
the family Safe — for both; **(B)** sealed snapshot is the shared interim. The
two Safes use one verification mechanism, just a different pinned Safe, so wiring
(A) once covers both. (Today: the operator path ships interim-(B); the family
path is design-only, so it should be built straight onto whichever this resolves
to — ideally (A).)

## The problem it solves: pooling
Today an LP self-hosts on SGX, one box, one channel (one-channel-per-LP). For a
small contributor that's a lot: their own SGX box to run, and enough capital to
make a single channel worth opening. The naive answer for `n` such people is `n`
boxes and `n` channels.

The family plan collapses that to **one** shared LP they all co-own:
- **One SGX box + one channel** instead of `n` (fewer deployments / lower
  operational overhead — the obvious win),
- **Pooled capital** reaches a viable channel size that no single member could
  justify alone,
- **Shared custody**: an n-of-m quorum is required to move or migrate the
  funds, so no single member (nor the host, nor the hop) can steal.

"Fewer SGX deployments" is the *consequence*; pooling-under-shared-custody is the
*purpose*.

## It STACKS on SGX — it does not replace it
There are two orthogonal trust problems, solved by two different mechanisms:

| Trust problem | Question | Solved by |
|---|---|---|
| **Host** trust | Can the box operator extract the key? | **SGX** (born-in-enclave key; host can't read it) |
| **Member** trust | Can one co-owner steal from the others? | **Family n-of-m msig** |

One shared SGX box gives the group **both**: the member who physically runs the
box can't extract the key (SGX), and no single member can move funds (msig).

> The only way to drop SGX entirely is a fully **key-split threshold signature**
> (FROST/MuSig2) across members' own devices, so no single box ever holds the
> key. But that needs `k` members **online for every HTLC and commitment** —
> which kills always-on forwarding. For a liquidity node that must be live 24/7,
> **SGX-for-liveness + msig-for-custody** is the right split.

## How authority is layered (the key design choice)
Don't make *every* channel op need a family quorum — that breaks availability
(a swap-out splice can't wait for 3 members "at 3am"). Split it:

1. **Autonomous layer — the enclave (liveness).** The pooled LP channel key is
   **born in the enclave** and signs routine channel ops (commitments, HTLCs,
   splices) **autonomously**, gated only by the in-enclave **validating-signer
   policy** (anti-revoked-reuse, payout-script lock, MuSig2 nonce-reuse guard).
   The family is NOT in the per-op path → swaps stay always-on. The box operator
   still can't read the key (SGX) and can't make it sign a bad op (policy).

2. **Quorum layer — k-of-n family (value + administration).** Every action that
   **moves value or changes trust** requires a **k-of-n family-signed
   authorization**, host-unforgeable (off-box member keys):
   - **Provision / import** the pooled seed,
   - **Migrate** the seed to a new enclave (upgrade / TCB recovery / dead box),
   - **Withdraw** (splice-out to the family's addresses),
   - **Policy / config** changes.

## LN side (the shared enclave)
- A configurable family quorum: `FAMILY_PUBKEYS: [address; N]` +
  `FAMILY_THRESHOLD: k`. **The member keys ARE the members' EVM browser wallets**
  (MetaMask / WalletConnect / passkey) — no separate keygen, no CLI, no ed25519.
  Members never hold a bespoke secret; they sign with the wallet they already
  use to interact with the site.
- A tagged **`FamilyAuth { action, params }`** (action ∈ {provision, migrate,
  withdraw, set-policy}) presented as **EIP-712 typed data**, signed in the
  browser by each member, verified k-of-n in the enclave via `ecrecover`
  (secp256k1) against `FAMILY_PUBKEYS`. Same threshold-verify *shape* as the
  operator multisig, but secp256k1/EIP-712 (web-native) instead of the
  operator's ed25519 — separate instance, separate keys. The enclave performs a
  value/admin action ONLY with a valid `FamilyAuth`.
- This unifies the keys: the same member wallets are the owners of the EVM
  `lpEth` Safe AND the signers of LN-side `FamilyAuth`. One wallet per member,
  used for both, all in-browser.
- Routine channel signing stays autonomous (validating-signer policy only).

## EVM side (the shared on-chain identity)
- `lpEth` (the on-chain identity that authorizes `openChannel` via `lpAuth`,
  receives proceeds, and triggers withdrawals) = a **family Safe** (n-of-m
  Gnosis Safe), NOT a single EOA:
  - `lpAuth` (the `openChannelDigest` signature the hop relays) is produced by a
    family threshold,
  - proceeds (`btcFeesOwedSats`, swap proceeds, splice-out payouts) accrue to the
    Safe,
  - withdrawals require the Safe quorum.
- One-channel-per-LP is unchanged: the shared Safe is **one** `lpEth`, **one**
  channel; capacity grows by splice, not a second channel.

## Hosting & provisioning (web-only — NO CLI)
LPs interact **only with the website**. There is no CLI in the normal path.
Three ways to get the SGX box, chosen on the site:

1. **Managed / auto-provisioned (default).** The LP (or family) clicks "host it
   for me" and the platform **auto-provisions** an SGX instance (cloud
   confidential compute) running the audited quid-hop LP image. The channel key
   is **born inside the enclave** — the platform never sees it. The site shows
   the attestation result (see the decision below) so the LP can confirm the box
   is genuine before funding.
2. **Self-host (explicit opt-out).** Only if the LP expressly says "I'll set it
   up myself" do they leave the managed path — then they pick their own hosting
   provider or run it on their own laptop. (This is the one path that touches a
   terminal; it's opt-in.)
3. **Family plan** = either of the above, but one shared box co-owned n-of-m by
   the members' browser wallets.

### Frontend flow — where the choice lives (⚠ NOT YET BUILT)
**Status:** this step does **not exist in the SPA today** — there is no enclave /
hosting / key-source choice anywhere in the open-channel flow. The backend it
would drive **is** wired: born-in-enclave (default boot) and import-over-RA-TLS
(`/provision` → `provision_seed`, the same path migration uses, e2e-green). What
is missing is the **frontend step + the managed auto-provision/payment service**.

Where it belongs in the execution flow (the order matters for custody):
1. **Open-channel intent** — the LP starts "provide BTC liquidity" on the site.
2. **Hosting choice** (this new step, BEFORE any key exists): **Managed** (we
   auto-provision) vs **Self-host** ("I'll set it up myself" → own provider /
   laptop). Family-plan: the n-of-m members + their wallets are named here.
3. **Key source** (only meaningful for self-host; managed is always
   born-in-enclave): **Born-in-enclave** (default) vs **Import** (custody
   downgrade — drives the RA-TLS `/provision` import; warn explicitly).
4. **Provision + ATTEST, BEFORE funding** — the box is provisioned and the LP
   confirms it is genuine. For managed, this is the attestation gate (see the
   open decision below): the LP must not fund until the box proves genuine, or a
   colluding platform+hop could take the 2-of-2. **The attest step MUST gate the
   transition from "box exists" to "fund the channel."**
5. **Authorize hosting (managed only)** — sign the `FamilyAuth{authorize-hosting}`
   rate (and, cold-start only, a stablecoin prepay). **No card.** The fee is then
   withheld from on-chain proceeds (see below).
6. **Fund + openChannel** — only now does the LP commit BTC; `lpAuth` is signed
   by the member wallet(s) / family Safe.

Build scope (not done): the steps-2/3 chooser UI, the managed auto-provision
service + its on-chain hosting-fee withholding (accrual + co-sign predicate +
redeem→USDC sweep), and the step-4 attestation surface
(whatever the attestation decision below resolves to). The self-host path needs
only docs + the existing `quid-provision` client; managed needs all of it.

### Paying for managed hosting — on-chain fee withholding (NO card, maximally trustless)
The LP **never gives a credit card and never actively sends a payment.** The
managed-hosting fee is **withheld from the LP's own on-chain proceeds** — value the
LP already holds/earns — so there is no card rail, no fiat-in, no PII, and no
money-transmission / card-acquiring exposure on our side. (This replaces an earlier
card / "accordion" sketch; see "Why not cards" below.)

**Mechanism (reuses existing fee machinery — little net-new):**
- **Accrue.** A per-LP `hostingFeesOwedUsd` accumulates against a published hosting
  rate, mirroring the existing trading-fee accrual (`Vault.btcFeesOwedSats`,
  `Vault.sol:170`, accrued at swap settlement). Accrual is **on-chain-visible**, so
  the LP can verify it — trustless, not trusted.
- **Consent once, up front.** The family pre-authorizes the rate via a
  `FamilyAuth{action: authorize-hosting, rateUsd, period}` k-of-n EIP-712 signature
  (same quorum primitive as withdraw/migrate). No per-charge approval.
- **Withhold at close/splice — enforced by signature, not trust.** The cooperative
  close/splice is a **2-of-2**, so the owed fee is settled by the same **co-sign
  predicate** already specified for LP fees (`BTC-LP-FEE-WITHHOLDING-FIX.md`): the
  tx must carry a fee output ≥ `hostingFeesOwedUsd` to a treasury key or the
  counterparty won't co-sign. No new on-chain machinery; `recordClose` delivery
  attribution is unchanged (separate fee output, like the BTC-leg fee).
- **Convert + pay the bill (pooled, no PII).** The bridge daemon redeems the
  withheld value **QUI 6909 → USDC** (`Aux.redeem`) and sweeps it to treasury — the
  same `lp_fees.rs` sweeper that already pays BTC-leg LP fees — and the platform
  pays ONE aggregate cloud bill for many LPs (the cloud provider sees the platform's
  account, not per-LP identities or amounts).

**Why this is maximally trustless + PII-free:** born-in-enclave key (platform never
holds it); wallet/passkey auth (no KYC, no email tied to the box); RA-TLS carries no
PII; and the fee is taken from on-chain value the LP **already owns**, is
**verifiable on-chain**, and is **enforced by the 2-of-2** — never a card, never a
fiat-in rail we operate.

**Cold-start (first fee, before proceeds accrue).** If an LP has no accrued proceeds
yet, it can **prepay the hosting fee in stablecoin** (QUI/USDC) from its own wallet
in the same provisioning flow (one signature) — still no card, still no PII.
Withholding-from-yield is the steady state; stablecoin-prepay is only the cold-start
fallback. (Cloud-bill timing vs. accrual cadence is an ops detail — a small prepaid
buffer / platform float covers the lag; it does not change the trust model.)

**Why not cards (accordion / Rain / Exodus — REJECTED).** An earlier sketch funded
hosting (and "approved-purchase" merchant spend) by collecting members' cards and
charging them through an "accordion," or via a card partner (Rain / Exodus-Baanx).
Dropped entirely: (1) it asks the user for a **credit card** — PII plus a fiat-in
rail we would have to operate; (2) charging collected member cards as a non-merchant
"hop" has **no legitimate doctrine** — a verified doctrine survey found the best fit
is card-network **factoring / transaction-laundering** (prohibited outright) plus
unexempted **money transmission**, with every exemption (integral-to-sale,
payment-processor, agent-of-payee, PayFac) collapsing; (3) it buys nothing the
on-chain withholding above doesn't already give us. The card layer is gone; managed
hosting is paid from on-chain value only.

### ⚠ OPEN DECISION — attestation verification when WE provision + run the hop
Auto-provisioning introduces a vector that self-hosting didn't: if the platform
provisions the box **and** runs the hop, then a *fake* enclave (host keeps the LP
key in plaintext) + the hop could **collude to spend the 2-of-2** and take the
LP's channel funds. The validating-signer policy only protects the LP if the
enclave is **genuine** — which requires the LP to verify attestation
**independently of the platform** (the platform serves the website, so "the site
says it's fine" is circular).

This is exactly the browser-verification question we previously set aside for the
*central hop* (correct-by-construction made it moot there) — but it is **live
again** for an LP's own provisioned box. Options:
- **(A) On-chain DCAP verification (recommended).** Publish the reproducible
  MRENCLAVE; an on-chain DCAP verifier (e.g. Automata) validates the box's quote;
  the site (and anyone) reads the verdict from chain — platform-independent, no
  in-browser crypto. The LP funds only after the chain confirms the quote +
  MRENCLAVE match.
- **(B) In-browser WASM DCAP verifier** against an RA-TLS quote fetched directly
  from the enclave — also platform-independent, but ships a verifier to the
  browser.
- **(C) Accept platform+hop collusion risk** for managed hosting (document it;
  self-host to avoid). Not recommended for a self-custody product.

## Withdrawal flow (no single member can drain)
1. k-of-n family sign a `FamilyAuth{action: withdraw, amount, dest}`.
2. The enclave verifies it (host-unforgeable) and executes a **splice-out** to
   the family Safe's BTC address (or members' addresses).
3. EVM settlement (`recordClose` / splice-out accounting) pays the Safe.

No single key (member, host, hop) can move funds; k-of-n is required end to end.

## Durability (lose a member OR the box, not the funds)
- **k-of-n redundancy**: up to `n−k` members can be lost/compromised; the
  position is still operable and unstealable.
- **Hot replication** (spec §11 layer 3): the enclave replicates its sealed seed
  (attested enclave→enclave) to a standby on another member's box, so a dead box
  → migrate, not stranded funds. Migration is itself k-of-n-authorized.
- **Cold floor**: optional one-time member-held encrypted backup.

## Trust summary
| Adversary | Defeated by |
|---|---|
| The host (whoever runs the box) | SGX (can't read key) + validating-signer (can't misuse it) + k-of-n for value |
| The hop | 2-of-2 + EVM correct-by-construction |
| Any single family member | k-of-n family quorum (LN admin) + Safe (EVM economics) |
| A dead box / lost member | hot replication + k-of-n redundancy |

## Implementation deltas (all extensions of what exists)
1. **LN**: rework `quid_hop::migration` from baked `ed25519 OPERATOR_PUBKEYS` to
   **Safe-based verification** — a generic action-tagged `FamilyAuth` (EIP-712),
   verified k-of-n via secp256k1 `ecrecover` against a **pinned Safe**'s
   owner-set + threshold (operator Safe and family Safe are the same code, a
   different pinned address). Includes the owner-set mechanism chosen above
   (A: state-proof, or B: sealed snapshot).
2. **EVM**: allow `lpEth` to be a Safe (it already only needs to produce the
   `lpAuth` signature + receive funds — a Safe does both); document the n-of-m
   onboarding. No new on-chain trust surface (EVM custody is already
   correct-by-construction).
3. **Web (NO CLI)**: the site drives everything — managed auto-provisioning of
   the SGX box, **on-chain hosting-fee withholding** (no card: accrue
   `hostingFeesOwedUsd`, withhold at close/splice via the 2-of-2 co-sign
   predicate, redeem→USDC and sweep pooled for privacy), and `FamilyAuth` signing
   as EIP-712 typed data in each member's
   browser wallet (the site collects the k-of-n signatures and submits the
   bundle to the enclave). The CLI path exists only for the explicit
   "I'll self-host" opt-out.
4. **Attestation**: implement the chosen verification path (recommended: on-chain
   DCAP + published reproducible MRENCLAVE) so an LP can confirm a managed box is
   genuine **without trusting the platform** before funding it.
