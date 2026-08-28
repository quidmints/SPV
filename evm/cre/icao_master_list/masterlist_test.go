// Tests for in-sandbox verification of ICAO's Master List signature.
//
// THESE RUN AGAINST THE REAL PUBLISHED FILE, not a fixture, because the whole claim is about a
// specific real artifact: that ICAO signs its master list and that we can check that signature
// ourselves. A synthetic CMS blob would test the parser and prove nothing about the claim.
//
//	ICAO_MASTER_LIST=~/Downloads/passport/ICAO_ML_20260721154956.ml go test ./...
//
// The expected values below were measured from the 2026-07-21 issue. ICAO reissues quarterly, so a
// later file legitimately has different counts - the tests assert SHAPE (a verifying signature, a
// signer chaining to the pinned CSCA, plausible coverage) and pin only what must not drift.
package main

import (
	"encoding/hex"
	"os"
	"strings"
	"testing"
)

func masterList(t *testing.T) []byte {
	t.Helper()
	path := os.Getenv("ICAO_MASTER_LIST")
	if path == "" {
		t.Skip("ICAO_MASTER_LIST not set - skipping (the real file is not committed; it is 880 KB)")
	}
	der, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read master list: %v", err)
	}
	return der
}

// THE CLAIM: we verify ICAO's own signature, with no help from a DON, a postman or an owner key.
func TestIcaosSignatureVerifiesAgainstThePinnedUnCsca(t *testing.T) {
	ml, err := VerifyMasterList(masterList(t), PinnedUnCscaSha256)
	if err != nil {
		t.Fatalf("the published ICAO master list did not verify: %v", err)
	}
	if !strings.Contains(ml.SignerSubject, "Master List") {
		t.Fatalf("signer is not the Master List Signer: %q", ml.SignerSubject)
	}
	if len(ml.Keys) < 400 {
		t.Fatalf("only %d CSCA certificates - the list looks truncated", len(ml.Keys))
	}
	t.Logf("verified: %d CSCA certificates, signer %q", len(ml.Keys), ml.SignerSubject)
}

// AND IT IS NOT VACUOUS. A different anchor must fail: otherwise "signed by ICAO" would mean
// "signed by anybody", which is precisely the property the pin exists to provide.
func TestAnotherAnchorIsRejected(t *testing.T) {
	wrong := PinnedUnCscaSha256
	wrong[0] ^= 0x01

	if _, err := VerifyMasterList(masterList(t), wrong); err == nil {
		t.Fatal("a master list verified against an anchor that is not the UN CSCA")
	}
}

// Tampering the CONTENT must fail even though the signature bytes are untouched - that is what
// binding the digest into the signed attributes buys.
func TestATamperedMasterListIsRejected(t *testing.T) {
	der := masterList(t)
	tampered := make([]byte, len(der))
	copy(tampered, der)
	tampered[len(tampered)/2] ^= 0x01

	if _, err := VerifyMasterList(tampered, PinnedUnCscaSha256); err == nil {
		t.Fatal("a modified master list verified")
	}
}

// The root must match what the Solidity side computes; this is the same value
// `tools/build-icao-master-root.py` produces and what `changeICAOMasterTreeRoot` would receive.
func TestTheRootMatchesTheIndependentlyComputedOne(t *testing.T) {
	ml, err := VerifyMasterList(masterList(t), PinnedUnCscaSha256)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	root, err := MasterRoot(ml.Keys)
	if err != nil {
		t.Fatalf("root: %v", err)
	}
	got := hex.EncodeToString(root[:])

	// Measured from the 2026-07-21 issue by an INDEPENDENT implementation (Python + ethers), so
	// agreement here is two toolchains agreeing rather than this code agreeing with itself.
	const expected = "63e9022d5269f33b8d2d0a56cbef49584f94ac3e5753176cce03c13ec3826072"
	if got != expected {
		t.Fatalf("root mismatch\n  go:     %s\n  python: %s\n(a different quarterly issue "+
			"legitimately differs - check the file date before assuming a bug)", got, expected)
	}
	t.Logf("root %s over %d keys", got, len(ml.Keys))
}

// Deduplication is load-bearing: rollover certificates re-certify an existing key, so the tree must
// be keyed on KEYS. Measured on the real list: 581 certificates, 391 distinct keys.
func TestRolloverCertificatesShareKeysAndAreDeduplicated(t *testing.T) {
	ml, err := VerifyMasterList(masterList(t), PinnedUnCscaSha256)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	distinct := map[string]struct{}{}
	for _, k := range ml.Keys {
		distinct[string(k)] = struct{}{}
	}
	if len(distinct) >= len(ml.Keys) {
		t.Fatalf("expected shared keys from rollover certificates; %d keys, %d distinct",
			len(ml.Keys), len(distinct))
	}
	t.Logf("%d certificates carry %d distinct keys", len(ml.Keys), len(distinct))
}
