// Run: node --test src/pp/relay.test.ts
//
// THE HIGHEST-CONSEQUENCE ENCODING BOUNDARY IN THE WITHDRAWAL PATH. `context` is the only public
// signal naming who gets paid, so if this derivation and PrivacyPool's disagree, every proof is
// generated at full cost and then reverts with ContextMismatch on submission.
//
// WHY THIS FILE EXISTS WHEN RelayContext.t.sol ALREADY CROSS-CHECKS IT. That test hardcodes the
// value the TypeScript produced and compares Solidity against it — so it catches SOLIDITY drifting,
// and is blind to TypeScript drifting, because it never runs any TypeScript. The pin was
// one-directional. This is the other half: the same constants, asserted from this side, so a change
// to either implementation now fails on the side that changed.
//
// `tsc` cannot help here — the TS ABI types are strings — and neither can any amount of TypeScript
// testing TypeScript, which is the whole reason the fixture is borrowed rather than computed.
import test from "node:test";
import assert from "node:assert";
import {
  SNARK_SCALAR_FIELD,
  buildRelayedWithdrawal,
  buildSelfWithdrawal,
  encodeRelayData,
  withdrawalContext,
} from "./relay.ts";

// ── the cross-language fixture ────────────────────────────────────────────────────────────────
//
// These four constants and both expected values are copied from
// backend/contracts/test/pool/RelayContext.t.sol. Do NOT "fix" a failure here by pasting in
// whatever this side now produces — establish which side moved first, exactly as
// BatchCommitmentTest instructs.

const ENTRYPOINT = "0x00000000000000000000000000000000000000e1";
const RECIPIENT = "0x00000000000000000000000000000000000000A1";
const FEE_RECIPIENT = "0x00000000000000000000000000000000000000f1";
const FEE_BPS = 250n;
const SCOPE = 42n;

/** `uint256(keccak256(abi.encode(_withdrawal, SCOPE))) % SNARK_SCALAR_FIELD`, per PrivacyPool. */
const SOLIDITY_CONTEXT =
  7948633688262801802494452180195935100535116121924170774747370064017535756814n;

/** `abi.encode(RelayData)` as Solidity produces it. */
const SOLIDITY_RELAY_DATA =
  "0x" +
  "00000000000000000000000000000000000000000000000000000000000000a1" +
  "00000000000000000000000000000000000000000000000000000000000000f1" +
  "00000000000000000000000000000000000000000000000000000000000000fa";

const RELAY = { recipient: RECIPIENT, feeRecipient: FEE_RECIPIENT, relayFeeBPS: FEE_BPS };
const withdrawalFor = (relay = RELAY) => ({
  processooor: ENTRYPOINT,
  data: encodeRelayData(relay),
});

test("encodeRelayData reproduces Solidity's abi.encode(RelayData)", () => {
  assert.strictEqual(encodeRelayData(RELAY).toLowerCase(), SOLIDITY_RELAY_DATA.toLowerCase());
});

test("withdrawalContext reproduces the value PrivacyPool derives", () => {
  assert.strictEqual(
    withdrawalContext(withdrawalFor(), SCOPE),
    SOLIDITY_CONTEXT,
    "the TypeScript context derivation diverged from PrivacyPool.validWithdrawal",
  );
});

test("the context is a usable field element", () => {
  // It is a circuit public input, so a value at or above the field would be silently reduced
  // somewhere downstream rather than rejected here.
  const c = withdrawalContext(withdrawalFor(), SCOPE);
  assert.ok(c > 0n && c < SNARK_SCALAR_FIELD);
});

// ── what the context must bind ────────────────────────────────────────────────────────────────

test("every field a relayer could tamper with changes the context", () => {
  // This is the entire anti-theft argument in relay.ts: a relayer that alters the recipient, the
  // fee recipient or the fee produces a context mismatch and the withdrawal reverts. If any of these
  // did NOT move the context, that field would be freely editable in the mempool.
  const baseline = withdrawalContext(withdrawalFor(), SCOPE);
  const variants: Array<[string, typeof RELAY]> = [
    ["recipient", { ...RELAY, recipient: "0x00000000000000000000000000000000000000A2" }],
    ["feeRecipient", { ...RELAY, feeRecipient: "0x00000000000000000000000000000000000000f2" }],
    ["relayFeeBPS", { ...RELAY, relayFeeBPS: FEE_BPS + 1n }],
  ];
  for (const [name, relay] of variants) {
    assert.notStrictEqual(
      withdrawalContext(withdrawalFor(relay), SCOPE),
      baseline,
      `${name} is not bound by the context — a relayer could rewrite it`,
    );
  }
});

test("the processooor and the scope are bound too", () => {
  const baseline = withdrawalContext(withdrawalFor(), SCOPE);
  assert.notStrictEqual(
    withdrawalContext({ ...withdrawalFor(), processooor: RECIPIENT }, SCOPE),
    baseline,
    "the processooor is not bound — the proof could be submitted through a different path",
  );
  assert.notStrictEqual(
    withdrawalContext(withdrawalFor(), SCOPE + 1n),
    baseline,
    "the scope is not bound — a proof could be replayed against another pool",
  );
});

// ── the two builders ──────────────────────────────────────────────────────────────────────────

test("buildRelayedWithdrawal targets the Entrypoint and agrees with withdrawalContext", () => {
  // `Entrypoint.relay` rejects any other processooor (InvalidProcessooor), because it is the
  // Entrypoint that calls PrivacyPool.withdraw and splits the proceeds.
  const { withdrawal, context } = buildRelayedWithdrawal(ENTRYPOINT, SCOPE, RELAY);
  assert.strictEqual(withdrawal.processooor, ENTRYPOINT);
  assert.strictEqual(withdrawal.data, encodeRelayData(RELAY));
  assert.strictEqual(context, SOLIDITY_CONTEXT);
  assert.strictEqual(context, withdrawalContext(withdrawal, SCOPE));
});

test("an out-of-range relay fee is refused", () => {
  // Rejected on-chain against assetConfig maxRelayFeeBPS anyway, but a proof built around an
  // impossible fee is minutes of proving thrown away.
  for (const bps of [-1n, 10_001n]) {
    assert.throws(
      () => buildRelayedWithdrawal(ENTRYPOINT, SCOPE, { ...RELAY, relayFeeBPS: bps }),
      /relayFeeBPS must be within 0..10000/,
    );
  }
  assert.doesNotThrow(() => buildRelayedWithdrawal(ENTRYPOINT, SCOPE, { ...RELAY, relayFeeBPS: 0n }));
  assert.doesNotThrow(() =>
    buildRelayedWithdrawal(ENTRYPOINT, SCOPE, { ...RELAY, relayFeeBPS: 10_000n }),
  );
});

test("buildSelfWithdrawal carries no relay data and is a different context", () => {
  // The censorship escape hatch goes straight to PrivacyPool.withdraw, so there is no RelayData and
  // no fee. Its context must not collide with the relayed one for the same scope.
  const self = buildSelfWithdrawal(RECIPIENT, SCOPE);
  assert.strictEqual(self.withdrawal.processooor, RECIPIENT);
  assert.strictEqual(self.withdrawal.data, "0x");
  assert.strictEqual(self.context, withdrawalContext(self.withdrawal, SCOPE));
  assert.notStrictEqual(self.context, SOLIDITY_CONTEXT);
});
