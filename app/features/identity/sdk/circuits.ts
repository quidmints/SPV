// Registers THIS FUSION'S OWN Noir circuits with the SDK's circuit registry.
//
// REPLACES a vendored copy of the SDK's entire RnNoirModule.ts. That copy existed because
// `supportedNoirCircuits` was module-private, so the only way to add a circuit was to fork the
// module and edit the array - and once forked it drifted, to the point where the local copy was
// the only one carrying the expo-file-system 57 migration while the package could not even build.
// `registerNoirCircuit` was added upstream (quidmints/rarime-rn-sdk) precisely so this file can be
// ~40 lines instead of ~250, and so SDK fixes arrive by `npm install` rather than by hand-merging.
//
// Import this module ONCE, for its side effect, before any code calls
// `NoirCircuitParams.fromName('withdraw_identity' | 'title_holder')`.

import { NoirCircuitParams, registerNoirCircuit } from "@rarimo/rarime-rn-sdk";

/**
 * Both circuits are BUNDLED, not hosted. Every circuit the SDK ships fetches its bytecode from
 * storage.googleapis.com/rarimo-store/...; ours are built locally by
 * backend/circuits/codegen-verifiers.sh and published nowhere, so they ride along in the app
 * bundle as assets/circuits/*.circuit (registered in metro.config.js's `assetExts`).
 *
 * That is also the better security posture rather than merely a workaround: the bytecode
 * determines WHAT IS BEING PROVEN, so fetching it from a mutable remote URL would put whoever
 * controls that URL inside the trust boundary of every proof. `codegen-verifiers.sh` re-copies
 * these assets on every run, so they cannot drift from the circuit whose on-chain verifier was
 * generated alongside them.
 *
 * `byteCodeUri` is unused when `bundledAsset` is set (loadByteCode short-circuits to the bundle);
 * the `unhosted:` string is a self-describing placeholder rather than a plausible-looking URL that
 * would fail as a generic 404.
 *
 * BOTH ARE ULTRAHONK, so they must be proven with `proveHonk()`, never `prove()` - and proveHonk is
 * ANDROID-ONLY (iOS's RnNoirModule.swift hardcodes proof_type: "plonk"). See sec. 2.1a.
 * `pub_signals_count` is recorded for completeness but is NOT used on the Honk path: proveHonk
 * returns the raw proof without slicing public signals out, and the caller already holds them
 * (`buildWithdrawalWitness` returns `pubSignals`).
 */
export const WITHDRAW_IDENTITY = new NoirCircuitParams(
  "withdraw_identity",
  "unhosted:withdraw_identity",
  8, // ProofLib.WithdrawProof.pubSignals - pinned, see withdraw_identity/src/main.nr
  require("../../assets/circuits/withdraw_identity.circuit"),
);

export const TITLE_HOLDER = new NoirCircuitParams(
  "title_holder",
  "unhosted:title_holder",
  2, // expected_commitment, title_id - title_holder/src/main.nr:17
  require("../../assets/circuits/title_holder.circuit"),
);

registerNoirCircuit(WITHDRAW_IDENTITY);
registerNoirCircuit(TITLE_HOLDER);
