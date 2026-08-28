// Run: node --test src/pp/withdrawPlan.test.ts
//
// THE PROPERTY THAT MATTERS is that every leg pays ONE address. A plan whose gas lands somewhere the
// tokens are not is worse than no plan: both halves are stranded, and the user cannot rescue either
// without funding an address from their own, which is the linkage the whole withdrawal path exists
// to avoid. Nothing about that failure is loud — both withdrawals succeed.
import test from "node:test";
import assert from "node:assert";
import {
  DEFAULT_GAS_STIPEND,
  NATIVE_ASSET,
  isNativeAsset,
  planWithdrawal,
} from "./withdrawPlan.ts";
import { recipientForNote } from "./recipient.ts";
import { withdrawalContext } from "./relay.ts";

const PHRASE =
  "produce front turtle firm rival still push install produce front turtle firm " +
  "rival still push install produce front turtle firm rival still push infant";
const ENTRYPOINT = "0x00000000000000000000000000000000000000e1";
const FEE = { feeRecipient: "0x00000000000000000000000000000000000000f1", relayFeeBPS: 250n };
const TOKEN = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // a plain ERC-20
const PAYOUT_NOTE = { nullifier: 0x11117777n };
const GAS_NOTE = { nullifier: 0x22228888n };

const base = {
  mnemonic: PHRASE,
  entrypointAddress: ENTRYPOINT,
  fee: FEE,
  payoutScope: 7n,
  payoutNote: PAYOUT_NOTE,
  payoutValue: 1_000_000n,
};

// ── the native case needs nothing extra ───────────────────────────────────────────────────────

test("a native withdrawal is a single leg — it arrives as its own gas", () => {
  const plan = planWithdrawal({ ...base, asset: NATIVE_ASSET });
  assert.strictEqual(plan.legs.length, 1);
  assert.strictEqual(plan.legs[0]!.purpose, "payout");
  assert.strictEqual(plan.recipient.address, recipientForNote(PHRASE, PAYOUT_NOTE).address);
});

test("a native withdrawal does not add a pointless stipend even when a gas note is offered", () => {
  const plan = planWithdrawal({ ...base, asset: NATIVE_ASSET, gasNote: GAS_NOTE, gasScope: 1n });
  assert.strictEqual(plan.legs.length, 1, "a second withdrawal was made for no benefit");
});

test("the native sentinel is matched case-insensitively", () => {
  // It is a checksummed constant in Solidity and routinely lower-cased in JS; comparing raw would
  // silently take the token branch for ETH and demand a stipend that is not needed.
  assert.ok(isNativeAsset(NATIVE_ASSET.toLowerCase()));
  assert.ok(isNativeAsset(NATIVE_ASSET.toUpperCase().replace("0X", "0x")));
  assert.ok(!isNativeAsset(TOKEN));
});

// ── the token case: one address, both legs ────────────────────────────────────────────────────

test("a token withdrawal pays the stipend to THE SAME address as the tokens", () => {
  const plan = planWithdrawal({ ...base, asset: TOKEN, gasNote: GAS_NOTE, gasScope: 1n });
  assert.strictEqual(plan.legs.length, 2);
  const [gas, payout] = plan.legs;
  assert.strictEqual(gas!.purpose, "gas-stipend");
  assert.strictEqual(payout!.purpose, "payout");

  // The whole point. Deriving per-leg addresses would strand both halves.
  const paid = new Set(plan.legs.map((l) => JSON.parse(JSON.stringify(l.withdrawal)).data));
  assert.strictEqual(paid.size, 1, "the legs pay different recipients");
  assert.strictEqual(plan.recipient.address, recipientForNote(PHRASE, PAYOUT_NOTE).address);
});

test("the stipend is ordered before the payout", () => {
  // Gas must be present before there is any reason to spend from the address; the reverse ordering
  // leaves a window in which the tokens are there and unmovable.
  const plan = planWithdrawal({ ...base, asset: TOKEN, gasNote: GAS_NOTE, gasScope: 1n });
  assert.deepStrictEqual(plan.legs.map((l) => l.purpose), ["gas-stipend", "payout"]);
});

test("each leg carries its own scope, note and value, and a context matching its withdrawal", () => {
  const plan = planWithdrawal({
    ...base,
    asset: TOKEN,
    gasNote: GAS_NOTE,
    gasScope: 1n,
    gasStipend: 5n,
  });
  const [gas, payout] = plan.legs;
  assert.deepStrictEqual([gas!.scope, gas!.note, gas!.withdrawnValue], [1n, GAS_NOTE, 5n]);
  assert.deepStrictEqual(
    [payout!.scope, payout!.note, payout!.withdrawnValue],
    [7n, PAYOUT_NOTE, 1_000_000n],
  );
  // The context must be derived per leg, because the scope differs — reusing one would produce a
  // proof the pool rejects.
  for (const leg of plan.legs) {
    assert.strictEqual(leg.context, withdrawalContext(leg.withdrawal, leg.scope));
  }
  assert.notStrictEqual(gas!.context, payout!.context, "both legs share a context");
});

test("the withdrawal targets the Entrypoint, since only it can relay", () => {
  const plan = planWithdrawal({ ...base, asset: TOKEN, gasNote: GAS_NOTE, gasScope: 1n });
  for (const leg of plan.legs) assert.strictEqual(leg.withdrawal.processooor, ENTRYPOINT);
});

// ── the refusal ───────────────────────────────────────────────────────────────────────────────

test("a token withdrawal with no gas note is REFUSED, not silently stranded", () => {
  // The failure this prevents is permanent and quiet: the tokens arrive, and the only way to move
  // them is to fund the address from one the user controls, which links it and defeats the point.
  assert.throws(
    () => planWithdrawal({ ...base, asset: TOKEN }),
    /no native note was supplied/,
    "a token payout with no gas was planned anyway",
  );
});

test("the refusal can be overridden deliberately, and says what that costs", () => {
  const plan = planWithdrawal({ ...base, asset: TOKEN, allowUnspendablePayout: true });
  assert.strictEqual(plan.legs.length, 1);
  assert.strictEqual(plan.legs[0]!.purpose, "payout");
});

test("a gas note without its scope is refused rather than guessed", () => {
  assert.throws(
    () => planWithdrawal({ ...base, asset: TOKEN, gasNote: GAS_NOTE }),
    /without gasScope/,
  );
});

test("nonsensical amounts are refused", () => {
  assert.throws(() => planWithdrawal({ ...base, asset: NATIVE_ASSET, payoutValue: 0n }), /payoutValue/);
  assert.throws(
    () =>
      planWithdrawal({ ...base, asset: TOKEN, gasNote: GAS_NOTE, gasScope: 1n, gasStipend: 0n }),
    /gasStipend must be > 0/,
  );
});

test("the default stipend is a sane, non-zero amount", () => {
  // A zero default would make the token path succeed and still strand the funds — the exact failure
  // the refusal above exists to prevent, reintroduced through a constant.
  assert.ok(DEFAULT_GAS_STIPEND > 0n);
  assert.ok(DEFAULT_GAS_STIPEND < 10n ** 17n, "the default stipend is large enough to be worth stealing");
  const plan = planWithdrawal({ ...base, asset: TOKEN, gasNote: GAS_NOTE, gasScope: 1n });
  assert.strictEqual(plan.legs[0]!.withdrawnValue, DEFAULT_GAS_STIPEND);
});
