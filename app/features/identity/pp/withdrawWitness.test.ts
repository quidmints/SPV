// Run: node --test src/pp/withdrawWitness.test.ts
//
// THE WITNESS HANDED TO THE PROVER. Every fault here is silent in the same way: the map still has
// the right shape, the prover still runs, and the failure appears either as an unprovable witness
// minutes later or as an on-chain rejection with nothing pointing back to this file.
//
// THE TEST THAT MATTERS MOST is the input-name check. The keys of `inputs` must be exactly the
// parameter names of `withdraw_identity::main`, because Noir binds by name — a renamed or dropped
// key is not a type error in TypeScript and not a compile error in the circuit, it is a proof that
// never happens. So the names are pinned here against the circuit source, the same way the state
// tree is pinned against lean-imt.sol rather than against more TypeScript.
import test from "node:test";
import assert from "node:assert";
import {
  buildWithdrawalWitness,
  holderRootFromSk,
  nextWithdrawalIndex,
} from "./withdrawWitness.ts";
import { MAX_TREE_DEPTH, StateTree } from "./stateTree.ts";
import { IDENTITY_TREE_DEPTH } from "./identityProof.ts";
import {
  commitment as commitmentHash,
  depositSecrets,
  masterKeysFromMnemonic,
  nullifierHash,
  withdrawalSecrets,
} from "./notes.ts";
import type { RecoveredNote } from "./discovery.ts";

const PHRASE =
  "produce front turtle firm rival still push install produce front turtle firm " +
  "rival still push install produce front turtle firm rival still push infant";

const KEYS = masterKeysFromMnemonic(PHRASE);
const SCOPE = 0x5c09en;
const LABEL = 0x1abe1n;
const VALUE = 10n ** 18n;

/** A real note: real secrets, real commitment. Nothing here is hand-built. */
function makeNote(overrides: Partial<RecoveredNote> = {}): RecoveredNote {
  const secrets = depositSecrets(KEYS, SCOPE, 0n);
  const base: RecoveredNote = {
    scope: SCOPE,
    label: LABEL,
    index: 0,
    kind: "deposit",
    nullifier: secrets.nullifier,
    secret: secrets.secret,
    value: VALUE,
    commitment: commitmentHash(VALUE, LABEL, secrets),
    spent: false,
  };
  return { ...base, ...overrides };
}

/** A tree holding the note among unrelated leaves, at a carry-up index — the case the old
 *  StateTree.proof() got wrong, so the witness is built over the shape that used to break. */
function makeTree(note: RecoveredNote): { tree: StateTree; index: bigint } {
  const tree = new StateTree([111n, 222n, note.commitment]);
  return { tree, index: 2n };
}

const build = (over: Record<string, unknown> = {}) => {
  const note = (over.note as RecoveredNote) ?? makeNote();
  const { tree, index } = makeTree(note);
  return buildWithdrawalWitness({
    note,
    stateLeafIndex: index,
    stateTree: tree,
    masterKeys: KEYS,
    withdrawnValue: VALUE / 4n,
    context: 0x123456789abcdefn,
    identity: { identityRoot: 0xabcdefn, siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n) },
    revocationSecret: 0xdeadbeefn,
    // Non-zero root: the pool refuses zero, so a fixture proving against an empty tree describes a
    // withdrawal that could never settle. Exclusion witnesses stay in the empty-subtree form.
    blacklist: {
      root: 0xb1acn,
      label: { siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n), oldKey: 0n, oldValue: 0n, isOld0: true },
      document: { siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n), oldKey: 0n, oldValue: 0n, isOld0: true },
    },
    documentId: 0xd0cn,
    withdrawalIndex: 0n,
    ...over,
  } as Parameters<typeof buildWithdrawalWitness>[0]);
};

// ── the circuit contract ──────────────────────────────────────────────────────────────────────

test("the input keys are EXACTLY withdraw_identity::main's parameters", () => {
  // Pinned from backend/circuits/withdraw_identity/src/main.nr. Noir binds by name, so a key this
  // list does not contain is ignored by the prover and a parameter missing from `inputs` makes the
  // proof impossible — neither is visible to the type system on either side.
  const CIRCUIT_PARAMS = [
    // public, in declaration order
    "new_commitment",
    "existing_nullifier_hash",
    "withdrawn_value",
    "state_root",
    "state_tree_depth",
    "identity_root",
    "context",
    "blacklist_root",
    // private
    "value",
    "label",
    "nullifier",
    "secret",
    "state_leaf_index",
    "state_siblings",
    "out_nullifier",
    "out_secret",
    "revocation_secret",
    "identity_siblings",
    // the blacklist predicate: ONE root, two domain-separated exclusions
    "blacklist_siblings",
    "blacklist_old_key",
    "blacklist_old_value",
    "blacklist_is_old0",
    "document_id",
    "document_siblings",
    "document_old_key",
    "document_old_value",
    "document_is_old0",
  ].sort();

  assert.deepStrictEqual(Object.keys(build().inputs).sort(), CIRCUIT_PARAMS);
});

test("pubSignals is the eight public parameters, in the circuit's declaration order", () => {
  // ProofLib.WithdrawProof.pubSignals is positional: a reordering here pairs each value with the
  // wrong meaning on-chain, and `context` landing anywhere but [6] breaks the recipient binding.
  const w = build();
  const i = w.inputs as Record<string, string>;
  assert.deepStrictEqual(
    w.pubSignals.map(String),
    [
      i.new_commitment,
      i.existing_nullifier_hash,
      i.withdrawn_value,
      i.state_root,
      i.state_tree_depth,
      i.identity_root,
      i.context,
      // [7] the blacklist root. BOTH exclusion terms are proven against this one value - the
      // domains separate the keys, not the trees, so a second root would defeat the point.
      i.blacklist_root,
    ],
  );
  assert.strictEqual(w.pubSignals.length, 8);
});

test("the fixed-size arrays match the circuit's declared lengths", () => {
  const w = build();
  assert.strictEqual((w.inputs.state_siblings as string[]).length, MAX_TREE_DEPTH);
  assert.strictEqual((w.inputs.identity_siblings as string[]).length, IDENTITY_TREE_DEPTH);
  assert.strictEqual((w.inputs.blacklist_siblings as string[]).length, IDENTITY_TREE_DEPTH);
  assert.strictEqual((w.inputs.document_siblings as string[]).length, IDENTITY_TREE_DEPTH);
});

test("every scalar input is a plain decimal string", () => {
  // Noir accepts decimal or 0x-hex, but mixing them is how a leading-zero or width assumption slips
  // in unnoticed. The module documents decimal; this asserts it.
  for (const [k, v] of Object.entries(build().inputs)) {
    // The SMT `is_old0` flags are genuinely boolean and must reach the toml unquoted, so they are
    // outside this convention rather than an exception to it - `is_old0 = "true"` fails to
    // deserialize, and the error names the argument rather than the quoting.
    if (typeof v === "boolean") continue;
    for (const s of Array.isArray(v) ? v : [v]) {
      assert.match(s, /^\d+$/, `${k} is not a decimal string: ${s}`);
    }
  }
});

// ── value conservation ────────────────────────────────────────────────────────────────────────

test("the change note carries exactly the remainder", () => {
  const note = makeNote();
  for (const withdrawn of [1n, VALUE / 4n, VALUE / 2n, VALUE - 1n, VALUE]) {
    const w = build({ note, withdrawnValue: withdrawn });
    const expected = commitmentHash(note.value - withdrawn, note.label, w.changeNote);
    assert.strictEqual(w.newCommitment, expected, `remainder wrong when withdrawing ${withdrawn}`);
    assert.strictEqual(BigInt(w.inputs.withdrawn_value as string), withdrawn);
  }
});

test("the change note is re-derivable from the seed, or the remainder is lost forever", () => {
  // The single most dangerous input in this module: discovery re-derives change notes as
  // withdrawalSecrets(keys, label, k). If the witness used anything else, the remainder would be
  // unspendable and nothing would say so until the user came back for it.
  for (const k of [0n, 1n, 5n]) {
    const w = build({ withdrawalIndex: k });
    assert.deepStrictEqual(w.changeNote, withdrawalSecrets(KEYS, LABEL, k));
  }
});

test("the spent note's nullifier hash is the published one", () => {
  const note = makeNote();
  const w = build({ note });
  assert.strictEqual(w.pubSignals[1], nullifierHash(note.nullifier));
});

test("the state root and depth come from the tree, not from the note", () => {
  const note = makeNote();
  const { tree, index } = makeTree(note);
  const w = build({ note });
  const p = tree.proof(index, MAX_TREE_DEPTH);
  assert.strictEqual(w.pubSignals[3], p.root);
  assert.strictEqual(w.pubSignals[4], BigInt(p.depth));
  assert.deepStrictEqual(w.inputs.state_siblings, p.siblings.map((s) => s.toString(10)));
});

// ── refusals ──────────────────────────────────────────────────────────────────────────────────

test("a spent note is refused", () => {
  assert.throws(() => build({ note: makeNote({ spent: true }) }), /already spent/);
});

test("a withdrawal outside (0, value] is refused", () => {
  assert.throws(() => build({ withdrawnValue: 0n }), /must be > 0/);
  assert.throws(() => build({ withdrawnValue: -1n }), /must be > 0/);
  assert.throws(() => build({ withdrawnValue: VALUE + 1n }), /withdrawing/);
});

test("a note whose commitment does not match its own secrets is refused", () => {
  // Catches a corrupted or hand-built note before the prover spends minutes proving nothing.
  const bad = makeNote({ value: VALUE * 2n });
  assert.throws(() => build({ note: bad }), /holds|recomputed commitment/);
});

test("a leaf index pointing at the wrong commitment is refused", () => {
  const note = makeNote();
  const { tree } = makeTree(note);
  assert.throws(
    () =>
      buildWithdrawalWitness({
        note,
        stateLeafIndex: 0n, // holds 111n, not the note
        stateTree: tree,
        masterKeys: KEYS,
        withdrawnValue: 1n,
        context: 0x1234n,
        identity: { identityRoot: 1n, siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n) },
        revocationSecret: 1n,
        // Non-zero root: the pool refuses zero, so a fixture proving against an empty tree describes a
        // withdrawal that could never settle. Exclusion witnesses stay in the empty-subtree form.
        blacklist: {
          root: 0xb1acn,
          label: { siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n), oldKey: 0n, oldValue: 0n, isOld0: true },
          document: { siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n), oldKey: 0n, oldValue: 0n, isOld0: true },
        },
        documentId: 0xd0cn,
        withdrawalIndex: 0n,
      }),
    /Wrong index, or a stale tree/,
  );
});

test("an identity witness of the wrong depth is refused", () => {
  assert.throws(
    () => build({ identity: { identityRoot: 1n, siblings: [0n, 0n] } }),
    /siblings, but the circuit is fixed at/,
  );
});

test("a context outside the field is refused", () => {
  // `context` is the only thing binding the proof to a recipient, so a zero or wrapped value would
  // silently unbind it.
  assert.throws(() => build({ context: 0n }), /context must be a nonzero/);
});

// ── the withdrawal index convention ───────────────────────────────────────────────────────────

test("nextWithdrawalIndex counts change notes on THIS label only", () => {
  const change = (label: bigint): RecoveredNote =>
    makeNote({ kind: "withdrawal-change", label });
  assert.strictEqual(nextWithdrawalIndex([], LABEL), 0n);
  assert.strictEqual(nextWithdrawalIndex([change(LABEL), change(LABEL)], LABEL), 2n);
  assert.strictEqual(nextWithdrawalIndex([change(LABEL + 1n)], LABEL), 0n);
  // Deposits on the same label must not be counted — they are not withdrawals.
  assert.strictEqual(nextWithdrawalIndex([makeNote(), change(LABEL)], LABEL), 1n);
});

// ── the shared holder-root derivation ─────────────────────────────────────────────────────────

test("holderRootFromSk is deterministic and separates identities", () => {
  // Exported so the wallet, the postman tooling and the fixture builder cannot drift apart.
  assert.strictEqual(holderRootFromSk(12345n), holderRootFromSk(12345n));
  assert.notStrictEqual(holderRootFromSk(12345n), holderRootFromSk(12346n));
});
