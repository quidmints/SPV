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


def newpub():
    a = cli("getnewaddress", "", "bech32")
    return clij("getaddressinfo", a)["pubkey"]            # 33-byte compressed


def one_open(seed, sats):
    """One REAL funded key-path P2TR channel output, with its own proof."""
    lp = bytes.fromhex(newpub())
    hop = bytes.fromhex(newpub())
    assert len(lp) == 33 and len(hop) == 33
    addr = cli("getnewaddress", "", "bech32m")
    spk = bytes.fromhex(clij("getaddressinfo", addr)["scriptPubKey"])
    assert len(spk) == 34 and spk[0] == 0x51 and spk[1] == 0x20, \
        f"expected key-path P2TR 0x5120||Q, got {spk.hex()}"
    q = spk[2:]
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
        (9, 50_000_000), (201, 20_000_000), (202, 15_000_000), (203, 25_000_000),
        (42, 300_000_000), (51, 300_000_000), (54, 300_000_000),
        (64, 300_000_000), (65, 300_000_000), (88, 300_000_000),
    ]
    opens = [one_open(s, a) for s, a in PAIRS]
    cli("generatetoaddress", 7, cli("getnewaddress"))       # 7 confirmations (>=6)
    entries = [finish_open(o) for o in opens]

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
