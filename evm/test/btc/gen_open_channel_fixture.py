#!/usr/bin/env python3
"""Generate a REAL openChannel fixture from a live bitcoind regtest node.

No custom Bitcoin crypto in the protocol: bitcoind builds + confirms the funding
tx and we shape its data (witness-stripped legacy tx, merkle branch, headers)
into exactly what BTCChannels.openChannel / SPVGateway verify. The merkle branch
is recomputed here ONLY to self-check that it folds to the block's real
merkleroot before we ever feed it to Solidity (hashlib, not custom Rust).

Run it via `regtest/gen-fixture.sh`, which sources regtest/env.sh and passes
BTC_CLI/DATADIR/WALLET for the pinned node — so the bitcoin-core version lives in
exactly ONE place (env.sh `BITCOIN_VERSION`) and is never spelled out here.
Standalone (regtest bitcoind already up):
    BTC_CLI=/path/to/bitcoin-cli DATADIR=/path/to/datadir \
      python3 gen_open_channel_fixture.py > open_channel_fixture.json
"""
import hashlib, json, os, subprocess
from decimal import Decimal

CLI = os.environ.get("BTC_CLI", "bitcoin-cli")   # harness always sets it; PATH fallback
DD = os.environ.get("DATADIR", "/tmp/btcreg")
WALLET = os.environ.get("WALLET", "")  # optional -rpcwallet (regtest harness sets it)
AMOUNT_SATS = 20_000_000   # 0.2 BTC — matches the `_openHopChannel(..., 2e7)` call sites   # 0.05 BTC channel


def cli(*args):
    cmd = [CLI, f"-datadir={DD}"]
    if WALLET:
        cmd.append(f"-rpcwallet={WALLET}")
    return subprocess.check_output(cmd + list(map(str, args))).decode().strip()


def clij(*args):
    return json.loads(cli(*args), parse_float=Decimal)


def sha256(b): return hashlib.sha256(b).digest()
def dsha(b): return sha256(sha256(b))


def varint(n):
    if n < 0xfd: return bytes([n])
    if n <= 0xffff: return b"\xfd" + n.to_bytes(2, "little")
    if n <= 0xffffffff: return b"\xfe" + n.to_bytes(4, "little")
    return b"\xff" + n.to_bytes(8, "little")


def build_legacy(tx):
    """Witness-STRIPPED serialization: double-sha256 of this == txid."""
    out = int(tx["version"]).to_bytes(4, "little")
    out += varint(len(tx["vin"]))
    for vin in tx["vin"]:
        out += bytes.fromhex(vin["txid"])[::-1]          # prevout (internal order)
        out += int(vin["vout"]).to_bytes(4, "little")
        ss = bytes.fromhex(vin.get("scriptSig", {}).get("hex", ""))
        out += varint(len(ss)) + ss                       # empty for segwit inputs
        out += int(vin["sequence"]).to_bytes(4, "little")
    out += varint(len(tx["vout"]))
    for vout in tx["vout"]:
        sats = int((vout["value"] * Decimal(100000000)).to_integral_value())
        out += sats.to_bytes(8, "little")
        spk = bytes.fromhex(vout["scriptPubKey"]["hex"])
        out += varint(len(spk)) + spk
    out += int(tx["locktime"]).to_bytes(4, "little")
    return out


def merkle_branch(leaves, index):
    layer, idx, branch = list(leaves), index, []
    while len(layer) > 1:
        if len(layer) % 2 == 1:
            layer.append(layer[-1])                       # duplicate last on odd layer
        branch.append(layer[idx ^ 1])
        layer = [dsha(layer[i] + layer[i + 1]) for i in range(0, len(layer), 2)]
        idx //= 2
    return branch, layer[0]



# ── BIP-327 MuSig2 KeyAgg + BIP-341 taproot tweak ────────────────────────────────────
# ⚠️ ADDED (E147-d). The generator USED TO ask bitcoind for an unrelated `getnewaddress
#    bech32m` and record its output key as `fundingTaproot`, while emitting two other
#    unrelated wallet pubkeys as lpPubkey/hopPubkey. **The three had no relationship at
#    all** — Q was a SINGLE-KEY BIP-86 wallet output standing in for a 2-of-2. That was
#    invisible while the contract only byte-matched `0x5120||Q`, and it made the fixture
#    structurally incapable of satisfying an on-chain KeyAgg check (E129/E142). The header's
#    claim of "no custom Bitcoin crypto" was the reason it stayed that way; the honest
#    version is that the ONE relationship the fixture must encode cannot come from the
#    wallet, because the wallet does not know these are supposed to be channel keys.
# This mirrors `quid-hop/src/funding.rs::taproot_funding_aggregate_xonly` and is checked
# against the BIP-327 reference vector below, so a silent drift fails loudly at generation.
P  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


def _tagged(tag, msg):
    t = sha256(tag.encode())
    return sha256(t + t + msg)


def _pt_add(p1, p2):
    if p1 is None: return p2
    if p2 is None: return p1
    if p1[0] == p2[0] and (p1[1] + p2[1]) % P == 0: return None
    if p1 == p2:
        lam = 3 * p1[0] * p1[0] * pow(2 * p1[1], P - 2, P) % P
    else:
        lam = (p2[1] - p1[1]) * pow(p2[0] - p1[0], P - 2, P) % P
    x = (lam * lam - p1[0] - p2[0]) % P
    return (x, (lam * (p1[0] - x) - p1[1]) % P)


def _pt_mul(k, pt):
    r = None
    while k:
        if k & 1: r = _pt_add(r, pt)
        pt = _pt_add(pt, pt); k >>= 1
    return r


def _decompress(pk33):
    x = int.from_bytes(pk33[1:], "big")
    y_sq = (pow(x, 3, P) + 7) % P
    y = pow(y_sq, (P + 1) // 4, P)
    assert pow(y, 2, P) == y_sq, "pubkey is not on the curve"
    if y % 2 != pk33[0] % 2: y = P - y
    return (x, y)


def taproot_2of2_output_key(lp33, hop33):
    """Q = lift_x(KeyAgg(KeySort(lp,hop))) + H_TapTweak(x(agg))*G, empty merkle root."""
    p1, p2 = (lp33, hop33) if lp33 < hop33 else (hop33, lp33)   # BIP-327 KeySort
    ell = _tagged("KeyAgg list", p1 + p2)
    # BIP-327: the SECOND key's coefficient is 1, not a hash.
    a1 = int.from_bytes(_tagged("KeyAgg coefficient", ell + p1), "big") % N
    agg = _pt_add(_pt_mul(a1, _decompress(p1)), _decompress(p2))
    even = (agg[0], agg[1] if agg[1] % 2 == 0 else P - agg[1])   # BIP-341 tweaks the even-y lift
    t = int.from_bytes(_tagged("TapTweak", even[0].to_bytes(32, "big")), "big") % N
    return _pt_add(even, _pt_mul(t, (GX, GY)))[0].to_bytes(32, "big")


_B32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _bech32m(hrp, witver, prog):
    def polymod(v):
        gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        chk = 1
        for x in v:
            b = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ x
            for i in range(5):
                chk ^= gen[i] if ((b >> i) & 1) else 0
        return chk
    def conv(data):
        acc = bits = 0; out = []
        for b in data:
            acc = (acc << 8) | b; bits += 8
            while bits >= 5:
                bits -= 5; out.append((acc >> bits) & 31)
        if bits: out.append((acc << (5 - bits)) & 31)
        return out
    data = [witver] + conv(prog)
    hrp_exp = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]
    chk = polymod(hrp_exp + data + [0] * 6) ^ 0x2bc830a3          # bech32m constant
    return hrp + "1" + "".join(_B32[d] for d in data + [(chk >> 5 * (5 - i)) & 31 for i in range(6)])


# SELF-CHECK at import: the BIP-327 reference vector. If this ever fails, the fixture
# would silently encode a Q the contract cannot reproduce -- which is the exact defect
# E147 spent a session diagnosing. Fail at generation instead.
assert taproot_2of2_output_key(
    bytes.fromhex("02F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9"),
    bytes.fromhex("03DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659"),
).hex() == "dee725e810716d6f0748b3d82aa67cdc1066028ffc8a8ebbe5ca148148153325", \
    "KeyAgg drifted from the BIP-327 reference vector"


def _privkey_wif(d, testnet=True):
    """WIF-encode a 32-byte secret for a COMPRESSED key (regtest shares testnet's 0xEF)."""
    payload = (b"\xef" if testnet else b"\x80") + d.to_bytes(32, "big") + b"\x01"
    chk = dsha(payload)[:4]
    raw = payload + chk
    n = int.from_bytes(raw, "big")
    alpha = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    out = ""
    while n:
        n, r = divmod(n, 58); out = alpha[r] + out
    leading_zeros = len(raw) - len(raw.lstrip(b"\x00"))   # base58 encodes each as "1"
    return "1" * leading_zeros + out


def _pubkey_compressed(d):
    x, y = _pt_mul(d, (GX, GY))
    return bytes([2 + (y & 1)]) + x.to_bytes(32, "big")


def channel_keypair(label):
    """A channel key we OWN the secret for. (E147-d2) These used to come from
    `getnewaddress`+`getaddressinfo`, which meant the generator could not sign a
    key-path spend of the 2-of-2 -- and `build_splice` DOES spend it. Deriving them
    here is what makes the aggregate secret computable below."""
    d = int.from_bytes(sha256(label.encode()), "big") % N
    assert d != 0
    return d, _pubkey_compressed(d)


def aggregate_secret(d_lp, lp33, d_hop, hop33):
    """The secret for `taproot_2of2_output_key(lp,hop)`.

    Holding BOTH MuSig2 shares means the aggregate key has a known secret, so the
    fixture can spend the funding output with an ordinary single-signer BIP-340
    signature -- no MuSig2 nonce ceremony needed to produce a REAL confirmed splice.
    ⚠️ Parity is the whole difficulty and every step below is forced:
      * a secret whose pubkey is odd-y must be negated to represent the even-y point
        BIP-327 aggregation works with;
      * BIP-341 tweaks the EVEN-Y LIFT of the aggregate, so if the aggregate came out
        odd-y the combined secret flips sign before the tweak is added.
    """
    p1, p2 = (lp33, hop33) if lp33 < hop33 else (hop33, lp33)
    d1, d2 = (d_lp, d_hop) if lp33 < hop33 else (d_hop, d_lp)
    ell = _tagged("KeyAgg list", p1 + p2)
    a1 = int.from_bytes(_tagged("KeyAgg coefficient", ell + p1), "big") % N
    # x-only convention: a key with odd y is represented by the negated secret.
    if p1[0] == 3: d1 = N - d1
    if p2[0] == 3: d2 = N - d2
    # ...but KeyAgg operates on the FULL points, so undo that for the arithmetic.
    if p1[0] == 3: d1 = N - d1
    if p2[0] == 3: d2 = N - d2
    d_agg = (a1 * d1 + d2) % N
    agg = _pt_add(_pt_mul(a1, _decompress(p1)), _decompress(p2))
    if agg[1] % 2 != 0: d_agg = N - d_agg          # tweak applies to the even-y lift
    even_x = agg[0]
    t = int.from_bytes(_tagged("TapTweak", even_x.to_bytes(32, "big")), "big") % N
    return (d_agg + t) % N

def newpub():
    a = cli("getnewaddress", "", "bech32")
    return clij("getaddressinfo", a)["pubkey"]            # 33-byte compressed


def one_open(seed, sats):
    """One REAL funded key-path P2TR channel output, with its own proof."""
    # (E147-d2) Keys we own the SECRET for -- see channel_keypair/aggregate_secret.
    d_lp, lp = channel_keypair(f"quid-fixture-lp-{seed}-{sats}")
    d_hop, hop = channel_keypair(f"quid-fixture-hop-{seed}-{sats}")
    assert len(lp) == 33 and len(hop) == 33
    # (E147-d) Q IS DERIVED FROM lp/hop, NOT ASKED OF THE WALLET.
    # This used to be `getnewaddress bech32m` + read back its scriptPubKey — an output key
    # with NO relationship to lp/hop, so `KeyAgg(lpPubkey,hopPubkey) != fundingTaproot` for
    # every entry ever generated. The funding output is a 2-of-2; the wallet cannot produce
    # one, because it does not know these two keys are meant to be aggregated.
    # ⚠️ The output is consequently NOT spendable by this wallet. That is correct and
    #    intended: the fixture only needs the output to EXIST and be SPV-provable, which is
    #    all BTCChannels.openChannel checks. Nothing in the suite spends it.
    q = taproot_2of2_output_key(lp, hop)
    spk = b"\x51\x20" + q
    addr = _bech32m("bcrt", 1, q)
    assert bytes.fromhex(clij("getaddressinfo", addr)["scriptPubKey"]) == spk, \
        "bech32m encoding disagrees with bitcoind on the derived P2TR address"
    # Import the AGGREGATE secret as a `rawtr()` descriptor so bitcoind can sign the
    # key-path spend `build_splice` performs. `rawtr` takes the output key directly (no
    # further BIP-86 tweak), which is exactly what Q already is.
    d_q = aggregate_secret(d_lp, lp, d_hop, hop)
    assert _pt_mul(d_q, (GX, GY))[0].to_bytes(32, "big") == q, \
        "aggregate secret does not correspond to the aggregate output key"
    desc = f"rawtr({_privkey_wif(d_q)})"
    # ⚠️ APPEND THE CHECKSUM TO *THIS* STRING. `getdescriptorinfo(...)["descriptor"]` returns the
    #    PUBLIC form with the secret stripped, and importing that fails with "Cannot import
    #    descriptor without private keys to a wallet with private keys enabled" — which the old
    #    code discarded, so the import silently did nothing and only surfaced later as an
    #    unsignable splice input ("Witness program was passed an empty witness").
    desc = f"{desc}#{clij('getdescriptorinfo', desc)['checksum']}"
    res = json.loads(cli("importdescriptors",
                         json.dumps([{"desc": desc, "timestamp": "now", "internal": False}])))
    assert all(r.get("success") for r in res), f"importdescriptors failed: {res}"
    txid = cli("sendtoaddress", addr, "%.8f" % (sats / 1e8))
    return {"seed": seed, "sats": sats, "lp": lp, "hop": hop, "q": q, "spk": spk, "txid": txid}


def finish_open(o):
    tx = clij("getrawtransaction", o["txid"], "true")
    blockhash = tx["blockhash"]
    blk = clij("getblock", blockhash, 1)
    tx_index = blk["tx"].index(o["txid"])
    fund_sats = next(int((v["value"] * Decimal(1e8)).to_integral_value())
                     for v in tx["vout"] if v["scriptPubKey"]["hex"] == o["spk"].hex())
    assert fund_sats == o["sats"], f"funding value {fund_sats} != {o['sats']}"
    legacy = build_legacy(tx)
    assert dsha(legacy)[::-1].hex() == o["txid"], "reconstructed legacy txid mismatch"
    leaves = [bytes.fromhex(t)[::-1] for t in blk["tx"]]
    branch, root = merkle_branch(leaves, tx_index)
    assert root == bytes.fromhex(blk["merkleroot"])[::-1], "branch does not fold to header merkleroot"
    x = lambda h: "0x" + h
    return {
        "seed": o["seed"],
        "lpPubkey": x(o["lp"].hex()),
        "hopPubkey": x(o["hop"].hex()),
        "amountSats": o["sats"],
        "fundingTaproot": x(o["q"].hex()),
        "rawFundingTx": x(legacy.hex()),
        "fundingTxidDisplay": x(o["txid"]),
        "fundingBlockHashBE": x(blockhash),
        "fundingHeight": blk["height"],
        "txIndex": tx_index,
        "merkleBranch": [x(b.hex()) for b in branch],
    }



def le(n, w):
    return n.to_bytes(w, "little")


def build_splice(o, new_sats, withdraw_sats, payout_spk_hex):
    """A REAL splice: spend the funding outpoint into [new funding Q, payout script].

    Hand-serialised because `createrawtransaction` cannot emit an ARBITRARY scriptPubKey (it takes
    addresses or `data`), and the payout leg is a raw script the Solidity test chooses.

    ⚠️ ZERO FEE ON PURPOSE. The shapes the tests assert are exact — 20e6 -> 15e6 + 5e6 sums to the
    input with nothing left over. A 0-fee tx is VALID BY CONSENSUS but rejected by mempool POLICY,
    so `sendrawtransaction` would fail. Inventing a fee would silently change the amounts the tests
    assert on, i.e. make them pass for the wrong reason. `generateblock` submits straight into a
    block and bypasses policy, which is exactly the escape hatch for this.
    """
    tx = clij("getrawtransaction", o["txid"], "true")
    vout = next(v["n"] for v in tx["vout"] if v["scriptPubKey"]["hex"] == o["spk"].hex())
    payout = bytes.fromhex(payout_spk_hex)
    raw = (le(2, 4) + b"\x01"
           + bytes.fromhex(o["txid"])[::-1] + le(vout, 4) + b"\x00" + b"\xff\xff\xff\xff"
           + b"\x02"
           + le(new_sats, 8) + bytes([len(o["spk"])]) + o["spk"]
           + le(withdraw_sats, 8) + bytes([len(payout)]) + payout
           + le(0, 4))
    prevtxs = json.dumps([{ "txid": o["txid"], "vout": vout,
                            "scriptPubKey": o["spk"].hex(),
                            "amount": float(Decimal(o["sats"]) / Decimal(1e8)) }])
    signed = clij("signrawtransactionwithwallet", raw.hex(), prevtxs)
    assert signed.get("complete"), f"splice not fully signed: {signed.get('errors')}"
    shex = signed["hex"]
    # generateblock: into a block directly, bypassing the 0-fee policy rejection.
    res = clij("generateblock", cli("getnewaddress"), json.dumps([shex]))
    blockhash = res["hash"]
    blk = clij("getblock", blockhash, 1)
    stx = clij("decoderawtransaction", shex)
    stxid = stx["txid"]
    idx = blk["tx"].index(stxid)
    legacy = build_legacy(clij("getrawtransaction", stxid, "true"))
    assert dsha(legacy)[::-1].hex() == stxid, "reconstructed splice txid mismatch"
    leaves = [bytes.fromhex(x)[::-1] for x in blk["tx"]]
    branch, root = merkle_branch(leaves, idx)
    assert root == bytes.fromhex(blk["merkleroot"])[::-1], "splice branch does not fold to merkleroot"
    h = lambda b: "0x" + b
    return {
        "newAmountSats": new_sats, "withdrawSats": withdraw_sats,
        "payoutScript": h(payout.hex()),
        "spliceRawTx": h(legacy.hex()),
        "spliceTxidDisplay": h(stxid),
        "spliceBlockHashBE": h(blockhash),
        "spliceHeight": blk["height"],
        "spliceTxIndex": idx,
        "spliceMerkleBranch": [h(b.hex()) for b in branch],
    }


def main():
    # SIMPLE-TAPROOT (BOLT #995): each funding output is a KEY-PATH-ONLY P2TR
    # `OP_1 PUSH32 || Q` (0x5120||Q, 34 bytes) — see BitcoinTx.buildTaprootScriptPubKey
    # and ChannelLib._verifyAndLocate. NOT the old P2WSH 2-of-2: key-path taproot
    # reveals no script on-chain, so there is no redeem script to reconstruct.
    #
    # Q is the MuSig2 key-path aggregate in production. The contract does NO EC math on
    # it (_verifyAndLocate: "Q is lpAuth-committed and byte-matched, NOT reconstructed
    # from the keys"), so we take a real bech32m output from bitcoind and read Q straight
    # out of its scriptPubKey — no custom Bitcoin crypto in this file either.
    #
    # SEEDS: one entry per `_openHopChannel(seed)` used by the Solidity fixture. They all
    # share ONE header chain, so a test builds the gateway once and every open is proven
    # against the same real mainchain. Add a seed here when a test needs a new channel.
    # (seed, sats) — one REAL funded output per pair the Solidity fixtures open. Extracted
    # mechanically from the `_open*(ch, seed, sats)` call sites; the contract checks the funding
    # output's value against `amountSats`, so a pair needs its OWN on-chain output. Keyed
    # `s<seed>_<sats>` in the JSON so Solidity looks one up in O(1).
    PAIRS = [
        (1, 20_000_000), (91, 20_000_000),                      # _openHopChannel
        (1, 1_000_000),  (2, 1_000_000),  (2, 30_000_000),      # VBtcLevFeeLane / BtcLpMintStress
        (7, 1_000_000),  (7, 1_600_000),  (7, 2_000_000),
        (9, 50_000_000), (77, 20_000_000), (201, 20_000_000), (202, 15_000_000), (203, 25_000_000),
        (42, 300_000_000), (51, 300_000_000), (54, 300_000_000),
        (64, 300_000_000), (65, 300_000_000), (88, 300_000_000),
    ]
    # (seed, sats) -> (newSats, withdrawSats, payoutScript). Extracted from the `_buildShrink` /
    # `_spliceOut` call sites; only 3 distinct shapes exist. `splice()` SPV-proves the tx SPENDS
    # the funding UTXO, so each needs a REAL confirmed splice — a fabricated one is what
    # `MockSPV` was hiding.
    SPLICES = {
        (77, 20_000_000): (15_000_000, 5_000_000,
                           "5120" + "11" * 32),   # payout P2TR; the Solidity side pins the real key
        (1,  20_000_000): (15_000_000, 5_000_000, "5120" + "22" * 32),
        (7,   1_000_000): (  600_000,    400_000, "5120" + "33" * 32),
        # FEE-BEARING shape. Every other entry sums EXACTLY to the input, so they only ever
        # exercise perfect conservation — but a mainnet splice MUST pay a miner fee, so
        # newAmount + withdraw is ALWAYS < funding there. Verified against the contract before
        # adding this: `ChannelLib:565` checks only that the NEW FUNDING OUTPUT equals
        # `p.amountSats`, and there is NO input-vs-output conservation check; `BTCChannels:496`
        # additionally requires outputs OTHER than funding+payout to sum to zero, which a fee
        # satisfies because a fee is implicit (inputs - outputs), not an output. So this SHOULD
        # pass — and if it ever does not, every real mainnet splice is broken.
        (9,  50_000_000): (30_000_000, 19_900_000, "5120" + "44" * 32),   # 100_000 sat to fee
    }
    opens = [one_open(s, a) for s, a in PAIRS]
    cli("generatetoaddress", 7, cli("getnewaddress"))       # 7 confirmations (>=6)
    entries = [finish_open(o) for o in opens]
    for o, e in zip(opens, entries):
        spec = SPLICES.get((o["seed"], o["sats"]))
        if spec:
            e["splice"] = build_splice(o, *spec)

    tip = int(cli("getblockcount"))
    headers = [cli("getblockheader", cli("getblockhash", h), "false") for h in range(0, tip + 1)]
    x = lambda h: "0x" + h
    print(json.dumps({
        "genesisHeader": x(headers[0]),
        "headers": [x(h) for h in headers[1:]],             # blocks 1..tip
        "tip": tip,
        "opens": entries,
        "bySeed": {f"s{e['seed']}_{e['amountSats']}": e for e in entries},
        # Back-compat: OpenChannelE2E.t.sol reads the single-open keys at top level.
        **entries[0],
    }, indent=2))


if __name__ == "__main__":
    main()
