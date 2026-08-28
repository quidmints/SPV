// Run: node --test src/pp/deposit.test.ts
//
// THE SPLITTING RULES HAD NO TESTS, because this module could not be loaded by the test runner at
// all: it declared a TypeScript `enum`, which Node's strip-only TypeScript support refuses outright,
// and imported interfaces as values. Both are fixed; this is the first pass over the logic.
//
// WHAT MATTERS HERE. `splitIntoDenominations` decides the SHAPE a deposit takes on-chain, and every
// property below fails silently if broken — a wrong split still deposits, still spends, and still
// looks fine to the user. Only an observer correlating amounts would ever notice. So:
//
//   1. CONSERVATION. The notes must sum to the deposit. Losing wei here is losing money.
//   2. EVERY NOTE IS A STANDARD DENOMINATION unless the caller explicitly accepted a remainder.
//      A uniquely-sized note is the exact fingerprint splitting exists to remove.
//   3. THE REFUSAL IS REAL. The module's claim is that it will not silently emit a distinctive
//      shape. An error that does not fire is a false assurance, which is worse than no splitting.
//   4. THE NOTE COUNT IS BOUNDED. Uniform mode's count is value/unit, which is unbounded in the
//      value — and each note is a separate transaction the user must sign and pay for.
import test from "node:test";
import assert from "node:assert";
import {
  DENOMINATIONS,
  DepositMode,
  MAX_NOTES_PER_DEPOSIT,
  MIN_DENOMINATION,
  splitIntoDenominations,
} from "./deposit.ts";

const ETH = 10n ** 18n;
const TENTH = ETH / 10n;

const sum = (xs: readonly bigint[]) => xs.reduce((a, b) => a + b, 0n);
const isStandard = (x: bigint) => DENOMINATIONS.includes(x);

// ── 1. conservation ───────────────────────────────────────────────────────────────────────────

test("the notes always sum to the deposit", () => {
  const values = [TENTH, ETH, 10n * ETH, 99n * TENTH, 101n * TENTH, 137n * TENTH];
  for (const v of values) {
    for (const mode of [DepositMode.Uniform, DepositMode.Mixed]) {
      const notes = splitIntoDenominations(v, { mode });
      assert.strictEqual(sum(notes), v, `${mode} split of ${v} lost or invented wei`);
    }
  }
});

test("a remainder split still conserves the total", () => {
  // The remainder path is the one that can silently drop wei, since it is the only branch that
  // pushes a value the denominations did not produce.
  const v = 137n * TENTH + 12345n;
  for (const mode of [DepositMode.Uniform, DepositMode.Mixed]) {
    const notes = splitIntoDenominations(v, { mode, allowRemainder: true });
    assert.strictEqual(sum(notes), v);
  }
});

// ── 2. every note is a standard denomination ──────────────────────────────────────────────────

test("no non-standard note appears unless a remainder was explicitly allowed", () => {
  for (const v of [TENTH, ETH, 10n * ETH, 99n * TENTH, 101n * TENTH]) {
    for (const mode of [DepositMode.Uniform, DepositMode.Mixed]) {
      for (const n of splitIntoDenominations(v, { mode })) {
        assert.ok(isStandard(n), `${mode} split of ${v} emitted a non-standard note of ${n}`);
      }
    }
  }
});

test("uniform mode emits ONE size, which is what collapses the multiset to a count", () => {
  // The privacy claim in deposit.ts rests entirely on this: if two sizes appear, the shape is a
  // fingerprint again and the extra transactions bought nothing.
  for (const v of [ETH, 10n * ETH, 99n * TENTH, 101n * TENTH, 7n * ETH]) {
    const notes = splitIntoDenominations(v, { mode: DepositMode.Uniform });
    assert.strictEqual(new Set(notes).size, 1, `uniform split of ${v} used more than one size`);
  }
});

test("uniform picks the LARGEST unit that divides, so it emits the fewest such notes", () => {
  assert.deepStrictEqual(splitIntoDenominations(10n * ETH, { mode: DepositMode.Uniform }), [10n * ETH]);
  assert.deepStrictEqual(splitIntoDenominations(2n * ETH, { mode: DepositMode.Uniform }), [ETH, ETH]);
  assert.strictEqual(splitIntoDenominations(99n * TENTH, { mode: DepositMode.Uniform }).length, 99);
});

test("mixed mode is greedy and therefore minimal, since each denomination divides the next", () => {
  assert.deepStrictEqual(splitIntoDenominations(11n * ETH, { mode: DepositMode.Mixed }), [
    10n * ETH,
    ETH,
  ]);
  // 10.1 ETH: one 10, then one 0.1 — two notes, versus 101 in uniform mode. That is the trade the
  // module documents, pinned so the two modes cannot silently converge.
  assert.strictEqual(splitIntoDenominations(101n * TENTH, { mode: DepositMode.Mixed }).length, 2);
  assert.strictEqual(splitIntoDenominations(101n * TENTH, { mode: DepositMode.Uniform }).length, 101);
});

// ── 3. the refusal is real ────────────────────────────────────────────────────────────────────

test("a value below the smallest denomination is refused, not rounded away", () => {
  for (const mode of [DepositMode.Uniform, DepositMode.Mixed]) {
    assert.throws(() => splitIntoDenominations(MIN_DENOMINATION - 1n, { mode }), /remainder|multiple/);
  }
});

test("a non-multiple is refused in BOTH modes unless a remainder is allowed", () => {
  const odd = 137n * TENTH + 12345n;
  for (const mode of [DepositMode.Uniform, DepositMode.Mixed]) {
    assert.throws(
      () => splitIntoDenominations(odd, { mode }),
      /remainder|multiple/,
      `${mode} silently accepted a non-multiple, emitting a fingerprint note`,
    );
  }
});

test("zero and negative values are refused", () => {
  assert.throws(() => splitIntoDenominations(0n), /must be > 0/);
  assert.throws(() => splitIntoDenominations(-ETH), /must be > 0/);
});

// ── 4. the note count is bounded ──────────────────────────────────────────────────────────────

test("an unusable note count is refused with guidance instead of attempted", () => {
  // Uniform mode's count is value/unit. A deposit that is a multiple of ONLY the smallest
  // denomination therefore scales without limit: 1000.1 ETH is 10,001 notes, which is 10,001
  // transactions to sign and pay for. Left unchecked the wallet either freezes for hours or dies
  // allocating the array — and the user's instruction was that this must never become a UX problem.
  const huge = (BigInt(MAX_NOTES_PER_DEPOSIT) + 1n) * MIN_DENOMINATION;
  assert.throws(
    () => splitIntoDenominations(huge, { mode: DepositMode.Uniform }),
    /too many notes/i,
    "an unbounded note count was accepted",
  );
  // The error must be actionable, not just a refusal: a larger deposit that lands on a bigger unit
  // is fine, and that is exactly the advice the message has to give.
  assert.doesNotThrow(() =>
    splitIntoDenominations(BigInt(MAX_NOTES_PER_DEPOSIT) * ETH, { mode: DepositMode.Uniform }),
  );
});

test("the bound does not reject ordinary deposits", () => {
  // A cap set too low would be its own UX problem, so pin that everyday amounts still split.
  for (const v of [TENTH, ETH, 10n * ETH, 99n * TENTH, 500n * ETH]) {
    assert.doesNotThrow(() => splitIntoDenominations(v, { mode: DepositMode.Uniform }), `${v} was rejected`);
  }
});

test("the greedy path is bounded too, and refuses before it allocates", () => {
  // Mixed mode looks safe because it emits few notes for ordinary amounts, but its count is
  // value/10ETH — 1e30 wei is 1e11 notes. Building that array is the failure, so the refusal has to
  // come first; a test that merely asserted the throw would pass even if it took the machine down
  // getting there, hence the timing floor.
  const started = process.hrtime.bigint();
  assert.throws(
    () => splitIntoDenominations(10n ** 30n, { mode: DepositMode.Mixed, allowRemainder: true }),
    /too many notes/i,
  );
  const ms = Number(process.hrtime.bigint() - started) / 1e6;
  assert.ok(ms < 500, `the refusal took ${ms}ms — it is happening after the array was built`);
});
