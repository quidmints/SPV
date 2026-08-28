# TODO — open items only

Everything here is UNDONE. Completed work, superseded designs and the evidence behind both live in
`TODO-ARCHIVE.md`, which is unchanged and is still the authority for *why* a thing is the way it is.
Each section below cites its archive line so the reasoning is one jump away.

⚠️ **Sections are kept only where an item is still open.** A section's absence here means it is done
or superseded, NOT that it never existed - check the archive before concluding anything is missing.

---

## Live now — opened or reopened 2026-08-13..15, not yet in the numbered scheme

### ⚖️ TRIAGE — order this work by whether a wrong outcome is PROVABLY WRONG AFTERWARDS

Derived from the UMA/Polymarket failure. Attacker payoff scales with what is being decided; defender
payoff is fixed. No quorum size fixes that. **What separates a safe mechanism from an unsafe one is
not the incentive, it is whether a bad outcome can be CONTRADICTED BY EVIDENCE after the fact.**
Ranked by size of the un-contradictable surface:

| # | predicate | ground truth | external claim surface |
|---|---|---|---|
| 1 | **non-association** (`label ∉ tainted`) | **the chain itself** - propagation is deterministic and anyone can recompute it | **only the SEED set**, and it is small |
| 2 | **sanctions non-membership** | the published register - anyone can rebuild the leaves | the whole register, but public |

⇒ **Build in that order.** (1) has the smallest un-contradictable core of anything here and needs NO
CRE at all beyond anchoring a small seed - which makes it a better first target than the sanctions
work I had queued ahead of it.

⛔ **OUT OF SCOPE, ENTIRELY** (owner, 2026-08-24: *"ignore everything related to court/jury and the
monarchy stuff completely"*). Removed from this file: the sortition port, `court.sol`, the secret
ballot, and modularising `iran-constitutional-monarchy`. **Do not re-derive them** — the reasoning
survives in `TODO-ARCHIVE.md`, and the two ranked rows above are all that is left of the table.
⭐ **AND DROPPING THEM SIMPLIFIES THE DESIGN RATHER THAN LEAVING A HOLE, which is worth stating so
nobody re-adds an adjudicator to fill one.** The question those items existed to answer was *"who
rules on a disputed transcription?"* — and the answer, once you stop looking for a venue, is
**nobody, because a wrong transcription is contradictable by anyone.** The full leaf set is on-chain
calldata plus an event, the source is public, and `_computeRoot` derives the root on-chain, so
rebuilding the snapshot and showing the mismatch needs no standing, no panel and no ruling. **The
remedy is publication, not adjudication.** ⇒ Removing Court removes an authority; it does not leave
a gap where one used to be.


- [x] ✅ **Non-association predicate — LANDED on the single-withdrawal path.** `label ∉ tainted`, proven
      in-circuit as an eighth public signal. The PP paper's EXCLUSION branch, where 0xbow deployed
      membership. Third use of `smt_verifier_full`: identity uses `fnc=false`, this uses `fnc=true`.
      * The taint root is SUBSTITUTED by `PrivacyPool`, never read from the proof - a prover-supplied
        root would let them prove exclusion from an empty tree of their own and make it vacuous.
      * `taintRoot = 0` means EMPTY, and empty admits everyone: the bootstrap and the fail-open
        failure mode in one. Proven feasible first by
        `smt::test_exclusion_against_an_empty_tree_is_the_zero_witness`, which is what made the
        committed fixtures updatable with zeros instead of needing a taint tree built first.
- [ ] ⭐ **ONE BLACKLIST, ONE PREDICATE — the tree exists, the wiring rides with the batch
      regeneration** (owner, 2026-08-24: *"it's one predicate: proof of not on any blacklist of any
      kind, chainalysis, or identity related (in any country's blacklist, not just OFAC), but we
      don't have to check every country, just based on the passport"*).
      ✅ **LANDED: `pp/src/blacklist.nr`**, 4 tests, 93 in the package. Domain-separated keys over ONE
      tree — `DOMAIN_LABEL` (chainalysis/association taint), `DOMAIN_ADDRESS` (what upstream PP
      checked, and ONLY that), `DOMAIN_DOCUMENT` (sanctions, keyed by `document_identifier(issuing
      state, document number)`).
      🔑 **WHY ONE TREE RATHER THAN THREE.** `withdraw.nr` used to say sanctions would be *"the same
      call again against a DIFFERENT tree — one proof shape, three predicates"*. Three trees is three
      roots to anchor, three publication paths, three activation windows, and three ways for one to
      go stale unnoticed. **One tree is one root, one anchor, one window — and adding a source
      becomes a DATA change, not a code change.**
      ⭐ **WHICH IS WHAT MAKES "ANY COUNTRY, NOT JUST OFAC" FREE: the SOURCE IS NOT PART OF THE KEY.**
      A listing is a listing, whoever published it. OFAC, the UN consolidated list, OFSI and any
      national register coexist in one tree and no circuit, contract or client learns which.
      ⭐ **AND THE HOLDER NEVER ENUMERATES.** They prove absence of THEIR OWN key, so a tree holding
      fifty countries is proven against with exactly the same single witness as an empty one.
      *"Just based on the passport"* is not a scoping rule to implement — **it is a property of the
      shape**, and that is the elegance.
      🔴 **DOMAIN SEPARATION IS LOAD-BEARING.** A passport number and a pool label are both `Field`s;
      without a domain in the preimage a sanctioned document number could collide with an innocent
      label and blacklist it — a false positive nobody could explain and the holder could not appeal,
      because the tree would be CORRECT. Pinned by `domains_do_not_collide`. The issuing state is
      likewise part of the identifier, not context: numbers are unique only within an issuer.
      🔴 **THE REMAINING WIRING IS ONE ATOMIC CHANGE — IT CANNOT BE SPLIT, AND IT CANNOT START UNTIL
      `bb` IS BACK** (owner, 2026-08-24: *"they should be one thing"* — correct, and the blast radius
      is why).
      **Everything below moves together or the tree is broken in a way that only shows at proving
      time:**
        1. `withdraw.nr`: taint key becomes `blacklist_key(DOMAIN_LABEL, w.label)`. **Changes the
           constraint system** ⇒ invalidates `WithdrawalHonkVerifier.sol`.
        2. `build-recursion-tree.py`: `PUB_LEN` **7 → 8** (the leaf folds `2 x 7` and the withdrawal
           has carried 8 signals since the taint root landed) ⇒ invalidates
           `TreeRoot8/16/32HonkVerifier.sol`.
        3. `BatchCommitmentLib.PUB_LEN` **7 → 8** — must equal (2) exactly.
        4. Rename `taint_root` → `blacklist_root` through `withdraw.nr`, `ProofLib`,
           `PrivacyPool.taintRoot`/`setTaintRoot`, the wallet and the tests. Positional, so no ABI
           risk; it is the SEMANTICS that moved — "taint" names one domain and the root now spans
           three.
        5. Regenerate **four of the five checked-in verifiers** — `WithdrawalHonkVerifier`,
           `TreeRoot8`, `TreeRoot16`, `TreeRoot32` (only `RagequitHonkVerifier` is untouched).
      ⛔ **WHY A PARTIAL LAND IS WORSE THAN NO LAND: THE VERIFIERS ARE CHECKED IN.** They are Solidity
      files in `contracts/pool/verifiers/`, not build artifacts — so shipping (1)–(4) without (5)
      leaves the contracts computing a commitment the deployed verifier cannot match. **Nothing
      reverts at compile time and nothing fails a Solidity test; it fails when someone tries to
      prove.** That is the exact shape of failure this repo's rules exist to prevent, so **do not
      land any prefix of this list.**
      ✅ **CORRECTION — `bb` IS INSTALLED AND WAS ALL ALONG.** I ran `which bb`, got nothing, and
      called it a blocker. It is an **npm package, not a PATH binary**, which
      `codegen-verifiers.sh:51` states outright: *"bb 6.0.0-nightly — an npm package, NOT bbup"*.
      It lives at `backend/circuits/node_modules/.bin/bb`, pinned in that directory's
      `devDependencies`, and reports **6.0.0-nightly.20260804** — the exact `REQUIRED_BB`. ⇒ **Invoke
      it by path.** Same mistake shape as the capability search: absence from where I looked, read as
      absence.
      ▶️ **AND ONE PART IS BLOCKED BEYOND THE TOOLCHAIN:** the `DOMAIN_DOCUMENT` term needs the
      identity leaf BOUND to a document nullifier (sec. 4's *"bind the leaf to a document nullifier
      (trap 6), not to `sk_identity`"*), or a prover names any clean document and the term is
      vacuous. `DOMAIN_ADDRESS` needs nothing extra once (1) lands — same call, different domain.

- [ ] 🔴 **The BATCH path does not carry it — and the cause moved, so re-read this before acting.**
      The item used to name `aggregate_withdrawals`; that circuit was **deleted in `aa50335`** when the
      flat aggregator was retired for the recursion tree. **The gap survived the migration intact**,
      because the tree inherited the same width: `build-recursion-tree.py:127` generates a leaf that
      *"pins `withdraw_identity` and folds 2 x 7 signals"*, and `BatchVerifierLib.PUB_LEN` is still
      **7**. So a batched withdrawal still bypasses non-association.
      Closing the path was tried once and REVERTED: it deleted the guard coverage (nullifier reuse,
      context binding, proof rejection) and traded a known gap for untested code.
      ⇒ Widen the LEAF template in `build-recursion-tree.py` to EIGHT signals, regenerate every level
      and the `TreeRoot{8,16,32}` verifiers, and widen `PUB_LEN` in both batch libraries — **before
      enabling batching on a pool with a non-empty taint root.**
- [ ] Anchor the taint root: seed set + deterministic propagation, and a setter path from the
      registry. `setTaintRoot` is entrypoint-gated and defaults to 0 (empty).
- [ ] 🔴 **`setForwarder` IS THE UNGUARDED TWIN OF `pinWorkflow`, AND IT IS THE TOTAL BYPASS**
      (owner, 2026-08-16: *"what about what was there removing the point also"* — checked, and it
      does). §2.15a's four mitigations ALL landed on the workflow axis: `pinWorkflow` is append-only,
      REFUSES a re-pin of the same id (`WorkflowAlreadyPinned`, so a contested version cannot be
      quietly re-armed), carries `WORKFLOW_ACTIVATION_DELAY = 24 hours`, and fails open to its
      predecessor. **`setForwarder` got none of them**: `onlyRole(OWNER_ROLE)`, no timelock, not
      write-once, effective in the same block.
      ⇒ The surviving path is one transaction: re-point `forwarder` at an EOA, then have it call
      `onReport` citing the genuinely pinned workflow id, with any root. The contract concedes it
      cannot see this (`:187-190`): *"what this contract cannot tell is WHICH address it was given,
      so the guarantee is conditional on `setForwarder` having been pointed at the genuine
      deployment."* Friction is `ForwarderSet` firing plus `ROOT_ACTIVATION_DELAY = 1 hour`.
      ⚠️ **So `notary_registry/main.go`'s claim — *"no single operator can substitute a tampered
      registry snapshot"* — is NOT what the code enforces.** It enforces "not without emitting an
      event and waiting an hour". That is detection where prevention is claimed, and it means the
      multi-node DON story is capped by a single owner key regardless of how many nodes fetch.
      ⇒ Either timelock `setForwarder` to match `pinWorkflow`, or make it write-once, or verify DON
      report signatures so the forwarder address stops being the whole trust boundary (the last is
      already booked separately, sec. 4 *"Verify DON report signatures in RegistrySourceAnchor"*).
      **Until one of those lands, do not repeat the no-single-operator claim in any document.**
- [ ] 🔴 **SCRAPER ROT IS UNCOVERED, AND THE PASSPORT BINDING DOES NOT COVER IT — THE DEPENDENCY RUNS
      THE WRONG WAY** (owner, 2026-08-16: *"no mpc tls, the scraper rot must be handled by the DON
      being ran as an authorised workflow"* — the workflow half is right; this is the half it leaves
      open). **DECISION RECORDED: no MPC-TLS, no TLSNotary.** §2.15a's authorised-workflow machinery
      is the answer to a rogue workflow and it is built: append-only pin, same-id re-pin REFUSED, 24h
      delay, fail-open, and `onReport` checks the report against the active pin.
      ⚠️ **But it does nothing about a parser that is wrong the same way on every node**, which is the
      failure §2.15a itself named and never closed. The intuition that passport-registered notaries
      supply the cross-check DOES NOT WORK AS WIRED: `TitleLedger.registerNotary` takes
      `registryProof_`, *"Merkle proof of `notaryDataHash_` in that snapshot's active root"*, so
      **snapshot membership is a PRECONDITION of registering**. A notary the parser dropped cannot
      register at all, so she cannot create the contradiction that would expose the drop. The
      identity check sits DOWNSTREAM of the membership check; for a cross-check it must sit beside it.
      ⇒ **Admit a passport-proven CLAIM without the Merkle proof**, in a pending state carrying NO
      notary authority: prove control of `holderRoot` (`pp::title_holder` with a bind context, the
      mechanism `registerNotary` already uses) and name the claimed `notaryDataHash_`. Absence of
      that hash from the active root is then a PUBLIC ON-CHAIN CONTRADICTION instead of silence.
      Fail-closed on authority, fail-loud on the discrepancy — the rule-3 inverse exactly: the check
      earns its place because the failure it catches is otherwise invisible.
      ⚠️ Watch the privacy interaction before building: sec. 2.18am made the notary anonymity set
      load-bearing, and `_notaryTree` replaced two mappings *because they were ENUMERABLE*. A pending
      claim that names a register entry in the clear re-opens exactly that. The contradiction must be
      provable without publishing the claimant's entry — settle this first, it is the hard part.
      ✅ **SETTLED 2026-08-24, AND THE ANSWER IS THAT IT CANNOT BE BUILT AGAINST THE CURRENT ROOT.**
      Proving "my entry is ABSENT" without naming it is a non-membership proof, and
      `RegistrySourceAnchor._computeRoot` cannot support one. Both halves checked in the code:
        * **leaves ARE strictly sorted** — `leaves_[i_] <= leaves_[i_ - 1]` reverts
          `LeavesNotStrictlySorted`, so an ordering exists at the leaf level;
        * **but internal nodes use `_hashSortedPair`** (`a < b ? H(a,b) : H(b,a)`), which is
          COMMUTATIVE, so a proof path does not reveal whether a sibling sat left or right.
      ⇒ **Bracketing is therefore unsound**: you can prove a leaf is IN the tree, but you cannot
      prove two leaves are ADJACENT, and adjacency is the whole content of a sorted-tree absence
      proof. The commutative hash destroys exactly the positional information the proof needs.
      🔗 ⇒ **THIS IS DOWNSTREAM OF AN ITEM ALREADY BOOKED FOR THE SANCTIONS WORK — one change serves
      both.** *"CRE publishes the identifier set as a Poseidon SMT keyed by the leaf hash, not a
      sorted list"* is the prerequisite; an SMT gives non-membership by construction, and it keeps
      the dedup that `LeavesNotStrictlySorted` currently provides (one leaf per key, structurally).
      **Do the SMT root first. The pending-claim path is not independently buildable.**
      ✅ **THE TRANSPORT FOR IT NOW EXISTS AND IS TESTED — the ROOT itself is still uncomputed**
      (`6aadf74`, 2026-08-24). `RegistrySourceAnchor.onReport` decodes `(registryId, smtRoot,
      leaves)` and the workflow packs all three; `report_test.go` reads the `.sol` and compares its
      decode tuple against `snapshotABI`, so the pair cannot drift again.
      ⛔ **AND IT HAD ALREADY DRIFTED, INVISIBLY, BECAUSE OF A BUILD TAG.** The contract grew the
      third field while the workflow kept packing two — **every report would have reverted on-chain**
      — and the host-arch `go test` reported `ok` throughout, because `main.go` is `//go:build
      wasip1` and was **excluded from compilation entirely**. Same shape as SPV's *"a green suite is
      what an uncompiled crate produces"*, reached through Go build tags instead of cargo. The ABI
      now lives in an UNTAGGED `report.go` so a developer-machine test can see it at all.
      🔴 **WHAT IS PUBLISHED TODAY IS ZERO, AND FOR AN EXCLUSION PREDICATE THAT IS FAIL-OPEN.** An
      empty tree admits EVERYONE: until a real root lands, the blacklist term in `withdraw_identity`
      is satisfied by every prover, sanctioned included. It is consistent with the 32 batch witnesses
      (empty-tree zero witness, valid for any key by construction) and is a bootstrap state, not a
      design. **Two ways to close it and exactly one must be chosen — do not leave both open:**
        (a) publish a real root here, or
        (b) make `PrivacyPool` REJECT a zero `blacklistRoot`, so an unpublished list BLOCKS
            withdrawals instead of waving them through.
      ⚠️ **(b) is the safer default and it is NOT free: the 32 batch fixtures carry `blacklist_root =
      "0"` and would all need a real root.** That is the cost of the choice, not an argument against
      it. `TestUnpublishedSmtRootIsTheEmptyTree` pins the zero so whichever way this goes is a
      deliberate edit to an asserted value.
      ✅ **THE PREDICATE IS NOW WHOLE AND ENFORCED — 484/484 (2026-08-24).** The identity leaf binds
      its document (`Poseidon(revocation_secret, document_id)`, the identifier read from the MRZ
      in-circuit), so the sanctions term is no longer satisfiable by naming a stranger's clean
      passport; the batch path COMPARES `s[7]` against pool state, which it never did — widening the
      leaf to eight signals made the signal exist without making it true, and an unchecked signal
      reads as coverage where the old gap at least announced itself; and every fixture now proves
      against a POPULATED tree, where all 32 previously carried the empty-tree witness that verifies
      for any key, so the exclusion branch had never once been exercised.
      ✅ **THE CENSORSHIP LEVER IS CLOSED — the pool PULLS its root from the anchor** (`8df5855`,
      2026-08-24). `setBlacklistRoot`, the `blacklistRoot` field and `BlacklistRootSet` are deleted;
      `PrivacyPool` reads `latestActiveSmtRoot` from an **immutable** `RegistrySourceAnchor`, which is
      append-only, ownerless and fed by a DON through a timelocked forwarder — the same shape that
      already bounds `IncorrectASPRoot`. **Refusing zero was never the fix**: it closed the fail-open
      hole and refusing to re-zero removed the cost-free halt, but ONE ADDRESS STILL CHOSE THE VALUE,
      and a root nobody holds a witness against halts every withdrawal. The SOURCE is immutable for
      the same reason — a settable source is a settable root wearing one more layer.
      ⚠️ **WHAT THIS STILL DOES NOT BUY, and it is inherent rather than fixable here:** liveness now
      depends on the feed having published once and the activation delay having elapsed. A stalled
      feed keeps the last ACTIVE root rather than emptying it, so staleness admits a newly-listed key
      and never everyone. That is a property of gating on a rotating root at all.
      ⛔ **`test_NoGovernanceLeverCanBlockAWithdrawal`'s enumeration is now true again** — it had been
      false since `setBlacklistRoot` landed, and nobody noticed until this thread.
      ▶️ **`DOMAIN_ADDRESS` IS DERIVED AND LISTED BUT NEVER PROVEN.** The fixture's listed set
      includes a sanctioned address key, and `blacklist.nr` defines the domain, but no circuit term
      queries it — a withdrawal proves its LABEL and its DOCUMENT are absent, not its recipient.
      Adding it is one more `smt_verifier_full` call against the same root plus four witness fields;
      the open question is WHICH address a withdrawal should be judged on (`processooor`, the
      relayer, or the payout recipient), and that is a design decision, not a coding one.
      ▶️ **THE REGENERATION SEQUENCE IS NOW A COMMITTED SCRIPT: `tools/regenerate-fixtures.sh`.**
      Every chain in it was reconstructed by hand at least once during 2026-08-24, and one
      (`withdraw_e2e.proof`) could not be reconstructed at all until an emitter was added. Order is
      load-bearing — identity leaves are escrow PROOFS' public inputs, so a leaf-construction change
      invalidates everything downstream, and rebuilding out of order yields artifacts that verify
      individually and cannot settle together.
      ⚠️ **AND ONE THING IN IT CANNOT BE MADE CONSISTENT: each recursion tree needs a witness set
      generated at ITS OWN count.** Padding lives in the WITNESSES (`--count 5` pads to 8 with three
      zero-value members; `--count 32` is 32 real ones), so `batch-witnesses/` cannot simultaneously
      reproduce n8, n16 and n32. It is left holding the 32-member set, which is what the repo tracks
      — meaning a fresh checkout can rebuild n32 and will silently rebuild n8 WITHOUT padding.
      `test_APaddedBatchReproducesItsRoot` is the only thing that catches that.
      ✅ **THE SMT BUILDER IS DONE AND PROVEN — `sanctions_lists/smt.go`** (2026-08-24). Poseidon from
      `iden3/go-iden3-crypto` (audited, and it BUILDS FOR `wasip1`, which was the gating question).
      The convention is copied from `SparseMerkleTree._getNodeHash`, not chosen: leaf =
      `Poseidon(key, value, 1)`, branch = `Poseidon(left, right)`, empty subtree = 0, bit `depth` of
      the key LSB-first.
      ⭐ **THREE LANGUAGES ARE PINNED TO ONE NUMBER, and two independent checks do it:**
      `TestPoseidonMatchesTheCircuit` compares Go's Poseidon against a value **the Noir circuit
      accepted** (`document_identifier` for identity 0, as solved by `nargo execute`), and
      `TestSmtRootMatchesTheSolidityTree` compares a Go-built root against one a **real solarity
      SparseMerkleTree** emitted over the same entries.
      ▶️ **Both falsified before being trusted:** changing the leaf's trailing `1` and reversing the
      bit order each make the conformance test fail. A convention mismatch does not error — it yields
      a different-but-valid root, every exclusion proof fails, and the search starts in Noir.
      🔴 **BUT IT IS NOT CALLED, AND THE BLOCKER IS THE INPUT RATHER THAN THE WIRING.** The predicate
      keys on `blacklist_key(DOMAIN_DOCUMENT, document_identifier(issuing_state, document_number))`,
      and `ListedSubject` carries **`Reference`, `Kind`, `NameParts` — no document number and no
      issuing state.** No source parser extracts them; OFAC SDN publishes them in `idList` and each
      other source has its own schema, so this is per-source parsing work.
      ⛔ **DO NOT CLOSE IT BY PUBLISHING A ROOT OVER THE NAME LEAVES.** It would compute, anchor, and
      look published while **every exclusion proof still succeeded** — the circuit queries keys that
      tree does not contain. That is strictly worse than the zero it replaces: zero HALTS withdrawals
      loudly (the pool refuses it), whereas a name-keyed root passes silently while listing nobody the
      predicate can see. This is the §VACUOUS-BOUNDS shape arriving through a data feed.
      ⇒ **AND THE REMAINING ITEM IS NARROWER THAN "A PARSER" — HALF OF IT IS ALREADY BUILT AND
      UNWIRED** (surveyed 2026-08-24 against `testdata/ofac_ids_excerpt.xml`, the real export).
      `identifiers.go` already declares `IdentifierSet{Path, TypeField, ValueField, TypePrefix}`,
      already walks the NESTED `sdnList/sdnEntry/idList/id` the row parser cannot see, and already
      normalises per chain — folding case for hex chains only, because XBT/TRX/XMR/LTC/BCH are base58
      or bech32 where **case is significant and `ToUpper` silently corrupts the address**. Its header
      reaches the same conclusion this row did independently: a name-keyed tree is *"TRUE FOR
      EVERYONE"*. `decodeIdentifiers` is **not called from `main.go`.**
      ▶️ **DOMAIN_ADDRESS is therefore the SHORT path, and it has a real feed:** the excerpt carries
      **137 `Digital Currency Address - TRX`**, plus XMR and XBT, and the type string is a prefix
      match that already admits `- ETH`. What is missing is Poseidon keying (`identifierLeafHash` is
      keccak, for the anchor's dense tree — a different tree), the wiring, and the circuit term.
      ✅ **BOTH NORMALISATIONS ARE DONE AND PINNED BY MEASUREMENT — `documents.go`** (`398b738`).
      `Egypt`→`EGY` via a table seeded from the feed, and `1084010`→`1084010<<` in the MRZ's
      nine-character `<`-padded field. The expected identifier was computed by the WALLET's Poseidon
      over a TD1 DG1 at the offsets `td1_dg1_data_extractor` reads, and that derivation is itself
      pinned to the circuit — `nargo execute` solves the escrow witness only when the two agree — so
      the padding rule is now fixed across **three** languages. Falsified before being trusted:
      dropping the padding, and padding with spaces, each fail the conformance test. Over-length
      numbers are refused rather than truncated; `IdentifierSet` gained the optional `CountryField`;
      verified end to end against `testdata/ofac_ids_excerpt.xml` (4 rows, 3 keyed, 1 skipped).
      ⚠️ **AND THE EXPORT CARRIES A PASSPORT WITH NO ISSUING STATE** (its `idNumber` is `19820215`,
      a date). It cannot be keyed — the key takes both arguments — so it is skipped and **counted**.
      For an exclusion predicate a dropped listing is a FALSE NEGATIVE, and failing the whole
      publication over one unmappable country halts every withdrawal instead. Neither is free, so
      omissions are made countable rather than silent. **That count is not yet surfaced anywhere the
      operator sees — booking it here rather than calling the trade-off handled.**
      ✅ **THE WORKFLOW NOW PUBLISHES A REAL ROOT** (`4312e5a`, 2026-08-25). Passport rows are decoded
      from the same body as the designations — one fetch, one consensus round — keyed, and the
      Poseidon root is anchored. Skips are surfaced at WARN every run with a reason per row, which
      closes the "not surfaced anywhere" item above; a source that declares identifiers and keys NONE
      of them now fails loudly, because that is a schema change and an empty exclusion tree admits
      everyone.
      ⛔ **AND THE OBVIOUS SIMPLIFICATION IS A SILENT REGRESSION — BUILT, MEASURED, REVERTED, AND
      RECORDED SO IT IS NOT RE-ATTEMPTED.** Making the anchored leaves BE the keys gives one dataset,
      makes the calldata the SMT's preimage, and deletes a name tree no predicate can consume. It
      reads as strictly better. **`UK_OFSI_CONSOLIDATED` and `UN_SC_CONSOLIDATED` publish no document
      numbers at all**, so both registries would have anchored an EMPTY leaf set and a zero root
      while still reporting success.
      ⇒ **The two trees cover different POPULATIONS, and that is the whole reason there are two:**
      `leaves` is every designation (transparency, keccak, derived on-chain); `smtRoot` is only the
      designations the predicate can key (Poseidon, asserted). A name tree cannot be consumed by a
      predicate, and a key tree cannot represent a register that publishes no keys — **both are true
      at once.** The asymmetry is real, not drift.
      ⚠️ **The SMT root is ASSERTED, not derived, and that is forced rather than lax:** deriving it
      on-chain is Poseidon at list scale, ~494M gas against a 30M block (measured). Verifying it means
      rebuilding from the public source — which is what an auditor does to check the leaves are honest
      anyway, so the marginal loss is small.
      🔴 **WHAT IS STILL NOT ENFORCED, and it is now the honest gap:** only OFAC declares an identifier
      set, so **UK and UN designations are anchored and contribute NOTHING to the predicate.** A
      sanctioned person listed only by those two registers passes the check. Closing it needs a
      document-number field in each of their schemas, or an explicit statement that those registers
      are transparency-only.
      🔴 **STILL OPEN — the original wording, kept because these were the hazards:**
        1. **`idCountry` IS A COUNTRY NAME, THE MRZ CARRIES ISO ALPHA-3.** Published: `Egypt`, `Iran`.
           The circuit hashes the MRZ's three bytes — `EGY`, `IRN`. A mapping is required, OFAC's
           naming is not ISO, and `IdentifierSet` has no third field to carry it.
        2. **THE MRZ FIELD IS NINE CHARACTERS, `<`-PADDED; OFAC PUBLISHES THE BARE NUMBER.** Measured
           lengths in the excerpt: 4, 4, 6, 7, 8, 9. `td1_dg1_data_extractor` reads all nine bytes, so
           `1084010` is hashed as `1084010<<` in-circuit and as `1084010` from the feed.
        ⛔ **Either mistake produces a tree that matches nothing, and NOTHING ANNOUNCES IT** — the
        root anchors, the proofs verify, and every listed person passes. Same shape as publishing over
        the name leaves, reached from the normalisation side instead.
        ▶️ Also filter on `idType == "Passport"` exactly: the same `idList` carries
        `Secondary sanctions risk:`, `Email Address` and `Gender` rows, whose `idNumber` is prose.
      ⏸️ **BLOCKED ON A DECISION, NOT ON WORK: which address a withdrawal is judged on** — the
      `processooor`, the relayer, or the payout recipient. Until that is settled the DOMAIN_ADDRESS
      term cannot be written, and publishing an address-keyed root before the term exists would be
      the same silent-pass hole as the name leaves.
      ▶️ **AND WHEN IT IS BUILT, BE HONEST ABOUT WHAT THE CLAIM IS.** A ZK absence proof yields a
      SIGNAL, not evidence: *"some passport-holder asserts the parse dropped them"*, with a nullifier
      and no name. That is still the entire point — **silence becomes a visible, counted alarm**, and
      the count is a health metric for the parser. Turning a signal into an actionable finding needs
      🔴 **AND THERE IS NO ADJUDICATOR TO ESCALATE TO — court/jury is out of scope entirely (see
      the TRIAGE block).** That is not a gap: the dropped entry is in a PUBLIC register and the
      anchored leaf set is on-chain, so anyone can rebuild the snapshot and show the entry missing,
      without standing or a ruling. **The claim's job is to raise the alarm; the proof of the drop is
      a rebuild anyone can perform.** ⇒ Two items, one chain: **SMT root → anonymous absence claim.**
      🔗 Prerequisite: the `setForwarder` item above. "No fabrication possible" is the premise this
      design rests on, and it is not currently true.
- [ ] 🔴🔴 **THE ANONYMITY TRACE: THE DON IS THE SAFEST COMPONENT, AND REGISTRATION PUBLISHES EVERY
      USER'S PASSPORT** (owner asked for a holistic challenge, 2026-08-25; every claim below was read
      out of the tree, not reasoned about).

      ⭐ **THE QUESTION WAS "CAN THE DON WIRETAP US" AND THE ANSWER IS NO, BY CONSTRUCTION.** The
      sanctions workflow has ONE trigger — `cre.Handler(scheduleTrigger, onSchedule)`, a cron — and one
      outbound call, `SendRequest{Url: spec.PublishedAt, Method: "GET"}` against a public government
      file. **No HTTP trigger, no user endpoint, no session, no request body.** The names it parses are
      OFAC's published designations, not users'. Flow is one-way: public list in, public root out, and
      the user's device proves against it. `document_id` is a PRIVATE witness; the eight public signals
      are `new_commitment`, `existing_nullifier_hash`, `withdrawn_value`, `state_root`,
      `state_tree_depth`, `identity_root`, `context`, `blacklist_root` — none identity-bearing.
      ⇒ **Deleting the CRE workflow would improve privacy by ZERO and would cost the ownerless root
      (§8df5855). Do not "fix" privacy by removing it.**

      🔴 **#1 — `escrow_envelope` PUBLISHES THE FULL MRZ, ENCRYPTED TO ONE KEY, FOREVER.**
      `sealed: pub [Field; PAYLOAD_LEN]` (PAYLOAD_LEN = 5) carries `revocation_secret` + the **packed
      DG1**: name, date of birth, nationality, sex, expiry, document number. Sealed to
      `CONTROLLER_KEY_X/Y` — a **single immutable pair** on `IdentityRegistry`, no threshold, no MPC,
      no rotation — and emitted as `event IdentityRegistered(..., uint256[5] sealedPayload)`, so it is
      permanently indexable rather than merely present in calldata. **One secret key decrypts every
      registered user's passport, retroactively.** Nothing in this repo decrypts it (the only
      `decrypt` hits are `CRSASigner`'s unrelated RSA path).
      ⚠️ **IT IS NOT AN OVERSIGHT — the circuit states its purpose:** *"the one-time, permissionless
      transaction that makes an identity REVOCABLE … so the controller CAN list that identity later.
      Without it, a user picks a secret nobody knows and their absence from the blacklist is
      guaranteed forever."* The controller cannot compute `commitment = Poseidon(revocation_secret,
      document_id)` without the user's secret, so the secret is escrowed.
      ⛔ **BUT THE MRZ IS NOT NEEDED FOR THAT, AND THE GAP IT COVERS IS THE ONE THE DESIGN ALREADY
      CALLS UNSOUND.** Revocation needs `revocation_secret` (to compute the commitment) and at most
      `document_id` (to know WHICH envelope matches a sanctioned document). The rest — name, DOB,
      nationality — is only useful for matching a designation **by name**, which is precisely what
      `identifiers.go` rejects for on-chain use: *"no transliteration, no alias ordering, no
      similarity matching, no threshold."* So the full-MRZ escrow buys the controller a fuzzy
      name-match it can run unilaterally off-chain, over everyone, with a master key.
      ⚠️ **AND IT IS LARGELY REDUNDANT NOW.** Since §79bbabc the identity leaf binds `document_id` and
      the blacklist carries `blacklist_key(DOMAIN_DOCUMENT, …)`, so a sanctioned passport is ALREADY
      excluded in-circuit against a public list, with no controller, no escrow and no disclosure. The
      only case escrow still covers is a designation whose document number is not published — which is
      exactly the UK/UN coverage gap booked below.
      ✅ **DECIDED AND LANDED (owner, 2026-08-25): OPTION (b), SEAL LESS** — `856abb0`. `PAYLOAD_LEN`
      5 → 2: `revocation_secret` + `document_id`. Name, date of birth, nationality, sex and expiry no
      longer reach the chain in any form. Revocation is unchanged and still works, because
      `document_id` is recomputable from a published designation. Soundness unchanged: the DG1 is
      still a private witness, still proven included in `registrationSmt`, and `document_id` derives
      from those same bytes. `pack_dg1`/`DG1_WORDS`/`BYTES_PER_FIELD` became unreachable and are
      deleted; public inputs 11 → 8, verifier 19 → 16, and `PUBLIC_INPUT_COUNT` is now DERIVED
      (`PUB_SEALED_0 + SEALED_LEN`) so the width cannot drift from the circuit silently.
      ⭐ **Identity commitments did not move** (`Poseidon(revocation_secret, document_id)` was already
      the leaf), so every downstream fixture survived without regeneration. 484/484.
      🔴 **THE TRACE IS NOW DONE, AND IT SAYS `revocation_secret` SHOULD NOT BE SEALED AT ALL —
      OPTION (b) AS I FRAMED IT WAS ONE FIELD TOO GENEROUS** (2026-08-25). Two measurements:
        1. **`revoke(bytes32 commitment_, bytes32 predicate_)` TAKES ONLY THE COMMITMENT**, and the
           commitment is a PUBLIC signal at registration, stored in `registered[]`. The sealed secret
           is used nowhere in the revocation path. Nothing else in the repo reads it either — the only
           references are the circuit's own derivation and this file.
        2. **IT IS A LIVE CREDENTIAL, NOT INERT DATA.** `withdraw.nr:142` computes
           `identity_commitment(w.revocation_secret, w.document_id)` — the secret IS the witness that
           proves identity in a withdrawal. Sealing it hands whoever holds `CONTROLLER_SK` the
           identity half of every user's withdrawal proof.
      ⇒ **So it buys the controller nothing operational and costs every user a credential.** Not fund
      theft on its own — spending still needs the note's nullifier and secret — but it is exactly the
      kind of thing that should not sit encrypted under a single immutable key for no reason.
      ✅ **DONE — `PAYLOAD_LEN` 2 → 1** (`0fbfcb6`). The secret is still PROVEN in-circuit
      (`identity_commitment(revocation_secret, document_id) == commitment` is what makes knowledge of
      the preimage mandatory); it is only no longer PUBLISHED. Public inputs 8 → 7, verifier 16 → 15,
      484/484, and identity commitments did not move again so downstream fixtures survived untouched a
      second time.
      ⇒ **WHAT REGISTRATION NOW PUTS ON CHAIN, as a trajectory:** plaintext `holder_root` + `dg1_hash`
      (removed before this session) → the full packed MRZ encrypted → secret + document id → **the
      document id alone.** 11 → 8 → 7 public inputs.
      🔴 **AND THE IRREDUCIBLE REMAINDER, STATED SO IT IS NOT MISTAKEN FOR ZERO:** a
      `CONTROLLER_SK` holder still learns **which registered commitment corresponds to a given
      passport** — which links a document to a registration transaction and its funding address. That
      is not removable while targeted revocation is a requirement AT ALL; removing it means option (a),
      deleting the escrow and letting the public blacklist be the only enforcement. Still open,
      alongside thresholding the key (option (c), which now guards a document identifier rather than a
      passport — a smaller prize, not nothing).
      ⏸️ **AND THE OTHER TWO OPTIONS ARE NOT THEREBY CLOSED.** (c) still applies to whatever remains
      sealed: `CONTROLLER_KEY_X/Y` is a **single immutable pair**, so one key still decrypts every
      envelope — now yielding a document identifier rather than a passport, which is a far smaller
      prize but not nothing. Thresholding it is a separate decision.
      🔴 **ORPHANED FIXTURES, FOUND BY THE REGENERATION AND FIXED AT THE ROOT.**
      `prove-escrow-fixtures.sh` globbed `Prover.escrow*.toml`, and an earlier 16-identity run had
      left `escrow3..15` **tracked** while the fixture carries three documents. They cannot be
      regenerated — there is no document 10 to prove against — so they were orphaned BY CONSTRUCTION
      and every future run would have tripped over them. It surfaced as a Noir type error about
      `sealed` having length 5 when the circuit wanted 2, three steps in, naming neither the stale
      file nor the count behind it. The script now derives its witness list from
      `escrow_documents.json`; the 13 orphans were deleted in the same commit as that fix.

      ⏸️ **THE ORIGINAL THREE OPTIONS, KEPT AS THE RECORD OF WHAT WAS WEIGHED:**
        (a) **Delete the escrow.** Enforcement becomes "the public blacklist only". Removes the largest
            leak in the system outright, shrinks the circuit, and makes the anonymity claim true as
            stated. Costs the name-matched revocation path.
        (b) **Seal less** — `revocation_secret` + `document_id` only, dropping four DG1 words to one
            field. Keeps targeted revocation for published document numbers; removes name/DOB/
            nationality from public chain data forever.
        (c) **Keep it and threshold the key.** Every user is still escrowed; only the single-point
            risk improves. Users must be told.
      🔴 **THE SAME REASONING ALREADY REMOVED `holder_root`/`dg1_hash` FROM THIS CIRCUIT** — its own
      header calls that *"the largest privacy defect in our own code"* — and stopped one step short.
      **Encrypting an identifier to a key the user does not hold is deferred disclosure, not privacy.**

      🔴 **#2 — `getProof(commitment_)` TELLS YOUR RPC PROVIDER WHICH IDENTITY YOU ARE.** It is an
      `eth_call` carrying the wallet's own commitment, with its IP and timing, shortly before the
      withdrawal from the same connection. Same class as #3: **querying for your own key reveals your
      own key.** Fix is the same — fetch the whole tree and derive the witness locally, or route it
      somewhere that cannot correlate.

      🔴 **#3 — BLACKLIST WITNESS RETRIEVAL IS UNSPECIFIED, AND IS A DEANONYMISER IF BUILT AS A QUERY.**
      `withdrawWitness.ts` TAKES a `BlacklistWitness` and never fetches one, so nothing leaks today and
      nothing is decided either. Asking any service *"the witness for key K"* hands it a deterministic
      function of the user's passport, correlatable with the withdrawal.
      ⇒ **REQUIRED SHAPE: download the ENTIRE key set, rebuild the SMT locally, derive the witness.
      Never query.** Everyone fetches identical bytes, so the fetch says nothing.
      ⭐ **AND THE SERVER IS UNTRUSTED BY CONSTRUCTION:** the wallet rebuilds and compares its root to
      `latestActiveSmtRoot` on-chain. A doctored set fails the comparison. No server to trust, and none
      to talk to about yourself.
      ⚠️ **BLOCKER: THE KEY SET IS NOT PUBLISHED IN A REBUILDABLE FORM.** The anchored calldata holds
      NAME leaves, not keys. A `<SOURCE>_KEYS` registry — leaves = keys, ADDED alongside the name
      registries rather than replacing them (see the reverted collapse at §4312e5a) — gives the wallet
      a verifiable public preimage without breaking UK/UN.
      ⚠️ **AND IT NEEDS TS/Go PARITY:** the padding, the alpha-3 table and the domain separation must
      exist in TypeScript byte-identically, or a locally-built tree silently will not match the root.

      ⚪ **#4 — ORDINARY PP LINKAGE, unchanged and not made worse:** funding address, recipient, timing,
      anonymity-set size. **And `commitment` is public at registration**, so PARTICIPATION is visible
      even though ACTIVITY is not — the circuit header draws that distinction itself. Combined with #1
      it is worse than it looks: decrypting an envelope yields MRZ ↔ commitment ↔ funding address.

      ✅ **JAILBREAKING IS NOT A THREAT TO SOUNDNESS, AND NO ATTESTATION IS NEEDED** (owner's standing
      rule: *no attestation gates of any kind anywhere*). A modified app cannot skip the blacklist term
      — the proof would not verify. It cannot choose a friendlier root: `withdraw` SUBSTITUTES the
      pool's root into the public inputs and `withdrawBatch` COMPARES `s[7]` against the anchor. It
      cannot borrow a clean document — the leaf binds it to a `revocation_secret` it would have to
      know. A modified app can only harm **its own** user's privacy, which no attestation would
      prevent anyway.

- [ ] ⭐ **CONFIDENTIAL HTTP IS THE PLUG-IN — TEE-BACKED FETCH, CHAINLINK'S OWN, NOTHING ROLLED**
      (owner, 2026-08-24: *"find a trustworthy thing we can plug right into the workflow SDK"* and
      *"you can write your own capability for CRE, it is extendable"*).
      🔴 **I CLOSED THIS DOOR TOO EARLY AND WAS WRONG.** I checked the vendored SDK, found three
      capabilities (`blockchain/evm`, `networking/http`, `scheduler/cron`), and concluded there was
      "no plug point". **The CRE docs list a fourth: CONFIDENTIAL HTTP.**
      ✅ **WHAT IT IS, AND WHY IT IS THE ANSWER TO COLLUSION:** the HTTPS request executes **inside a
      TEE** (Intel SGX / AMD SEV) in a hardened cloud environment, with the DON providing threshold
      decryption of long-term secrets and **cryptographically verifying enclave integrity**. ⇒ A
      corrupt NODE OPERATOR cannot fabricate the response, because the fetch happened inside an
      enclave they can neither read nor tamper with. That is a materially different trust model from
      `ConsensusIdenticalAggregation`, which only says a majority agreed.
      🔑 **AND THIS TEAM IS UNUSUALLY WELL PLACED TO EVALUATE IT**, which is worth saying because it
      is normally the objection: SPV's entire seed-custody design is SGX/SEV sealing, MRENCLAVE
      binding, attestation and `require_backend_for_role`. **The same caveats we already apply to our
      own enclaves apply here** — TEE trust is not cryptographic trust, SGX has real breaks, and
      attestation freshness matters. Evaluate it the way `quid-hop::seed` evaluates a backend, not as
      a black box.
      ▶️ **THREE THINGS TO SETTLE BEFORE COMMITTING TO IT:**
        1. **It is not in the vendored SDK.** `cre-sdk-go` here carries only the three above. Find the
           capability module and version; this may need an SDK bump.
        2. **Does the enclave attestation reach OUR CONTRACT, or only the DON?** If only the DON, the
           Forwarder is still the trust boundary and the timelock still stands. The docs say the DON
           verifies enclave integrity — which reads like the latter. **Confirm, because it decides
           whether the Forwarder deletes.**
        3. **DECO is the non-TEE alternative** (three-party handshake, ZK proof about session data,
           oracle verifies without seeing the raw data). Different trust assumption — cryptographic
           rather than hardware. Price both.
      ⚠️ **CORRECTION — I CLAIMED "AUTHORING IS NOT AVAILABLE" AND THAT WAS TOO STRONG** (owner:
      *"authoring isnt open yet would be false"*). It rested on a docs page not mentioning it, which
      is absence-of-evidence, not evidence. **The mechanism is real and open-source: LOOPP, the
      node's out-of-process plugin architecture** — `smartcontractkit/chainlink` issue #21635
      (*"[CRE] Confidential workflow execution"*) describes the engine detecting confidential
      workflows and *"delegating execution to an enclave via a new LOOP capability"*. ⇒ **The honest
      split: authoring a capability against LOOPP is open; DEPLOYING one onto Chainlink's production
      DONs self-serve is the roadmap item.** Two different claims and I ran them together.
      ⇒ ⭐ **AND IT MAKES ONE OPTION REAL THAT I HAD WRITTEN OFF: IF WE RUN OUR OWN DON, WE CHOOSE
      THE CAPABILITY SET** — and could author a TLS-notarizing one. Not alien to this team; SPV
      already operates an enclave fleet. Price it against Confidential HTTP rather than assuming
      it is out of reach.
      ❓ **STILL UNVERIFIED AND IT BLOCKS ANY QUORUM DESIGN: IS `donId` AUTHENTICATED?** The metadata
      header carries it at offset 37 (4 bytes), and a cross-DON quorum would count distinct ids. **If
      the Forwarder does not bind `donId` to the signing key set that produced the report, one DON
      forges k ids and a quorum buys nothing.** The docs do not say. Read `KeystoneForwarder`, not the
      documentation, before designing on it.

- [ ] 🔴 **ONLY ONE WORKFLOW CAN EVER PUBLISH, AND TWO NEED TO — PINNING ONE SILENTLY DISABLES THE
      OTHER** (found 2026-08-24 answering *"how does the contract check that the DON is running the
      latest workflow"*).
      **`activeWorkflowId()` returns exactly ONE id** — it scans `workflowVersions` backwards and
      returns the newest whose `activeFrom` has elapsed — and `onReport` requires
      `reported_ == active_`. So the anchor accepts reports from a single workflow at a time.
      ⚠️ **BUT TWO WORKFLOWS WRITE ON-CHAIN**: `cre/notary_registry/main.go` and
      `cre/sanctions_lists/main.go` (checked; `icao_master_list` has no write path, which is its own
      booked item). They are separate Go modules producing separate binaries, and a workflow id is
      `hash(binary, config)` — so **two distinct ids, one accepted.** Pin the sanctions workflow and
      every notary report reverts `UnpinnedWorkflow`, and vice versa.
      ⇒ **AND IT CONTRADICTS THE CONTRACT'S OWN DESIGN INTENT.** Its header says snapshots are *"keyed
      by `registryId` rather than hardwired to one list"* because *"more are expected"*. The data
      model is many registries; the workflow gate is one. The two were never reconciled.
      ⚠️ **IT WILL PRESENT AS "THE SANCTIONS ROOT STOPPED UPDATING"**, days after the pin that caused
      it, with a revert reason naming a workflow id nobody recognises.
      ▶️ **FIX: PIN PER `registryId`.** `activeWorkflowId(bytes32 registryId)`, so each list names the
      code entitled to publish it — which is what the pin was always for. ⚠️ **STORAGE: the file
      commits to append-only (UUPS, no gap), so `workflowVersions` cannot change type in place.**
      Either append `mapping(bytes32 => WorkflowVersion[])` and treat the existing array as a
      registry-agnostic fallback, or — if nothing is deployed yet, which the zeroed `CONTRACTS` and
      the unwritten deployment sequence both suggest — change it outright and say so. **That is a
      deployment-state question, not a design one; settle it before writing the code.**
      📌 Answers the second half of the same question: **the contract cannot check what the DON is
      RUNNING.** It checks what the report CLAIMS, and the claim is backed by DON signatures verified
      at the Forwarder. Pin a new version and the old one stops being accepted after
      `WORKFLOW_ACTIVATION_DELAY`, so **deploy the new workflow to the DON FIRST, then pin** — pinning
      first buys a 24-hour window and then a stall.

- [ ] 🔑 **THERE ARE NO UNSIGNED SOURCES — AND THAT IS THE ROOT FIX THAT DELETES THE FORWARDER
      ENTIRELY** (owner, 2026-08-24: *"there is an even more elegant fix and there should be no
      unsigned sources"*).
      ⭐ **THE OBSERVATION THAT REFRAMES EVERYTHING: "unsigned source" IS A CATEGORY THAT DOES NOT
      EXIST.** OFAC, the Ukrainian notary registry, the ICAO PKD — every one is served over **TLS**,
      and the server's certificate chain SIGNS THE SESSION. The signature is already there; it is
      simply not carried to the chain. I had split sources into "source-signed (ICAO) ⇒ no authority
      needed" and "unsigned (OFAC, notary) ⇒ the DON must attest". **That split is wrong. The second
      category is empty.**
      ⇒ **IF THE REPORT CARRIES A PROOF THAT HOST X's CERTIFICATE AUTHENTICATED THESE BYTES AT TIME
      T, THE CALLER BECOMES IRRELEVANT.** `forwarder`, `NotForwarder`, `setForwarder`, the
      `FORWARDER_ACTIVATION_DELAY` I just added, `promoteForwarder`, and `pinWorkflow`'s role in
      CORRECTNESS all delete. **Publication becomes permissionless**, and the DON drops to what it is
      actually good for — **liveness, not correctness**. That is the split §2.18cu's polarity argument
      implies and this is what makes it real rather than asserted.
      🔴 **SO THE TIMELOCK I LANDED (`499de9d`) IS THE CLAMP, AND THIS IS THE ROOT** — standing rule
      17, a root fix makes the previous fix DELETABLE. Keep the timelock until this lands: the
      one-transaction bypass is real today and a circuit is not a week's work. But do not mistake it
      for the answer, and delete it when this arrives rather than leaving both.
      ✅ **AND MOST OF THE MACHINERY IS ALREADY BUILT HERE, WHICH IS WHY THIS IS CHEAPER THAN IT
      SOUNDS.** X.509 chain verification IS the passport capability pointed at a different PKI:
      `register_identity/src/main.nr` already verifies **CSCA → DSC → SOD** across 88 profiles, and
      `noir_dl_lib` carries `rsa.nr` (PKCS#1 v1.5), `rsa_pss.nr`, `sha1/224/384/512.nr`, and
      `big_curve`/`bignum`/`sigver` for ECDSA over arbitrary curves. **A TLS server chain is RSA or
      ECDSA over P-256/P-384 with SHA-256/384 — every one of those primitives is present and
      exercised.** Do not scope this as new cryptography.
      🔴 **MEASURED 2026-08-24, AND IT KILLS OPTION (a) OUTRIGHT: THE CRE HTTP CAPABILITY CANNOT
      EXPOSE THE TLS SESSION, SO IN-WORKFLOW VERIFICATION IS NOT "UNBUILT" — IT IS UNBUILDABLE.**
      `cre-sdk-go/capabilities/networking/http@v1.4.0`'s `Response` has exactly four fields:
      `StatusCode`, `Headers`, `Body`, `MultiHeaders`. **No peer certificates, no TLS state.** The
      only certificate type in the whole capability is `MtlsAuth` — OUR client cert for mutual TLS,
      the opposite direction. The node runtime performs the handshake and hands the workflow bytes.
      ⇒ **No amount of Go in the workflow fixes this**, and that includes TLSNotary or DECO: a
      workflow cannot open its own socket, it must go through the capability. **The notary has to
      live OUTSIDE CRE**, and CRE becomes transport rather than the security property.
      ⇒ **SO `RegistrySourceAnchor.sol:128-130` MUST BE REWRITTEN TO SAY THE WINDOW IS LOAD-BEARING**
      — the sibling item below offers "either build the in-workflow verification the comment assumes,
      or rewrite the comment". **The first option does not exist. Rewrite it.**
      ⇒ **AND THE FORWARDER TIMELOCK STAYS**, for every source that does not sign its own data. It is
      not a stopgap for something arriving shortly; it is the only thing between one owner key and a
      fabricated snapshot.
      ✅ **THE ICAO PATH IS ALREADY THE RIGHT SHAPE, AND IT IS THE TEMPLATE.** `icao_master_list`
      verifies **CMS SignedData** signed by `C=UN, O=United Nations` against a pinned hash, using Go
      stdlib (`crypto/x509`, `encoding/asn1`) — hand-parsed because `go.mozilla.org/pkcs7`'s
      `Verify()` fails on the genuine file. **That source signs its own data, so it needs no DON
      authority at all**, which is why "remove the role from the ICAO path entirely" is a separate
      and much easier item. ⇒ **The generalisation is not "notarize the TLS", it is "prefer sources
      that sign".** Where a register offers a signed feed, take it; the TLS question only arises for
      registers that publish bare files.
      ❓ **MULTIPLE DONs DO NOT HELP HERE, and it is worth saying because it is easy to over-credit**
      (owner asked, 2026-08-24). More DONs buy LIVENESS and censorship-resistance — a second DON can
      publish when the first will not. They buy nothing for AUTHENTICITY, because none of them can
      see the TLS session either; N nodes agreeing on bytes they cannot attribute is still
      `ConsensusIdenticalAggregation`, just wider. **Independence of attestor from prover matters
      only once there IS an attestor, and inside CRE there cannot be one.**
      ⛔ **DO NOT ROLL OUR OWN** (owner, 2026-08-24: *"chainlink CRE workflows are extendable with
      external modules... im sure someone on github already did TLS"* — correct on both).
        * **TLSNotary** (`github.com/tlsnotary/tlsn`) — the mature Rust implementation. Prover and
          Verifier run **MPC-TLS** together during the session; the Verifier acts as **Attestor**,
          and the Prover then makes a presentation *"which can be verified by anyone who trusts the
          Attestor"*.
        * **DECO** — Chainlink's OWN ZKP+TLS oracle protocol (Ari Juels et al.), and CRE is
          Chainlink's orchestration layer, so DECO-inside-CRE is the vendor-native path. Check it
          before reaching for anything else.
      🔴 **AND THE SEARCH CORRECTED MY CLAIM THAT THIS "DELETES THE FORWARDER". IT DEPENDS ENTIRELY
      ON WHERE THE PROOF LANDS, and these are two different projects:**
        * **(a) TLS verified INSIDE the workflow.** DON nodes attest; the report still arrives via
          the Forwarder. This makes `RegistrySourceAnchor.sol:128-130`'s claim TRUE — fabricated
          data becomes impossible rather than detectable — and is the cheap version. **It does NOT
          remove the Forwarder, and the timelock is still load-bearing under it.**
        * **(b) The ATTESTATION REACHES THE CONTRACT.** ⭐ **This is available, and the trick is that
          the DON signatures are not the only payload: `onReport(bytes metadata, bytes report)` —
          the METADATA is a fixed 109-byte header we cannot extend, but the REPORT IS OURS TO
          DEFINE.** Put the TLSNotary presentation in it and verify the attestor signature on-chain,
          and data authenticity stops depending on who called. **Then the Forwarder, `NotForwarder`,
          `setForwarder` and the timelock all delete.**
      ⚠️ **(b) DOES NOT REACH ZERO AUTHORITIES, AND SAYING SO IS THE POINT.** TLSNotary is
      attestor-based by construction — verification is *"by anyone who trusts the Attestor"*. So (b)
      swaps "trust the DON's plain HTTP fetch" for "trust an attestor set's MPC-TLS attestation".
      That is a real gain ONLY IF THE ATTESTOR SET IS INDEPENDENT OF THE DON; if the DON attests to
      itself the argument is circular and nothing was bought.
      ❓ **UNVERIFIED, AND IT DECIDES THE ON-CHAIN COST:** which signature scheme and curve the
      attestor uses. If secp256k1/P-256 the verification is `ecrecover` or the ECDSA the passport
      circuits already do; anything exotic changes the estimate. **Read the tlsn source, not the
      docs — the protocol pages did not say.**
      ▶️ **WHAT IS GENUINELY NEW, and it is the transcript half, not the certificate half:**
        1. **Binding the RESPONSE BYTES to the session.** A verified cert chain proves who the server
           is; it does not prove what it sent. That needs the handshake-key derivation and AEAD
           transcript — the TLSNotary/zkTLS part, and the real work.
        2. **Anchoring the CA roots.** One authority survives, and it is the **Web PKI** — the trust
           root of the entire internet rather than one owner key. Not zero, and say so plainly rather
           than claiming trustlessness.
        3. **Freshness.** Bind `T` and reject stale transcripts, or an old snapshot replays as current.
      ⭐ **ONE SIMPLIFICATION WORTH NAMING, because it makes this far easier than the usual zkTLS
      case: THE DATA IS PUBLIC.** Standard TLS notarization spends most of its complexity hiding the
      response from the notary while proving things about it. **We do not need to hide anything** —
      OFAC's list is published. So the selective-disclosure machinery drops out and what remains is
      authentication only.
      ⚠️ **THIS SUPERSEDES THE "source-signed vs unsigned" FRAMING WHEREVER IT APPEARS**, including
      the ICAO-path item below and sec. 4's *"permissionless for unsigned sources"* — that phrasing
      encodes the empty category. Every path is the same path once the transcript is proven.

- [ ] 🔴 **A SECURITY ARGUMENT RESTING ON AN UNBUILT PREMISE — `RegistrySourceAnchor.sol:128-130`.**
      It explains why the snapshot path needs no contest window: *"Once each DON node verifies the
      register's TLS session inside the workflow, fabricated DATA becomes impossible rather than
      merely detectable — so the snapshot path needs no contest window."* **`notary_registry/main.go`
      does no such thing**: a plain `http.SendRequest` + `cre.ConsensusIdenticalAggregation`, with no
      TLS session verification, no certificate handling, nothing. Grepped for `tls|x509|cert` — the
      only hits are the two comment lines admitting scrapers rot.
      The code is currently SAFER than its own rationale (`ROOT_ACTIVATION_DELAY = 1 hour` exists
      anyway), which is exactly why this is dangerous: **the next person to read that comment can
      delete the delay and cite it.** Either build the in-workflow session verification the comment
      assumes, or rewrite the comment to say the window is load-bearing. Do not leave it asserting a
      property the workflow does not have.
      🔗 Bears directly on the TLSNotary question (§2.15a): the current design already WANTS the
      property TLSNotary provides and asserts it without having it, so "CRE instead of TLSNotary" is
      not the clean either/or that section framed it as.
- [ ] 📲 **FUND BY BTC QR, NOT BY AN EVM TRANSACTION — the answer to Phantom's MEV downgrade is to
      remove the broadcast, not to detect it** (owner, 2026-08-16). I had written that for a
      Phantom session "no probe can make the claim true" and stopped there. That was looking for a
      better DETECTOR when the fix is to delete the thing being detected — SPV standing rule 17,
      prefer making the bad state unconstructible over making it observable. **If the user funds
      over Bitcoin there is no EVM transaction of theirs to frontrun, so the custody problem does
      not arise on the entry path at all**, whoever holds the key.
      ✅ **AND IT IS ALREADY BUILT — this is a screen, not a mechanism.** `chain/hop.ts` (ported)
      exposes `requestOnchainSwapIn(seller, token, sats)` → `{ depositAddress, exactSats,
      minDeliveredUsd, swapId, expiresAt }`, plus `pollSwapIn` (`awaiting_deposit → confirming →
      settled`), `submitOpenChannel` / `pollOpenChannel`, and `hopApiConfigured`. The Rust side is
      tested to match (`swap_in_onchain.rs`: the deposit address is a P2TR over the tweaked output
      key, is deterministic and index-scoped, and a distinct CLTV or user yields a distinct
      address). That quote object IS the QR payload — `bitcoin:<depositAddress>?amount=<btc>`.
      🔴 **THREE CONSTRAINTS THE QR MUST RESPECT, and each is a silent failure if it does not.**
        1. **`exactSats` IS NOT A SUGGESTION.** Its own comment: *"send EXACTLY this (the low-order
           nonce is how the hop matches it)"*. The amount MUST be in the URI and MUST NOT be
           user-editable — a rounded send is unmatchable, and it fails as "nothing arrived".
        2. **`expiresAt` bounds the address.** The screen needs a countdown and must stop
           presenting the code once it lapses, or a user pays a dead quote.
        3. **A wrong-amount or late deposit needs a stated recovery.** The refund path exists
           (`refund_leaf_encodes_cltv_and_user_key`, `user_refund_script_path_verifies`), so the
           UI should point at it rather than leaving the user with a silent loss.
        4. 🔴 **THE QUOTED ADDRESS MUST BE RECOMPUTED, NEVER RENDERED — and this became
           load-bearing on 2026-08-16, so it is not the same requirement it was yesterday.** SPV's
           §T2 fix commits `seller`, `token` and `minDeliveredUsd` into an unspendable taproot
           leaf, and **that binding is enforced by THE PAYER CHECKING THE ADDRESS BEFORE SENDING**,
           not on-chain. (The alternative — deriving `seller` from the x-only refund key — was
           dropped because Ledger and Phantom separate the BTC and EVM keys by construction; see
           `SPV/docs/actionable/HOP-TRUST-AUDIT.md`.) ⇒ **A screen that displays whatever
           `requestOnchainSwapIn` returned provides NO protection at all** while looking exactly
           like one that does. The wallet must derive `q = internalKey ⊕ TapTweak(merkleRoot)`
           from the terms it agreed and refuse to show a QR that disagrees.
           ⚠️ **Needs two things the wallet does not have yet:** bech32m (for the P2TR address —
           `@scure/base`, same maintainer as the noble packages already here) and taproot tweak /
           point-add over secp256k1. **Do not hand-roll either.** ⚠️ And it must verify the shape
           the hop ACTUALLY quotes: today that is the SINGLE-leaf tree (`swapInDepositKey`
           tweaks by `tapLeafHash(refundLeaf)` alone). Implementing the two-leaf shape before the
           Solidity and Rust sides land it would reject every real quote.
      ⚠️ **OFFER THE ON-CHAIN RAIL FIRST, NOT THE LIGHTNING ONE, AND THE REASON IS A SECURITY
      DIFFERENCE RATHER THAN A UX ONE.** The on-chain deposit terminates in a Bitcoin proof the
      contract verifies (`settleSwapInProven` — tx + SPV inclusion proof). **The BOLT11 rail does
      NOT: an HTLC settled inside a channel produces no on-chain transaction to prove, so it
      still credits through the unproven `settleSwapIn` on the hop's word.** That is SPV
      §T1-BLOCKED, gated on §E166 item 2 (*"BOLT11 rail gated on an on-chain splice proof so EVERY
      credit path ends in a Bitcoin proof"*). ⇒ A Lightning invoice in the app is fine, but it is
      the rail with a trust assumption the other one does not have, and the app should not present
      them as equivalent while that is true.
      ⚠️ **THIS NARROWS THE PHANTOM EXPOSURE, IT DOES NOT REMOVE IT.** Redeem, withdraw and the
      leverage actions are still EVM writes through whatever wallet holds the key, so
      `signerKind()` and the honest badge still matter — the QR path takes the ENTRY flow (where
      the value and the MEV surface are largest) off the EVM entirely.
- [ ] 🏗️ **CONSOLIDATION (owner, 2026-08-16): `backend/` MERGES INTO THE SPV REPO, AND THE SPA's SWAP
      + LP FUNCTIONALITY MOVES INTO REACT NATIVE — the landing page does NOT come.** Measured before
      any file moved; both halves are smaller than they look, for different reasons.
      **(A) THE BACKEND MERGE HAS A RULE-2 ARGUMENT, WHICH IS STRONGER THAN THE TIDINESS ONE.**
      `backend/contracts` does NOT import the pinned SPV submodule at all — the coupling is
      `contracts/pool/spv/ISpvVenue.sol`, where ibiza HAND-DECLARES `ISpvVogue` and `ISpvBasket` as
      subsets of SPV's real contracts. That is the same interface declared twice in two repos, i.e.
      exactly what SPV standing rule 2 forbids inside one ("one declaration per interface, in a
      shared file"), and it is the mechanism behind SPV's *"depends on exactly four Vogue/Basket
      signatures staying permissionless and stable"*. ⇒ **Merging replaces a hand-copied interface
      with a real import, and the cross-repo drift risk deletes itself.** Scope: ~128 circuit +
      ~448 contract source files, plus 8 vendored `lib/` deps whose remappings must be reconciled
      with SPV's `evm/remappings.txt` (`@openzeppelin/`, `forge-std/` overlap; `@solarity/`,
      `@rarimo/`, `poseidon-solidity/`, `lean-imt/`, `solady/`, `evidence-registry/` are new).
      **(B) THE RN PORT IS MOSTLY A MOVE, NOT A REWRITE — because both apps already use `ethers` 6**
      (SPA `^6.16.0`, wallet `^6.17.0`; no wagmi, no viem, no rainbowkit). The SPA splits on a clean
      seam already: `(site)/` + `components/castle/*` is the LANDING PAGE (Hero, FeatureA-D,
      SalesLanding, LogosStrip) and is **explicitly excluded**; `(app)/app/page.tsx` +
      `components/app/*` + `lib/*` is the swap/LP app.
      📌 **MEASURED, and this is the number that matters: of the 15 files (1,765 lines) in
      `spa/src/lib/`, only TWO touch the browser at all** — `eth.ts` (75 lines) and `protect.ts`
      (63) — **and every hit is `window.ethereum`**, the injected-wallet connector. Five more files
      matched a first grep only on the `'use client'` pragma, which is an inert string off Next.
      ⇒ **The chain layer ports as-is; `window.ethereum` is replaced by the signer this wallet
      already has** (`ethers` + `expo-secure-store`), which is a substitution the LP-signer item
      below needs anyway. The genuine rewrite is the VIEW layer only: `components/app/*` from
      DOM+tailwind to RN primitives (tailwind → `nativewind` or plain styles — not yet chosen).
      ▶️ **THE ONE DECISION THAT ORDERS THIS, and it is not technical:** SPV's tree currently has a
      second thread committing into it hourly (`Aux.sol`, `Basket.sol`, `SwapLib.sol`, `vault.rs`
      all moved during one session on 2026-08-16). Dropping ~576 files in while that runs will
      collide. **Either land (A) in a quiet window with the other thread paused, or do (B) first** —
      (B) is purely additive, touches only `frontend/identity-wallet`, and is not blocked by (A).
      ⚠️ **Do NOT start (A) by moving files.** Reconcile the two `remappings.txt` first and prove
      `forge build` green on the union, or the merge lands as a repo that does not compile.
- [ ] 📡 **THE PHONE MUST POST LIVENESS HEARTBEATS — NEW OBLIGATION FROM SPV, 2026-08-21/22, AND IT IS
      THE ONE PIECE THAT NEEDS NO BIP-327.** SPV landed `§LP-LIVENESS`: `quid-hop`'s `RoutingGate`
      drops a channel from BOLT11 route hints unless a recent signed heartbeat exists, and it
      **FAILS CLOSED** — an unbound channel is treated as unroutable. It ships OFF (`gate = None`)
      precisely because turning it on before the phone posts anything would strand every swap-in.
      ⚠️ **SO THIS IS A HARD DEPENDENCY FOR TURNING THE GATE ON, not a nice-to-have.**
      * **Shape:** `tag ‖ channel_id ‖ height(be) ‖ seq(be)`, tag `QUID-REALM::lp-liveness.v1`,
        signed as a **65-byte EVM-shaped ECDSA** recoverable signature. `quid-hop/src/liveness.rs`
        (`Heartbeat::digest`, `recover_heartbeat`) is the reference; recovery must yield the
        channel's `lpEth`.
      * ⭐ **NO MuSig2. NO `@scure/btc-signer`.** It is signed by the same secp256k1 channel key the
        wallet already holds, in the shape `ethers` already produces ⇒ **it can ship WELL AHEAD of
        the ladder**, which is the only piece genuinely blocked on BIP-327. Landing it first is real
        progress against the same blocker `lp_sig` used to represent before §E183 deleted it.
      * ⚠️ **The staleness threshold is DELIBERATELY un-defaulted on the SPV side** — `RoutingGate::new`
        takes it as a required argument with no default, because it must be DERIVED from the slowest
        co-sign an LP must complete, not picked. Do not invent one here either.
      * **Why it exists:** BIP-341 `Prevouts::All` binds every pre-signed exit to the funding
        outpoint, and rotation invalidates them — so a channel taking traffic while its LP is
        unreachable accrues rotations nobody can re-arm. The gate blocks the traffic, at the
        narrowest point, reversibly.

- [x] ✅ **REKEY NEEDS NO SIGNATURE AFTER ALL — RETRACTED THE SAME DAY IT WAS FILED (SPV, 2026-08-22).**
      ⚠️ **DO NOT BUILD EVM SIGNING FOR REKEY. The entry that stood here asked for exactly that and
      it is now WRONG** — SPV folded the rekey consent into the exit ladder (`§REKEY-FOLD`), so
      `rekey` no longer takes an `lpSig` and `ChannelLib` no longer verifies one. The digest and its
      four supporting parameters are deleted; `SignatureChecker` is gone from the tree entirely.
      🔑 **WHY THE LADDER IS THE CONSENT, and it is stronger than the signature it replaced:** a
      rotation must carry a fresh `exits` ladder, and every rung is verified as BIP-340 under
      `Q' = TapTweak(KeyAgg(lpPubkey, NEW hopPubkey))`. **`Q'` DERIVES FROM THE NEW HOP KEY**, so a
      rung cannot exist unless the LP co-signed a MuSig2 session over exactly this rotation. The
      signature proved the LP agreed; the ladder proves the LP agreed AND still has an escape after
      the rotation — which is the property the rotation actually threatens, since BIP-341
      `Prevouts::All` voids every pre-signed rung the moment the outpoint moves.
      ⇒ **"THE LP SIGNS NOTHING ON THE EVM" IS NOW TRUE WITHOUT EXCEPTION.** The §E183 correction
      further down this file needs no caveat; the exception I added has been deleted at the source.
      ⇒ **NET EFFECT ON THIS REPO: one fewer thing to build**, and the remaining Bitcoin-side work is
      unchanged — the ladder (BIP-327, the one genuinely blocked item), the payout PoP (BIP-340), and
      the heartbeats above (no MuSig2, shippable first).

- [ ] 🌐 **THE WEB/APP SPLIT — DO AS MUCH BTC AS POSSIBLE ON THE WEBSITE; GATE THE REST** (owner,
      2026-08-22: *"react native must be copy of the react we wrote for the ETH SPA … we must be able
      to do as much as we can with BTC through the website as well, while the app handles what it
      needs and we just make sure that you cant use certain parts of the web page until you did what
      you have to with the app"*).
      ⇒ **The discriminator is not "BTC vs ETH", it is WHAT TOUCHES THE CHANNEL KEY.** Everything
      that does not — browsing, quoting, positions, swap-in/swap-out *requests*, redemption views —
      belongs on the web SPA for both assets. Only these need the app, because only these sign with
      the LP funding half: the **exits ladder** (MuSig2, BIP-327), the **payout-key PoP**
      (`btcRecipientPoPDigest`, BIP-340), the **rekey consent** above, and the **heartbeats** above.
      * **Gating rule:** the web page must refuse the LP-side actions until the app has produced the
        artefact they depend on, rather than letting them start and fail late. The on-chain checks
        are already the source of truth for "has it been done" — `btcRecipientOf[lpEth] != 0` and the
        armed-ladder state are readable, so the gate needs no new backend.
      * ⚠️ **A swapper is NOT an LP.** Swap-in/swap-out users never hold a funding half, so nothing
        about them should be gated behind the app — gating them would be a self-inflicted funnel loss.

- [ ] 🔑 **THE LP-SIDE SIGNER — ibiza's half of the SPV fleet split (SPV §E166-3, §E175).** The fleet
      RELAYS consent and provably cannot manufacture it: `VaultRegistry.LpConsent { auth, exits }`
      goes DORMANT on absence, a conflicting re-bind is REFUSED not overwritten, and both halves need
      the LP funding key which §E175-a removed from the fleet. `quid-lp-daemon` landed on the SPV side
      (683 passed) and holds the LP funding half; **nothing produces the consent, and that is here.**
      Two pieces:
        * **`auth.lp_sig`** - an EVM signature over `openAuthDigest`. Small; the wallet already signs.
        * **`exits` ladder** - one pre-signed spend of the 2-of-2 PER RUNG, each requiring an
          INTERACTIVE MuSig2 session between the LP's vault node and the fleet's hop at open.
      ⚠️ **DO NOT HAND-ROLL MuSig2.** BIP-327 nonce handling is where reuse silently leaks the
      private key, and this signs spends of a live 2-of-2.
      ✅ **THE LIBRARY QUESTION IS SETTLED, AND THE ANSWER WAS IN A README WE ALREADY SHIP** (checked
      2026-08-16). `@noble/curves` 2.2.0 exports `schnorr`, `secp256k1_FROST`, `schnorr_FROST` and
      **no MuSig2** - read off `node_modules/@noble/curves/secp256k1.d.ts`, not assumed. Its own
      README says where it went: *"MuSig2 signature scheme and BIP324 ElligatorSwift mapping for
      secp256k1 are available in a separate package"* → **`@scure/btc-signer`**, same maintainer
      (paulmillr) as the `@noble/curves` + `@noble/hashes` this wallet already depends on.
      ⇒ **Use `@scure/btc-signer`; adding it is step one**, since `@scure/` is absent from the
      wallet's `node_modules` today. ⚠️ Confirm its MuSig2 export surface against the INSTALLED
      package before designing the session flow - this entry cites noble's README, which is evidence
      the package exists and is the sanctioned route, NOT evidence of its API shape.
      ✅ **CHECK EXECUTED 2026-08-26 against the real package (`npm pack @scure/btc-signer`, v2.3.0).**
      The route is confirmed: `musig2.js` ships at the package root and is a named entry in the
      `exports` map (`"./musig2.js"`), so it is importable without deep-pathing into `lib/`. The
      surface is raw BIP-327: `IndividualPubkey`, `sortKeys`, `keyAggregate`, `keyAggExport`,
      `nonceGen`, `nonceAggregate`, `Session`, `deterministicSign`.
      🔴 **AND THE CHECK CHANGED THE DESIGN, WHICH IS WHY IT WAS WORTH EXECUTING.** SPV §E171-r
      sanctions MuSig2 on the strength of the Rust `musig2` crate the hop uses, *"whose `FirstRound`/
      `SecondRound` types CONSUME `self` and make reuse a type error rather than a review item."*
      **`@scure/btc-signer` has no such property.** `nonceGen` returns a plain `Nonces` value; nothing
      consumes it, nothing invalidates it, and signing twice under one secnonce is an ordinary call
      that type-checks. The guarantee §E171-r leans on **does not cross the language boundary**, so
      adopting this library means the nonce-reuse guard is now OURS to build — and the failure it
      prevents is the one §E171-r calls silent and total: two partials under one secnonce leak the
      LP's secret key, the fleet recovers it, holds both halves again, and every on-chain byte still
      looks correct. This tree has already shipped that bug once.
      ⭐ **USE `deterministicSign`, NOT `nonceGen` + `Session`.** BIP-327's deterministic mode derives
      the nonce from the secret, the message and `aggOtherNonce`, so there is no secnonce to persist,
      leak or replay — it removes the failure mode instead of guarding it, which is the standing
      preference for exactly this class of bug. It requires every OTHER signer's nonce first, so it
      is only available to the signer who goes last; in our 2-of-2 the fleet's hop presents its nonce
      and the LP signs second, which is precisely that position. ⚠️ Confirm the hop cannot be made to
      sign second (that would force the LP into stateful `nonceGen` and put the guard back on us).
      🔑 **The two pieces are independent and only ONE is Bitcoin.** `auth.lp_sig` is an EVM digest
      `ethers` can already sign and needs no new dependency; only the `exits` ladder needs BIP-327.
      Landing `lp_sig` first is real progress that is not blocked on the library question.
      ⚠️ **Nothing named `LpConsent`, `OpenAuth`, `lp_sig` or "pre-signed ladder" exists anywhere in
      ibiza** - re-verified 2026-08-16: every match in the repo is inside the vendored
      `backend/contracts/lib/SPV/` submodule, i.e. SPV's own code, not ours. Still greenfield, and
      the spec lives in SPV's QUEUE.md §E166-3 rather than in an ibiza section.
      🔴 **CORRECTION FROM SPV, 2026-08-18 — `auth.lp_sig` NO LONGER EXISTS. DO NOT BUILD IT.**
      SPV's §E183 item 1 (`7d11fe22`) DELETED `lp_eth` and `lp_sig` from `OpenAuth`; the struct is now
      `{ btc_recipient, btc_recipient_pop }` and the ABI signature is `(bytes32,bytes)`. **The LP signs
      NOTHING on the EVM side**: `lpEth` is DERIVED on-chain from `lpPubkey` via
      `ChannelLib.lpEthOf`, because Bitcoin and the EVM share secp256k1, so the channel key already
      determines the LP's EVM address. An `lpEth` supplied alongside a signature was a second source
      of truth for an address the chain can compute, which is the attribution hole that deletion closes.
      ⇒ **The "two pieces" above are now ONE.** The EVM-signature half — described here as *"small; the
      wallet already signs"* and as the piece to land first because it is not blocked on the MuSig2
      library — **is gone entirely.** What remains is the `exits` ladder, which is the BIP-327 half, so
      **this item is now blocked on `@scure/btc-signer` rather than having an easy first step.** That is
      a schedule change, not a scope reduction: the easy half did not get done, it stopped existing.
      📌 What the LP still supplies in `OpenAuth` is `btc_recipient_pop` — a BIP-340 Schnorr
      proof-of-possession over `btcRecipientPoPDigest(lpEth)`, i.e. a *Bitcoin* signature, not an EVM one.
      ⛔ **AND THE RELATED VERDICT, REACHED IN SPV AND RECORDED HERE BECAUSE ibiza OWNS THE DECISION:
      DO NOT ADOPT ERC-7947 (social recovery) FOR `lpEth`.** Three independent reasons:
        * It **reopens the attribution hole** the deletion above just closed. `_lpPayoutScript(lpEth)`
          derives the BTC payout FROM `lpEth`, and `btcRecipientOf` is one source of truth for BOTH
          cooperative-close attribution and the splice path — so **whoever compromises the recovery
          provider redirects that LP's payouts.**
        * It is a **trusted off-chain attester accepting a `proof`**, the category ruled out wholesale;
          the ERC's own security section concedes a malicious provider takes full account control.
        * It is **redundant, which is the strongest reason.** After §E183 item 1 `lpEth` IS the channel
          key's address, so an LP proves control of its own identity by signature with no third party.
          A recovery provider would buy — at the price of a trusted attester — a primitive already owned.
      ⚠️ Recovery of a LOST key is a different question and is NOT answered by this verdict; it is
      SPV's `§HANDOFF-2026-08-16-SEED-THREAD` OPEN 1 (an enclave-hosted LP has no recovery path, and
      needs a migration trust anchor of its own). Do not read "no ERC-7947" as "recovery is solved".
      ⚠️ It gates SPV Phases 2-3. **1(a), 1(b) AND 1(c) have all landed** (SPV `09fc4f8c`/`28a80ee3`,
      2026-08-16): the LP declares `Individual` so it boots on mainnet, a born seed is written out
      once as a mnemonic, `QUID_SEED` takes it back, and a `family` role gets a K-of-N Shamir split
      instead. ⇒ **Nothing on the SPV side is holding this item up any more; it is waiting on ibiza.**
- [ ] **Simplify along the `quid` seam.** Measured: quid `Aux+Vogue+VogueCore` = 1,742 lines with **0**
      `isBTC`; SPV `Aux+Vogue+Core` = 4,164 with **358**. quid is a working reference for the §J.2
      consolidation - but it never faced BTC, so it proves the cost, not that one impl serves both.
- [x] ✅ **`Registration2` certificate paths** - `test/registration/CertificateLifecycle.t.sol`, 5 tests,
      real contracts. Pins that `revokeCertificate` is PERMISSIONLESS BY DESIGN: it forwards to
      `StateKeeper.removeCertificate`, which is `onlyRegistration` and requires an expiry in the past,
      so it needs no authority precisely BECAUSE its precondition is on-chain fact rather than
      judgment. ⚠️ That is the property most likely to be "fixed" by adding `onlyOwner`; the tests
      make that fail loudly. Also recorded: `onlyRegistration` is an ALLOWLIST - a Registration2 must
      be added via `updateRegistrationSet`; pointing it at the keeper is not enough, and only one of
      the two directions comes from the initializer.
- [ ] **brainpoolP224r1** (DE 63, AE 42 DSCs). Deliberately unbuilt: unreachable until a tuple exists.
- [ ] **File the upstream reports.** `backend/circuits/UPSTREAM-REPORTS.md`, corrected; needs `gh` creds.

⚠️ **Needs a phone and a passport, and cannot be closed without one:** a committed witness for
`register_identity_td1`; end-to-end `registerViaNoir` / `registerDocumentViaIcao`; profile tuples for the
~3.5% PKD gap (IN 312, CH 240, SC 44, AT 62).

---

### 2.18ck THE WORKFLOW PIN WAS NEVER ENFORCED - `onReport` threw away the field that names it (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 7879</sub>

⛔ **PREMISE IS STALE (audited 2026-08-15).** The pin IS enforced: `RegistrySourceAnchor.onReport`
reads the workflow ID out of the metadata and reverts `UnpinnedWorkflow`. The remaining item below is
stale too - `REGISTRY_POSTMAN` was REPLACED by the forwarder+pin, not granted to it (`:167`).
⇒ Close unless someone identifies a path the pin does not cover. **The same hole is still OPEN in
`quid`'s `UMA.onReport` - see Live now.**

- [ ] Grant REGISTRY_POSTMAN to the Forwarder address alone once its calling convention is confirmed;

### 2.18cl "WE DONT NEED A POSTMAN AT ALL THOUGH?" - the chain cannot see a TLS session (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 7939</sub>

⛔ **PARTLY STALE (audited 2026-08-15).** `REGISTRY_POSTMAN` survives only in COMMENTS in
`RegistrySourceAnchor`; the grantable role was replaced by the forwarder + workflow pin. Items 1-2
below are therefore moot. Item 4 (`publishSnapshot` carries no workflow ID) was NOT re-audited and
may still be live.

- [ ] **Grant REGISTRY_POSTMAN to the Forwarder address and to nothing else** - this is the actual
- [ ] **Remove the role from the ICAO path entirely** - source-signed, so it needs no authority.
- [ ] Decide whether to verify DON signatures in-contract (permissionless for unsigned sources) or
- [ ] `publishSnapshot` is the bigger hole and outlives all of this: it carries no workflow ID and no

### 2.18cx THE PERMISSIONLESS ENROLMENT PATH IS ALREADY WIRED - what remains is a product decision (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 7982</sub>

⛔ **BLOCKER CLEARED (audited 2026-08-15).** "Close the six-profile gap first" is done: **88 live
profiles, 1 quarantined** (2.18gz). The enrolment path is also multi-profile now and `notAfter` is
derived from the document. What remains is the product decision in items 2-3, not the gap.

- [ ] Close the six-profile gap first (2.18co), or deleting the signer paths strands those holders.
- [ ] Then retire `registerDocumentViaNoir`/`renewDocumentViaNoir` and update the wallet SDK in the
- [ ] The revoke path is separate: it is the holder revoking their OWN document, so a signer there is

### 2.18df THE SIZE-CLASS QUESTION IS ANSWERED - and the answer is FIVE, measured (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 8009</sub>

- [ ] Prototype ONE 2^18-class circuit with padded arrays + true lengths as witnesses, and check it
- [ ] Do NOT pursue a single universal circuit (128x). Size classes only.

### 2.18ez FOUR CORRECTIONS, AND THE SCARCITY ARGUMENT HAS AN ALLOWLIST UNDER IT (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8051</sub>

- [ ] **Restore the taint predicate as REQUIRED, inverted**: `label ∉ tainted`. Not optional, not an
- [ ] **Fix or justify the signer gate on `registerDocumentViaNoir`.** As written, personhood is
- [ ] Automate taint propagation from public chain data, with the SEED set anchored separately from

### 2.18ey WHY THE CERTIFICATE CODE EXISTS - and what today's measurements did to that reason (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8123</sub>

- [ ] **This is a scope decision for the repo owner, not a defect to fix quietly.** Either restore
- [ ] If personhood-only is the answer, the certificate code stays - `HolderRegistration`, the title

### 2.18ex ANY CSCA MAY SIGN ANY CERTIFICATE, AND NOTHING RECORDS WHICH ONE DID (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8174</sub>

- [ ] **Record the signing CSCA on each certificate.** Small, and it is what makes issuer-scoped
- [ ] Then an issuer-scoped removal: drop every certificate whose `signerKey` is in an anchored
- [ ] Consider whether the certificate's own issuer field should be checked against the signer.

### 2.18ew PP'S ASSOCIATION SET WAS DELETED, NOT DEFERRED - and 2.13b said keep it (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8226</sub>

- [ ] **Fix the false header on `PrivacyPool`** before anything else here - it describes a guarantee
- [ ] **Decide whether to restore predicate 3.** It is the whole regulatory argument of Privacy
- [ ] If restored, it is a SEPARATE predicate, per 2.13b - a deployment may enable it, with the

### 2.18ev A REVOKED-BUT-UNEXPIRED CERTIFICATE CANNOT BE REMOVED AT ALL - and the fix needs no circuit (2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8277</sub>

- [ ] **Extend the ICAO workflow to emit the revoked-key tree.** `CRLs` is already a parsed field of
- [ ] **⚠️ AND THE ICAO WORKFLOW HAS NO ON-CHAIN WRITE PATH AT ALL.** `backend/cre/icao_master_list`
- [ ] **Do not gate it on the workflow.** The contract half closes the hole for any anchored revoked

### 2.18eu NO THRESHOLDS: reduce the CLAIM to what has a canonical key, and every one of those is trustless (user, 2026-08-06)
<sub>archive: `TODO-ARCHIVE.md` line 8336</sub>

- [ ] **Build CRL revocation** - and 2.18ev refines the shape: NOT keyed on issuer+serial, because
- [ ] **State the scope reduction explicitly**: the protocol does not screen persons against
- [ ] Re-check `IdentityRegistry`'s remaining predicates against the table above. If every one has a

### 2.18et "IS THERE A WAY WITH NO SACRIFICE" - no, and the binding constraint is the DATA (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8401</sub>

- [ ] **Say this in the docs.** The sanctions predicate has an authority; the reason is that the
- [ ] Revisit ONLY if a source begins publishing a canonical subject identifier, or if registration

### 2.18es FEWER MOVING PARTS: split the controller KEY, not the trust model (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8454</sub>

- [ ] Decide `n` and who holds the shares. **The only real question here**, and it is governance, not
- [ ] Additive `n`-of-`n` first, since it needs no dealer. Move to `t`-of-`n` only if a lost share
- [ ] Require `revoke` to cite `(registryId, snapshotIndex)` as EVIDENCE, explicitly not as a check.
- [ ] Say plainly in the docs that the sanctions predicate has an authority. Three measurements say

### 2.18er THE OPRF IS NOT THE BLOCKING DEPENDENCY, AND IT CONTRADICTS 2.18cu'S CENTRAL CLAIM (2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8510</sub>

- [ ] **Correct 2.18cu's central claim.** "Nobody whose action is required" is false for any design
- [ ] **The real open question: is there a canonical subject identifier at all?** Names are not,
- [ ] Only after that: OPRF for grindability, if there is an identifier to blind.

### 2.18eq MEASURED: Poseidon on-chain is dead, keccak in-circuit is fine, and coverage is 27.7% (2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8559</sub>

- [ ] If shipped, the claim must be stated exactly: *"not listed under a published passport number"*,

### 2.18ep BIND ON THE DOCUMENT NUMBER, NOT THE NAME - simpler, cheaper, and removes the controller (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8642</sub>

- [ ] Extend `sources.go` to parse `idList` (OFAC), the UN's `INDIVIDUAL_DOCUMENT`, and OFSI's
- [ ] Build the country map as an ENUMERATED table with an unmapped-string FAILURE, and anchor its
- [ ] Emit number variants as separate leaves rather than normalising, and pin the exact-match rule
- [ ] Then the non-membership circuit: extract issuing state + document number from the MRZ at their

### 2.18eo THE NAME-BINDING CIRCUIT CANNOT BE BUILT AGAINST THESE LEAVES - and the reason is in our own code (2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8737</sub>

- [ ] **Do the OPRF first.** It is the dependency, not an enhancement, and nothing downstream of a
- [ ] **Assess the NOTARY name-binding separately** - its leaf lacks the fatal `Reference` component,
- [ ] **Do NOT build sanctions name-binding as specified.** If it is wanted anyway, the CRE workflow

### 2.18en THE POSTMAN ROLE IS GONE - and 2.18cp's preferred option does not exist (2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8790</sub>

- [ ] **UNDO WRITE-ONCE.** It blocks the documented simulation-to-production migration. Make it
- [ ] **Implement `IReceiver` and `IERC165`.** `IReceiver is IERC165`, so `supportsInterface` may be
- [ ] Take the forwarder address from the Forwarder Directory for the target network rather than
- [ ] **Set the Forwarder at deployment.** A one-time step with no default; an anchor without it
- [ ] 2.18cm's "replace REGISTRY_POSTMAN with quid's write-once forwarder address" is DONE in

### 2.18ek THE FOLD CEILING IS 25, AND IT IS THE FOLD'S ALONE - the tree has none (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 8961</sub>

- [ ] Build a tree at 64 if a batch that size is ever wanted. Depths 3, 4 and 5 all give the same

### 2.18eh 5.1.0 DELETED - one pin, in one file, for host and container (user, 2026-08-05)
<sub>archive: `TODO-ARCHIVE.md` line 9134</sub>

- [ ] The nargo pin is still `1.0.0-beta.26+quid-icefix1` on the host and stock `1.0.0-beta.26` in the

### 2.18ec THE BATCH COMMITMENT HAD SILENTLY DIVERGED, and its guard could not fire (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9442</sub>

- [ ] **Audit the other cross-language pins for the same shape.** `NotaryRegistryProofTest` is cited

### 2.18dy The folded stack, built and measured (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9679</sub>

- [ ] Fold a real sixteen-withdrawal stack end to end. Needs witnesses threaded through the chain
- [ ] Generate the wrapper's EVM verifier and check it against `BatchVerifierLib`, which must move from

### 2.18dx Designing the fold to keep its advantages, not just its gate count (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9719</sub>

- [ ] Thread the accumulated COUNT through the kernels so the wrapper can expose it, and check it

### 2.18dw The folding number, measured directly (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9760</sub>

- [ ] Restructure `withdraw_identity` to `return_data`, and write the kernel and hiding circuits.
- [ ] Write our own chonk-verifying wrapper, the analogue of `rollup_tx_base_private`, and emit its EVM
- [ ] Decide whether to move the whole repo to a 6.0 toolchain or keep 5.1.0 for everything except this

### 2.18dv The decider number, found (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9797</sub>

- [ ] Build `bb-avm` from barretenberg source to compile and measure our own wrapper. That is now the

### 2.18du Folding researched properly: Aztec's is coupled, the general one is unfinished, and its decider needs a ceremony (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9836</sub>

- [ ] Recheck sonobe when ProtoGalaxy (PR 247), the decider (PR 259) and the Noir frontend land. If the

### 2.18dr Folding: accumulation is ~57x cheaper, and the decider needs a circuit we do not have (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9950</sub>

- [ ] To measure the decider we need either Aztec's hiding kernel circuit, or a folding implementation

### 2.18ds Batch sizes are fixed per circuit, and the multi-prover choice (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 9994</sub>

- [ ] Wire elect-to-wait at deposit: a queue the batcher serves, with the immediate path as the
- [ ] Decide which fixed sizes to run. 16 fills sooner and saves less; 256 saves 12x more and will not
- [ ] The multi-prover choice (2.18do) sits on top of this, and its blocker is the ceremony rather than

### 2.18dq Folding measured as far as it goes: accumulation is ~57x cheaper, the decider is still unmeasured (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10017</sub>

- [ ] Work out the app/kernel structure chonk expects, or find whether a plain stack is supported at

### 2.18do Two withdrawal paths, and what stands between us and them (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10055</sub>

- [ ] Prototype the translation and on-device proving with a **throwaway single-contributor key**,
- [ ] Test the translated circuit adversarially. Witnesses that must fail, confirmed failing. Seam 1 is
- [ ] Freeze the withdrawal circuit before the real ceremony. Every revision needs a new one, and this
- [ ] Only then the ceremony, with open contribution, published transcript, and a final random beacon.
- [ ] Dispatcher and wallet path selection last. Worthless without the above.
- [ ] Keep the batched Honk path as the default, so the yield floor and the timing cohort are what

### 2.18dp The batcher as a standing target (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10117</sub>

- [ ] Measure the folding decider against the recursive baseline in 2.18dk. It decides whether the

### 2.18dn COSTING GROTH16 FOR WITHDRAWALS - and it would make the aggregator redundant (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10142</sub>

- [ ] Prototype `noir-gnark` on `withdraw_identity` FIRST. Everything else is routine; this is the
- [ ] Do NOT build the depth-2 tree until this is decided - it is 256-slot fill for a saving the

### 2.18dm AGGREGATION IS A THROUGHPUT WIN, NOT A PER-WITHDRAWAL ONE - and Groth16 wins the thin case (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10184</sub>

- [ ] Fix `verifyBatch`'s unreachable `signals.length < maxBatch` branch - require a full batch, or
- [ ] Decide the FILL POLICY: settle singly below 2 pending, batch above. Nothing does this today.
- [ ] Price the hybrid seriously: Groth16 withdrawal (one ceremony) + Honk registration. On the thin
- [ ] Note the tension with the depth-2 tree (2.18dl): 256 slots make fill HARDER, so the tree pays

### 2.18dl THE AGGREGATION ECONOMICS, MEASURED ON-CHAIN AT LAST (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10240</sub>

- [ ] Build the depth-2 tree (N=256). Largest measured efficiency win available, no new primitives.
- [ ] Consider EIP-4844 blobs for the signal calldata at large N - at N=256 signals are ~917k gas, the

### 2.18dk THE N=16 BASELINE, MEASURED END-TO-END ON THE CURRENT PIN (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10281</sub>

- [ ] Minor: `BATCH_N=1` fails to compile (N=2 and N=16 are fine) - unexamined, and it would make the
- [ ] Minor: `inner_vk.nr`'s header says "112 field elements"; it is **115**. Stale comment.

### 2.18dj FOLDING ATTACKS THE 28 GB WITHOUT LEAVING THE STACK - and `bb` already ships it (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10326</sub>

- [ ] Prototype `bb prove -s chonk --ivc_inputs_path <stack>` over 16 `withdraw_identity` instances and
- [ ] Then price the final UltraHonk wrap of the folded accumulator (one recursive verification, not

### 2.18di WHAT STAYING FULLY NOIR ACTUALLY COSTS (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10371</sub>

- [ ] Revisit annually, not continuously, and revisit on EVIDENCE: (a) does `acvm-backend-plonky2` or a

### 2.18dh TESTING THE STARK PATH AS FAR AS THIS MACHINE ALLOWS - and "no rewrite" is mostly RIGHT (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10425</sub>

- [ ] Cheapest decisive test, in order: (a) does our ACIR load in that backend at all, given the
- [ ] Do NOT restate "we would rewrite every circuit" - measured false. The circuits are Noir; the

### 2.18dg "BUT WE DO AGGREGATION" - the gas argument against STARKs does not survive it (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10474</sub>

- [ ] If the on-device constraint ever relaxes (server-side proving, or a delegated prover that does

### 2.18dd IT WAS NEVER THE STACK - it is PER-PROFILE SPECIALISATION (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10552</sub>

- [ ] Do NOT re-open Noir vs Groth16 on the strength of this (2.18dc): the verifier count is a circuit

### 2.18dc IS NOIR/ULTRAHONK STRICTLY BETTER THAN CIRCOM/GROTH16? NO - and the reason we chose it is one axis (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10591</sub>

- [ ] When EIP-170 is finally addressed (deferred by the repo owner until last), remember the cause is

### 2.18da THE ORPHANS ARE ENUMERABLE AFTER ALL - EC_LEN is quantised by data-group count (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10622</sub>

- [ ] Cheap first check before building: 2.18cy showed `SA_LEN`/`DG1_LEN`/`N` are recoverable from the

### 2.18db KECCAK vs POSEIDON IS PRINCIPLED - but self-proved non-membership breaks the split (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10664</sub>

- [x] ✅ **DECIDED BY THE MEASUREMENT THAT WAS ALREADY SITTING THERE (2026-08-24).** The item asked
      for a measurement rather than a preference, and `test/registry/SanctionsRootHashCost.t.sol` —
      which inlines Poseidon, exactly as the item required — answers it. **Run it; do not re-derive:**
        * keccak pair hash **239 gas** · Poseidon pair hash **29,113 gas** — **121×**
        * a tree over N leaves is N−1 pair hashes:
          N=1,000 → keccak **238,761** / Poseidon **29,083,887**;
          N=17,000 → keccak **4,062,761** / Poseidon **494,891,887**
        * calldata floor alone at N=17,000: **8,704,000 gas**
      ⛔ **AN ETHEREUM BLOCK IS 30,000,000 GAS.** A Poseidon root over the OFAC SDN is **~16.5 whole
      blocks of hashing**, and even 1,000 leaves is a full block. ⇒ **`_computeRoot` CANNOT BE
      POSEIDON AT ANY REALISTIC LIST SIZE.** Not a tuning question — off by more than an order of
      magnitude at the smallest plausible input.
      ⇒ **SO THE POSEIDON SMT ROOT MUST BE ANCHORED AS A CLAIM, NOT COMPUTED**, which is what sec. 4's
      *"CRE publishes the identifier set as a Poseidon SMT keyed by the leaf hash"* already says. This
      measurement is why it is the only option rather than a preference.
      🔑 **AND THAT IS SAFE FOR EXACTLY THE REASON COURT'S REMOVAL RESTS ON: the root is not
      trusted, it is CHECKABLE.** Keep publishing the full leaf set for data availability so anyone
      can rebuild the Poseidon SMT off-chain and contradict a wrong root; `ROOT_ACTIVATION_DELAY` is
      the window to do it in. **Not-computed is not the same as not-verified**, and conflating the two
      is how this decision gets reopened.
      ⚠️ **THE REMAINING COST IS DATA AVAILABILITY, ALREADY BOOKED ELSEWHERE.** 8.7M gas of calldata
      per refresh at SDN scale is real; sec. 2.18dm's *"consider EIP-4844 blobs for the signal
      calldata at large N"* is the answer, and it now has a second reason to exist.
      ❓ Still open and NOT settled by this: whether the on-chain keccak root stays ALONGSIDE the
      anchored Poseidon one. Keeping both costs 4M gas of hashing at SDN scale and buys *"the leaf set
      provably corresponds to a root this contract derived"*. **Measure whether that property is worth
      4M gas before assuming either way.**

### 2.18cz WHAT FOLDS AND WHAT CANNOT - and 7 profiles we are missing (user, 2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10693</sub>

- [ ] ~~Treat the OPRF as a dependency of self-proved non-membership.~~ **RE-ORDERED by 2.18er**: the

### 2.18cy THE SIX ORPHANS: EC_LEN IS THE ONLY MISSING GENERIC, AND IT IS DOCUMENT-SPECIFIC (2026-08-04)
<sub>archive: `TODO-ARCHIVE.md` line 10747</sub>

- [ ] Six orphans need one SOD each. NOT RAM-blocked, NOT toolchain-blocked - the swap fix does not
- [ ] Until then the Groth16 verifiers for those six MUST stay: they are those profiles' only

### 2.18cw REMOVING ALL FOUR, AND EACH REPLACEMENT IS STRICTLY STRONGER (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10788</sub>

- [ ] 1. Land the proofs first - name-binding circuit, DON signature verification, CRL anchoring,
- [ ] 2. Remove the four authorities as each proof lands, smallest blast radius first.
- [ ] 3. THEN freeze the proof-path contracts (immutable, or an owner-renounced timelock). Until this
- [ ] Never claim the postman is gone while step 3 is open - the upgrade key IS the postman, with a

### 2.18cv THE POSTMAN INVENTORY - one is gone, four are not (user: "there is no postman anymore", 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10836</sub>

- [ ] Track these four to zero. None is blocked on a decision: three share the same circuit (2.18cu)

### 2.18cu SELF-PROVED NON-MEMBERSHIP - reinstating 2.18ct's retraction, which was wrong twice (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10856</sub>

- [ ] Withdrawal-time non-membership against the anchored sanctions root, root validity by
- [ ] Recheck the ~8-opcode estimate against the bracketing term (third revision of this number; the

### 2.18ct FEWER MOVING PARTS - SUPERSEDED BY 2.18cu, both its grounds were wrong (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10907</sub>

- [ ] **`ROOT_ACTIVATION_DELAY` is still live** in `latestActiveRoot`, although 2.18br concluded it

### 2.18cs EVIDENCE FOR #41, FROM THE SHIPPED CODE - two of its open questions are already answered (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 10968</sub>

- [ ] For #41: bind the leaf to a document nullifier (trap 6), not to `sk_identity`.
- [ ] For #41: the label term's answer to silence is `registerViaNoir`'s shape. Also fix the live

### 2.18cr EVIDENCE-BOUND REVOCATION IS NOT CONTRACT-ONLY - I said it was, and the envelope says otherwise (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11010</sub>

- [ ] Name-binding circuit: prove `hash(document name fields) == leaf` for a leaf in an anchored
- [ ] THEN evidence-bound `revoke`: inclusion proof replaces `CONTROLLER`'s discretion for the

### 2.18cq THE BLACKLIST IS NOT INTEGRATED WITH THE ASP AT ALL - and the lean way in already exists (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11047</sub>

- [ ] Record per-source whether exclusion is by ABSENCE or by a status field, in `SourceSpec`

### 2.18cp "WHY CAN'T IT BE REMOVED?" - it can; the claim conflated trust with authority (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11094</sub>

- [ ] Verify DON report signatures in `RegistrySourceAnchor` and drop `onlyRole` from the report path,

### 2.18co THE 35/6/ADDRESS CLAIM RE-MEASURED - and today's Docker work did not touch it (2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11185</sub>

- [ ] Decide the six twinless profiles: generate Noir verifiers or retire the profiles. Not

### 2.18cm THE FORWARDER PATTERN, TAKEN FROM `quid` AS REFERENCE ONLY (user, 2026-08-03)
<sub>archive: `TODO-ARCHIVE.md` line 11219</sub>

- [ ] **Replace `REGISTRY_POSTMAN` with quid's write-once forwarder address** in
- [ ] **Write ibiza's deployment sequence**, with forwarder wiring as an explicit step that FAILS

### 2.18gz-unify 🟢 THE COHESIVE PREDICATE IS BUILDABLE — but on ADDRESSES, not names
<sub>archive: `TODO-ARCHIVE.md` line 16179</sub>

- [ ] CRE publishes the identifier set as a Poseidon SMT keyed by the leaf hash, not a sorted list
- [ ] `RegistrySourceAnchor` anchors that root; reuse `isValidRoot`'s `MAX_ROOT_AGE` rule so
- [ ] Withdrawal circuit: one `smt_verifier_full(..., fnc = true)` term keyed by the recipient
- [ ] Recheck the opcode estimate against THIS term - the third revision the note asks for, now


---

# §SOLANA-RUST — handoff from the SPV/svm session (2026-08-27/28)

Moved here because the client-side proof lives here: puppeteer against the
deployed program, and **StrongBox enrollment on a physical phone**, which is the
next thing to be plugged in. Protocol-side work stays in `SPV/svm`; this is the
list of what is done, what is not, and what is now known.

## STATUS OF THE CODE

- ✅ **One config instruction.** `set_kestrel` folded into `update_config`; it was
  never a second config *account*, only a second entrypoint onto the same
  `ProgramConfig` with its own accounts struct and its own spelling of the admin
  gate. `init_config` is one instruction (lib.rs entrypoint + entra.rs body).
- ✅ **`bebop_authority` → `flash_authority`.** The account it gates was already
  named that; the error said a third thing. Bebop is one prospective integration
  in its own repo, and the gate is venue-agnostic.
  ⚠️ It must SIGN — so it is a PDA of whatever settlement program is trusted, or
  a keypair. We PIN an address; we do not own the key.
- ✅ **`ProgramConfig::SPACE` fixed.** It counted a `keeper` field that does not
  exist and claimed 324 against terms summing to 283; real need is 251.
  ⚠️ Deployed accounts keep 32 bytes of slack; a FRESH deploy does not, so any
  later field needs a real `realloc`.
- ✅ **One ticker file.** `tickers_slim.rs` deleted, the `all-tickers` feature
  gate removed. 1,704 non-deliverable equity entries COMMENTED (reversible),
  160 kept = the 80 `XSTOCK_MINTS` tickers across hex + account maps.
- ✅ **29 tests that had never run now run.** They were behind the feature gate
  AND did not compile under it (`use super::*` reaches `tickers`, which
  re-exports none of the risk types). Root cause was three private consts.
  **Default `cargo test` is now 101/101 with no flag.**
- ✅ **Risk-model fixes:** cold-start GPD prior n=4→n=2 (an unmeasured tail is now
  a BOUND, not a guess); drawdown decay made elapsed-time-based, so splitting a
  gap can no longer accelerate the fade.

## NOT DONE — do not mark these off

- 🟠 **LayerZero devnet: WAS UNREACHABLE BY CONSTRUCTION; code blocker now
  removed, run still not done.** The bridge has never carried a message.
  ⭐ THE BLOCKER WAS TWO INTEGERS, which is why the task looked merely unstarted:
  `SOLANA_EID`/`ETHEREUM_EID` were compile-time MAINNET constants (30168/30101),
  `lz_receive` enforces `params.src_eid == ETHEREUM_EID`, and `bridge_home` sends
  to `dst_eid: ETHEREUM_EID`. LayerZero testnet EIDs are 40xxx — Solana devnet
  **40168**, Sepolia **40161** (confirmed against LZ docs 2026-08-28). So a
  devnet message would have been rejected by OUR OWN GUARD, and a send would have
  gone to Ethereum mainnet. No amount of funding or deployment would have fixed
  it.
  ✅ Now behind `--features testnet`. Kept as CONSTANTS rather than moved into
  `OAppStore`, because that struct's docstring gives the right reason —
  "storing either would only create a way for the record and the code to
  disagree" — which holds; it just assumed one deployment. `eids_are_coherently_paired`
  fails any build that mixes a 30xxx with a 40xxx. 102/102 both ways.
  ⚠️ REMAINING BLOCKERS, both environmental:
    - wallet `4BYcGVBnvzPKT74wZaTE3aoaJTePZWunEDiji1EbkuNP` has **0 devnet SOL**
      and the faucet is rate-limited;
    - the devnet program `EnEfbQwmy9GpKx55EfUh79sV8ruhDmtCpVaAikjjgfDp` IS
      deployed (1.6 MB, slot 455147212) but its upgrade authority is
      `4tN59r6FjtPeepxvinp4q5Ckg2ir5ckPkt16UHaRgVJ6` — **not ours** — so the
      current build cannot be pushed to it.
  ✅ Endpoint pin is correct: `76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6` is
  executable on BOTH devnet and mainnet (checked live), and the 819 KB local
  fixture matches.
  ⛔ AND A CORRECTION TO AN EARLIER AUDIT NOTE IN THIS THREAD: it recorded
  "source chain verified (`src_eid == store.eid`) ✅". There is no `store.eid`.
  The check is against a constant. The check exists; the coordinate was wrong.
- 🔴 **StrongBox enrollment untested** — this is the phone work, and it is why
  this list is here.
- 🔴 **Puppeteer proof of the deployed program** — client side, not started.
- 🔴 **SEEKER APP IS OUT OF SYNC WITH THE PROGRAM, AND THE GUARD WAS DEAD.**
  Earlier in the same thread the app was stripped (device enrollment removed —
  it is Expo + Mobile Wallet Adapter, never had Seed Vault or StrongBox; the IDL
  it shipped was the 28-instruction prediction-market build), cut to 4 components
  + 4 hooks, typechecked clean, and pushed to `github.com/quidmints/quid` `dev`
  @ `933ee54` with 4 parity tests. **It was NOT brought into SPV** — only
  `svm/tests/seeker-parity.ts` came across.
  ✅ NO RUNTIME BREAKAGE from the 2026-08-27/28 program changes: the app calls
  only `.deposit(` and `.withdraw(`, whose account lists are untouched, and it
  decodes `ProgramConfig` reading only `tokenMint`, which sits before every field
  that moved.
  🔴 STALE IDL: `seeker-main/constants/quid.json` declares **14** instructions
  including `set_kestrel`; the program now exposes **13**, and `update_config`
  changed args and gained a `bank` account. Parity test P.1 compares the two IDLs
  byte-for-byte and WOULD fail.
  🔴 THE GUARD WAS INERT ALL SESSION AND PASSED WHILE INERT. `findSeeker()` looks
  in `svm/seeker` and `<repo>/seeker`; the app is at
  `/home/rico/projects/seeker-main`. `svm/target/idl/quid.json` requires an
  `anchor build` that was never run. Both sides missing ⇒ every assertion
  skipped, silently.
  ▶️ TO RE-ARM: `anchor build`, then
  `QUID_SEEKER_DIR=/home/rico/projects/seeker-main yarn test`, then refresh
  `constants/quid.json` from `target/idl/quid.json`. Decide whether the app moves
  into SPV or stays in `quidmints/quid` — the parity test assumes one repo.
- 🔴 **Squads multisig is an unenforced `&str`.**
- 🔴 **The compromised `keypair.json` in `main`'s history.**

## FINDINGS THAT CHANGE THE DESIGN

- 🔴 **`downside_vol_bps` IS COMPUTED AND CONSUMED BY NOTHING.** `etc.rs:992`
  maintains a GJR downside EMA; `collar_bps`, `hazard_rate_bps` and `lgd_bps` all
  read the TWO-SIDED `eff_sigma`. Its own docstring says it is kept "so the
  asymmetry is observable rather than just baked in" — and nothing observes it.
  **The fitted asymmetry exists and is being discarded.** This is the foundation
  for the asymmetric-collar work below; it is not new machinery.
- 🔴 **The collar over-collateralises ~6× its own stated target.** It is sized to
  `COLLAR_BREACH_BPS = 100` (1%); measured against calibrated equity returns
  (Student-t ν=4, GARCH(1,1) α=.08 β=.90, GJR, overnight+weekend gaps) the worst
  realised breach is **17 bps**. Same answer as an independently invented tail
  (16 bps), so it is robust to the return process.
- 🔴 **The collar stops discriminating leverage above ~2×.** 2×/5×/10× give
  IDENTICAL collars because the σ floor binds. A 10× position posts the same
  proportional band as a 5× with twice the sensitivity.
- 🔴 **Horizon mismatch.** `collar_bps` is a ONE-STEP tail; the unwind ladder runs
  `N = 7d/LIQ_GRACE_SECS = 168` windows at `MAX_TRANCHE_BPS = 185`. So the pool
  carries a decaying position for A WEEK against a one-hour collar (√168 ≈ 13×).
  6× of cushion against 13× of horizon ⇒ **~2× short**. That gap is the only
  thing a securities facility needs to fund.
- 🔴 **~26% of variance arrives in gaps** (overnight + weekend), which is exactly
  when neither the ladder can unwind nor a spot hedge can trade.
- 🔴 **SOL settlement can create an unhedged short.** `NativeLeg` pays dollar
  claims out of pool lamports while a SOL depositor's claim IS lamports;
  `clutch.rs:671` bounds the withdrawal, so it fails as a REVERTED WITHDRAWAL,
  not silent insolvency. The pool must buy SOL back at an unknown later price.
  No `sol_owed` liability is recorded when it happens.

## THE FACILITY POLICY (settled)

Buy real paper **as principal**, for the **aggregate residual only**, sized to
**~2× the collar**, concentrated in high-vol / high-leverage positions.
Not per-position (the band handles that). Not full coverage (7.5% deliverable is
ample for a 2× residual). No borrow leg — no borrow market for tokenised equities
exists; every venue lists them as collateral only. No competitor venue (owner).

**Licensing: ordinary customer.** FinSA Art 5 opt-out is **CHF 2M in assets**, a
pure asset test — not the €20M/€40M large-undertaking route.
⚠️ It must be the ENTITY'S OWN capital, not depositor TVL.
⚠️ The *"private investment structure with professional treasury"* route requires
"a professionally qualified person managing its financial resources" — which the
no-board design deliberately lacks. **Take the asset route, not the treasury
route.** Whichever entity holds the securities is the one that must qualify.
⚠️ **Ostium is not precedent for holding real paper** — they were purely
synthetic and never bought a share. Their model avoided the securities question
rather than answering it.

## NEXT: THE ASYMMETRIC COLLAR ("two draggable bars")

The `[lower, upper]` band IS a collar strategy — long the synthetic, floored at
`lower`, capped at `upper`. Dragging a bar moves a strike, and the premium
differential is option value. The new calculus:

1. **Per-side collars.** `collar_down` off the DOWNSIDE tail, `collar_up` off the
   upside. GJR already says downside vol > upside vol, so equal breach
   probability implies `collar_down > collar_up` — a symmetric band is either
   under-protecting the downside or over-charging the upside.
2. **Per-side hazard.** `hazard_rate_bps` takes ONE collar today. It becomes the
   sum of two side hazards, each with its own intensity and LGD.
3. **The differential is convex**, which is why it is "tremendous": the downside
   tail is fatter, so stretching the floor costs disproportionately more than
   stretching the cap. That convexity is the product.
4. ⚠️ **This also fixes the objective mismatch.** Principal protection is an
   OPTION payoff; a delta hedge is linear and cannot truncate one tail without
   truncating the other. Per-side bars give the convexity directly, on-chain,
   without a broker.
