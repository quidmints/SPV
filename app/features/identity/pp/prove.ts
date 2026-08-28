// The proving endpoint for a Privacy Pool withdrawal — the step after buildWithdrawalWitness().
//
// WHY THIS FILE EXISTS AT ALL: `src/sdk/circuits.ts` registers `withdraw_identity` with the SDK's
// circuit registry as an import SIDE EFFECT, so it only takes effect if something imports it.
// Nothing did — the assembler stops at the witness and the proving call site did not exist — which
// made the registration dead code that would have failed at `fromName('withdraw_identity')` with
// "Noir Circuit with name withdraw_identity not found". Importing it HERE, in the one module that
// needs the registry, is what ties the two halves together.
//
// NOT RUNNABLE ON THIS DEV MACHINE, and not runnable on iOS at all:
//   • `proveHonk` is ANDROID-ONLY. The SDK's Android native module implements it
//     (RnNoirModule.kt, proofType = "honk"); iOS's RnNoirModule.swift hardcodes
//     proof_type: "plonk" and has no Honk entry point.
//   • `noir.aar` ships only an `arm64-v8a` slice, so an x86 emulator cannot prove either.
//   • The trusted setup is downloaded on first use and is ~large; `ensureTrustedSetup` exposes
//     that as an explicit, progress-reportable step rather than a hidden stall inside prove.
// See sec. 1b / sec. 2.1a. Every claim here is reasoned from the code, NOT measured — no
// device has ever run this path.

// NOT `import type` — used as a value below.
//
// THIS MODULE CANNOT BE LOADED BY `node --test`, and the cause is THIS LINE rather than the
// `../sdk/circuits` import below (checked: importing `@rarimo/rarime-rn-sdk` on its own fails
// identically). The SDK reaches expo-file-system, which ships untranspiled TypeScript inside
// node_modules, and Node refuses to strip types there. Making `circuits` lazy would therefore
// change nothing.
//
// That is a boundary rather than a defect: both functions here are thin awaits over SDK calls with
// no logic of their own, so there is nothing to unit-test that would not amount to asserting a mock
// returns what it was told to. Exercised on a device.
import { NoirCircuitParams } from "@rarimo/rarime-rn-sdk";
import "../sdk/circuits.ts"; // side effect: registers withdraw_identity + title_holder
import type { WithdrawWitness } from "./withdrawWitness.ts";

/** Name registered by src/sdk/circuits.ts. Kept as a constant so a typo is one edit, not two. */
export const WITHDRAW_CIRCUIT = "withdraw_identity";

export interface ProveProgress {
  bytesWritten: number;
  totalBytes: number;
}

/**
 * Download the Barretenberg structured reference string, once per install.
 *
 * Separate from `proveWithdrawal` on purpose: it is the only slow, network-dependent, and
 * progress-reportable part, and a UI wants to show it rather than have proving appear to hang.
 * It is a no-op once the file is present.
 *
 * UNVERIFIED — the SRS file is named `ultraPlonkTrustedSetup.dat` and is reused for Honk.
 * Barretenberg's SRS is a universal curve-level KZG setup shared across its proof systems rather
 * than Plonk-specific, so this SHOULD be correct despite the name, but that is an argument and not
 * a measurement. If device proving fails, this is the first thing to check; the fix would be a
 * Honk-specific SRS download. See sec. 2.1a(b).
 */
export async function ensureTrustedSetup(
  onProgress?: (p: ProveProgress) => void,
): Promise<string> {
  return NoirCircuitParams.downloadTrustedSetup({ onDownloadingProgress: onProgress });
}

/**
 * Prove a withdrawal witness, returning the raw UltraHonk proof bytes as a hex string.
 *
 * Returns ONLY the proof. It deliberately does not try to re-extract public signals from the
 * prover output: that slicing convention is Plonk-specific in this binding and unconfirmed for
 * Honk. The caller already holds them — `buildWithdrawalWitness` returns `pubSignals` alongside the
 * circuit inputs, in the exact ProofLib order `PrivacyPool.withdraw` expects. Pair them with
 * `submitRelayedWithdrawal` from ./relay.
 */
export async function proveWithdrawal(
  witness: WithdrawWitness,
  onProgress?: (p: ProveProgress) => void,
): Promise<string> {
  const circuit = NoirCircuitParams.fromName(WITHDRAW_CIRCUIT);

  // Bundled, so this reads from the app bundle and never touches the network — see
  // src/sdk/circuits.ts for why the bytecode is shipped rather than fetched.
  const byteCode = await circuit.loadByteCode({ onDownloadingProgress: onProgress });

  return circuit.proveHonk(JSON.stringify(witness.inputs), byteCode);
}
