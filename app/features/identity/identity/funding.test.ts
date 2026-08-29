/*
 * §M1#2 phase 1(c) — the LP's Bitcoin funding half.
 *
 * These pin a key that controls FUNDS, so they assert the two properties that make ONE SEED safe:
 * the funding key is derivable from the same mnemonic (no second backup), and it is DISTINCT from
 * the identity key.
 *
 * `root.ts` imports `expo-secure-store` at module scope, so the derivation cannot be imported
 * without it even though the functions under test are pure. Stubbed the same way
 * `identity/root.test.ts` does — run with `--experimental-test-module-mocks`, from an environment
 * that can resolve `expo-secure-store` (i.e. `app/node_modules`, not a bare one). `root.test.ts`
 * has the same requirement.
 *
 * ⚠️ THE PINNED KEY BELOW WAS MEASURED INDEPENDENTLY, not copied from a run of this code: derived
 * directly with `ethers.HDNodeWallet.fromPhrase(PHRASE, "", "m/86'/0'/0'/0/0")` in a standalone
 * script, so the assertion checks the PATH rather than agreeing with whatever `root.ts` does.
 */
import test, { mock } from 'node:test';
import assert from 'node:assert';

mock.module('expo-secure-store', {
  namedExports: {
    getItemAsync: async () => null,
    setItemAsync: async () => undefined,
    deleteItemAsync: async () => undefined,
    canUseBiometricAuthentication: () => true,
    WHEN_UNLOCKED_THIS_DEVICE_ONLY: 'when-unlocked-this-device-only',
  },
});


// A published BIP-39 all-zeros-entropy vector. NOT a wallet — used so these assertions pin the
// derivation rather than re-deriving whatever the code happens to do.
const PHRASE =
  'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

test('the funding key derives from the same mnemonic as identity', async () => {
  const { deriveFundingKey } = await import('./root.ts');
  const f = deriveFundingKey(PHRASE);
  assert.match(f.privateKey, /^0x[0-9a-f]{64}$/, 'a 32-byte secp256k1 scalar');
  assert.match(f.publicKey, /^0x[0-9a-f]{66}$/, 'a 33-byte compressed point');
});

/// THE PROPERTY THAT MAKES ONE SEED ACCEPTABLE. §E182-b rejected reusing one secret across roles
/// because it "converts a degraded-service event into fund loss"; the same argument forbids
/// identity and funding collapsing onto one scalar.
test('the funding key is NOT the identity key', async () => {
  const { deriveFundingKey, deriveSkIdentity } = await import('./root.ts');
  const f = deriveFundingKey(PHRASE).privateKey.toLowerCase().replace(/^0x/, '');
  const id = deriveSkIdentity(PHRASE).toLowerCase();
  assert.notStrictEqual(f, id, 'funding and identity must not share a scalar');
});

/// DETERMINISM IS THE BACKUP STORY. §E188's "a lost phone restores from words the LP already backs
/// up" is only true if the same phrase yields the same key every time.
test('derivation is deterministic — the words ARE the backup', async () => {
  const { deriveFundingKey } = await import('./root.ts');
  assert.strictEqual(deriveFundingKey(PHRASE).privateKey, deriveFundingKey(PHRASE).privateKey);
});

/// AND IT MUST BE THE TAPROOT PATH. A silent change to m/44'/60' would still produce a valid key
/// and a working channel, and would quietly put BTC on the identity path — so pin the value.
test("the path is BIP-86 taproot (m/86'/0'/0'/0/0), not the EVM path", async () => {
  const { deriveFundingKey } = await import('./root.ts');
  assert.strictEqual(
    deriveFundingKey(PHRASE).privateKey,
    '0x41f41d69260df4cf277826a9b65a3717e4eeddbeedf637f212ca096576479361',
    "if this fails, check FUNDING_PATH was not changed away from m/86'/0'/0'/0/0",
  );
});
