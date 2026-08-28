#!/usr/bin/env node
/*
 * Exercise the wallet's key-recovery crypto for real.
 *
 * WHY A SCRIPT AND NOT A TEST FILE. This repo has no test runner in the wallet package, and adding
 * one to hold five assertions would be a bigger change than the code under test. The standing rule
 * here is no tests that cannot run - so this is a plain node script that runs.
 *
 * WHY IT EXISTS AT ALL. A recovery path is the one piece of a wallet that is never exercised until
 * the day someone has already lost their phone. Every assertion below is a way this could be
 * broken while looking completely fine on screen:
 *
 *   - the phrase round-trips but comes back TRUNCATED (ethers' keystore mnemonic field has a
 *     history of assuming 16 bytes of entropy; ours is 32, i.e. 24 words)
 *   - the wrong passphrase is ACCEPTED, or fails with an error a caller would misread as corruption
 *   - a keystore holding only a private key "restores" into a wallet with no identity and no notes
 *   - a mistyped word is accepted, silently deriving the wrong keys for an empty wallet
 *   - the stripped metadata turns out to be load-bearing, so backups made today cannot be opened
 *     by a future ethers
 *
 * USAGE (from the repo root):
 *   cd frontend/identity-wallet && npm run build:pp
 *   node tools/check-recovery.js
 *
 * The flags live in frontend/identity-wallet/tsconfig.fixtures.json. They were spelled out here, and
 * in four other places, until the day pp/ moved to .ts-suffixed imports and all five went stale at
 * once - tsc emitted require("./notes.ts") and every generator died inside a file it had just built.
 *
 * recovery.ts is PURE - no expo-secure-store, no React Native - which is precisely what makes this
 * possible. If someone imports SecureStore into it, this script stops working and the only test
 * this code has disappears with it.
 */
const path = require('path');
const fs = require('fs');

const WALLET = path.join(__dirname, '..', 'frontend', 'identity-wallet');
const BUILD = path.join(WALLET, 'build', 'identity', 'recovery.js');

if (!fs.existsSync(BUILD)) {
  console.error(
    `No compiled recovery module at ${BUILD}.\n\n` +
    'cd frontend/identity-wallet && npm run build:pp\n',
  );
  process.exit(1);
}

const { createRequire } = require('module');
const walletRequire = createRequire(path.join(WALLET, 'package.json'));
const { HDNodeWallet, Mnemonic, Wallet } = walletRequire('ethers');
const recovery = require(BUILD);

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`  ok    ${name}`);
  } else {
    console.log(`  FAIL  ${name}${detail ? ` — ${detail}` : ''}`);
    failures++;
  }
}
async function throws(name, fn, expectedName) {
  try {
    await fn();
    check(name, false, 'did not throw');
  } catch (e) {
    check(name, e.name === expectedName, `threw ${e.name}, expected ${expectedName}: ${e.message}`);
  }
}

(async () => {
  // A FIXED phrase, not a random one: a generator bug that produced the same phrase every run would
  // still pass a random round-trip, and this file is the thing meant to catch that class of error.
  // 24 words, because that is what getOrCreateRootMnemonic emits (32 bytes of entropy).
  const PHRASE = Mnemonic.fromEntropy('0x' + '11'.repeat(32)).phrase;
  const PASSPHRASE = 'correct horse battery staple';

  console.log(`\nphrase under test: ${PHRASE.split(' ').length} words`);
  if (PHRASE.split(' ').length !== 24) {
    console.error('the test vector is not 24 words - the entropy width changed');
    process.exit(1);
  }

  console.log('\nround trip');
  const backup = await recovery.sealMnemonic(PHRASE, PASSPHRASE);
  const restored = await recovery.openBackup(backup, PASSPHRASE);
  check('the phrase comes back exactly', restored === PHRASE,
    `got ${restored.split(' ').length} words`);
  check('all 24 words survive', restored.split(' ').length === 24);

  console.log('\nthe backup names nobody');
  const parsed = JSON.parse(backup);
  const flat = JSON.stringify(parsed).toLowerCase();
  // The address for m/44'/60'/0'/0/0 IS Privacy Pool note account 0's address (src/pp/notes.ts).
  // Publishing it in the clear would link every copy of the backup to the user's note secrets.
  const ppAccount0 = HDNodeWallet.fromPhrase(PHRASE, '', "m/44'/60'/0'/0/0").address;
  check('no plaintext address field', parsed.address === undefined);
  check('the PP account-0 address does not appear anywhere',
    !flat.includes(ppAccount0.slice(2).toLowerCase()), ppAccount0);
  check('no gethFilename (address + creation time)',
    !(parsed['x-ethers'] || {}).gethFilename);
  check('no per-file id', parsed.id === undefined);
  check('the mnemonic ciphertext is present',
    !!(parsed['x-ethers'] || {}).mnemonicCiphertext);
  check('the KDF is scrypt', (parsed.Crypto || parsed.crypto || {}).kdf === 'scrypt');

  console.log('\nwrong passphrase');
  await throws('a wrong passphrase is rejected',
    () => recovery.openBackup(backup, 'not the passphrase'), 'InvalidMnemonicError');
  await throws('an empty passphrase is rejected',
    () => recovery.openBackup(backup, ''), 'InvalidMnemonicError');
  await throws('sealing with a short passphrase is refused',
    () => recovery.sealMnemonic(PHRASE, 'short'), 'WeakPassphraseError');

  console.log('\na private-key-only keystore is not a backup');
  // Decrypts perfectly and yields NO mnemonic. Accepting it would produce a working Ethereum wallet
  // with no identity and no notes - an empty wallet rather than an error.
  const keyOnly = await new Wallet(
    '0x' + '22'.repeat(32),
  ).encrypt(PASSPHRASE);
  await throws('rejected rather than restoring an empty wallet',
    () => recovery.openBackup(keyOnly, PASSPHRASE), 'InvalidMnemonicError');

  console.log('\nmistyped phrases');
  const words = PHRASE.split(' ');
  await throws('a misspelled word is rejected',
    () => recovery.sealMnemonic([...words.slice(0, 23), 'zzzz'].join(' '), PASSPHRASE),
    'InvalidMnemonicError');
  await throws('a dropped word is rejected',
    () => recovery.sealMnemonic(words.slice(0, 23).join(' '), PASSPHRASE), 'InvalidMnemonicError');
  await throws('an empty phrase is rejected',
    () => recovery.sealMnemonic('   ', PASSPHRASE), 'InvalidMnemonicError');
  // BIP39's checksum catches a wrong word; swapping two CORRECT words often survives it. Asserting
  // the real behaviour rather than a hoped-for one - the doc comment says so too.
  const swapped = [...words];
  [swapped[0], swapped[1]] = [swapped[1], swapped[0]];
  let swapAccepted = true;
  try { await recovery.sealMnemonic(swapped.join(' '), PASSPHRASE); } catch { swapAccepted = false; }
  console.log(`  note  a two-word swap is ${swapAccepted ? 'ACCEPTED' : 'rejected'} by the checksum` +
    ' — order must be verified by the user, not by us');

  console.log('\nnormalisation');
  const messy = `  ${PHRASE.toUpperCase().replace(/ /g, '   ')}  `;
  const fromMessy = await recovery.openBackup(
    await recovery.sealMnemonic(messy, PASSPHRASE), PASSPHRASE);
  check('extra whitespace and capitals are tolerated', fromMessy === PHRASE);

  console.log(
    failures === 0
      ? '\nOK - recovery round-trips, leaks no identifier, and rejects every bad input above\n'
      : `\n${failures} FAILED\n`,
  );
  process.exit(failures === 0 ? 0 : 1);
})().catch((e) => {
  console.error('\nunexpected failure:', e);
  process.exit(1);
});
