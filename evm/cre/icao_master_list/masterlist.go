// Pure ICAO Master List logic: verify ICAO's own signature, extract the CSCA keys, build the root.
//
// NO `//go:build wasip1` TAG, DELIBERATELY - same split as `sanctions_lists` and `notary_registry`,
// so every line below runs under `go test` on a host machine.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THIS IS THE FIRST SOURCE WHERE THE TRUSTED PUBLISHER GENUINELY DISAPPEARS (TODO sec. 2.18bv).
//
// The sanctions and notary registers are `authenticityTransportOnly`: nobody signs them, so DON
// consensus proves the nodes AGREED and never that they were RIGHT. sec. 2.18bv concluded that
// SOURCE-SIGNED data removes the publisher completely instead - the signature is bound to the DATA,
// not to a session, so anyone can verify it at any time from a cache, a mirror, or a hostile
// transport. That design sat blocked because sec. 2.18bw could not confirm any register we had
// actually signed its data.
//
// The ICAO Master List does. It is CMS SignedData, signed under `C=UN, O=United Nations,
// CN=United Nations CSCA`. So this workflow does not ask the DON to vouch for anything: it verifies
// ICAO's signature IN THE SANDBOX against a key pinned below, and consensus then runs over an
// already-verified result. A fabricated master list fails verification and cannot be published at
// all - which is prevention, not detection, and needs no postman, no committee and no owner key.
//
// IT ALSO NEEDS NO NEW CRE CAPABILITY. sec. 2.18bu found the `http` capability does not expose TLS,
// which blocks SELF-OBSERVED TLS - but TLS proves transport authenticity and we do not need it here.
// Fetch by any means; the signature is what is trusted.
// ═════════════════════════════════════════════════════════════════════════════════════════════
//
// WHY THE ASN.1 IS NOT DELEGATED TO A LIBRARY (standing rule 8 - evaluated 2026-08-03, not skipped).
// `go.mozilla.org/pkcs7` parses this file correctly - 2 embedded certificates, 876,231 bytes of
// content - but **`p7.Verify()` FAILS on the genuine ICAO master list with "Message has no
// signers"**, because it matches the SignerInfo to a certificate by issuer-and-serial and the
// signer's issuer DN differs AS BYTES from the CSCA's subject DN. That is the same name-encoding
// trap that makes DN-based chaining reject the real file. Nor can the library be used for the
// envelope alone: `AuthenticatedAttributes` has an UNEXPORTED element type, so it cannot return the
// raw attribute bytes the signature is actually computed over. Both were tried before this was
// written by hand.
//
// Nothing here touches the network, the CRE runtime, or a chain: stdlib plus keccak.
package main

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"errors"
	"fmt"
	"sort"

	gethcrypto "github.com/ethereum/go-ethereum/crypto"
)

// PinnedUnCscaSha256 identifies the trust anchor: SHA-256 of the UN CSCA's RSA modulus.
//
// WHY THE KEY AND NOT THE CERTIFICATE OR THE NAME, measured 2026-08-03:
//   - the Master List Signer is certified by this CSCA, verified BY SIGNATURE
//   - that CSCA appears TWICE in the master list (certificates 0368 and 0389) as a rollover pair
//     SHARING this key, so pinning a certificate would pin one arbitrary half of a pair
//   - and pinning the NAME is worse than useless: `signerCert.issuer` and `cscaCert.subject` differ
//     AS BYTES in the real file, so an implementation that chains by distinguished name REJECTS the
//     genuine ICAO master list. Chain by signature; treat the DN as a hint.
var PinnedUnCscaSha256 = [32]byte{
	0x19, 0xd4, 0x1f, 0x41, 0xfe, 0xea, 0xd4, 0x4d, 0x9f, 0x28, 0x28, 0xa9, 0x81, 0x1b, 0x28, 0x42,
	0xe4, 0xed, 0x31, 0x11, 0x3b, 0x0a, 0xa8, 0x0e, 0x58, 0x97, 0x84, 0x8e, 0x1d, 0xb2, 0xa1, 0xf4,
}

var (
	oidSignedData   = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 2}
	oidMessageDigst = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 9, 4}
)

type contentInfo struct {
	ContentType asn1.ObjectIdentifier
	Content     asn1.RawValue `asn1:"explicit,tag:0"`
}

type encapContentInfo struct {
	EContentType asn1.ObjectIdentifier
	EContent     asn1.RawValue `asn1:"explicit,optional,tag:0"`
}

type issuerAndSerial struct {
	Issuer       asn1.RawValue
	SerialNumber *asn1.RawValue
}

type signerInfo struct {
	Version            int
	SID                asn1.RawValue
	DigestAlgorithm    asn1.RawValue
	SignedAttrs        asn1.RawValue `asn1:"optional,tag:0"`
	SignatureAlgorithm asn1.RawValue
	Signature          []byte
	UnsignedAttrs      asn1.RawValue `asn1:"optional,tag:1"`
}

type signedData struct {
	Version          int
	DigestAlgorithms asn1.RawValue
	EncapContentInfo encapContentInfo
	Certificates     asn1.RawValue `asn1:"optional,tag:0"`
	CRLs             asn1.RawValue `asn1:"optional,tag:1"`
	SignerInfos      []signerInfo  `asn1:"set"`
}

// cscaMasterList is the eContent: SEQUENCE { version INTEGER, certList SET OF Certificate }.
type cscaMasterList struct {
	Version  int
	CertList []asn1.RawValue `asn1:"set"`
}

// MasterList is the verified result. It is only ever constructed by VerifyMasterList, so holding one
// is itself evidence that ICAO's signature checked out.
type MasterList struct {
	// Keys are the leaf preimages in certificate order, duplicates included - a rollover
	// certificate re-certifies an existing key, and MasterRoot is what deduplicates.
	Keys          [][]byte
	EContentHash  [32]byte
	SignerSubject string
}

// VerifyMasterList checks ICAO's signature and returns the CSCA set. It refuses everything it cannot
// prove: an unverifiable signature, a signer that does not chain to the pinned CSCA, or a digest
// that does not match the content. "Never fake a root" (sec. 2.18k) is enforced here rather than
// left to the caller.
func VerifyMasterList(der []byte, pinned [32]byte) (*MasterList, error) {
	var ci contentInfo
	if _, err := asn1.Unmarshal(der, &ci); err != nil {
		return nil, fmt.Errorf("not a CMS ContentInfo: %w", err)
	}
	if !ci.ContentType.Equal(oidSignedData) {
		return nil, fmt.Errorf("content type is %v, not SignedData", ci.ContentType)
	}

	var sd signedData
	if _, err := asn1.Unmarshal(ci.Content.Bytes, &sd); err != nil {
		return nil, fmt.Errorf("malformed SignedData: %w", err)
	}
	if len(sd.SignerInfos) != 1 {
		return nil, fmt.Errorf("expected exactly one signer, found %d", len(sd.SignerInfos))
	}
	si := sd.SignerInfos[0]

	certs, err := x509.ParseCertificates(sd.Certificates.Bytes)
	if err != nil {
		return nil, fmt.Errorf("embedded certificates: %w", err)
	}

	signer, err := signerAndAnchor(certs, pinned)
	if err != nil {
		return nil, err
	}

	// THE SIGNATURE IS OVER THE DER *SET OF* ENCODING (RFC 5652 5.4): the transmitted [0] IMPLICIT
	// tag must be replaced by SET before hashing. Getting this wrong fails every genuine list, which
	// is exactly the kind of silent-looking mismatch this project keeps meeting.
	if len(si.SignedAttrs.FullBytes) == 0 {
		return nil, errors.New("no signed attributes - the digest could not be bound to the content")
	}
	toVerify := append([]byte{0x31}, si.SignedAttrs.FullBytes[1:]...)

	pub, ok := signer.PublicKey.(*rsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("signer key is %T, expected RSA", signer.PublicKey)
	}
	sum := sha256.Sum256(toVerify)
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], si.Signature); err != nil {
		return nil, fmt.Errorf("ICAO signature does not verify: %w", err)
	}

	// UNWRAP ONE MORE LAYER. `EContent` is `[0] EXPLICIT OCTET STRING`, so RawValue.Bytes still
	// holds the OCTET STRING's own TLV - the content sits inside it. Skipping this compares the
	// digest against a wrapper and fails on every genuine list, which is how this was caught.
	var eContent []byte
	if _, err := asn1.Unmarshal(sd.EncapContentInfo.EContent.Bytes, &eContent); err != nil {
		return nil, fmt.Errorf("eContent is not an OCTET STRING: %w", err)
	}
	digest, err := messageDigestAttr(si.SignedAttrs.Bytes)
	if err != nil {
		return nil, err
	}
	actual := sha256.Sum256(eContent)
	if !bytes.Equal(digest, actual[:]) {
		return nil, errors.New("messageDigest does not match the content it claims to cover")
	}

	var ml cscaMasterList
	if _, err := asn1.Unmarshal(eContent, &ml); err != nil {
		return nil, fmt.Errorf("malformed CscaMasterList: %w", err)
	}

	out := &MasterList{EContentHash: actual, SignerSubject: signer.Subject.String()}
	for _, raw := range ml.CertList {
		// NOT `x509.ParseCertificate`. Go's standard library REJECTS the real ICAO master list with
		// "x509: invalid ECDSA parameters", because member states use BRAINPOOL curves that the
		// stdlib does not implement (measured: 129-byte keys, i.e. brainpool P-512). Anything built
		// on stdlib x509 either errors here or, worse, silently drops those states' certificates and
		// anchors a root missing them. We need the raw key bytes, not a policy-validated chain, so
		// the SubjectPublicKeyInfo is read directly.
		key, err := rawSubjectPublicKey(raw.FullBytes)
		if err != nil {
			return nil, fmt.Errorf("CSCA certificate %d: %w", len(out.Keys), err)
		}
		out.Keys = append(out.Keys, key)
	}
	return out, nil
}

// rawSubjectPublicKey walks a certificate's DER to its SubjectPublicKeyInfo and returns exactly what
// `keccak256(icaoMember_.publicKey)` hashes on-chain: the RSA modulus (minimal, no leading zero) or
// the uncompressed EC point. It deliberately validates nothing else - this is key extraction, not
// certificate validation, and the ICAO signature over the whole list is what vouches for the entry.
func rawSubjectPublicKey(der []byte) ([]byte, error) {
	var cert struct {
		TBS struct {
			Version      asn1.RawValue `asn1:"optional,explicit,tag:0"`
			SerialNumber asn1.RawValue
			SigAlg       asn1.RawValue
			Issuer       asn1.RawValue
			Validity     asn1.RawValue
			Subject      asn1.RawValue
			SPKI         struct {
				Algorithm asn1.RawValue
				PublicKey asn1.BitString
			}
			Rest asn1.RawValue `asn1:"optional,any"`
		}
		SigAlg    asn1.RawValue
		Signature asn1.BitString
	}
	if _, err := asn1.Unmarshal(der, &cert); err != nil {
		return nil, fmt.Errorf("malformed certificate: %w", err)
	}
	bits := cert.TBS.SPKI.PublicKey.RightAlign()

	var rsaKey struct{ N, E asn1.RawValue }
	if _, err := asn1.Unmarshal(bits, &rsaKey); err == nil && rsaKey.N.Tag == asn1.TagInteger {
		return bytes.TrimLeft(rsaKey.N.Bytes, "\x00"), nil
	}
	return bits, nil // EC: the uncompressed point as published
}

// signerAndAnchor finds the Master List Signer and the pinned CSCA that certifies it, CHAINING BY
// SIGNATURE rather than by name - see PinnedUnCscaSha256 for why the name cannot be used.
func signerAndAnchor(certs []*x509.Certificate, pinned [32]byte) (*x509.Certificate, error) {
	var anchor *x509.Certificate
	for _, candidate := range certs {
		key, kerr := leafPreimage(candidate)
		if kerr != nil {
			continue
		}
		if sha256.Sum256(key) == pinned {
			anchor = candidate
			break
		}
	}
	if anchor == nil {
		return nil, errors.New("the pinned UN CSCA is not among the embedded certificates")
	}
	for _, candidate := range certs {
		if candidate.Equal(anchor) {
			continue
		}
		if err := candidate.CheckSignatureFrom(anchor); err == nil {
			return candidate, nil
		}
	}
	return nil, errors.New("no embedded certificate is signed by the pinned UN CSCA")
}

func messageDigestAttr(attrs []byte) ([]byte, error) {
	rest := attrs
	for len(rest) > 0 {
		var attr struct {
			Type   asn1.ObjectIdentifier
			Values []asn1.RawValue `asn1:"set"`
		}
		var err error
		rest, err = asn1.Unmarshal(rest, &attr)
		if err != nil {
			return nil, fmt.Errorf("malformed signed attribute: %w", err)
		}
		if attr.Type.Equal(oidMessageDigst) && len(attr.Values) == 1 {
			var digest []byte
			if _, err := asn1.Unmarshal(attr.Values[0].FullBytes, &digest); err != nil {
				return nil, fmt.Errorf("malformed messageDigest: %w", err)
			}
			return digest, nil
		}
	}
	return nil, errors.New("no messageDigest attribute")
}

// leafPreimage is exactly what `keccak256(icaoMember_.publicKey)` hashes on-chain, read out of
// `CRSASigner.verifyICAOSignature` rather than guessed: it feeds the key straight into
// `decrypt(signature, exponent, modulus)`, so RSA leaves are the RAW MODULUS - no ASN.1 wrapper and
// no leading zero. EC leaves are the uncompressed point as it appears in the SubjectPublicKeyInfo.
func leafPreimage(cert *x509.Certificate) ([]byte, error) {
	switch pub := cert.PublicKey.(type) {
	case *rsa.PublicKey:
		return pub.N.Bytes(), nil // big.Int.Bytes() is already minimal-length, big-endian
	case *ecdsa.PublicKey:
		// The uncompressed point (0x04 || X || Y), which is what sits in the SubjectPublicKeyInfo
		// BIT STRING - measured against the real list: lengths come out at exactly 65/97/129/133
		// bytes for P-256, P-384, brainpool-512 and P-521.
		return elliptic.Marshal(pub.Curve, pub.X, pub.Y), nil
	default:
		return nil, fmt.Errorf("unsupported CSCA key type %T", pub)
	}
}

// MasterRoot is the OpenZeppelin-compatible keccak tree `Registration2.registerCertificate` checks
// with `processProof`: leaves DEDUPLICATED and SORTED, each internal node hashing its children in
// sorted order.
//
// DEDUPLICATION IS NOT TIDINESS. A CSCA rollover re-certifies an existing key, so the list holds
// more certificates than keys (measured: 581 certificates, 391 distinct keys). The tree is keyed on
// what the contract looks up - the KEY - so duplicates would be equal neighbours, which is not
// strict ascent.
func MasterRoot(keys [][]byte) ([32]byte, error) {
	if len(keys) == 0 {
		return [32]byte{}, errors.New("no keys")
	}
	seen := map[[32]byte]struct{}{}
	var leaves [][32]byte
	for _, k := range keys {
		leaf := keccak(k)
		if _, dup := seen[leaf]; dup {
			continue
		}
		seen[leaf] = struct{}{}
		leaves = append(leaves, leaf)
	}
	sort.Slice(leaves, func(i, j int) bool { return bytes.Compare(leaves[i][:], leaves[j][:]) < 0 })

	level := leaves
	for len(level) > 1 {
		next := make([][32]byte, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 == len(level) {
				next = append(next, level[i]) // odd one out, promoted unchanged
				continue
			}
			next = append(next, hashSortedPair(level[i], level[i+1]))
		}
		level = next
	}
	return level[0], nil
}

func keccak(b []byte) (out [32]byte) {
	return gethcrypto.Keccak256Hash(b)
}

func hashSortedPair(a, b [32]byte) [32]byte {
	if bytes.Compare(b[:], a[:]) < 0 {
		a, b = b, a
	}
	return gethcrypto.Keccak256Hash(a[:], b[:])
}
