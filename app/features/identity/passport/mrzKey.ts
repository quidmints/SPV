// BAC key derivation from the MRZ - ICAO 9303 Part 11.
//
// WHY THIS EXISTS NOW, BEFORE THERE IS A SCANNER (sec. 2.18aq). A passport chip will not talk to you
// until you prove you can read the printed page: the Basic Access Control key is derived from the
// document number, date of birth and expiry date, all taken from the MRZ. Every scanner needs this,
// and it is PURE - no NFC, no device, no native module. So it can be written and fully verified
// today, and when a phone and a passport do arrive, this piece is already known-good rather than
// being debugged at the same time as the radio.
//
// IT IS ALSO THE PART THAT FAILS SILENTLY. A wrong key does not error; the chip simply refuses
// mutual authentication, and the failure surfaces as "scanning didn't work" with nothing to
// distinguish a bad key from a bad antenna, a bad read or an unsupported document. Pinning it to the
// spec's own worked example means that ambiguity is resolved before anyone is holding a passport.
//
// PACE IS NOT IMPLEMENTED HERE. Modern documents prefer PACE, and some newer ones refuse BAC
// outright. BAC is what the ICAO worked example covers and what every scanner falls back to; PACE
// needs its own vectors and is deliberately out of scope for this file rather than half-done.

/// ICAO 9303 check-digit weights, applied cyclically.
const WEIGHTS = [7, 3, 1];

/**
 * Character value per ICAO 9303: digits are themselves, A-Z are 10-35, and the filler `<` is 0.
 *
 * ANYTHING ELSE THROWS rather than being coerced to 0. A lowercase letter or a stray space would
 * otherwise silently compute a valid-looking check digit over the wrong value, and the only symptom
 * would be a chip that never opens.
 */
function charValue(c: string): number {
  if (c >= '0' && c <= '9') return c.charCodeAt(0) - 48;
  if (c >= 'A' && c <= 'Z') return c.charCodeAt(0) - 55;
  if (c === '<') return 0;
  throw new Error(`invalid MRZ character ${JSON.stringify(c)} - expected 0-9, A-Z or <`);
}

/// The ICAO 9303 check digit over an MRZ field.
export function checkDigit(field: string): number {
  let sum = 0;
  for (let i = 0; i < field.length; i++) {
    sum += charValue(field[i]) * WEIGHTS[i % 3];
  }
  return sum % 10;
}

/**
 * The "MRZ information" string the BAC seed is hashed from: each of the three fields followed by its
 * own check digit.
 *
 * @param documentNumber as printed, `<`-padded to 9 characters
 * @param dateOfBirth    YYMMDD
 * @param dateOfExpiry   YYMMDD
 *
 * THE PADDING IS LOAD-BEARING. The document number field is exactly 9 characters in the MRZ and
 * short numbers are `<`-padded; hashing an unpadded number produces a different key, and the chip
 * just refuses. Padding is applied here so a caller cannot forget.
 */
export function mrzInformation(
  documentNumber: string,
  dateOfBirth: string,
  dateOfExpiry: string,
): string {
  if (documentNumber.length > 9) {
    // Documents with longer numbers encode the overflow in the optional-data field, which this
    // simple form does not handle. Throwing beats producing a key that silently never works.
    throw new Error(
      `document number ${JSON.stringify(documentNumber)} exceeds 9 characters - the extended form ` +
        '(overflow in optional data) is not implemented',
    );
  }
  if (dateOfBirth.length !== 6 || dateOfExpiry.length !== 6) {
    throw new Error('dates must be YYMMDD (6 characters)');
  }

  const paddedNumber = documentNumber.padEnd(9, '<');
  return (
    paddedNumber +
    checkDigit(paddedNumber) +
    dateOfBirth +
    checkDigit(dateOfBirth) +
    dateOfExpiry +
    checkDigit(dateOfExpiry)
  );
}
