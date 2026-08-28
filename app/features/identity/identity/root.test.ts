// Run: node --experimental-test-module-mocks --test src/identity/root.test.ts
//
// WHAT THIS FILE EXISTS TO PIN. `root.ts` holds the root seed — the identity scalar and every PP
// note key derive from it — and it had no tests at all. The session cache added for UX (one
// biometric prompt per session instead of one per call) is correct for ordinary work and WRONG for
// the two operations that move the seed off the device, because those hand over the key rather than
// use it. With the cache applied to them, anyone holding an unlocked phone could display all 24
// words, or write a backup under a passphrase they chose, with no biometric challenge.
//
// The distinction is invisible in the types and survives no refactor unless it is asserted, so what
// is tested here is the PROMPT COUNT: a SecureStore read is what triggers the biometric challenge
// (`requireAuthentication: true`), so counting reads is counting prompts.
import test from 'node:test';
import assert from 'node:assert';
import { mock } from 'node:test';

const ROOT_KEY = 'quid.wallet.root.mnemonic';
/** A REAL 24-word phrase with a valid BIP39 checksum (entropy 0xab*32).
 *  Not the 12-word test vector repeated: that has no valid checksum, and `sealMnemonic` validates
 *  while `revealRootMnemonic` does not -- so the wrong constant makes only SOME tests fail, which is
 *  exactly the kind of half-failure that gets papered over. */
const PHRASE =
  'produce front turtle firm rival still push install produce front turtle firm ' +
  'rival still push install produce front turtle firm rival still push infant';

/** Stands in for the platform keystore, counting the reads that would each raise a prompt. */
class FakeSecureStore {
  store = new Map<string, string>();
  reads = 0;
  writes = 0;
  biometricsAvailable = true;

  getItemAsync = async (key: string) => {
    this.reads += 1;
    return this.store.get(key) ?? null;
  };
  setItemAsync = async (key: string, value: string) => {
    this.writes += 1;
    this.store.set(key, value);
  };
  deleteItemAsync = async (key: string) => {
    this.store.delete(key);
  };
  canUseBiometricAuthentication = () => this.biometricsAvailable;
  WHEN_UNLOCKED_THIS_DEVICE_ONLY = 'when-unlocked-this-device-only';
}

// `mock.module` may register a specifier only once per process, so the mock delegates to a
// swappable holder rather than being re-registered per test.
let fake = new FakeSecureStore();

mock.module('expo-secure-store', {
  namedExports: {
    getItemAsync: (k: string) => fake.getItemAsync(k),
    setItemAsync: (k: string, v: string) => fake.setItemAsync(k, v),
    deleteItemAsync: (k: string) => fake.deleteItemAsync(k),
    canUseBiometricAuthentication: () => fake.canUseBiometricAuthentication(),
    WHEN_UNLOCKED_THIS_DEVICE_ONLY: 'when-unlocked-this-device-only',
  },
});

let caseId = 0;

/** Fresh module graph per test so the module-level `sessionMnemonic` never leaks between cases. */
async function loadRoot(seeded: boolean) {
  fake = new FakeSecureStore();
  if (seeded) fake.store.set(ROOT_KEY, PHRASE);

  const mod = await import(`./root.ts?case=${caseId++}`);
  return { mod, fake };
}

// ---- the exfiltration paths must ALWAYS re-authenticate -----------------------------------------

test('revealRootMnemonic re-reads the keystore even when the session is already warm', async () => {
  const { mod, fake } = await loadRoot(true);

  await mod.getOrCreateRootMnemonic(); // warms the cache — one read, one prompt
  const warmReads = fake.reads;
  assert.strictEqual(warmReads, 1, 'setup: the first unlock should read once');

  const revealed = await mod.revealRootMnemonic();
  assert.strictEqual(revealed, PHRASE);
  assert.strictEqual(
    fake.reads,
    warmReads + 1,
    'revealing the seed used the session cache — it displayed 24 words with no biometric prompt',
  );

  // ...and again: every reveal is its own challenge, not just the first after unlocking.
  await mod.revealRootMnemonic();
  assert.strictEqual(fake.reads, warmReads + 2);
});

test('exportEncryptedBackup re-reads the keystore even when the session is already warm', async () => {
  const { mod, fake } = await loadRoot(true);

  await mod.getOrCreateRootMnemonic();
  const warmReads = fake.reads;

  await mod.exportEncryptedBackup('a-passphrase-the-caller-chose');
  assert.strictEqual(
    fake.reads,
    warmReads + 1,
    'backup export used the session cache — the passphrase is chosen by whoever calls this, so ' +
      'it is no substitute for the biometric challenge',
  );
});

// ---- ...while ordinary use keeps the cache, which is the whole point of it ----------------------

test('ordinary derivation still prompts at most once per session', async () => {
  const { mod, fake } = await loadRoot(true);

  await mod.getOrCreateRootMnemonic();
  await mod.getOrCreateRootMnemonic();
  await mod.getOrCreateRootMnemonic();
  assert.strictEqual(fake.reads, 1, 'the session cache regressed — this is the unshippable-UX case');
});

test('lockWallet forces the next ordinary read to re-authenticate', async () => {
  const { mod, fake } = await loadRoot(true);

  await mod.getOrCreateRootMnemonic();
  assert.strictEqual(fake.reads, 1);
  mod.lockWallet();
  await mod.getOrCreateRootMnemonic();
  assert.strictEqual(fake.reads, 2, 'lockWallet did not actually clear the cache');
});

// ---- refusing rather than creating --------------------------------------------------------------

test('revealRootMnemonic refuses on a device with no wallet instead of minting one', async () => {
  const { mod, fake } = await loadRoot(false);

  await assert.rejects(() => mod.revealRootMnemonic(), /NoWalletError/);
  assert.strictEqual(fake.writes, 0, 'a "reveal" created a seed — the user would be shown 24 words that protect nothing');
});

test('exportEncryptedBackup refuses on a device with no wallet', async () => {
  const { mod, fake } = await loadRoot(false);

  await assert.rejects(() => mod.exportEncryptedBackup('pw'), /NoWalletError/);
  assert.strictEqual(fake.writes, 0);
});

// ---- the hardware-backing refusal applies to the fresh path too ---------------------------------

test('the exfiltration paths refuse a device without hardware-gated storage', async () => {
  const { mod, fake } = await loadRoot(true);
  fake.biometricsAvailable = false;

  // Must not fall back to returning the phrase from memory when the hardware check fails.
  await assert.rejects(() => mod.revealRootMnemonic(), /InsecureDeviceError/);
  await assert.rejects(() => mod.exportEncryptedBackup('pw'), /InsecureDeviceError/);
});
