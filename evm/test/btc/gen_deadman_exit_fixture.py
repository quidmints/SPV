#!/usr/bin/env python3
"""(E128) Generate SIGNED dead-man exit fixtures for the Solidity tests.

WHY THIS EXISTS
---------------
`_armDeadManExit` now VERIFIES the exit: structure, BIP-341 sighash and BIP-340 signature
against the funding key `Q`. That is the point -- until E128 the LP's only fleet-independent
escape was whatever bytes the hop chose to hand over, and a hop could arm every channel with
garbage while the chain recorded it as protection.

The cost is that a channel can no longer be opened with a placeholder exit. Test channels use
pubkeys with no known discrete log, so they cannot sign one. This script derives channel keys we
DO own (`channel_keypair`), computes the aggregate secret for `Q` (`aggregate_secret` -- which
handles the two parity flips BIP-327/341 force), and emits a genuinely signed exit.

⚠️ WHAT IS AND IS NOT ESTABLISHED BY A FIXTURE FROM THIS SCRIPT. It exercises the WIRING --
witness extraction, input location, prevout pinning, byte order. It cannot establish that our
sighash or signature verification is CORRECT: for that the Solidity side is pinned to the
official BIP-341 (`TapSighash.t.sol`) and BIP-340 (`SchnorrBip340.t.sol`) vectors. A fixture
signed and verified by the same codebase would confirm a wrong tagged-hash tag just as happily
as a right one.

Usage:  python3 evm/test/btc/gen_deadman_exit_fixture.py > evm/test/btc/deadman_exit_fixture.json
"""
import json
import sys
from hashlib import sha256

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from gen_open_channel_fixture import (          # noqa: E402  (path set above)
    N, GX, GY, _pt_mul, _tagged, channel_keypair, aggregate_secret,
    taproot_2of2_output_key,
)


def _le(v, k):
    return v.to_bytes(k, "little")


def _bip340_sign(d, msg):
    """BIP-340 sign with aux = 32 zero bytes. `d` is the secret for the EVEN-Y point."""
    px, py = _pt_mul(d, (GX, GY))
    if py % 2:                                   # represent the even-y point
        d = N - d
        px, py = _pt_mul(d, (GX, GY))
    pbytes = px.to_bytes(32, "big")
    t = (d ^ int.from_bytes(_tagged("BIP0340/aux", b"\x00" * 32), "big")).to_bytes(32, "big")
    k0 = int.from_bytes(_tagged("BIP0340/nonce", t + pbytes + msg), "big") % N
    assert k0 != 0
    rx, ry = _pt_mul(k0, (GX, GY))
    k = k0 if ry % 2 == 0 else N - k0
    e = int.from_bytes(_tagged("BIP0340/challenge", rx.to_bytes(32, "big") + pbytes + msg), "big") % N
    return rx.to_bytes(32, "big") + ((k + e * d) % N).to_bytes(32, "big"), pbytes


def build_exit(funding_txid_internal, vout, funding_sats, q, payout_spk, deadline, out_value):
    """The exit tx (segwit-serialised) plus its BIP-341 SIGHASH_DEFAULT sighash."""
    def tx(sig):
        return (bytes.fromhex("02000000") + b"\x00\x01" + b"\x01"
                + funding_txid_internal + _le(vout, 4) + b"\x00" + bytes.fromhex("ffffffff")
                + b"\x01" + _le(out_value, 8) + bytes([len(payout_spk)]) + payout_spk
                + b"\x01" + bytes([len(sig)]) + sig + _le(deadline, 4))

    spk = bytes.fromhex("5120") + q
    h = lambda b: sha256(b).digest()                                     # noqa: E731
    sighash = _tagged("TapSighash",
        b"\x00"                       # epoch
        + b"\x00"                     # SIGHASH_DEFAULT
        + _le(2, 4) + _le(deadline, 4)
        + h(funding_txid_internal + _le(vout, 4))                        # sha_prevouts
        + h(_le(funding_sats, 8))                                        # sha_amounts
        + h(bytes([len(spk)]) + spk)                                     # sha_scriptpubkeys
        + h(bytes.fromhex("ffffffff"))                                   # sha_sequences
        + h(_le(out_value, 8) + bytes([len(payout_spk)]) + payout_spk)   # sha_outputs
        + b"\x00"                     # key path, no annex
        + _le(0, 4))                  # input_index
    return tx, sighash


def one(label, funding_txid_hex, vout, funding_sats, payout_hex, deadline, fee_sats):
    d_lp, lp33 = channel_keypair(f"{label}-lp")
    d_hop, hop33 = channel_keypair(f"{label}-hop")
    q = taproot_2of2_output_key(lp33, hop33)
    d_agg = aggregate_secret(d_lp, lp33, d_hop, hop33)

    txid = bytes.fromhex(funding_txid_hex)
    payout = bytes.fromhex(payout_hex)
    out_value = funding_sats - fee_sats
    tx, sighash = build_exit(txid, vout, funding_sats, q, payout, deadline, out_value)
    sig, qx = _bip340_sign(d_agg, sighash)
    assert qx == q, "aggregate secret does not correspond to Q -- parity handling is wrong"

    return {
        "label": label,
        "lpPubkey": "0x" + lp33.hex(),
        "hopPubkey": "0x" + hop33.hex(),
        "fundingTaproot": "0x" + q.hex(),
        "fundingTxId": "0x" + txid.hex(),
        "fundingVout": vout,
        "fundingSats": funding_sats,
        "cltvDeadline": deadline,
        "paysLp": out_value,
        "signedExitTx": "0x" + tx(sig).hex(),
    }


def _cli():
    """(E128) FFI modes, so a test can sign an exit for the funding txid IT built at runtime.

    Pre-enumerating every channel shape was the alternative and it is brittle: the sighash
    commits to the funding OUTPOINT and AMOUNT, so Python would have to replicate each test's
    funding-tx construction byte-for-byte and stay in sync with it forever. Asking the test for
    its own txid removes that coupling entirely.

      keys <lp-label> <hop-label>
          -> 0x<lp33><hop33><Q>   (concatenated; the test slices them)

      sign <lp-label> <hop-label> <txidHex> <vout> <sats> <payoutHex> <deadline> <feeSats>
          -> 0x<signed exit tx>
    """
    a = sys.argv[1:]
    if a and a[0] == "keys":
        d_lp, lp33 = channel_keypair(f"{a[1]}-lp")
        d_hop, hop33 = channel_keypair(f"{a[2]}-hop")
        print("0x" + (lp33 + hop33 + taproot_2of2_output_key(lp33, hop33)).hex())
        return True
    if a and a[0] == "payoutpop":
        # (E138) An OWNED payout key plus a BIP-340 proof-of-possession over the contract's
        # digest. Test payout keys were `_validXOnly(...)` -- valid points with NO known secret,
        # so no possession could ever be proven for them. This returns a key we hold and its
        # signature: 0x<xonly><64-byte sig>.
        _, label, digest_hex = a
        d, pk33 = channel_keypair(f"{label}-payout")
        x = pk33[1:]                                   # x-only
        if pk33[0] == 3:                               # odd-y -> negate for the even-y point
            d = N - d
        msg = bytes.fromhex(digest_hex[2:] if digest_hex.startswith("0x") else digest_hex)
        sig, px = _bip340_sign(d, msg)
        assert px == x, "payout key parity handling is wrong"
        print("0x" + (x + sig).hex())
        return True
    if a and a[0] == "signfull":
        # (E128) Sign for a channel whose keys came from SOMEWHERE ELSE's label convention --
        # notably `open_channel_fixture.json`, which uses `quid-fixture-{lp,hop}-{seed}-{sats}`
        # rather than this script's `<base>-lp` / `<base>-hop`. Verified: those labels reproduce
        # the fixture's recorded lpPubkey/hopPubkey exactly, so the aggregate secret is ours.
        _, lpl, hopl, txid, vout, sats, payout, deadline, fee = a
        d_lp, lp33 = channel_keypair(lpl)
        d_hop, hop33 = channel_keypair(hopl)
        q = taproot_2of2_output_key(lp33, hop33)
        d_agg = aggregate_secret(d_lp, lp33, d_hop, hop33)
        txid_b = bytes.fromhex(txid[2:] if txid.startswith("0x") else txid)
        pay = bytes.fromhex(payout[2:] if payout.startswith("0x") else payout)
        sats_i, fee_i = int(sats), int(fee)
        tx, sighash = build_exit(txid_b, int(vout), sats_i, q, pay, int(deadline), sats_i - fee_i)
        sig, qx = _bip340_sign(d_agg, sighash)
        assert qx == q, "aggregate secret does not correspond to Q"
        print("0x" + tx(sig).hex())
        return True
    if a and a[0] == "sign":
        _, lpl, hopl, txid, vout, sats, payout, deadline, fee = a
        d_lp, lp33 = channel_keypair(f"{lpl}-lp")
        d_hop, hop33 = channel_keypair(f"{hopl}-hop")
        q = taproot_2of2_output_key(lp33, hop33)
        d_agg = aggregate_secret(d_lp, lp33, d_hop, hop33)
        txid_b = bytes.fromhex(txid[2:] if txid.startswith("0x") else txid)
        pay = bytes.fromhex(payout[2:] if payout.startswith("0x") else payout)
        sats_i, fee_i = int(sats), int(fee)
        tx, sighash = build_exit(txid_b, int(vout), sats_i, q, pay, int(deadline), sats_i - fee_i)
        sig, qx = _bip340_sign(d_agg, sighash)
        assert qx == q, "aggregate secret does not correspond to Q"
        print("0x" + tx(sig).hex())
        return True
    return False


if __name__ == "__main__":
    if _cli():
        sys.exit(0)
    # One canonical channel. Deadlines are FIXED, not `block.number + n`: the sighash commits to
    # nLockTime, so a runtime-dependent deadline could not be pre-signed at all.
    out = [one(
        label="canonical",
        funding_txid_hex="0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
        vout=1,
        funding_sats=250_000,
        payout_hex="512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
        deadline=800_042,
        fee_sats=1_000,
    )]
    print(json.dumps({"exits": out}, indent=2))
