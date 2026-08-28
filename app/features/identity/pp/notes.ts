// Privacy Pool note derivation — rooted in the SAME device-enclave seed as the rarime identity.
// This is the rarime↔PP "fusion" (greenlit): one RootSeed → identity AND all PP notes, so the
// notes are recoverable from the seed (no separate note backup), and the wallet has one secret.
//
// Mirrors Privacy Pools' scheme's STRUCTURE (PP packages/sdk/src/crypto.ts + commitment.circom):
//   masterNullifier = Poseidon(hdKey(seed, acct 0))     masterSecret = Poseidon(hdKey(seed, acct 1))
//   deposit:    nullifier = Poseidon(masterNullifier, scope, index)   secret = Poseidon(masterSecret, scope, index)
//   withdrawal: nullifier = Poseidon(masterNullifier, label, index)   secret = Poseidon(masterSecret, label, index)
//   commitment  = Poseidon(value, label, Poseidon(nullifier, secret))   nullifierHash = Poseidon(nullifier)
//
// CROSS-CHECKED EMPIRICALLY (2026-07, not "by construction" — that was retracted) against PP's real
// SDK using PP's exact pinned `viem@2.22.14` + `maci-crypto`:
//   - The HD derivation itself IS byte-identical: viem's mnemonicToAccount(...).getHdKey().privateKey
//     and ethers' HDNodeWallet.fromPhrase(mnemonic, "", "m/44'/60'/N'/0/0").privateKey produce the
//     exact same raw key for the same mnemonic + account index.
//   - PP's reference crypto.ts does NOT match our output, because PP's OWN code has a real precision
//     bug: it converts the raw 32-byte private key via viem's `bytesToNumber` into a plain JS
//     `number` (which cannot hold a ~256-bit integer — silent, catastrophic precision loss) before
//     wrapping it in BigInt(). We never round-trip through a lossy `number` (the hex string parses
//     directly to a `bigint`), so OUR derivation is internally correct — but it will NOT reproduce
//     PP's actual reference-SDK output for the same mnemonic.
//   - Practical effect: this wallet's notes are self-consistent (this wallet always agrees with
//     itself) but NOT byte-identical to what PP's official SDK/web app would derive from the same
//     mnemonic. That only matters if cross-tool interop with PP's official frontend is a requirement
//     — for a wallet that owns its whole PP integration rather than wrapping PP's official UI, it
//     isn't. Flagged, not assumed either way.
//
// Implemented with deps the wallet already has (RN-safe): ethers HD (canonical BIP32/44) + @iden3
// Poseidon (canonical circomlib, matches PP's maci-crypto poseidon — also verified, same vectors).
// The account-key reduction below (privkeys can exceed the BN254 field) is the standard, universal
// practice across the whole Ethereum ZK ecosystem (circomlib/snarkjs/PP/rarime all do this) — the
// modulo bias from reducing a 256-bit value into a ~254-bit field is cryptographically negligible.
//
// DOMAIN SEPARATION (checked): sk_identity lives at HD path index 100, PP's master keys at indices
// 0 and 1 — all are HARDENED derivation (the ' in each path segment), meaning none of these sibling
// keys are derivable from each other or from a shared parent public key; only the root mnemonic
// itself derives all three. Compromising one derived key does not compromise the others.

import { HDNodeWallet } from "ethers";
import { Poseidon } from "@iden3/js-crypto";

/** BN254 scalar field (SNARK_SCALAR_FIELD) — Poseidon inputs live here. */
export const FIELD =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export interface MasterKeys {
  masterNullifier: bigint;
  masterSecret: bigint;
}

export interface NoteSecrets {
  nullifier: bigint;
  secret: bigint;
}

/** BIP44 account private key from the root mnemonic, reduced into the field (PP uses acct 0 & 1). */
function accountKey(mnemonic: string, accountIndex: number): bigint {
  const node = HDNodeWallet.fromPhrase(mnemonic, "", `m/44'/60'/${accountIndex}'/0/0`);
  return BigInt(node.privateKey) % FIELD;
}

/** Master keypair from the device-enclave RootSeed mnemonic. PP-compatible. */
export function masterKeysFromMnemonic(mnemonic: string): MasterKeys {
  return {
    masterNullifier: Poseidon.hash([accountKey(mnemonic, 0)]),
    masterSecret: Poseidon.hash([accountKey(mnemonic, 1)]),
  };
}

/** Deposit note (nullifier, secret) for a given pool scope + account index. */
export function depositSecrets(keys: MasterKeys, scope: bigint, index: bigint): NoteSecrets {
  return {
    nullifier: Poseidon.hash([keys.masterNullifier, scope, index]),
    secret: Poseidon.hash([keys.masterSecret, scope, index]),
  };
}

/** Withdrawal note (nullifier, secret) for a given deposit label + withdrawal index. */
export function withdrawalSecrets(keys: MasterKeys, label: bigint, index: bigint): NoteSecrets {
  return {
    nullifier: Poseidon.hash([keys.masterNullifier, label, index]),
    secret: Poseidon.hash([keys.masterSecret, label, index]),
  };
}

/** Precommitment = Poseidon(nullifier, secret) — the value bound at deposit (Deposited._precommitmentHash). */
export function precommitment(note: NoteSecrets): bigint {
  return Poseidon.hash([note.nullifier, note.secret]);
}

/** Commitment hash = Poseidon(value, label, Poseidon(nullifier, secret)). Matches commitment.circom. */
export function commitment(value: bigint, label: bigint, note: NoteSecrets): bigint {
  return Poseidon.hash([value, label, precommitment(note)]);
}

/** Public nullifier hash spent on withdrawal = Poseidon(nullifier). */
export function nullifierHash(nullifier: bigint): bigint {
  return Poseidon.hash([nullifier]);
}
