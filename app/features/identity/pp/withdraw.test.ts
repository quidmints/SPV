// Run: node --test src/pp/withdraw.test.ts
//
// THE JOIN THE SCREEN CALLS. Everything below the relay is pinned elsewhere; what this asserts is
// the contract between the app and the relayer that nothing else can see: the fee the proof commits
// to is the fee the relayer quoted, the request carries exactly what `POST /pp/relay` reads, and a
// 402 is answered by re-proving at the named fee rather than by surfacing a step to the user.
import test from "node:test";
import assert from "node:assert";
import { withdraw, type WithdrawParams } from "./withdraw.ts";
import { withdrawalContext } from "./relay.ts";
import { StateTree } from "./stateTree.ts";
import { commitment as commitmentHash, depositSecrets, masterKeysFromMnemonic } from "./notes.ts";
import { IDENTITY_TREE_DEPTH } from "./identityProof.ts";
import type { RecoveredNote } from "./discovery.ts";
import { NATIVE_ASSET } from "./withdrawPlan.ts";

const PHRASE =
  "produce front turtle firm rival still push install produce front turtle firm " +
  "rival still push install produce front turtle firm rival still push infant";
const KEYS = masterKeysFromMnemonic(PHRASE);
const ENTRYPOINT = "0x00000000000000000000000000000000000000e1";
const RELAYER = "0x00000000000000000000000000000000000000f1";
const ETH = 10n ** 18n;

function note(scope: bigint, index: number, value: bigint): RecoveredNote {
  const s = depositSecrets(KEYS, scope, BigInt(index));
  const label = 0x1abe1n + BigInt(index);
  return {
    scope, label, index, kind: "deposit", nullifier: s.nullifier, secret: s.secret, value,
    commitment: commitmentHash(value, label, s), spent: false,
  };
}

function poolOf(scope: bigint, notes: RecoveredNote[]) {
  const tree = new StateTree([999n, ...notes.map((n) => n.commitment)]);
  return {
    scope, stateTree: tree,
    leafIndexOf: (n: RecoveredNote) => BigInt(notes.indexOf(n) + 1),
    notes,
    identity: { identityRoot: 0xabcdefn, siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n) },
    blacklist: {
      root: 0xb1acn,
      label: { siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n), oldKey: 0n, oldValue: 0n, isOld0: true },
      document: { siblings: Array<bigint>(IDENTITY_TREE_DEPTH).fill(0n), oldKey: 0n, oldValue: 0n, isOld0: true },
    },
    documentId: 0xd0cn,
  };
}

/** A relayer double: answers quotes and relays, recording what it was sent. */
function fakeRelayer(opts: { quoteBps: bigint; refuseFirst?: { minFeeBps: bigint } }) {
  const posts: Array<{ body: any }> = [];
  const quotes: string[] = [];
  let refused = false;
  const fetchImpl = async (url: string, init?: { method?: string; body?: string }): Promise<Response> => {
    if (!init || init.method !== "POST") {
      quotes.push(url);
      return new Response(JSON.stringify({ fee_recipient: RELAYER, min_fee_bps: opts.quoteBps.toString() }));
    }
    posts.push({ body: JSON.parse(init.body!) });
    if (opts.refuseFirst && !refused) {
      refused = true;
      return new Response(JSON.stringify({ fee_wei: "1", need_wei: "2", min_fee_bps: opts.refuseFirst.minFeeBps.toString() }), { status: 402 });
    }
    return new Response(JSON.stringify({ success: true }));
  };
  return { posts, quotes, fetchImpl };
}

const proofs: string[] = [];
const prove = async (): Promise<string> => {
  const p = `0x${(proofs.length + 1).toString(16).padStart(2, "0")}`;
  proofs.push(p);
  return p;
};

function params(over: Partial<WithdrawParams> = {}): WithdrawParams {
  const scope = 7n;
  const pool = poolOf(scope, [note(scope, 0, 2n * ETH), note(scope, 1, 5n * ETH)]);
  return {
    mnemonic: PHRASE, masterKeys: KEYS, entrypointAddress: ENTRYPOINT, asset: NATIVE_ASSET,
    payoutPool: pool, payoutValue: ETH, revocationSecret: 0x5ec7n, hopUrl: "http://hop", prove,
    ...over,
  };
}

async function withFetch<T>(impl: typeof fetch, f: () => Promise<T>): Promise<T> {
  const real = globalThis.fetch;
  globalThis.fetch = impl;
  try { return await f(); } finally { globalThis.fetch = real; }
}

test("the proof commits to the quoted fee and the request is what /pp/relay reads", async () => {
  const r = fakeRelayer({ quoteBps: 42n });
  const out = await withFetch(r.fetchImpl as typeof fetch, () => withdraw(params()));
  assert.strictEqual(out.status, "done");
  assert.strictEqual(r.quotes.length, 1, "one leg, one quote");
  assert.ok(r.quotes[0]!.endsWith(`/pp/relay?value=${ETH}`), "quoted for the payout value");
  assert.strictEqual(r.posts.length, 1);
  const body = r.posts[0]!.body;
  assert.strictEqual(body.withdrawal.processooor, ENTRYPOINT);
  assert.strictEqual(body.scope, "7");
  assert.strictEqual(body.proof.pubSignals.length, 8);
  // RelayData is the 96 bytes the relayer decodes: recipient ‖ feeRecipient ‖ bps.
  const data: string = body.withdrawal.data;
  assert.strictEqual(data.length, 2 + 192);
  assert.strictEqual("0x" + data.slice(2 + 64 + 24, 2 + 128), RELAYER.toLowerCase());
  assert.strictEqual(BigInt("0x" + data.slice(2 + 128)), 42n, "the quoted bps, not a constant");
  // The context the relayer recomputes from (withdrawal, scope) is pubSignals[6].
  const ctx = withdrawalContext({ processooor: body.withdrawal.processooor, data }, 7n);
  assert.strictEqual(BigInt(body.proof.pubSignals[6]), ctx);
});

test("a 402 is answered by re-proving at the fee it named — no step surfaces", async () => {
  const before = proofs.length;
  const r = fakeRelayer({ quoteBps: 10n, refuseFirst: { minFeeBps: 55n } });
  const out = await withFetch(r.fetchImpl as typeof fetch, () => withdraw(params()));
  assert.strictEqual(out.status, "done");
  assert.strictEqual(r.posts.length, 2, "refused once, then relayed");
  assert.strictEqual(proofs.length - before, 2, "the leg was re-proven, not re-sent");
  assert.strictEqual(BigInt("0x" + r.posts[0]!.body.withdrawal.data.slice(2 + 128)), 10n);
  assert.strictEqual(BigInt("0x" + r.posts[1]!.body.withdrawal.data.slice(2 + 128)), 55n, "the 402's fee");
  assert.notStrictEqual(r.posts[0]!.body.proof.pubSignals[6], r.posts[1]!.body.proof.pubSignals[6], "a new fee is a new context");
});

test("no relayer is an outcome, not an exception — the escape hatch is the screen's call", async () => {
  const out = await withFetch((async () => { throw new Error("ECONNREFUSED"); }) as typeof fetch, () => withdraw(params()));
  assert.deepStrictEqual(out, { status: "no_relayer" });
});
