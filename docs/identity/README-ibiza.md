# ibiza

A fork of **Privacy Pools** and **rarimo/rarime**, merged onto one Foundry + Noir/Honk stack.

## Where the name comes from

Two sources, and both are load-bearing.

**The first is lineage.** `ibiza` was the name of an iPhone wallet for **lbtc.io** — Lightning
Bitcoin, a delegated-proof-of-stake chain — which the project still lists as
*iOS Wallet "Ibiza", iOS (v1.0.5), update date 2019.09.12*, offering "On-chain Wallet & Private Key
Support & Community Governance". It never reached users. The name is inherited from a wallet that
was designed, versioned, and never landed, which is worth saying plainly rather than quietly
reusing.

**The chain behind it never launched and the project was abandoned — but its vision is the one
[SPV](https://github.com/quidmints/SPV) achieves.** Lightning Bitcoin set out to be an internet-of-value protocol: fast, secure global
payments, with governance held by its participants rather than an operator. It tried to reach that
by launching a chain and a validator set, and it did not get there. SPV reaches it without either —
value moves against Bitcoin collateral rather than against a new consensus layer, so there is no
token to bootstrap, no validator set to distribute, and no chain that has to survive its own launch
in order for the payment to work. Taking the name is therefore a claim of succession rather than
nostalgia: the same goal, by a route that does not require the part that killed the original.

**And that is why this repo exists at all.** ibiza is not an end in itself — its primary purpose is
to generate demand for [SPV](https://github.com/quidmints/SPV). Private, permissionless settlement
with credible identity and screening is what people actually want to use.

This repo is the demand side, and should be read and prioritised as such: a decision here is right
when it brings more real usage to SPV, and merely interesting when it does not.

What SPV is and does, read in SPV — `spec.md` and `docs/FAQ.md`.

**The second is the metaphor, and it is the reason the name fits this repo specifically.** In
*It's All Gone Pete Tong*, the protagonist — a DJ — goes deaf, and afterwards produces a track called
**"Hear No Evil"** made entirely without using his ears. He gets there by approximating the sense
he lost through the ones he has left — feeling the music as vibration, reading lips. The substitute
channel carries enough of the signal to do the job, and the job gets done.

That is exactly what this system does with **see no evil, hear no evil, speak no evil**:

- **See no evil** — the pool settles a withdrawal without seeing whose it is. Validity is established
  without the operator observing the depositor.
- **Hear no evil** — the identity layer proves eligibility without listening to who you are. A
  passport is checked without the check reporting back which passport it was.
- **Speak no evil** — nothing on-chain says it. `holderRoot` is stored as a commitment, the notary is
  a set membership rather than an address, the citizenship check has its own selector bit so it
  cannot leak a national ID, and a withdrawal names no depositor.

That substitution is precisely what a zero-knowledge proof is. The pool cannot observe who is
withdrawing, so it takes the fact it actually needed — that the withdrawal is valid — through a
different channel. A proof is to observation what vibration is to hearing: not the original sense,
but enough of the signal to act on.

The film is not making a metaphor. It depicts a deaf DJ finishing a record, literally — the
metaphor is ours, drawn from it. And what it supports is not a story about deprivation:
**the track was good.** A system that cannot see,
hear, or speak about its users is not a degraded version of one that can; it reaches the same
result through a substitute channel, and it has to be judged on the result. That is the standard
this repo is held to, and it is why "privacy" here means the information is never acquired rather
than acquired and withheld.

`TODO.md` is the canonical tracker and holds current state, traps and open decisions. This file
answers the questions the tracker cannot: **where the code came from, why the fork was made the way
it was, and what we changed.**

---

## Why the two were merged at all

rarime proves **who you are** from a biometric passport. Privacy Pools proves **membership in an
association set** — that your deposit is one of a chosen subset — **without revealing which one is
yours**.

**Privacy Pools does NOT prove where money came from, and saying so inverts the design.** Nothing
about origin is proven or disclosed on-chain. A screening provider curates a set OFF-CHAIN, using
whatever analysis it likes, and the circuit proves only that your deposit lies inside it. The
property is **provable dissociation** — "I am one of these depositors, none of whom are the ones you
excluded" — which is weaker than provenance and deliberately so: it is what lets an honest user
distance themselves from tainted deposits without ever identifying their own.

Neither is sufficient alone for the thing this repo exists to build: a person who can prove
eligibility and hold value without those two facts being linkable.

Merging them creates one property neither had: **the identity that gates a withdrawal and the note
being withdrawn are bound in a single proof**, so an operator sees a valid withdrawal without
learning whose it is. Everything below follows from paying for that.

## Why ONE toolchain

The fork inherited **two proving stacks**: rarime's passport circuits in **Circom/Groth16**, Privacy
Pools' in **Circom** too but a different pipeline, with separate verifiers, separate trusted setups
and separate tooling. That is not a tidiness problem:

- **Two verifiers on the same withdrawal cannot share a proof.** A withdrawal that must check both
  identity and note membership pays for two verifications and two calldata payloads.
- **Groth16 needs a per-circuit trusted setup.** Every passport profile — **88 of them** — would be
  a separate ceremony. Honk needs a *universal* SRS instead: **one setup, already performed, shared
  by every circuit.** Not "no ceremony" — one instead of 88, and a public one rather than a vendor's.
- **A shared hash is required for the fusion to work at all.** The identity tree and the pool's
  commitment tree must agree on Poseidon, or a single proof cannot span both.

So everything was ported to **Noir + UltraHonk**: one prover, one verifier shape, no per-circuit
ceremony, and one Poseidon shared across circuits, Solidity (`poseidon-solidity`) and the wallet
(`@iden3/js-crypto`) — each cross-checked against the others rather than assumed compatible.

**Both migrations are now complete — zero `.circom` files and zero Groth16 verifiers remain.** All
17 Groth16-era per-passport verifiers were deleted along with the Circom entrypoints that called
them; every passport profile has a Noir twin, and all 88 are generated from a single bb 6.0 library
state (`NUMBER_OF_SUBRELATIONS = 31`, no UltraPlonk anywhere in the tree).

**What is still NOT complete is the WIRING, and it is a harder gap than the counting suggests.**
`Registration2.passportVerifiers` is empty: no deploy script, no migration, nothing calls
`updateDependency`. `_getPassportVerifier` reverts on zero, so **`registerViaNoir` — the only
entrypoint that verifies the ICAO chain — reverts for every document today.** The 88 verifiers are
correct, current, and bound to nothing.

Verifiers are bound by address at deploy time rather than by symbol, so a reference count cannot
distinguish a live verifier from an unwired one; that is exactly how an empty registry stayed
invisible. Each profile's registry key is now recorded in `backend/circuits/passport-profiles.json`
as `zk_type` — `keccak256("Z_NOIR_PASSPORT_" + profile)`, upstream's scheme — and
`test/registration/PassportVerifierRegistry.t.sol` binds the whole manifest through the real
owner-gated entrypoint to prove the set registers and resolves. **Do not read "one toolchain" as
finished end-to-end** — see `TODO.md` sec. 2.18gz.

### Where the verifier count comes from

We use rarimo's proving system. Their circuit design is a separate question, and we did not follow it.

| | stack | verifiers needed |
|---|---|---|
| Privacy Pools side | Noir / UltraHonk | 3 |
| rarimo passport side | Noir / UltraHonk | 88 |

Same proving system, 29x the verifiers. PP's circuits keep one shape for every user. rarimo bakes each
document's array lengths in as compile-time generics, so every combination of `DG1_LEN/EC_LEN/SA_LEN/N`
compiles to its own circuit, and each circuit needs its own verifier.

Most of what goes wrong on the passport side traces back to that one choice. The six orphan profiles
exist because `EC_LEN` is a compile-time constant. So does the `EC_LEN` hunt recorded in `TODO.md`, the
82 release artifacts we had to recover, the 7 we missed on the first pass, and the three profiles whose
verifiers needed roughly 33 GiB to build. PP runs on the same stack with three verifiers and no
manifest.

Size classes would cut this down. `TODO.md` sec. 2.18df has the measurement: the profiles compile to
five distinct circuit sizes, spanning 2^18 to 2^25, with 58 of them sharing 2^18. Merging within a
class costs nothing in proving time, since cost follows the padded power of two. Merging across
classes would make a common passport pay the worst case, 128x.

Depending on Noir's maturity is what this costs us. We patched a compiler ICE ourselves, and several
other sharp problems in `TODO.md` come from the same place, including proof formats that shifted
between `bb` versions.

### Who pays what

An earlier version of this section quoted `write_vk` figures as though a phone paid them. It does not.

| workload | who runs it | how often | cost |
|---|---|---|---|
| `write_vk`, which produces the verification key and the `.sol` verifier | us, at build time | once per circuit, already done | 337 MB at 2^18, around 33 GB at 2^25 |
| proving a withdrawal | the user's phone | every withdrawal | `withdraw_identity`, 44,176 gates, about 1.3 s on a desktop and 15 to 40 s on a Samsung A16 |
| proving a settlement batch | a batcher, on a laptop | per batch | the recursion tree — no node exceeds ~1.54M gates, so peak is **2.11 GB at any depth**, minutes, paid from PP's relay fee |

⚠️ **The batcher stopped being a server.** The flat aggregator this row used to describe — one 2^24
circuit, 12.7M gates, ~21.7 GB peak — was retired in `aa50335` once the recursion tree matched its gas
at a third of the memory and with no ceiling. Do not confuse its cost with the `write_vk` row above:
that one is real, was paid, and is unaffected.

The 33 GB was a one-time cost and it is already paid. It is why the build needs a 32 GB swapfile, set
up in `backend/circuits/build-passport-verifiers-docker.sh`. All 88 passport profiles and the 10 light
verifiers are done. It comes back only when a circuit changes.

Registration is where the on-device question sits. Withdrawal is 44k gates and fits a budget phone.
Registration proves `register_identity`, spanning 2^18 to 2^25, and the two 2^25 profiles will not run
on a phone under any proving system. That belongs to those circuits rather than to Honk, and size
classes would fix it.

Two things here are still unmeasured. Peak memory for `bb prove` on a 2^18 registration circuit, on
phone-class hardware, has never been recorded; what we measured is `write_vk`, which is a different
workload. Whether STARKs run on a phone has never been tested here at all. `TODO.md` sec. 2.18dg has
the detail. One experiment settles both: prove a 2^18 registration circuit on an A16 under each
backend and record peak RSS and wall clock.

### How the proving system was chosen

The trusted setup decided it. Groth16 wants a ceremony for every circuit. At 88 shapes that means 88
ceremonies, and in practice it means using rarimo's, because we cannot run that many. Honk uses one
universal ceremony shared across the ecosystem, which many parties have scrutinised, and whose
compromise would be a public event.

Stronger options exist and we passed on them. STARKs and Halo2 over IPA need no ceremony at all. They
lose on EVM verification, somewhere around 1 to 5M gas against a withdrawal budget already near 3.1M.
Halo2 with KZG sits closer to Honk, with a universal SRS and better recursion, and it lost on other
grounds.

Halo2 circuits are hand-written Rust against a low-level API. Noir is a language, and the `EC_LEN` work
in `TODO.md` was tractable because the circuit reads like code. There was also nothing to inherit. Our
migration was a port; rarimo publishes Noir circuits, and the passport shapes came across mechanically.
In Halo2 someone would author each one with no upstream to diff against. Barretenberg also ships
prebuilt AARs for on-device proving through `@rarimo/rarime-rn-sdk`.

So the question was narrower than which system is strongest. Which one verifies affordably on the EVM,
has a real language, proves on a phone, and lets us inherit circuits? Honk is the only one here that
answers all of it. Aggregation uses Honk recursion and needs a single level, which happens to be where
Halo2's accumulation would have paid off most.

### Verifier size and EIP-170

A Honk verifier runs about 10x the size of a Groth16 one. Measured on the same profile family: 18,430
bytes against 1,736. Verification gas is higher too. That is the price of the setup property above.

For a while 18 contracts sat over the 24,576-byte EIP-170 limit, and no verifier was among them.
`HolderStateKeeper` measured 53,431 bytes, `StateKeeper` 50,044, `PoseidonSMT` 38,374. State contracts,
all of them.

Our own Poseidon inlining caused it. An `internal` library gets copied into every call site, and size
tracked call-site count closely: `PoseidonSMT` had 2 and weighed 38 KB, `HolderStateKeeper` had 7 and
weighed 53 KB, around 3 KB per site. Inlining saves 4,186 gas per hash, which is 12%. An older note in
`TODO.md` claimed 91%. `test/libraries/PoseidonInlineGas.t.sol` pins both figures.

We reverted the inlining on 2026-08-04. Every contract now fits under the limit. A contract above
24,576 bytes cannot be deployed at all, so 12% on hashing was never worth it.

## Batching, dwell time, and yield

These three get discussed apart from each other. They are one decision.

Yield here comes from ETH that sits still. `SpvTreasuryAdapter` routes what its own NatSpec calls "PP's
otherwise-idle ETH" into SPV's Vogue LP. Its sweeps are timing-decoupled from user activity on purpose,
because moving funds in lockstep with individual deposits and withdrawals would turn Vogue's public
event stream into a side channel that reconstructs the deposit-to-withdrawal link. The yield base is
balance multiplied by time.

Fast round trips earn nothing. A user who deposits and withdraws inside one cycle leaves no idle ETH,
the sweep finds nothing to move, and the integration does no work. For a pool whose users mostly
round-trip quickly, yield was never going to pay.

Batching puts a floor under dwell time. A batched withdrawal waits for the batch to fill, and through
that wait the deposit stays in the pool and keeps earning. The gas saving and the yield come out of the
same mechanism.

That shifts the cost comparison. Latency usually counts as a straight loss set against cheaper gas,
186k per withdrawal batched at N=16 against 2,528,007 for a Honk single. If the wait pays yield, the
user gets something back for it. Making withdrawals instant and cheap, which is what the Groth16 hybrid
in `TODO.md` would do, removes the dwell floor and shrinks the yield base. The gas table does not show
that.

### Timing

The proof hides which note is spent. It cannot hide when. How much that matters depends on how busy the
pool is, and it is easy to overstate. An earlier draft of this section said a quick round trip leaves
"almost no privacy". Nothing here measures that, and it is likely false whenever other people are
transacting in the same window, since any of them could have made the withdrawal.

The conditional version holds up. Timing correlation is a real deanonymisation vector in mixers, and
its strength scales inversely with concurrent activity. In a quiet window where a deposit and a
withdrawal are the only two events, it bites. In a busy one it approaches nothing. We have no data on
this pool's traffic, and a user has less.

Batching makes the cohort deterministic. Sixteen withdrawals settle in one transaction sharing a
timestamp and a submitter. A busy pool might produce that by chance. Batching stops it depending on
chance. The anonymity set stays what it always was, which is the deposit tree.

Upstream Privacy Pools leaves waiting unenforced and unpaid. The protocol never asks, never says how
long, and gives nothing for it. Users who wait are the ones who worked out on their own that
withdrawing straight after depositing can identify them, so privacy ends up tracking what the user
already knows.

Here the batch enforces the wait, the yield pays for it, and the choice happens at deposit time.
Register interest when you deposit, or leave it open if you do not know yet, and you join a batch when
one forms. An immediate single withdrawal stays available to anyone who picks it deliberately.

What this is worth is unknown. In a busy pool the cohort would form anyway and batching adds little. In
a quiet one it separates sixteen simultaneous withdrawals from whatever happened to occur. Which regime
applies is a traffic question nobody here has answered.

One line on evidence. The gas figures come from `AggregationProofOnChain.t.sol` and
`VerificationCostComparison.t.sol` and are measured. The yield and timing arguments are rationale.
Whether batching lifts the yield base depends on how long users would have held anyway, and how much
timing decorrelation buys depends on real withdrawal patterns. We have neither dataset. Do not quote
them as established.

## Why aggregation was the first big piece

Gas: **a single withdrawal costs roughly 3.1M gas**, dominated by the in-circuit Honk verification.
That is not a product — it is a demo.

⚠️ **Treat that figure as approximate.** Three numbers (2.85M, 3.07M, 3.1M) appear across working
notes at different points of the optimizer work, and only ~3.1M is traceable to `TODO.md`. The
batched figures below ARE sourced. **Re-measure before quoting any of this externally.**

**Aggregation is the only structural answer.** One recursive proof attests to N withdrawals, so the
verification cost is paid once per batch instead of once per withdrawal:

| | gas / withdrawal |
|---|---|
| solo, no batch | 2,528,007 |
| batched, N=16 | 173,542 |
| batched, N=32 | 86,771 |
| **batched, N=64** | **43,385** |
| batched, N=128 | 21,692 |

**The cost per settlement is FIXED**, so per-withdrawal gas halves every time the batch doubles, and
the tree has no ceiling on N. That is a ~15× improvement at N=16 and ~58× at N=64.

**Nobody waits for sixteen.** The curve is steepest at the start — the 2nd person in a batch halves
the cost, the 16th shaves a couple of dollars — so a batch settles with whoever is there. Empty slots
pad to the next power of two, and settlement skips padding before the duplicate-nullifier check.

This is why the recursion tree, `BatchVerifierLib` and `PrivacyPool.withdrawBatch` exist. It also
forced the toolchain question: recursive ZK proofs need a Noir/bb combination that produces them
correctly, which is what drove the beta.26 + bb pin.

Other measured gas work along the way:
- **keccak batch commitment instead of Poseidon** — the N=16 aggregation circuit fell from
  **11,610,552 to 550,404 gates**, and the N=2 case from 1,396,874 to 81,668. The Poseidon variant's
  in-circuit verifications were **vacuous** — present in the gate count, absent in effect.
- withdrawal verifier size brought under the **EIP-170** 24,576-byte limit (24,534 → 23,527) with
  `optimizer_runs = 1` scoped to the verifiers. **⚠️ That constraint is probably obsolete now:** on
  the current toolchain the verifiers measure ~17,723 bytes with ~6,853 spare, so `runs = 1` — chosen
  for SIZE over execution cost — may be costing gas for nothing. Not yet re-tested (TODO.md).
- **root memo** in `withdrawBatch`: distinct state/identity roots are checked once per batch rather
  than once per withdrawal, which is exactly equivalent because a root's validity is a pure function
  of pool state.

## How we changed Privacy Pools' screening architecture, and why

**Upstream shape.** In Privacy Pools an ASP publishes an association-set root; a withdrawal proves
its label is in that set. One authority, one root, one predicate — and the ASP can publish a new
root omitting your commitment at any time after you deposited. Your private exit disappears an hour
later without anyone taking your money. **That retroactive lever is the property we changed.**

**What we are changing it to — and read this before the list.** The design is a **closed set of
independent predicates**, each with its own anchored source, rather than a single curated root.
**Every predicate must pass — they are conjunctive, and none is optional or per-deployment.**
**It is not wired to the pool yet.** The sanctions and notary pipelines are built as far as the
on-chain anchor and stop there: no deposit or withdrawal reads them, there is no blacklist
function, tree or root anywhere in the contracts, and admission to the association set is still a
trusted signature — a postman asserts it. So the retroactive lever described above is **documented
as designed away, not yet demonstrated away**. Treat this section as the target shape:

- **identity** — holder-rooted registration, proven once at escrow (`escrow_envelope`), with
  revocation as a status in the same tree rather than a separate authority
- **sanctions** — `backend/cre/sanctions_lists` anchors a declared sanctions list (US OFAC SDN,
  UK OFSI consolidated, UN Security Council; one per deployment) via
  `RegistrySourceAnchor.publishSnapshot`
- **notary** — `backend/cre/notary_registry` anchors a notary registry the same way
- **the original ASP chain-analysis set** — kept as a full predicate, not deleted

**Why that shape.** Two reasons, both structural rather than cosmetic:

1. **Anchored external authority instead of an operator's opinion.** Each source is scraped by a
   Chainlink CRE workflow where every DON node fetches the same export independently and must
   produce a byte-identical result before a report is generated. A single relayer could substitute a
   tampered snapshot; this cannot. That property is the entire justification for admitting a
   predicate into a set that is otherwise deliberately tiny.
2. **A closed set is auditable; discretion is not.** Anyone can enumerate what may be checked. The
   upstream design lets an ASP decide, per-root, in a way nobody can enumerate after the fact.

**What this does NOT yet achieve, stated plainly because the claim is easy to overstate:** the
retroactive lever is **reduced, not removed**. Turning the equality check into an append-only
`mapping(root => publishedAt)` would remove it — at the cost of making a genuinely tainted root
permanently unremovable — and that is a governance decision, not an engineering one. `IdentityRegistry`
is also UUPS-upgradeable, so the upgrade key can un-register people independently of any of this.
**Both are open decisions recorded in `TODO.md`; until one is taken, "this fork has no retroactive
third-party lever" is false.**

## Why "one key, many documents"

A person with two passports is the user this design exists for — and the naive shape leaks them.
If each document produced its own identity, holding two would be visible, and **multi-citizenship
makes the leak worse rather than better**.

So identity is **holder-rooted**: one key owns many documents, the holder root is what the pool sees,
and which document was used is not disclosed. That is what `HolderStateKeeper`, `HolderRegistration`
and the escrow envelope exist for, and why `register_identity` has TD1/TD3/light variants — the same
holder, different document formats.

## What we fixed in the rarime SDK and wallet

- **`@rarimo/rarime-rn-sdk`** provides Noir proving on-device via prebuilt AARs. We forked it to
  `quidmints/rarime-rn-sdk`; **PR #1 (merged 2026-07-27)** migrated it to the expo-file-system 57
  File/Directory API, which the package declared as a dependency while still calling the string-path
  API that version removed — consumers hit "undefined is not a function". It also fixed a path bug
  in `TrustedSetupFileName` and made the noir directory exist before bytecode is written.
- **Six `pp/` wallet modules could not be loaded by `node --test` at all** — type-only imports used
  as values, extensionless relative imports, and a TypeScript `enum` (which Node's strip-only mode
  refuses). That is why that directory had zero tests; all fixed, and it now has ~132.
- **Root-seed handling**: `revealRootMnemonic` / `exportEncryptedBackup` bypass the session cache and
  force re-authentication, because those two operations hand over the key rather than use it.
- **Fresh withdrawal recipients** derived from the same seed (`pp/recipient.ts`), so a payout address
  is never one the user funded — and never a key they must back up separately.

## Provenance map

| path | origin |
|---|---|
| `backend/contracts/contracts/pool/**` | **Privacy Pools** (`0xbow-io/privacy-pools-core`) |
| `backend/contracts/contracts/{certificate,passport,registration,state,sdk,utils}/**` | **rarimo** (`rarimo/passport-contracts`) |
| `backend/circuits/{pp,withdraw_identity,ragequit}` | Privacy Pools circuits, ported Circom → Noir |
| `backend/circuits/{register_identity*,query_identity*}` | **rarimo** (`rarimo/passport-zk-circuits-noir`) |
| `backend/circuits/noir_dl_lib` | **rarimo**, which itself vendors `noir-lang/noir-bignum` + `noir_bigcurve` |
| `frontend/identity-wallet` | **rarimo/rarime** wallet |
| `backend/circuits/{escrow_envelope,title_holder,notary_action}` + the generated recursion-tree levels | **ours** |
| `backend/contracts/contracts/{title,holder,pool/spv}/**`, `registry/RegistrySourceAnchor.sol` | **ours** |
| `backend/cre/**`, `tools/**` | **ours** |

**The fork was imported as ONE squashed commit** (`0762975`), so there is no upstream history to diff
against here. Everything since is divergence:

```sh
git diff --name-only 0762975..HEAD -- backend/contracts/contracts \
  | grep -vE 'verifiers2|Verifier\.sol'
```

As of 2026-08-02: **51 non-generated contracts**, 58 files in `noir_dl_lib`, 3 rarimo circuit files,
62 in the wallet. **We are a heavily modified fork, not a thin skin. Do not assume any upstream file
is untouched.**

## Changes to upstream code whose consequences exceed their diff

### `noir_dl_lib` (rarimo → vendoring noir-bignum / noir_bigcurve)

Ported to nargo 1.0.0-beta.26; full detail in `backend/circuits/NOIR-DL-PORT.md`.

- **`u1` → `Field` at the BOUNDARY, not throughout.** `to_le_bits` now returns `[bool; N]`;
  substituting `bool` library-wide was tried and reverted, because the library does arithmetic on
  those bits and it meant editing modular-arithmetic and hash expressions. One conversion at each
  bit source keeps every algorithm body byte-identical.
- **`.eq()` disambiguated to `BigNumTrait::eq`.** `std::cmp::Eq` compares limbs; `BigNumTrait::eq`
  compares modular values. They differ for unreduced representations — the other choice would have
  compiled and been silently wrong.
- **22 `global … = BigNumParams::new(..)` became `pub fn`** — an ACCOMMODATION for a Noir compiler
  bug, **to revert when the fix ships upstream.** Zero measured gate cost.
- **`sigver/curve_384.nr` deleted** — a second, never-wired Brainpool P384R1 under a secp384r1 name.
- **Dependency pins bumped** (`sort`, `poseidon`, `sha256`); all were stale against beta.26.
- **⚠️ `ScalarField::from_bignum` carried the vendor's own `// TODO: NONE OF THIS IS CONSTRAINED
  YET. FIX!`** on the ECDSA scalar decomposition. See `TODO.md` — this is the most serious thing in
  the repo's history and was found by reading the file, not by any tracker.

### `noir-lang/noir` itself

A 3-hunk ICE fix (`backend/circuits/noir-ice-repro/noir-fix.patch`) with a 14-line reproduction.
Not vendored; the built compiler is local. See **Toolchain** below.

### Privacy Pools Solidity

Additive, but they change the contract surface:
- `withdrawBatch` + `MAX_BATCH` + batch errors, with `BatchVerifierLib` / `BatchCommitmentLib`
- `AGGREGATION_VERIFIER` as an immutable constructor argument — it was previously **declared, read,
  and never assigned**, so batching was unreachable
- `DeployLib` gained actual deployment functions; it previously held salts and nothing else, so no
  pool was ever constructed outside a test

---

## Toolchain (read before generating any artifact)

**`nargo` is a LOCALLY PATCHED beta.26** reporting `1.0.0-beta.26+quid-icefix1`. The suffix is
load-bearing: an unmarked patched build is indistinguishable from the release and would slip past
`codegen-verifiers.sh`'s guard. **CI and other developers will fail that guard, correctly** — the
circuits still build on stock beta.26, which is why the accommodation above was kept.

- stock binary: `~/.nargo/bin/nargo.beta26-release.bak`, or `noirup --version 1.0.0-beta.26`
- **`bb` 6.0.0-nightly must be on PATH**: `cd backend/circuits && npm install && export PATH="$PWD/node_modules/.bin:$PATH"` (pinned in `backend/circuits/package.json`; it is an npm package, not `bbup`)
- artifact generation is a **5-step pipeline**; `codegen-verifiers.sh` is step 4 and
  `tools/prove-escrow-fixtures.sh` is step 5. Skipping step 5 produces `SumcheckFailed()` far from
  the cause.
- **regenerate only what changed** — re-proving unchanged circuits is churn, and `title_holder`
  currently fails when re-proved (TODO.md).
- **not covered by the script:** the recursion tree, whose leaf and level circuits are generated on
  demand by `build-recursion-tree.py` rather than checked in. The 88 `NoirRegisterIdentity_*.sol` have
  their own generator, `build-passport-verifiers-docker.sh`, because five of them need a 2^25 CRS
  and cannot be built natively on macOS.
