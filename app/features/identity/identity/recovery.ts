// Recovery for the one root mnemonic — the seed every other key derives from.
//
// WHY THIS EXISTS. Until now there was NO RECOVERY AT ALL, and the shape of the gap was easy to
// miss because it looked like a security feature:
//   • `getOrCreateRootMnemonic()` GENERATES a phrase; nothing ever imported one.
//   • The phrase was never displayed, so the user could not write it down.
//   • `WHEN_UNLOCKED_THIS_DEVICE_ONLY` deliberately excludes it from iCloud Keychain and device
//     backups, and `requireAuthentication` ties it to the current biometric enrolment.
// A lost, wiped or re-enrolled phone therefore meant a lost identity and every Privacy Pool note
// gone, permanently.
//
// THE DISTINCTION THAT MAKES A FIX POSSIBLE: the phrase is NOT a non-extractable Secure Enclave
// key. It is a value STORED IN Keychain/Keystore, readable by the app after biometric auth. So
// recovery was a feature nobody had built, not a physical impossibility.
//
// WHY NOT AN MPC / SOCIAL-RECOVERY SDK (Web3Auth, Turnkey, Privy, Para). Every one of them puts a
// share on somebody's server, and most gate recovery behind Google or Apple sign-in — which is
// exactly the deniable-refusal lever this whole project exists to remove (sec. 2.22c), and
// a US-operated dependency for the users least able to afford one. It would contradict the
// no-infrastructure and censorship-resistance claims directly. So: a backup the USER holds,
// readable by nobody without their passphrase, and no party to ask.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
// THIS MODULE IS DELIBERATELY PURE — no expo-secure-store, no React Native.
//
// That is what lets `tools/check-recovery.js` actually RUN it under node and prove the round trip,
// instead of asserting in a comment that it works. The SecureStore-touching wrappers live in
// root.ts, which cannot be exercised off-device. Keep it that way: an import of expo-secure-store
// here silently deletes the only test this code has.
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// FORMAT: the Web3 Secret Storage keystore (v3) that ethers already implements — scrypt with
// N = 131072, AES-128-CTR, MAC-checked. Not a scheme invented here. We add no dependency, and the
// file is readable by any standard tool if this wallet ever disappears, which for a recovery
// artefact is the property that matters most.

import { HDNodeWallet, Mnemonic, Wallet } from "ethers";

/**
 * Minimum passphrase length.
 *
 * The backup is meant to be stored somewhere the device is not — cloud storage, a USB stick, a
 * second phone — so it must survive being COPIED. scrypt at N = 131072 makes guessing expensive
 * but cannot rescue a four-character passphrase from an attacker holding the file.
 *
 * A LIMIT, NOT A STRENGTH METER. We reject the obviously hopeless and refuse to editorialise about
 * the rest; a wallet that rejects a strong passphrase for lacking a digit teaches users to pick
 * weaker, more memorable ones.
 */
export const MIN_PASSPHRASE_LENGTH = 12;

export class InvalidMnemonicError extends Error {
  constructor(reason: string) {
    super(`InvalidMnemonicError: ${reason}`);
    this.name = "InvalidMnemonicError";
  }
}

export class WeakPassphraseError extends Error {
  constructor() {
    super(
      `WeakPassphraseError: the backup passphrase must be at least ${MIN_PASSPHRASE_LENGTH} ` +
        "characters — this file is meant to be stored off the device, so it must survive being copied",
    );
    this.name = "WeakPassphraseError";
  }
}

/**
 * Reject a phrase that is not valid BIP39 BEFORE it is stored.
 *
 * THE FAILURE THIS PREVENTS IS SILENT AND TOTAL. Storing a mistyped phrase would overwrite the
 * root with something that still DERIVES keys perfectly well — they would just be the wrong keys,
 * for an identity that owns nothing. The user would see an empty wallet rather than an error, and
 * the real phrase would by then be gone. BIP39's checksum catches a single wrong word, which is
 * the overwhelmingly common case when someone types 24 words from paper.
 */
export function assertValidMnemonic(phrase: string): string {
  const normalised = phrase.trim().replace(/\s+/g, " ").toLowerCase();
  if (normalised.length === 0) throw new InvalidMnemonicError("empty phrase");

  const words = normalised.split(" ");
  if (words.length !== 12 && words.length !== 24) {
    throw new InvalidMnemonicError(
      `expected 12 or 24 words, got ${words.length} — this wallet generates 24`,
    );
  }
  // Mnemonic.fromPhrase validates the wordlist AND the checksum; it throws on either.
  try {
    Mnemonic.fromPhrase(normalised);
  } catch {
    throw new InvalidMnemonicError(
      "the phrase is not valid BIP39 — a word is misspelled, out of order, or mistyped " +
        "(the checksum would not catch a swap of two correct words, so check the order too)",
    );
  }
  return normalised;
}

function assertUsablePassphrase(passphrase: string): void {
  if (passphrase.length < MIN_PASSPHRASE_LENGTH) throw new WeakPassphraseError();
}

/**
 * Encrypt the root mnemonic into a portable backup.
 *
 * IDENTIFYING METADATA IS STRIPPED, and this is not cosmetic. ethers writes a plaintext `address`
 * field — the address for `m/44'/60'/0'/0/0`, which is EXACTLY the path `src/pp/notes.ts` uses for
 * Privacy Pool account 0. So an unmodified keystore would publish, in the clear, an address derived
 * from the same key material as the user's note secrets: a stable identifier linking every copy of
 * the backup to every other, and to on-chain activity if that address were ever funded. For a file
 * whose whole purpose is to be stored somewhere less safe than the device, that is the wrong
 * default.
 *
 * `gethFilename` embeds the same address AND a creation timestamp, and `id`/`client` are a
 * per-file UUID and a version string — all removed for the same reason.
 *
 * MEASURED, NOT ASSUMED: `address` cannot merely be blanked. ethers checks it against the decrypted
 * key and rejects a zeroed one with "keystore address/privateKey mismatch"; DELETING it restores
 * cleanly. tools/check-recovery.js pins both behaviours, because a future ethers that started
 * requiring the field would break every backup silently.
 */
export async function sealMnemonic(mnemonic: string, passphrase: string): Promise<string> {
  const phrase = assertValidMnemonic(mnemonic);
  assertUsablePassphrase(passphrase);

  const json = JSON.parse(await HDNodeWallet.fromPhrase(phrase).encrypt(passphrase));

  delete json.address;
  delete json.id;
  if (json["x-ethers"]) {
    delete json["x-ethers"].gethFilename;
    delete json["x-ethers"].client;
  }

  return JSON.stringify(json);
}

/**
 * Recover the root mnemonic from a backup.
 *
 * Returns the phrase rather than writing it: storing it is root.ts's job, and that path has a guard
 * against overwriting a live wallet which this function must not be able to bypass.
 */
export async function openBackup(backupJson: string, passphrase: string): Promise<string> {
  let restored;
  try {
    restored = await Wallet.fromEncryptedJson(backupJson, passphrase);
  } catch (e) {
    throw new InvalidMnemonicError(
      "the backup could not be decrypted — wrong passphrase, or the file is corrupt " +
        `(${(e as Error).message})`,
    );
  }

  // A keystore holding only a private key decrypts fine and yields NO mnemonic. Restoring from one
  // would give a working Ethereum wallet whose identity and note keys are all missing - an empty
  // wallet rather than an error, which is the failure mode this whole module exists to avoid.
  const phrase = (restored as HDNodeWallet).mnemonic?.phrase;
  if (!phrase) {
    throw new InvalidMnemonicError(
      "this keystore contains a private key but NO recovery phrase, so it cannot restore an " +
        "identity or any Privacy Pool note — it is not a backup made by this wallet",
    );
  }
  return assertValidMnemonic(phrase);
}
