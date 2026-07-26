#!/usr/bin/env python3
"""Generate a REAL openChannel fixture from a live bitcoind regtest node.

No custom Bitcoin crypto in the protocol: bitcoind builds + confirms the funding
tx and we shape its data (witness-stripped legacy tx, merkle branch, headers)
into exactly what BTCChannels.openChannel / SPVGateway verify. The merkle branch
is recomputed here ONLY to self-check that it folds to the block's real
merkleroot before we ever feed it to Solidity (hashlib, not custom Rust).

Run with a regtest bitcoind already up (see the test's shell harness):
    BTC_CLI=/tmp/bitcoin-28.1/bin/bitcoin-cli DATADIR=/tmp/btcreg \
      python3 gen_open_channel_fixture.py > open_channel_fixture.json
"""
import hashlib, json, os, subprocess
from decimal import Decimal

CLI = os.environ.get("BTC_CLI", "/tmp/bitcoin-28.1/bin/bitcoin-cli")
DD = os.environ.get("DATADIR", "/tmp/btcreg")
WALLET = os.environ.get("WALLET", "")  # optional -rpcwallet (regtest harness sets it)
AMOUNT_SATS = 5_000_000   # 0.05 BTC channel


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


def newpub():
    a = cli("getnewaddress", "", "bech32")
    return clij("getaddressinfo", a)["pubkey"]            # 33-byte compressed


def main():
    # Wallet "t" + a matured balance are set up by the harness before this runs.
    lp = bytes.fromhex(newpub())
    hop = bytes.fromhex(newpub())
    assert len(lp) == 33 and len(hop) == 33

    # Sorted plain 2-of-2 — matches BitcoinTx.buildChannelRedeemScript + LDK's
    # make_funding_redeemscript: OP_2 <key_lo> <key_hi> OP_2 OP_CHECKMULTISIG,
    # keys lexicographically sorted (unsigned). No CLTV self-refund branch (§9b
    # removed the grief path — unilateral recovery is an LDK force-close).
    lo, hi = (lp, hop) if lp < hop else (hop, lp)
    redeem = bytes([0x52, 0x21]) + lo + bytes([0x21]) + hi + bytes([0x52, 0xae])
    spk = bytes([0x00, 0x20]) + sha256(redeem)            # P2WSH: single sha256
    addr = clij("decodescript", spk.hex())["address"]

    txid = cli("sendtoaddress", addr, "%.8f" % (AMOUNT_SATS / 1e8))
    cli("generatetoaddress", 7, cli("getnewaddress"))     # 7 confirmations (>=6)

    tx = clij("getrawtransaction", txid, "true")
    blockhash = tx["blockhash"]
    blk = clij("getblock", blockhash, 1)
    tx_index = blk["tx"].index(txid)

    # funding output must exist with exactly AMOUNT_SATS at our P2WSH spk.
    fund_sats = next(int((o["value"] * Decimal(1e8)).to_integral_value())
                     for o in tx["vout"] if o["scriptPubKey"]["hex"] == spk.hex())
    assert fund_sats == AMOUNT_SATS, f"funding value {fund_sats} != {AMOUNT_SATS}"

    legacy = build_legacy(tx)
    assert dsha(legacy)[::-1].hex() == txid, "reconstructed legacy txid mismatch"

    leaves = [bytes.fromhex(t)[::-1] for t in blk["tx"]]   # display -> internal
    branch, root = merkle_branch(leaves, tx_index)
    assert root == bytes.fromhex(blk["merkleroot"])[::-1], "branch does not fold to header merkleroot"

    tip = int(cli("getblockcount"))
    headers = [cli("getblockheader", cli("getblockhash", h), "false") for h in range(0, tip + 1)]

    x = lambda h: "0x" + h                                 # forge parseJson* wants 0x-prefixed hex
    print(json.dumps({
        "lpPubkey": x(lp.hex()),
        "hopPubkey": x(hop.hex()),
        "amountSats": AMOUNT_SATS,
        "rawFundingTx": x(legacy.hex()),
        "fundingTxidDisplay": x(txid),
        "fundingBlockHashBE": x(blockhash),                # display/BE (gateway key + OpenParams)
        "fundingHeight": blk["height"],
        "txIndex": tx_index,
        "merkleBranch": [x(b.hex()) for b in branch],      # internal order
        "genesisHeader": x(headers[0]),
        "headers": [x(h) for h in headers[1:]],            # blocks 1..tip
        "tip": tip,
    }, indent=2))


if __name__ == "__main__":
    main()
