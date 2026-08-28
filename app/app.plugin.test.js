// Tests for the NFC config plugin (sec. 2.18ap).
//
// Run with `node --test` - no jest, no new dependency. The transforms are pure functions over plain
// objects, so they can be asserted on any machine; what they CANNOT prove is that the generated
// native project builds, which needs an Xcode/Android toolchain this repo has never had (see
// app.plugin.js's own note that the Gradle change "has never been fed to Gradle").
//
// WHY BOTHER TESTING CONFIG. Because every one of these keys fails at RUNTIME on a device rather
// than at build time: a missing entitlement compiles, installs, launches, and then throws when a
// reader session starts. A typo in a reverse-DNS key name is invisible until someone is standing
// there with a passport.
const test = require('node:test');
const assert = require('node:assert');

const plugin = require('./app.plugin.js');
const { addNfcEntitlements, addNfcInfoPlist, addNfcFeature, EMRTD_AID } = plugin;

test('the entitlement requests TAG format, which is what an eMRTD needs', () => {
  const out = addNfcEntitlements({});
  assert.deepStrictEqual(out['com.apple.developer.nfc.readersession.formats'], ['TAG']);
});

test('NDEF alone would not do - a passport chip is not an NDEF tag', () => {
  // Simulate another plugin having asked for NDEF first; TAG must be ADDED, not replace it.
  const out = addNfcEntitlements({
    'com.apple.developer.nfc.readersession.formats': ['NDEF'],
  });
  assert.ok(out['com.apple.developer.nfc.readersession.formats'].includes('NDEF'));
  assert.ok(out['com.apple.developer.nfc.readersession.formats'].includes('TAG'));
});

test('applying twice does not duplicate the format', () => {
  const once = addNfcEntitlements({});
  const twice = addNfcEntitlements(once);
  assert.deepStrictEqual(twice['com.apple.developer.nfc.readersession.formats'], ['TAG']);
});

test('the eMRTD AID is declared, or the chip cannot be selected at all', () => {
  const out = addNfcInfoPlist({});
  assert.deepStrictEqual(
    out['com.apple.developer.nfc.readersession.iso7816.select-identifiers'],
    [EMRTD_AID]
  );
  // The ICAO 9303 LDS1 application identifier. Pinned as a literal so a typo in the constant is a
  // failing test rather than a silent "no chip found" on a real passport.
  assert.strictEqual(EMRTD_AID, 'A0000002471001');
});

test('a usage description is present - iOS refuses the reader session without one', () => {
  const out = addNfcInfoPlist({});
  assert.ok(
    typeof out.NFCReaderUsageDescription === 'string' && out.NFCReaderUsageDescription.length > 0
  );
});

test("an existing usage description is not overwritten", () => {
  const out = addNfcInfoPlist({ NFCReaderUsageDescription: 'set by the app author' });
  assert.strictEqual(out.NFCReaderUsageDescription, 'set by the app author');
});

test('applying the Info.plist transform twice does not duplicate the AID', () => {
  const twice = addNfcInfoPlist(addNfcInfoPlist({}));
  assert.deepStrictEqual(
    twice['com.apple.developer.nfc.readersession.iso7816.select-identifiers'],
    [EMRTD_AID]
  );
});

test('the Android NFC feature is declared as NOT required', () => {
  const out = addNfcFeature({ manifest: {} });
  const feature = out.manifest['uses-feature'].find(
    (f) => f.$['android:name'] === 'android.hardware.nfc'
  );
  assert.ok(feature, 'the nfc feature was not declared');
  // required=true would stop the app installing on devices with no NFC radio - and someone who
  // restored from backup can still hold notes and withdraw without ever reading a document.
  assert.strictEqual(feature.$['android:required'], 'false');
});

test('applying the Android transform twice does not duplicate the feature', () => {
  const out = addNfcFeature(addNfcFeature({ manifest: {} }));
  const matches = out.manifest['uses-feature'].filter(
    (f) => f.$['android:name'] === 'android.hardware.nfc'
  );
  assert.strictEqual(matches.length, 1);
});

test('an unrelated existing uses-feature entry survives', () => {
  const out = addNfcFeature({
    manifest: { 'uses-feature': [{ $: { 'android:name': 'android.hardware.camera' } }] },
  });
  assert.strictEqual(out.manifest['uses-feature'].length, 2);
});

// The plugin's default export must stay a function, or `expo prebuild` fails with an error that
// does not name this file.
test('the plugin default export is still a config plugin function', () => {
  assert.strictEqual(typeof plugin, 'function');
});
