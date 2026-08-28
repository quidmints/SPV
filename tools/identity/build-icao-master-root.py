#!/usr/bin/env python3
"""Build `icaoMasterTreeMerkleRoot` from the real ICAO Master List (task 8).

  python3 tools/build-icao-master-root.py ~/Downloads/passport/ICAO_ML_20260721154956.ml

WHAT THIS IS. `StateKeeper.icaoMasterTreeMerkleRoot` is a keccak Merkle tree of **CSCA public keys**
(sec. 2.18l - and note that is the OWNER-ONLY tree; the permissionless `certificatesSmt` holds DSC
hashes one level below, and confusing the two is a mistake this repo has already made once).
`Registration2.registerCertificate` checks membership with
`icaoMerkleProof_.processProof(keccak256(icaoMember_.publicKey))`, and OpenZeppelin's `processProof`
hashes each pair in SORTED order - the same convention as the sanctions and notary anchors.

WHAT `publicKey` IS, read from the code rather than assumed: `CRSASigner.verifyICAOSignature` passes
`icaoMemberKey_` straight into `decrypt(signature, exponent, modulus)`, so for RSA it is the RAW
MODULUS with no ASN.1 wrapper and no leading zero byte. For EC it is the uncompressed point as it
appears in the SubjectPublicKeyInfo BIT STRING (0x04 || X || Y).

NEVER FAKE A ROOT (sec. 2.18k). This refuses to run on anything whose CMS signature does not verify,
because an unverified master list is the same failure wearing a different hat.
"""
import collections, pathlib, subprocess, sys, tempfile

KECCAK_JS = """
const {keccak256}=require('ethers');const fs=require('fs');
const leaves=[...new Set(fs.readFileSync(process.argv[1],'utf8').trim().split('\\n')
  .map(h=>keccak256('0x'+h)))].sort();
let lvl=leaves;
while(lvl.length>1){const nx=[];for(let i=0;i<lvl.length;i+=2){
  if(i+1===lvl.length){nx.push(lvl[i]);continue;}
  const [a,b]=lvl[i]<lvl[i+1]?[lvl[i],lvl[i+1]]:[lvl[i+1],lvl[i]];
  nx.push(keccak256('0x'+a.slice(2)+b.slice(2)));}
  lvl=nx;}
console.log(JSON.stringify({distinct:leaves.length,root:lvl[0]}));
"""

ROOT = pathlib.Path(__file__).resolve().parent.parent
WALLET = ROOT / "frontend/identity-wallet"   # carries ethers, so keccak256 is not hand-rolled


def der_tlv(buf, i):
    tag = buf[i]; i += 1
    length = buf[i]; i += 1
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(buf[i:i + n], "big"); i += n
    return tag, length, i


def der_children(buf, start, end):
    out = []
    while start < end:
        head = start
        tag, length, body = der_tlv(buf, start)
        out.append((tag, head, body, length))
        start = body + length
    return out


def der_oid(raw):
    parts = [raw[0] // 40, raw[0] % 40]; acc = 0
    for byte in raw[1:]:
        acc = (acc << 7) | (byte & 0x7F)
        if not byte & 0x80:
            parts.append(acc); acc = 0
    return ".".join(map(str, parts))


def extract_content(master_list: pathlib.Path, workdir: pathlib.Path) -> bytes:
    """CMS SignedData -> the CscaMasterList eContent. Refuses an unverifiable signature."""
    out = workdir / "content.der"
    result = subprocess.run(
        ["openssl", "cms", "-inform", "DER", "-in", str(master_list),
         "-verify", "-noverify", "-out", str(out)],
        capture_output=True, text=True)
    if result.returncode != 0 or not out.exists():
        raise SystemExit(f"CMS verification FAILED - refusing to build a root from it:\n{result.stderr}")
    print(f"  CMS signature verified ({out.stat().st_size:,} bytes of eContent)")
    return out.read_bytes()


def certificates(content: bytes) -> list[bytes]:
    """CscaMasterList ::= SEQUENCE { version INTEGER, certList SET OF Certificate }"""
    _, length, i = der_tlv(content, 0)
    _, ver_len, ver_body = der_tlv(content, i)          # version
    _, set_len, set_body = der_tlv(content, ver_body + ver_len)
    return [content[head:body + length]
            for _, head, body, length in der_children(content, set_body, set_body + set_len)]


def public_key_and_country(cert: bytes) -> tuple[str, bytes, str]:
    _, length, i = der_tlv(cert, 0)
    tbs = der_children(cert, i, i + length)[0]
    fields = der_children(cert, tbs[2], tbs[2] + tbs[3])
    base = 1 if fields[0][0] == 0xA0 else 0            # optional [0] version
    subject, spki = fields[base + 4], fields[base + 5]

    country = "??"
    for _, _, rdn_body, rdn_len in der_children(cert, subject[2], subject[2] + subject[3]):
        for _, _, atv_body, atv_len in der_children(cert, rdn_body, rdn_body + rdn_len):
            kids = der_children(cert, atv_body, atv_body + atv_len)
            if len(kids) == 2 and der_oid(cert[kids[0][2]:kids[0][2] + kids[0][3]]) == "2.5.4.6":
                country = cert[kids[1][2]:kids[1][2] + kids[1][3]].decode("latin1")

    algid, bitstring = der_children(cert, spki[2], spki[2] + spki[3])
    alg = der_oid(cert[der_children(cert, algid[2], algid[2] + algid[3])[0][2]:][:16])
    alg_kids = der_children(cert, algid[2], algid[2] + algid[3])
    alg = der_oid(cert[alg_kids[0][2]:alg_kids[0][2] + alg_kids[0][3]])
    raw = cert[bitstring[2] + 1:bitstring[2] + bitstring[3]]   # skip the unused-bits byte

    if alg == "1.2.840.113549.1.1.1":                  # rsaEncryption -> raw modulus
        _, seq_len, seq_body = der_tlv(raw, 0)
        modulus = der_children(raw, seq_body, seq_body + seq_len)[0]
        return "rsa", raw[modulus[2]:modulus[2] + modulus[3]].lstrip(b"\x00"), country
    return "ec", raw, country                          # 0x04 || X || Y


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__); return 2
    source = pathlib.Path(sys.argv[1]).expanduser()

    with tempfile.TemporaryDirectory() as tmp:
        workdir = pathlib.Path(tmp)
        certs = certificates(extract_content(source, workdir))
        keys, algs, countries = [], collections.Counter(), collections.Counter()
        for cert in certs:
            alg, key, country = public_key_and_country(cert)
            keys.append(key); algs[alg] += 1; countries[country] += 1

        print(f"  {len(certs)} CSCA certificates, {len(countries)} countries, "
              f"{algs['rsa']} RSA / {algs['ec']} EC")
        # Certificates outnumber keys because a CSCA rollover re-certifies the same key (link
        # certificates). Deduplicating is what makes the leaf set a set of KEYS, which is what
        # `keccak256(icaoMember_.publicKey)` looks up.
        print(f"  {len(set(keys))} distinct public keys ({len(certs) - len(set(keys))} shared by "
              f"link/rollover certificates)")

        hexfile = workdir / "keys.hex"
        hexfile.write_text("\n".join(k.hex() for k in keys))
        result = subprocess.run(["node", "-e", KECCAK_JS, str(hexfile)],
                                capture_output=True, text=True, cwd=WALLET)
        if result.returncode != 0:
            raise SystemExit(f"keccak/merkle step failed:\n{result.stderr}")
        import json
        out = json.loads(result.stdout)

    print(f"\n  icaoMasterTreeMerkleRoot = {out['root']}")
    print(f"  (over {out['distinct']} distinct keys, sorted, OpenZeppelin sorted-pair convention)")
    print("\n  Set it with StateKeeper.changeICAOMasterTreeRoot - OWNER ONLY, and see TODO sec. 4:")
    print("  ICAO's own terms require each entity to decide its OWN trust policy for these certs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
