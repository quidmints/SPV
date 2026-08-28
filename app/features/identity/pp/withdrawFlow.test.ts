// Run: node --test src/pp/withdrawFlow.test.ts
//
// THE JOIN. Selection is the part with real consequences: the circuit spends ONE note and returns
// the remainder as change, so choosing badly leaves a large, distinctively-valued change note that
// every later spend carries. And notes cannot be combined, so "insufficient" has to be reported
// against the largest SINGLE note rather than the balance — otherwise the wallet refuses while
// visibly holding enough, which reads as a bug and invites the user to retry forever.
import test from "node:test";
import assert from "node:assert";
import {
  largestSpendable,
  prepareWithdrawal,
  selectNoteFor,
} from "./withdrawFlow.ts";
import { NATIVE_ASSET } from "./withdrawPlan.ts";
import { StateTree } from "./stateTree.ts";
import {
  commitment as commitmentHash,
  depositSecrets,
  masterKeysFromMnemonic,
} from "./notes.ts";
import { IDENTITY_TREE_DEPTH } from "./identityProof.ts";
import type { RecoveredNote } from "./discovery.ts";

const PHRASE =
  "produce front turtle firm rival still push install produce front turtle firm " +
  "rival still push install produce front turtle firm rival still push infant";
const KEYS = masterKeysFromMnemonic(PHRASE);
const ENTRYPOINT = "0x00000000000000000000000000000000000000e1";
const FEE = { feeRecipient: "0x00000000000000000000000000000000000000f1", relayFeeBPS: 250n };
const TOKEN = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

/** A real note: real secrets, real commitment, so the witness builder's own checks apply. */
function note(scope: bigint, index: number, value: bigint, over: Partial<RecoveredNote> = {}): RecoveredNote {
  const s = depositSecrets(KEYS, scope, BigInt(index));
  const label = 0x1abe1n + BigInt(index);
  return {
    scope,
    label,
    index,
    kind: "deposit",
    nullifier: s.nullifier,
    secret: s.secret,
    value,
    commitment: commitmentHash(value, label, s),
    spent: false,
    ...over,
  };
}

const ETH = 10n ** 18n;

function poolOf(scope: bigint, notes: RecoveredNote[]) {
  // Real tree, with the notes at carry-up-prone indices — the shape StateTree.proof() used to break.
  const tree = new StateTree([999n, ...notes.map((n) => n.commitment)]);
  return {
    scope,
    stateTree: tree,
    leafIndexOf: (n: RecoveredNote) => BigInt(notes.indexOf(n) + 1),
    notes,
    identity: { identityRoot: 0xabcdefn, siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n) },
    // A NON-ZERO root, because the pool refuses zero - a fixture built against an empty tree could
    // never settle, so using one here would make these tests pass on a shape production rejects.
    // The exclusion witnesses are still the empty-subtree form: absence is what they must show, and
    // these tests are about note selection and leg planning, not about SMT paths.
    blacklist: {
      root: 0xb1acn,
      label: { siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n), oldKey: 0n, oldValue: 0n, isOld0: true },
      document: { siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n), oldKey: 0n, oldValue: 0n, isOld0: true },
    },
    documentId: 0xd0cn,
  };
}

// ── selection ─────────────────────────────────────────────────────────────────────────────────

test("an exact match wins — it leaves no change note at all", () => {
  const notes = [note(1n, 0, 5n * ETH), note(1n, 1, 2n * ETH), note(1n, 2, 3n * ETH)];
  assert.strictEqual(selectNoteFor(notes, 2n * ETH), notes[1]);
});

test("otherwise the SMALLEST covering note is chosen, to leave the smallest remainder", () => {
  // Spending the 5 ETH note for 1.5 would leave 3.5 — a distinctive number carried by every later
  // spend of that change.
  const notes = [note(1n, 0, 5n * ETH), note(1n, 1, 2n * ETH), note(1n, 2, 3n * ETH)];
  assert.strictEqual(selectNoteFor(notes, 3n * ETH / 2n), notes[1]);
});

test("spent notes are never selected", () => {
  const notes = [note(1n, 0, 5n * ETH, { spent: true }), note(1n, 1, 6n * ETH)];
  assert.strictEqual(selectNoteFor(notes, ETH), notes[1]);
});

test("no note is returned when none covers the amount — notes cannot be combined", () => {
  const notes = [note(1n, 0, ETH), note(1n, 1, ETH)];
  assert.strictEqual(selectNoteFor(notes, 2n * ETH), null, "two notes were treated as combinable");
});

test("selection is deterministic, so a restored wallet spends the same note", () => {
  const notes = [note(1n, 0, 3n * ETH), note(1n, 1, 3n * ETH)];
  assert.strictEqual(selectNoteFor(notes, 2n * ETH), selectNoteFor(notes, 2n * ETH));
  assert.strictEqual(selectNoteFor(notes, 2n * ETH), notes[0], "ties did not resolve to chain order");
});

test("largestSpendable reports the biggest single note, not the balance", () => {
  // The distinction the error message depends on.
  const notes = [note(1n, 0, ETH), note(1n, 1, 2n * ETH), note(1n, 2, 4n * ETH, { spent: true })];
  assert.strictEqual(largestSpendable(notes), 2n * ETH);
  assert.strictEqual(largestSpendable([]), 0n);
});

test("a zero or negative request is refused", () => {
  assert.throws(() => selectNoteFor([], 0n), /must be > 0/);
});

// ── preparation ───────────────────────────────────────────────────────────────────────────────

const prepareNative = (payoutValue: bigint, notes: RecoveredNote[]) =>
  prepareWithdrawal({
    mnemonic: PHRASE,
    entrypointAddress: ENTRYPOINT,
    fee: FEE,
    asset: NATIVE_ASSET,
    payoutValue,
    masterKeys: KEYS,
    payoutPool: poolOf(1n, notes),
    revocationSecret: 0xdeadbeefn,
  });

test("a native withdrawal prepares one leg with a complete witness", () => {
  const notes = [note(1n, 0, 5n * ETH), note(1n, 1, 2n * ETH)];
  const prepared = prepareNative(ETH, notes);

  assert.strictEqual(prepared.legs.length, 1);
  const leg = prepared.legs[0]!;
  assert.strictEqual(leg.selected, notes[1], "did not pick the smallest covering note");
  assert.strictEqual(leg.witness.pubSignals.length, 8);
  // The witness must carry THIS leg's context, or the pool rejects it.
  assert.strictEqual(leg.witness.pubSignals[6], leg.context);
  assert.strictEqual(BigInt(leg.witness.inputs.withdrawn_value as string), ETH);
});

test("insufficient funds names the largest single note rather than the balance", () => {
  // Balance is 3 ETH across two notes, but no single note covers 2.5.
  const notes = [note(1n, 0, 2n * ETH), note(1n, 1, ETH)];
  assert.throws(
    () => prepareNative(5n * ETH / 2n, notes),
    /no single note covers .*largest spendable note is 2000000000000000000/,
  );
});

test("a token withdrawal prepares stipend + payout, both paying one address", () => {
  const payoutNotes = [note(1n, 0, 5n * ETH)];
  const gasNotes = [note(2n, 0, ETH)];
  const prepared = prepareWithdrawal({
    mnemonic: PHRASE,
    entrypointAddress: ENTRYPOINT,
    fee: FEE,
    asset: TOKEN,
    payoutValue: 2n * ETH,
    masterKeys: KEYS,
    payoutPool: poolOf(1n, payoutNotes),
    gasPool: poolOf(2n, gasNotes),
    revocationSecret: 0xdeadbeefn,
  });

  assert.deepStrictEqual(prepared.legs.map((l) => l.purpose), ["gas-stipend", "payout"]);
  assert.strictEqual(prepared.legs[0]!.selected, gasNotes[0]);
  assert.strictEqual(prepared.legs[1]!.selected, payoutNotes[0]);
  // Each witness is built against ITS OWN pool's tree, or the state root is wrong.
  for (const leg of prepared.legs) {
    assert.strictEqual(leg.witness.pubSignals[6], leg.context);
  }
  assert.notStrictEqual(prepared.legs[0]!.witness.pubSignals[3], prepared.legs[1]!.witness.pubSignals[3]);
});

test("an empty native pool is refused with the real cause", () => {
  // The planner would otherwise report "no native note was supplied", which is true and useless —
  // the caller DID supply a pool, it is just empty.
  assert.throws(
    () =>
      prepareWithdrawal({
        mnemonic: PHRASE,
        entrypointAddress: ENTRYPOINT,
        fee: FEE,
        asset: TOKEN,
        payoutValue: ETH,
        masterKeys: KEYS,
        payoutPool: poolOf(1n, [note(1n, 0, 5n * ETH)]),
        gasPool: poolOf(2n, []),
        revocationSecret: 0xdeadbeefn,
      }),
    /native pool holds no note covering the gas stipend/,
  );
});

test("a token withdrawal with no native pool at all is still refused", () => {
  assert.throws(
    () =>
      prepareWithdrawal({
        mnemonic: PHRASE,
        entrypointAddress: ENTRYPOINT,
        fee: FEE,
        asset: TOKEN,
        payoutValue: ETH,
        masterKeys: KEYS,
        payoutPool: poolOf(1n, [note(1n, 0, 5n * ETH)]),
        revocationSecret: 0xdeadbeefn,
      }),
    /no native note was supplied/,
  );
});
