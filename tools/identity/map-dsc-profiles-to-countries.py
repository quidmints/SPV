#!/usr/bin/env python3
"""Map ICAO PKD Document Signer Certificates to (country, signature algorithm, key, hash).

WHY: a passport's SOD is signed by that country's DSC, so the DSC's signature algorithm and digest
ARE the circuit profile (SIG_TYPE + HASH_ALGO). The PKD LDIF therefore answers "which countries issue
documents matching profile X" - which nothing in the ibiza repo can.

Minimal DER walk rather than a cert library: 31k certificates is too many to shell out per-cert, and
we need only two fields - the outer signatureAlgorithm and subjectPublicKeyInfo.
"""
import base64, collections, sys

LDIF = sys.argv[1] if len(sys.argv) > 1 else "/Users/ricktobacco/Downloads/passport/icaopkd-001-complete-10245.ldif"

OIDS = {
    "1.2.840.113549.1.1.5":  ("RSA-PKCS1", "SHA-1"),
    "1.2.840.113549.1.1.11": ("RSA-PKCS1", "SHA-256"),
    "1.2.840.113549.1.1.12": ("RSA-PKCS1", "SHA-384"),
    "1.2.840.113549.1.1.13": ("RSA-PKCS1", "SHA-512"),
    "1.2.840.113549.1.1.14": ("RSA-PKCS1", "SHA-224"),
    "1.2.840.113549.1.1.10": ("RSA-PSS",   "?"),
    "1.2.840.10045.4.1":     ("ECDSA",     "SHA-1"),
    "1.2.840.10045.4.3.1":   ("ECDSA",     "SHA-224"),
    "1.2.840.10045.4.3.2":   ("ECDSA",     "SHA-256"),
    "1.2.840.10045.4.3.3":   ("ECDSA",     "SHA-384"),
    "1.2.840.10045.4.3.4":   ("ECDSA",     "SHA-512"),
}
HASH_OID = {
    "1.3.14.3.2.26": "SHA-1", "2.16.840.1.101.3.4.2.1": "SHA-256",
    "2.16.840.1.101.3.4.2.2": "SHA-384", "2.16.840.1.101.3.4.2.3": "SHA-512",
    "2.16.840.1.101.3.4.2.4": "SHA-224",
}
CURVES = {
    "1.2.840.10045.3.1.7": "secp256r1", "1.3.132.0.34": "secp384r1", "1.3.132.0.35": "secp521r1",
    "1.3.36.3.3.2.8.1.1.7": "brainpoolP256r1", "1.3.36.3.3.2.8.1.1.11": "brainpoolP384r1",
    "1.3.36.3.3.2.8.1.1.13": "brainpoolP512r1", "1.3.132.0.10": "secp256k1",
}


def oid_str(b):
    if not b: return ""
    out = [str(b[0] // 40), str(b[0] % 40)]
    v = 0
    for x in b[1:]:
        v = (v << 7) | (x & 0x7F)
        if not x & 0x80:
            out.append(str(v)); v = 0
    return ".".join(out)


def tlv(buf, i):
    """Return (tag, content_start, content_len, next_index)."""
    tag = buf[i]; i += 1
    n = buf[i]; i += 1
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(buf[i:i + k], "big"); i += k
    return tag, i, n, i + n


def children(buf, start, length):
    i, end = start, start + length
    while i < end:
        t, cs, cl, nxt = tlv(buf, i)
        yield t, cs, cl
        i = nxt


def parse(der):
    """-> (sig_alg_oid, key_alg_oid, key_bits, rsa_exponent, curve_oid, pss_hash_oid)"""
    _, cs, cl, _ = tlv(der, 0)                      # Certificate SEQUENCE
    kids = list(children(der, cs, cl))
    tbs_t, tbs_s, tbs_l = kids[0]
    sig_t, sig_s, sig_l = kids[1]                   # signatureAlgorithm
    sig_oid = ""; pss_hash = ""
    for t, s, l in children(der, sig_s, sig_l):
        if t == 0x06 and not sig_oid:
            sig_oid = oid_str(der[s:s + l])
        elif t == 0x30 and sig_oid.endswith("1.1.10"):
            # RSASSA-PSS-params ::= SEQUENCE { [0] hashAlgorithm, [1] maskGenAlgorithm, ... }
            # ⚠️ THE DIGEST IS NOT IN THE SIGNATURE OID FOR PSS. Reading only the OID reported every
            # PSS certificate with an unknown hash - 3,011 of 31,397 here, about 10% of the PKD, and
            # enough to make Canada look entirely unsupported when it is not.
            for t2, s2, l2 in children(der, s, l):
                if t2 == 0xA0:
                    for t3, s3, l3 in children(der, s2, l2):
                        if t3 == 0x30:
                            for t4, s4, l4 in children(der, s3, l3):
                                if t4 == 0x06 and not pss_hash:
                                    pss_hash = oid_str(der[s4:s4 + l4])
                    break

    key_oid = curve = ""; bits = 0; exp = 0
    tk = list(children(der, tbs_s, tbs_l))
    # subjectPublicKeyInfo is the SEQUENCE right before the optional [1]/[2]/[3] tagged items
    spki = None
    for t, s, l in tk:
        if t == 0x30:
            sub = list(children(der, s, l))
            if len(sub) == 2 and sub[0][0] == 0x30 and sub[1][0] == 0x03:
                spki = (s, l)
    if spki:
        algseq, bitstr = list(children(der, spki[0], spki[1]))
        # The curve is EITHER a named OID or a full ECParameters SEQUENCE (explicit parameters).
        # Only handling the OID form left every explicit-parameter certificate with no curve at all,
        # which is most of the ECDSA ones here.
        for t, s, l in children(der, algseq[1], algseq[2]):
            if t == 0x06:
                if not key_oid: key_oid = oid_str(der[s:s + l])
                else: curve = oid_str(der[s:s + l])
            elif t == 0x30 and key_oid:
                # ECParameters ::= SEQUENCE { version, fieldID SEQUENCE { OID, prime INTEGER }, ... }
                for t2, s2, l2 in children(der, s, l):
                    if t2 == 0x30:
                        for t3, s3, l3 in children(der, s2, l2):
                            if t3 == 0x02 and l3 >= 24:
                                curve = "p:" + der[s3:s3 + l3].lstrip(b"\x00").hex()[:16]
                        break
        bs, bl = bitstr[1], bitstr[2]
        inner = der[bs + 1: bs + bl]                # skip unused-bits octet
        if key_oid == "1.2.840.113549.1.1.1":       # RSA
            try:
                _, ms, ml, _ = tlv(inner, 0)
                mods = list(children(inner, ms, ml))
                mt, mstart, mlen = mods[0]
                bits = (mlen - (1 if inner[mstart] == 0 else 0)) * 8
                et, es, el = mods[1]
                exp = int.from_bytes(inner[es:es + el], "big")
            except Exception:
                pass
        else:
            bits = (len(inner) - 1) * 4             # uncompressed point -> field bits
    return sig_oid, key_oid, bits, exp, curve, pss_hash


def unfold(path):
    """LDIF folds ANY long line with a leading space, not just certificates. Folding only the
    certificate truncated every long `dn:` before its trailing `c=XX`, which is why a third of the
    entries reported country '??' - including every SHA-1 one."""
    cur = None
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith(" ") and cur is not None:
                cur += line[1:]; continue
            if cur is not None: yield cur
            cur = line
    if cur is not None: yield cur


def entries(path):
    dn = None; cert = None
    for line in unfold(path):
        if line.startswith("dn: "): dn = line[4:]
        elif line.startswith("dn:: "): dn = line[5:]
        elif line.startswith("userCertificate;binary:: "):
            cert = line[len("userCertificate;binary:: "):]
            if dn: yield dn, cert
            cert = None


def country(dn):
    # The AUTHORITATIVE country is the trailing `c=XX` of the DN tree, not any `c=` embedded in a
    # quoted cn. Scan from the right and take the first two-letter one.
    for part in reversed(dn.split(",")):
        p = part.strip()
        if p.lower().startswith("c=") and len(p) == 4 and p[2:].isalpha():
            return p[2:].upper()
    return "??"


def main():
    combos = collections.defaultdict(collections.Counter)
    n = bad = 0
    for dn, b64 in entries(LDIF):
        if not dn or "o=dsc" not in dn.lower(): continue
        try:
            der = base64.b64decode(b64)
            sig, key, bits, exp, curve, pss_hash = parse(der)
        except Exception:
            bad += 1; continue
        n += 1
        alg, digest = OIDS.get(sig, (sig, "?"))
        if alg == "ECDSA":
            desc = f"ECDSA {CURVES.get(curve, curve or '?')} / {digest}"
        elif alg == "RSA-PSS":
            desc = f"{alg}-{bits} e={exp} / {HASH_OID.get(pss_hash, digest)}"
        elif alg.startswith("RSA"):
            desc = f"{alg}-{bits} e={exp} / {digest}"
        else:
            desc = f"{alg} / {digest}"
        combos[desc][country(dn)] += 1
    print(f"parsed {n} DSCs ({bad} unparseable)\n")
    for desc, ctr in sorted(combos.items(), key=lambda kv: -sum(kv[1].values())):
        tot = sum(ctr.values())
        top = ", ".join(f"{c}({k})" for c, k in ctr.most_common(12))
        print(f"{tot:>6}  {desc}")
        print(f"        {top}")


if __name__ == "__main__":
    main()
