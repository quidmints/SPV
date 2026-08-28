// Run: node --test src/pp/recipient.test.ts
//
// WHAT THIS FILE EXISTS TO PIN. Every property `recipient.ts` claims is one whose violation is
// SILENT — a reused address still receives the money, a path level that is ignored still derives
// something, an account that overlaps the identity key still works. Nothing fails loudly; the user
// simply stops being anonymous, or a restored wallet looks in the wrong place, and only an observer
// correlating the chain would ever know. So each claim is asserted rather than argued:
//
//   1. RECOVERY WITHOUT STATE — the same seed and the same spent note re-derive the same address.
//      This is the substitute for a stored counter; if it fails, a restored wallet cannot find
//      funds that were already paid out.
//   2. FRESHNESS — different withdrawals get different addresses, which is the entire point.
//   3. NO OVERLAP with the PP master keys (accounts 0, 1) or `sk_identity` (account 100).
//   4. ALL THREE LEVELS CARRY BITS. The deep path is the reason no collision probe is needed, so a
//      level that silently ignored its input would restore the ~1e-4 collision this design exists
//      to remove — and would do it invisibly, since every address still derives fine.
//
// The seeds are fixed, valid BIP39 phrases: these are derivation vectors, and a random phrase would
// make a failure unreproducible.
import test from "node:test";
import assert from "node:assert";
import { HDNodeWallet } from "ethers";
import {
  LEVEL_SPAN,
  RECIPIENT_ACCOUNT,
  RECIPIENT_LEVELS,
  buildFreshRelayedWithdrawal,
  deriveRecipient,
  recipientForNote,
  recipientPath,
  recipientSigner,
} from "./recipient.ts";
import { nullifierHash } from "./notes.ts";

/** BN254 scalar field — Poseidon inputs must live here. */
const FIELD =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

/** A REAL 24-word phrase with a valid BIP39 checksum — ethers validates, so an invented one throws. */
const PHRASE =
  "produce front turtle firm rival still push install produce front turtle firm " +
  "rival still push install produce front turtle firm rival still push infant";

/** A second, unrelated seed — used to prove addresses are seed-bound, not id-bound. */
const OTHER_PHRASE =
  "legal winner thank year wave sausage worth useful legal winner thank year " +
  "wave sausage worth useful legal winner thank year wave sausage worth title";

/** Stands in for a note's nullifier. Arbitrary but fixed. */
const NULLIFIER = 0x2a3f91c07de4b5a6f1029384756abcdef0123456789abcdef0123456789abcdn;

// ── 1. recovery without stored state ──────────────────────────────────────────────────────────

test("the same seed and the same spent note re-derive the same address", () => {
  const atWithdrawal = recipientForNote(PHRASE, { nullifier: NULLIFIER });
  const afterReinstall = recipientForNote(PHRASE, { nullifier: NULLIFIER });
  assert.strictEqual(
    afterReinstall.address,
    atWithdrawal.address,
    "a restored wallet would not find funds already paid out to this note's recipient",
  );
  assert.strictEqual(afterReinstall.path, atWithdrawal.path);
});

test("the recipient depends on the note ALONE, not on which other notes are known", () => {
  // This is what buys unconditional recovery: a wallet that has rediscovered only SOME of its notes
  // still derives the right address for the ones it has. An assignment that depended on the set
  // would give a partially-restored wallet a different, wrong answer.
  const alone = recipientForNote(PHRASE, { nullifier: NULLIFIER });
  const known = [NULLIFIER - 1n, NULLIFIER, NULLIFIER + 1n].map((n) =>
    recipientForNote(PHRASE, { nullifier: n }),
  );
  assert.strictEqual(known[1].address, alone.address);
});

test("the address is bound to the seed, not just to the id", () => {
  const mine = deriveRecipient(PHRASE, 42n);
  const theirs = deriveRecipient(OTHER_PHRASE, 42n);
  assert.notStrictEqual(mine.address, theirs.address, "two seeds derived the same payout address");
});

test("the derived address is the one the signer controls", () => {
  // Without this the wallet could hand out an address it cannot spend from — funds withdrawn
  // privately and then stranded, which is worse than not withdrawing at all.
  const id = nullifierHash(NULLIFIER);
  assert.strictEqual(recipientSigner(PHRASE, id).address, deriveRecipient(PHRASE, id).address);
});

// ── 2. freshness ──────────────────────────────────────────────────────────────────────────────

test("different withdrawals get different addresses", () => {
  const seen = new Set<string>();
  for (let i = 0n; i < 64n; i++) {
    const { address } = recipientForNote(PHRASE, { nullifier: NULLIFIER + i });
    assert.ok(!seen.has(address), `address reused across withdrawals at offset ${i}`);
    seen.add(address);
  }
});

// ── 3. no overlap with the reserved accounts ──────────────────────────────────────────────────

test("recipients never occupy the PP master or identity accounts", () => {
  // The reservations live in notes.ts (0, 1) and root.ts (100). Assert against the ADDRESSES, so a
  // future change that happened to re-collide would still be caught.
  const reserved = new Map(
    [0, 1, 100, RECIPIENT_ACCOUNT].map((a) => [
      HDNodeWallet.fromPhrase(PHRASE, "", `m/44'/60'/${a}'/0/0`).address,
      a,
    ]),
  );
  for (let i = 0n; i < 32n; i++) {
    // Reduced into the field: `nullifierHash` is Poseidon, which REFUSES an out-of-field input
    // rather than wrapping it. Real nullifiers are Poseidon outputs and so always in range.
    const { address } = recipientForNote(PHRASE, { nullifier: (NULLIFIER * (i + 1n)) % FIELD });
    const clash = reserved.get(address);
    assert.strictEqual(clash, undefined, `a recipient collided with reserved account ${clash}`);
  }
});

test("the recipient account is not one of the reserved ones", () => {
  // The address comparison above CANNOT catch this, and a mutation setting the account to 0 passed
  // it: recipients sit three levels below the account, so they never collide with the five-level
  // reserved keys whatever account they use. The claim in recipient.ts is structural — "the spaces
  // cannot overlap" — so it has to be checked structurally, or the separation is only a comment.
  const account = recipientPath(nullifierHash(NULLIFIER)).split("/")[3];
  for (const reserved of [0, 1, 100]) {
    assert.notStrictEqual(
      account,
      `${reserved}'`,
      `recipients were moved onto reserved account ${reserved} (PP master keys / sk_identity)`,
    );
  }
});

test("the path sits under the reserved account, is fully hardened, and has the stated depth", () => {
  const segments = recipientPath(nullifierHash(NULLIFIER)).split("/");
  assert.strictEqual(segments[0], "m");
  assert.deepStrictEqual(segments.slice(1, 4), ["44'", "60'", `${RECIPIENT_ACCOUNT}'`]);
  assert.strictEqual(
    segments.length - 1,
    3 + RECIPIENT_LEVELS,
    "the path depth changed — every historical recipient address moves with it",
  );
  for (const s of segments.slice(1)) {
    assert.ok(s.endsWith("'"), `segment ${s} is not hardened, so a sibling key could be walked back`);
  }
});

test("a negative id is refused rather than derived", () => {
  assert.throws(() => recipientPath(-1n), /non-negative/);
});

// ── 4. all three levels carry bits ────────────────────────────────────────────────────────────

test("each hardened level actually carries part of the id", () => {
  // A level that ignored its input would be invisible: addresses still derive, tests 1-3 still pass,
  // and the collision space silently shrinks by 31 bits per dead level — back to the ~1e-4 collision
  // the deep path exists to remove. So probe each level in isolation.
  const base = 12345n;
  const seen = new Map<string, string>();
  for (let level = 0; level < RECIPIENT_LEVELS; level++) {
    const id = base + LEVEL_SPAN ** BigInt(level);
    const { address, path } = deriveRecipient(PHRASE, id);
    const clash = seen.get(address);
    assert.strictEqual(clash, undefined, `level ${level} does not affect the address (matches ${clash})`);
    seen.set(address, path);
  }
  assert.notStrictEqual(deriveRecipient(PHRASE, base).address, [...seen.keys()][0]);
});

test("the id is truncated to the levels available, deliberately", () => {
  // Documented, not accidental: only RECIPIENT_LEVELS * 31 bits are consumed, so ids differing
  // ONLY above that ceiling share an address. Pinned so the truncation cannot be quietly widened or
  // narrowed — either would re-point every historical recipient.
  const ceiling = LEVEL_SPAN ** BigInt(RECIPIENT_LEVELS);
  assert.strictEqual(ceiling, 2n ** 93n);
  assert.strictEqual(deriveRecipient(PHRASE, 7n).address, deriveRecipient(PHRASE, 7n + ceiling).address);
  // ...and one bit below the ceiling still separates, so the truncation is exactly where claimed.
  assert.notStrictEqual(
    deriveRecipient(PHRASE, 7n).address,
    deriveRecipient(PHRASE, 7n + ceiling / 2n).address,
  );
});

// ── 5. the composed entry point ───────────────────────────────────────────────────────────────

test("the built withdrawal pays the fresh address, and the context commits to it", () => {
  // The context is what stops a relayer redirecting the payout (relay.ts). If the recipient were
  // not inside it, the whole fresh-address scheme would be advisory: a relayer could swap in its
  // own address and the proof would still verify.
  const ENTRYPOINT = "0x1111111111111111111111111111111111111111";
  const FEE = { feeRecipient: "0x2222222222222222222222222222222222222222", relayFeeBPS: 50n };
  const note = { nullifier: NULLIFIER };

  const built = buildFreshRelayedWithdrawal(PHRASE, note, ENTRYPOINT, 7n, FEE);
  assert.strictEqual(built.recipient.address, recipientForNote(PHRASE, note).address);
  assert.strictEqual(built.withdrawal.processooor, ENTRYPOINT);
  assert.ok(
    (built.withdrawal.data as string).toLowerCase().includes(built.recipient.address.slice(2).toLowerCase()),
    "the payout address is not in the relay data the context is computed over",
  );

  // Same note, a DIFFERENT seed: a different recipient must move the context.
  const other = buildFreshRelayedWithdrawal(OTHER_PHRASE, note, ENTRYPOINT, 7n, FEE);
  assert.notStrictEqual(other.recipient.address, built.recipient.address);
  assert.notStrictEqual(
    other.context,
    built.context,
    "the context does not bind the recipient — a relayer could redirect the payout",
  );
});
