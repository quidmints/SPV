// Run: node --test src/passport/mrzKey.test.ts   (Node 24 strips types natively - no jest, no deps)
//
// PINNED TO ICAO 9303 PART 11's OWN WORKED EXAMPLE, not to whatever this implementation happens to
// produce. That distinction is the whole value of the file: a self-consistent implementation that
// agrees with itself would pass a test written the other way round and still never open a chip.
import test from 'node:test';
import assert from 'node:assert';

import { checkDigit, mrzInformation } from './mrzKey.ts';

// The specimen from ICAO 9303 Part 11's BAC worked example. Document number L898902C, born
// 1969-08-06, expires 1994-06-23.
const DOC_NUMBER = 'L898902C';
const DATE_OF_BIRTH = '690806';
const DATE_OF_EXPIRY = '940623';

test('the check digits match the worked example', () => {
  // Each is independently reproducible by hand from the 7-3-1 weights, which is why they are
  // asserted separately rather than only via the concatenated string - a compensating pair of
  // errors inside one field would otherwise hide.
  assert.strictEqual(checkDigit('L898902C<'), 3);
  assert.strictEqual(checkDigit(DATE_OF_BIRTH), 1);
  assert.strictEqual(checkDigit(DATE_OF_EXPIRY), 6);
});

test('the MRZ information string matches the worked example exactly', () => {
  assert.strictEqual(
    mrzInformation(DOC_NUMBER, DATE_OF_BIRTH, DATE_OF_EXPIRY),
    'L898902C<369080619406236',
  );
});

/*
 * THE PADDING IS LOAD-BEARING, and getting it wrong is invisible.
 *
 * The MRZ document-number field is exactly nine characters; a shorter number is `<`-padded. Hashing
 * the unpadded number yields a different seed, a different BAC key, and a chip that simply refuses
 * mutual authentication - with no error saying why.
 */
test('a short document number is padded to nine characters before its check digit', () => {
  const padded = mrzInformation('L898902C', DATE_OF_BIRTH, DATE_OF_EXPIRY);
  const prePadded = mrzInformation('L898902C<', DATE_OF_BIRTH, DATE_OF_EXPIRY);
  assert.strictEqual(padded, prePadded, 'padding must be applied before the check digit');
});

test('the filler character counts as zero, not as an error', () => {
  assert.strictEqual(checkDigit('<<<<<<<<<'), 0);
});

test('letters are valued A=10 through Z=35', () => {
  // 'A' alone at weight 7 -> 70 -> check digit 0; 'B' -> 11*7 = 77 -> 7.
  assert.strictEqual(checkDigit('A'), 0);
  assert.strictEqual(checkDigit('B'), 7);
  assert.strictEqual(checkDigit('Z'), 5); // 35*7 = 245
});

/*
 * MALFORMED INPUT THROWS RATHER THAN COMPUTING A PLAUSIBLE-LOOKING KEY.
 *
 * A lowercase letter is the realistic case: an OCR or hand-entry path that does not upper-case its
 * output would otherwise produce a well-formed key over the wrong value, and the only symptom would
 * be a chip that never opens - indistinguishable from a bad antenna or an unsupported document.
 */
test('a lowercase character is rejected instead of silently mis-valued', () => {
  assert.throws(() => checkDigit('l898902c<'), /invalid MRZ character/);
});

test('a space is rejected - the MRZ filler is < and nothing else', () => {
  assert.throws(() => checkDigit('L898902C '), /invalid MRZ character/);
});

test('a document number too long for the simple form is refused, not truncated', () => {
  assert.throws(
    () => mrzInformation('L898902C1234', DATE_OF_BIRTH, DATE_OF_EXPIRY),
    /exceeds 9 characters/,
  );
});

test('a malformed date is refused rather than padded or trimmed', () => {
  assert.throws(() => mrzInformation(DOC_NUMBER, '69080', DATE_OF_EXPIRY), /YYMMDD/);
  assert.throws(() => mrzInformation(DOC_NUMBER, DATE_OF_BIRTH, '9406231'), /YYMMDD/);
});
