// WalletRoot — the single device-enclave RootSeed (Lexe model, RN).
//
// ONE BIP39 mnemonic, held in the platform secure enclave (iOS Keychain / Android Keystore via
// expo-secure-store), roots EVERYTHING:
//   • sk_identity (rarime BJJ private key)  — derived at a dedicated HD path, reduced into the field
//   • PP master keys (all Privacy Pool notes) — via src/pp/notes (HD accounts 0 & 1)
//
// This is the greenlit rarime↔PP unification: recover the one mnemonic and you recover both the
// identity and every privacy-pool note. No separate note backup, one secret to protect.
//
// HARDWARE BACKING IS NOW ACTUALLY CHECKED AND ENFORCED, not just asserted in a comment.
// `keychainAccessible` alone (the only option previously set) controls WHEN a keychain item is
// accessible, not WHETHER the underlying storage is hardware-backed (Secure Enclave / TEE-
// StrongBox) — expo-secure-store can silently fall back to software-backed storage on a device
// without one. The real signal expo-secure-store exposes is `canUseBiometricAuthentication()` +
// the `requireAuthentication` option (ties the key to Android's `setUserAuthenticationRequired`
// / iOS's `biometryCurrentSet` — genuinely hardware-gated key material, per expo-secure-store's
// own SecureStore.d.ts). We now check availability explicitly and fail closed rather than
// silently store the root seed unprotected.
//
// SESSION CACHE, not re-auth on every call: `requireAuthentication: true` alone would prompt
// biometric auth on nearly every wallet operation (per expo-secure-store's own docs — on Android,
// EVERY operation) — unshippable UX. Correct pattern: authenticate once via SecureStore, cache the
// unlocked mnemonic in memory for the app's session, and only hit SecureStore (re-prompting) again
// after an explicit lockWallet() or process restart. The in-memory cache is the standard, accepted
// trade-off every mobile wallet/password manager makes for this UX — plaintext in JS memory for the
// session, never persisted unencrypted, cleared on lock/background.
//
// OPERATIONAL DEPENDENCY: requireAuthentication needs expo-secure-store's own config plugin
// registered (Face ID usage description on iOS) to work outside Expo Go — per expo-secure-store's
// own docs. Checked and registered in app.json's `expo.plugins` (was missing — only the rarime
// SDK's plugin was present before).

import * as SecureStore from "expo-secure-store";
import { HDNodeWallet, Mnemonic, hexlify } from "ethers";

import { drawSeedEntropy } from "./entropy.ts";
import { FIELD, masterKeysFromMnemonic, type MasterKeys } from "../pp/notes.ts";
import { assertValidMnemonic, openBackup, sealMnemonic } from "./recovery.ts";

const ROOT_KEY = "quid.wallet.root.mnemonic";

// HD path for the rarime identity scalar — domain-separated from PP's accounts (0 & 1).
const IDENTITY_PATH = "m/44'/60'/100'/0/0";

/** Thrown when the device cannot confirm hardware-gated secure storage is available. Callers
 *  should treat this as fatal for the root seed specifically (not a generic error to swallow) —
 *  proceeding would store identity + all PP notes without the hardware backing this design
 *  requires. */
export class InsecureDeviceError extends Error {
  constructor() {
    super(
      "InsecureDeviceError: device cannot confirm hardware-gated secure storage " +
        "(SecureStore.canUseBiometricAuthentication() returned false) — refusing to store the root seed",
    );
    this.name = "InsecureDeviceError";
  }
}

const SECURE_ITEM_OPTIONS: SecureStore.SecureStoreOptions = {
  keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
  requireAuthentication: true,
  authenticationPrompt: "Unlock your identity and Privacy Pool funds",
};

// In-memory session cache — see the module doc comment for the trade-off this accepts. Cleared by
// lockWallet(); a fresh SecureStore read (and its one biometric prompt) only happens again after
// that or a process restart.
let sessionMnemonic: string | undefined;

/** Read the enclave-held root mnemonic, creating one on first use. Never leaves the device.
 *  Throws InsecureDeviceError if hardware-gated storage isn't confirmed available — this does
 *  NOT silently degrade to software-backed storage for material this sensitive. Prompts biometric
 *  auth AT MOST once per session (see sessionMnemonic) — not on every call. */
export async function getOrCreateRootMnemonic(): Promise<string> {
  if (sessionMnemonic) return sessionMnemonic;

  if (!SecureStore.canUseBiometricAuthentication()) {
    throw new InsecureDeviceError();
  }

  const existing = await SecureStore.getItemAsync(ROOT_KEY, SECURE_ITEM_OPTIONS);
  if (existing) {
    sessionMnemonic = existing;
    return existing;
  }

  // Entropy comes from `drawSeedEntropy`, not straight from one RNG (sec. 2.18bd/bf). It asserts a
  // real CSPRNG is present and names the fix if not, rejects degenerate output, and extracts through
  // keccak so no single source determines the result. 32 bytes = 256 bits = 24 words - not 12: the
  // extra margin costs the user nothing to store and leaves 2^128 even under Grover.
  const phrase = Mnemonic.fromEntropy(hexlify(drawSeedEntropy())).phrase; // 24 words
  await SecureStore.setItemAsync(ROOT_KEY, phrase, SECURE_ITEM_OPTIONS);
  sessionMnemonic = phrase;
  return phrase;
}

/** Clear the in-memory session cache, forcing the next getOrCreateRootMnemonic() call to
 *  re-authenticate via SecureStore (a fresh biometric prompt). Call this on explicit user lock
 *  and when the app backgrounds, per your own session-timeout policy — this module doesn't decide
 *  that policy itself, it just provides the primitive. */
export function lockWallet(): void {
  sessionMnemonic = undefined;
}

/** Thrown when an operation needs an existing root seed and there is none. Distinct from creating
 *  one: the EXFILTRATION paths below must never bring a wallet into existence as a side effect of
 *  being asked to reveal or export it. */
export class NoWalletError extends Error {
  constructor() {
    super("NoWalletError: no root seed is stored on this device");
    this.name = "NoWalletError";
  }
}

/**
 * Read the stored phrase with a FRESH biometric prompt, deliberately BYPASSING the session cache.
 *
 * WHY THE CACHE MUST NOT APPLY HERE. The session cache is right for ordinary work — signing,
 * deriving, discovering notes — where re-prompting on every call is unshippable. It is wrong for the
 * two operations that take the seed OFF the device, because those are not "use the key", they are
 * "hand over the key". With the cache applied, anyone holding the phone during an unlocked session
 * could display all 24 words, or write an encrypted backup under a passphrase THEY choose, with no
 * biometric challenge at all. That is not one fraudulent transaction; it is permanent, silent,
 * total compromise of the identity and every PP note, and it survives the user later locking the app.
 *
 * `requireAuthentication: true` in SECURE_ITEM_OPTIONS makes each SecureStore read prompt, so simply
 * not consulting the cache is what restores the challenge.
 *
 * Refuses rather than creating a seed: being asked to reveal a wallet that does not exist is a
 * caller bug, and silently minting one would show the user 24 words that protect nothing.
 */
async function readRootMnemonicFresh(): Promise<string> {
  if (!SecureStore.canUseBiometricAuthentication()) throw new InsecureDeviceError();

  const existing = await SecureStore.getItemAsync(ROOT_KEY, SECURE_ITEM_OPTIONS);
  if (!existing) throw new NoWalletError();

  sessionMnemonic = existing;
  return existing;
}

/** rarime BJJ private key (64-char hex) derived from the root mnemonic. */
export function deriveSkIdentity(mnemonic: string): string {
  const node = HDNodeWallet.fromPhrase(mnemonic, "", IDENTITY_PATH);
  const scalar = BigInt(node.privateKey) % FIELD;
  return scalar.toString(16).padStart(64, "0");
}

/** Privacy Pool master keys derived from the SAME root mnemonic. */
export function deriveProfileMasterKeys(mnemonic: string): MasterKeys {
  return masterKeysFromMnemonic(mnemonic);
}

export interface WalletRoot {
  mnemonic: string;
  skIdentity: string;
  ppMasterKeys: MasterKeys;
}

/** Load the enclave root and derive both identity + PP material from it. */
export async function loadWalletRoot(): Promise<WalletRoot> {
  const mnemonic = await getOrCreateRootMnemonic();
  return {
    mnemonic,
    skIdentity: deriveSkIdentity(mnemonic),
    ppMasterKeys: deriveProfileMasterKeys(mnemonic),
  };
}

// ───────────────────────────────────────────────────────────────────────────────────────────────
// RECOVERY. Everything below exists because, until it did, THERE WAS NONE - see recovery.ts's
// header for the full shape of that gap. The crypto lives there, pure and node-testable
// (tools/check-recovery.js); this half is the part that touches SecureStore and therefore cannot
// be exercised off-device.
// ───────────────────────────────────────────────────────────────────────────────────────────────

/** Thrown when a restore would destroy a wallet that already holds funds. */
export class WalletAlreadyExistsError extends Error {
  constructor() {
    super(
      "WalletAlreadyExistsError: a root seed is already stored on this device. Restoring over it " +
        "would PERMANENTLY LOSE every identity and Privacy Pool note derived from the current " +
        "seed. Back up the existing seed first, then pass { replaceExistingWallet: true }.",
    );
    this.name = "WalletAlreadyExistsError";
  }
}

/** Whether this device already holds a root seed. Prompts biometric auth ONLY when the session
 *  cache is cold — an unlocked session answers from memory. (The previous comment claimed it always
 *  prompts, which the `sessionMnemonic` short-circuit below has never done.) Existence is not
 *  secret, so this is deliberate; the operations that expose the seed itself re-authenticate
 *  unconditionally instead. */
export async function hasRootMnemonic(): Promise<boolean> {
  if (sessionMnemonic) return true;
  return (await SecureStore.getItemAsync(ROOT_KEY, SECURE_ITEM_OPTIONS)) !== null;
}

/**
 * Reveal the root phrase so the user can WRITE IT DOWN.
 *
 * THE WALLET WAS PREVIOUSLY UNBACKUPABLE BY CONSTRUCTION: the phrase was generated on-device and
 * never displayed, so no amount of diligence let a user protect themselves. This is the whole
 * mechanism behind "24 words on paper", which needs no passphrase, no file and no service - and is
 * the only recovery path that still works when the user has lost the device AND cannot reach a
 * network.
 *
 * DELIBERATELY A SEPARATE FUNCTION from the internal derivation calls, so that "show the user their
 * secret" is a distinct, greppable, auditable action rather than an incidental use of
 * `loadWalletRoot().mnemonic`. Callers must treat the return value as display-only: never log it,
 * never put it in a screenshot-able view without warning, never send it anywhere.
 *
 * ALWAYS RE-AUTHENTICATES (see readRootMnemonicFresh). It previously delegated to
 * `getOrCreateRootMnemonic`, which returns the session cache — so during an unlocked session this
 * printed all 24 words with no biometric prompt.
 */
export async function revealRootMnemonic(): Promise<string> {
  return readRootMnemonicFresh();
}

/**
 * Store a user-supplied phrase as the root seed - the "I wrote down 24 words" path.
 *
 * VALIDATED BEFORE IT IS STORED. A mistyped phrase would derive keys perfectly well; they would
 * simply be the wrong keys, and the user would see an empty wallet rather than an error, with the
 * real phrase already overwritten. See recovery.ts::assertValidMnemonic.
 */
export async function importRootMnemonic(
  phrase: string,
  opts: { replaceExistingWallet?: boolean } = {},
): Promise<void> {
  const normalised = assertValidMnemonic(phrase);

  if (!SecureStore.canUseBiometricAuthentication()) throw new InsecureDeviceError();
  if (!opts.replaceExistingWallet && (await hasRootMnemonic())) {
    throw new WalletAlreadyExistsError();
  }

  await SecureStore.setItemAsync(ROOT_KEY, normalised, SECURE_ITEM_OPTIONS);
  sessionMnemonic = normalised;
}

/**
 * Produce an encrypted backup file the user can store anywhere.
 *
 * The ciphertext is useless without the passphrase, and carries no address, device identifier or
 * timestamp (recovery.ts strips them - the unmodified keystore would have published an address
 * derived from the same seed as the user's note secrets). Nothing here contacts a server: the user
 * holds the only copy and there is no party to ask for it back.
 *
 * ALWAYS RE-AUTHENTICATES (see readRootMnemonicFresh), for the same reason as revealRootMnemonic:
 * this writes the seed to a file that leaves the device. The passphrase is no substitute for the
 * biometric challenge — whoever calls this CHOOSES the passphrase, so an attacker holding an
 * unlocked phone would simply pick their own.
 */
export async function exportEncryptedBackup(passphrase: string): Promise<string> {
  return sealMnemonic(await readRootMnemonicFresh(), passphrase);
}

/**
 * Restore from an encrypted backup.
 *
 * REFUSES BY DEFAULT IF A WALLET ALREADY EXISTS. Restoring an older backup over a live wallet is
 * irreversible and silent: every note derived from the current seed becomes unspendable, and the
 * user's next screen looks like an ordinary balance rather than a loss. Overwriting has to be an
 * explicit decision taken with that spelled out, not a default that happens to be convenient.
 */
export async function restoreFromEncryptedBackup(
  backupJson: string,
  passphrase: string,
  opts: { replaceExistingWallet?: boolean } = {},
): Promise<void> {
  // Decrypt BEFORE touching storage, so a wrong passphrase or corrupt file cannot leave the device
  // in a half-restored state.
  const phrase = await openBackup(backupJson, passphrase);
  await importRootMnemonic(phrase, opts);
}
