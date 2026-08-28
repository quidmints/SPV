// Run: node --test src/pp/discovery.test.ts
//
// NOTE RECOVERY — the function a reinstalled wallet depends on to find its money. Its failures are
// all quiet: a missed note is an empty balance with no error, a mis-chained change note is a
// remainder whose secrets can never be re-derived, and a wrong spent flag offers the user a note the
// pool will reject.
//
// THE NETWORK IS SUBSTITUTED, NOT THE UNIT. `FakeRpc` serves REAL ABI-encoded logs to a REAL ethers
// Contract, and implements topic matching itself — the same shape as FakeSecureStore in
// root.test.ts. Nothing about the parsing, filtering or note logic is stubbed; only the transport
// is. That also lets the bucket-privacy claim be checked directly, by recording the filters asked
// for rather than taking the comment's word for it.
import test from "node:test";
import assert from "node:assert";
import { Interface } from "ethers";
import { PRECOMMITMENT_BUCKETS, discoverNotes } from "./discovery.ts";
import {
  commitment as commitmentHash,
  depositSecrets,
  masterKeysFromMnemonic,
  nullifierHash,
  precommitment,
  withdrawalSecrets,
} from "./notes.ts";

// @contract PrivacyPool
/** Mirrors discovery.ts's POOL_EVENTS_ABI (private there). A drift shows up as notes not found. */
const ABI = [
  "event Deposited(address indexed _depositor, uint256 indexed _precommitmentBucket, uint256 _commitment, uint256 _label, uint256 _value, uint256 _precommitmentHash)",
  "event Withdrawn(address indexed _processooor, uint256 _value, uint256 _spentNullifier, uint256 _newCommitment)",
  "event Ragequit(address indexed _ragequitter, uint256 _commitment, uint256 _label, uint256 _value)",
];
const iface = new Interface(ABI);

const POOL = "0x00000000000000000000000000000000000000p0".replace("p", "b");
const PHRASE =
  "produce front turtle firm rival still push install produce front turtle firm " +
  "rival still push install produce front turtle firm rival still push infant";
const KEYS = masterKeysFromMnemonic(PHRASE);
const SCOPE = 77n;
const LABEL = 0x1abe1n;
const VALUE = 10n ** 18n;

type RawLog = {
  address: string;
  topics: string[];
  data: string;
  blockNumber: number;
  transactionIndex: number;
  index: number;
  blockHash: string;
  transactionHash: string;
  removed: false;
};

let seq = 0;
function makeLog(name: string, args: unknown[], at?: { block: number; index: number }): RawLog {
  const { topics, data } = iface.encodeEventLog(iface.getEvent(name)!, args);
  const n = at?.index ?? seq++;
  return {
    address: POOL,
    topics,
    data,
    blockNumber: at?.block ?? 1,
    transactionIndex: 0,
    index: n,
    blockHash: "0x" + "11".repeat(32),
    transactionHash: "0x" + "22".repeat(32),
    removed: false,
  };
}

/** A provider that answers eth_getLogs from a fixed set, doing real topic matching. */
class FakeRpc {
  logs: RawLog[] = [];
  /** Every filter asked for — this is what the RPC provider would observe. */
  seen: Array<{ topics: unknown[] }> = [];

  get provider() {
    return this;
  }

  async getLogs(filter: { topics?: unknown[] }): Promise<RawLog[]> {
    this.seen.push({ topics: filter.topics ?? [] });
    return this.logs.filter((log) => this.matches(log, filter.topics ?? []));
  }

  private matches(log: RawLog, topics: unknown[]): boolean {
    for (let i = 0; i < topics.length; i++) {
      const want = topics[i];
      if (want === null || want === undefined) continue;
      const got = log.topics[i]?.toLowerCase();
      if (Array.isArray(want)) {
        if (!want.some((w) => String(w).toLowerCase() === got)) return false;
      } else if (String(want).toLowerCase() !== got) return false;
    }
    return true;
  }
}

/** Build the on-chain footprint of one deposit this seed owns. */
function ourDeposit(index: number, value = VALUE, label = LABEL) {
  const note = depositSecrets(KEYS, SCOPE, BigInt(index));
  const pc = precommitment(note);
  return {
    note,
    pc,
    label,
    value,
    commitment: commitmentHash(value, label, note),
    log: (at?: { block: number; index: number }) =>
      makeLog(
        "Deposited",
        [POOL, pc % PRECOMMITMENT_BUCKETS, commitmentHash(value, label, note), label, value, pc],
        at,
      ),
  };
}

/** A deposit belonging to somebody else — same pool, unrelated precommitment. */
function strangerDeposit(salt: bigint) {
  const pc = 0x9999n + salt;
  return makeLog("Deposited", [POOL, pc % PRECOMMITMENT_BUCKETS, 4242n + salt, 5n, 7n * VALUE, pc]);
}

const run = (rpc: FakeRpc, opts = {}) =>
  discoverNotes(rpc as never, POOL, KEYS, SCOPE, { maxIndex: 8, ...opts });

// ── recovery ──────────────────────────────────────────────────────────────────────────────────

test("our deposit is recovered and strangers' are ignored", () => {
  const rpc = new FakeRpc();
  const mine = ourDeposit(0);
  rpc.logs = [strangerDeposit(1n), mine.log(), strangerDeposit(2n)];

  return run(rpc).then(({ notes, balance }) => {
    assert.strictEqual(notes.length, 1, "recovered the wrong number of notes");
    assert.strictEqual(notes[0]!.commitment, mine.commitment);
    assert.strictEqual(notes[0]!.nullifier, mine.note.nullifier);
    assert.strictEqual(notes[0]!.kind, "deposit");
    assert.strictEqual(notes[0]!.spent, false);
    assert.strictEqual(balance, VALUE, "balance must be the sum of UNSPENT notes");
  });
});

test("a deposit beyond the gap limit is not found — maxIndex is a real bound", () => {
  // Silent by nature: the note exists on-chain and simply never appears, so the user sees a smaller
  // balance rather than an error.
  const rpc = new FakeRpc();
  rpc.logs = [ourDeposit(20).log()];
  return run(rpc, { maxIndex: 8 }).then(({ notes }) => {
    assert.strictEqual(notes.length, 0);
    return run(rpc, { maxIndex: 32 }).then(({ notes: found }) =>
      assert.strictEqual(found.length, 1, "raising maxIndex did not reach the note"),
    );
  });
});

// ── withdrawals and the change-note chain ─────────────────────────────────────────────────────

test("a withdrawal marks the note spent and chains a re-derivable change note", () => {
  const rpc = new FakeRpc();
  const mine = ourDeposit(0);
  const withdrawn = VALUE / 4n;
  const changeCommitment = 0xc4a49en;
  rpc.logs = [
    mine.log({ block: 1, index: 0 }),
    makeLog(
      "Withdrawn",
      [POOL, withdrawn, nullifierHash(mine.note.nullifier), changeCommitment],
      { block: 2, index: 0 },
    ),
  ];

  return run(rpc).then(({ notes, balance }) => {
    const deposit = notes.find((n) => n.kind === "deposit")!;
    const change = notes.find((n) => n.kind === "withdrawal-change")!;
    assert.strictEqual(deposit.spent, true, "the spent note was not marked");
    assert.strictEqual(change.value, VALUE - withdrawn, "the change note carries the wrong value");
    assert.strictEqual(change.commitment, changeCommitment);
    // The convention that must match buildWithdrawalWitness, or the remainder is unspendable.
    assert.deepStrictEqual(
      { nullifier: change.nullifier, secret: change.secret },
      withdrawalSecrets(KEYS, LABEL, 0n),
    );
    assert.strictEqual(balance, VALUE - withdrawn, "balance must follow the change note");
  });
});

test("consecutive withdrawals index the change notes 0, 1, 2 in chain order", () => {
  // wIndexByLabel assigns k by processing order. If it drifts from on-chain order, every change
  // note after the first is derived with the wrong k and cannot be re-derived later.
  const rpc = new FakeRpc();
  const mine = ourDeposit(0);
  const step = VALUE / 4n;
  rpc.logs = [
    mine.log({ block: 1, index: 0 }),
    makeLog("Withdrawn", [POOL, step, nullifierHash(mine.note.nullifier), 0xc1n], { block: 2, index: 0 }),
    makeLog(
      "Withdrawn",
      [POOL, step, nullifierHash(withdrawalSecrets(KEYS, LABEL, 0n).nullifier), 0xc2n],
      { block: 3, index: 0 },
    ),
  ];

  return run(rpc).then(({ notes, balance }) => {
    const changes = notes.filter((n) => n.kind === "withdrawal-change");
    assert.strictEqual(changes.length, 2);
    assert.deepStrictEqual(changes.map((c) => c.index), [0, 1]);
    for (const [k, c] of changes.entries()) {
      assert.deepStrictEqual(
        { nullifier: c.nullifier, secret: c.secret },
        withdrawalSecrets(KEYS, LABEL, BigInt(k)),
      );
    }
    assert.strictEqual(balance, VALUE - 2n * step);
  });
});

test("the result does not depend on the order the RPC returns logs", () => {
  // queryFilter's ordering is not guaranteed by eth_getLogs, and the change-note index is derived
  // from processing order — so the defensive sort is load-bearing, not tidiness.
  const mine = ourDeposit(0);
  const step = VALUE / 4n;
  const logs = [
    mine.log({ block: 1, index: 0 }),
    makeLog("Withdrawn", [POOL, step, nullifierHash(mine.note.nullifier), 0xc1n], { block: 2, index: 0 }),
    makeLog(
      "Withdrawn",
      [POOL, step, nullifierHash(withdrawalSecrets(KEYS, LABEL, 0n).nullifier), 0xc2n],
      { block: 3, index: 0 },
    ),
  ];

  const forward = new FakeRpc();
  forward.logs = [...logs];
  const reversed = new FakeRpc();
  reversed.logs = [...logs].reverse();

  return Promise.all([run(forward), run(reversed)]).then(([a, b]) => {
    assert.deepStrictEqual(
      b.notes.map((n) => [n.kind, n.index, n.value.toString(), n.spent]),
      a.notes.map((n) => [n.kind, n.index, n.value.toString(), n.spent]),
      "reversing the log order changed the recovered notes",
    );
    assert.strictEqual(b.balance, a.balance);
  });
});

test("a ragequit marks its note spent", () => {
  const rpc = new FakeRpc();
  const mine = ourDeposit(0);
  rpc.logs = [
    mine.log({ block: 1, index: 0 }),
    makeLog("Ragequit", [POOL, mine.commitment, LABEL, VALUE], { block: 2, index: 0 }),
  ];
  return run(rpc).then(({ notes, balance }) => {
    assert.strictEqual(notes[0]!.spent, true);
    assert.strictEqual(balance, 0n);
  });
});

// ── what the RPC provider gets to see ─────────────────────────────────────────────────────────

test("the default query narrows to this seed's buckets, and scanAllBuckets does not", () => {
  // The privacy trade discovery.ts documents, asserted rather than described: the bucketed query
  // tells the provider which buckets you care about; scanAllBuckets tells it nothing beyond
  // "someone read the deposit log".
  const mine = ourDeposit(0);

  const bucketed = new FakeRpc();
  bucketed.logs = [mine.log()];
  const all = new FakeRpc();
  all.logs = [mine.log()];

  return Promise.all([run(bucketed), run(all, { scanAllBuckets: true })]).then(([a, b]) => {
    const depositFilter = (rpc: FakeRpc) => rpc.seen[0]!.topics;
    assert.ok(
      Array.isArray(depositFilter(bucketed)[2]),
      "the default query did not restrict the bucket topic",
    );
    assert.ok(
      depositFilter(all)[2] === undefined || depositFilter(all)[2] === null,
      "scanAllBuckets still sent a bucket topic — the private option is not private",
    );
    // ...and the documented claim that correctness is identical either way.
    assert.deepStrictEqual(
      b.notes.map((n) => n.commitment),
      a.notes.map((n) => n.commitment),
      "the two scan modes recovered different notes",
    );
    assert.strictEqual(b.balance, a.balance);
  });
});

test("the bucket topic asked for is the one the seed's notes actually fall into", () => {
  // A mismatch here finds nothing at all, silently — the same failure mode as a wrong
  // PRECOMMITMENT_BUCKETS.
  const rpc = new FakeRpc();
  const mine = ourDeposit(0);
  rpc.logs = [mine.log()];
  return run(rpc, { maxIndex: 1 }).then(() => {
    // ethers collapses a single-element topic set to a scalar, so accept either shape.
    const raw = rpc.seen[0]!.topics[2];
    const asked = (Array.isArray(raw) ? raw : [raw]).map((t) => String(t).toLowerCase());
    const want = "0x" + (mine.pc % PRECOMMITMENT_BUCKETS).toString(16).padStart(64, "0");
    assert.ok(asked.includes(want), `the queried buckets do not include this note's bucket`);
  });
});
