//! EVM calldata + digest codec for the BTC-channel lifecycle.
//!
//! This is the production home of the ABI encoding, SPV-proof construction and
//! `BTCChannels` digest/channel-id derivation that the channel-lifecycle driver
//! (`quid-bridge`) submits on-chain. It was promoted verbatim from the
//! `e2e_ffi` test binary (which now re-uses it), so the byte-exactness already
//! proven against Solidity (`evm/test/AbiCheck.t.sol`, the cross-chain forge
//! test) covers this module too.
//!
//! Two layers:
//!   * a tiny hand-rolled ABI encoder ([`Tok`] + [`encode_tuple`]/[`encode_struct`]),
//!     byte-identical to `cast abi-encode` / Solidity `abi.encode`. We hand-roll
//!     rather than pull `alloy-dyn-abi` to keep the dependency surface minimal
//!     and the encoding auditable against the contract.
//!   * Bitcoin → SPV helpers that pull the inclusion data the contract verifies
//!     (raw LEGACY tx, block hash, height, tx-index, merkle branch) from an
//!     esplora client, plus funding-key recovery from the 2-of-2 witness.
//!
//! All amounts/encodings here MUST stay byte-exact with `BTCChannels.sol` /
//! `ChannelLib.sol` / `Types.sol`; the unit tests pin the load-bearing ones to
//! ground-truth vectors emitted by Solidity.

use alloy_primitives::{keccak256, Address, U256};
use bitcoin::consensus::{Decodable, Encodable};
use bitcoin::hashes::Hash as _;
use bitcoin::{BlockHash, Transaction, Txid, Witness};

use anyhow::{bail, ensure, Context};

use quid_ln::esplora::Esplora;

use crate::spv::{block_hash_be, merkle_branch};

// ──────────────────────────── tiny ABI encoder ───────────────────────────────
//
// Hand-rolled head/tail ABI encoding (verifiable byte-exact vs `cast abi-encode`).
// We only model the token kinds the channel calldata + digests use.

// ─────────────────────────────────────────────────────────────────────────────────────
// (E178) THE SIGNATURES, ONCE. Every Solidity signature this codec encodes lives here and
// NOWHERE ELSE.
//
// 🔴 WHY. On 2026-08-11 three of them drifted from the contract and the daemon would have
// encoded dead selectors, with `forge`, the full test suite and the ABI checker all green.
// The reason the tests could not catch it is instructive: they asserted
// `selector(encoder_output) == keccak(<literal>)` — the encoder against a SECOND COPY of
// the same string — which is circular. Two copies that drift together still agree, so the
// assertion holds while the call is dead. A THIRD copy sat in the hot-key policy allowlist
// in `quid-bridge/src/evm_validating_signer.rs`, and it drifted identically, which is why
// "just fix the allowlist" would have made the enclave sign calldata that reverts.
//
// ⇒ ONE copy, used to BUILD the calldata; the policy and the tests DERIVE from it; and
// `tools/check-client-abis.py` compares this one copy against the compiled ABI. An
// allowlist that restates the ABI is a second source of truth — the drift was the tell.
//
// ⚠️ These are the EXPANDED forms. A struct written as the bare token `tuple` hashes to a
// different selector, and the calldata still looks plausible.
pub const SIG_OPEN_CHANNEL: &str =
    "openChannel((bytes32,uint64,uint256,bytes,bytes,uint256,bytes32),bytes,bytes32[],\
(address,bytes32,bytes,bytes),(uint64[],bytes[],uint64,uint256,bytes)[])";
pub const SIG_SPLICE: &str =
    "splice(bytes32,(bytes32,uint64,uint256,bytes,bytes,uint256,bytes32),bytes,bytes32[],uint256)";
pub const SIG_RECORD_CLOSE: &str =
    "recordClose(bytes32,(bytes32,uint64,uint256,bytes,bytes,uint256,bytes32),bytes,bytes32,\
bytes32[],uint256)";
pub const SIG_RECORD_FORCE_CLOSE_PERMISSIONLESS: &str =
    "recordForceClosePermissionless(bytes32,bytes,bytes32,bytes32[],uint256)";
pub const SIG_DELIVER_SWAP_OUT_ONCHAIN: &str =
    "deliverSwapOutOnchain(bytes32,bytes32,(bytes32,uint64,uint256,bytes,bytes,uint256,bytes32),\
bytes,bytes32[],bytes)";
pub const SIG_EMIT_DEAD_MAN_EXIT: &str =
    "emitDeadManExit(bytes32,(bytes32,uint64,uint256,bytes,bytes,uint256,bytes32),\
(uint64[],bytes[],uint64,uint256,bytes))";
pub const SIG_REQUEST_SWAP_OUT_ONCHAIN: &str =
    "requestSwapOutOnchain(address,uint256,uint256,bytes32,bytes)";

/// (E178) Every signature the hop's hot key may legitimately be asked to sign on
/// `BTCChannels`. The EVM tx policy derives its selector set from THIS — it does not keep
/// its own list — so the policy cannot disagree with what the codec actually sends.
pub const HOP_BTCCHANNELS_SIGS: &[&str] = &[
    SIG_OPEN_CHANNEL,
    SIG_SPLICE,
    SIG_RECORD_CLOSE,
    SIG_RECORD_FORCE_CLOSE_PERMISSIONLESS,
    SIG_DELIVER_SWAP_OUT_ONCHAIN,
    SIG_EMIT_DEAD_MAN_EXIT,
];

/// An ABI token. Static tokens contribute one 32-byte word to the head; dynamic
/// tokens contribute a 32-byte offset in the head and their bytes in the tail.
#[derive(Clone, Debug)]
pub enum Tok {
    Uint(U256),
    Address(Address),
    FixedBytes32([u8; 32]),
    Bytes(Vec<u8>),
    BytesArray(Vec<Vec<u8>>),
    FixedBytes32Array(Vec<[u8; 32]>),
    /// A nested tuple (e.g. a Solidity struct passed as an argument). Encoded as
    /// `abi.encode` lays out an inline tuple: head = offset (when dynamic), tail =
    /// the field tuple. ONLY valid when at least one field is dynamic (Solidity
    /// inlines an all-static struct without an offset — we never need that here,
    /// and assert against it).
    Tuple(Vec<Tok>),
    /// (E178) A dynamic array of a STATIC numeric type — `uint64[]`, `uint256[]`.
    /// Needed by `ExitArming.prevValues`. Every element occupies one word, so the
    /// tail is simply `length ‖ words` with no offset table.
    UintArray(Vec<U256>),
    /// (E178) A dynamic array of TUPLES — `ExitArming[]`. The element tuples here are
    /// themselves dynamic (they carry `uint64[]`, `bytes[]` and `bytes`), so the tail
    /// is `length ‖ per-element offsets ‖ each encoded tuple`, exactly like
    /// [`Tok::BytesArray`]. An all-static element tuple would need the inline
    /// (offset-free) layout instead and is rejected rather than mis-encoded.
    TupleArray(Vec<Vec<Tok>>),
}

use crate::abi::word_u64;

impl Tok {
    fn is_dynamic(&self) -> bool {
        match self {
            Tok::Bytes(_)
            | Tok::BytesArray(_)
            | Tok::FixedBytes32Array(_)
            | Tok::UintArray(_)
            | Tok::TupleArray(_) => true,
            Tok::Tuple(fields) => {
                // A tuple is dynamic iff any field is. We only construct dynamic
                // tuples (OpenParams carries `bytes` pubkeys); guard the static
                // case which would need inline (no-offset) head encoding.
                debug_assert!(
                    fields.iter().any(Tok::is_dynamic),
                    "Tok::Tuple is only supported for tuples with a dynamic field"
                );
                true
            }
            _ => false,
        }
    }

    /// The static "head" word for a non-dynamic token.
    fn head_static(&self) -> [u8; 32] {
        match self {
            Tok::Uint(v) => v.to_be_bytes::<32>(),
            Tok::Address(a) => {
                let mut w = [0u8; 32];
                w[12..].copy_from_slice(a.as_slice());
                w
            }
            Tok::FixedBytes32(b) => *b,
            _ => unreachable!("dynamic token has no static head"),
        }
    }

    /// The tail bytes for a dynamic token (already 32-padded).
    fn tail(&self) -> Vec<u8> {
        match self {
            Tok::Bytes(b) => encode_bytes(b),
            Tok::BytesArray(items) => {
                // length ‖ per-element offsets ‖ each element (length ‖ padded bytes)
                let mut out = word_u64(items.len() as u64).to_vec();
                let mut off = (items.len() * 32) as u64;
                let mut tails = Vec::new();
                for it in items {
                    out.extend_from_slice(&word_u64(off));
                    let enc = encode_bytes(it);
                    off += enc.len() as u64;
                    tails.extend_from_slice(&enc);
                }
                out.extend_from_slice(&tails);
                out
            }
            Tok::FixedBytes32Array(items) => {
                let mut out = word_u64(items.len() as u64).to_vec();
                for it in items {
                    out.extend_from_slice(it);
                }
                out
            }
            Tok::Tuple(fields) => encode_tuple(fields),
            Tok::UintArray(items) => {
                // length ‖ one word per element (a static element type needs no offsets)
                let mut out = word_u64(items.len() as u64).to_vec();
                for v in items {
                    out.extend_from_slice(&v.to_be_bytes::<32>());
                }
                out
            }
            Tok::TupleArray(items) => {
                // length ‖ per-element offsets ‖ each encoded tuple. The offsets are
                // relative to the START OF THE OFFSET TABLE (i.e. just after the length
                // word), NOT to the start of the array — getting that wrong shifts every
                // element and decodes as garbage rather than failing.
                debug_assert!(
                    items.iter().all(|f| f.iter().any(Tok::is_dynamic)),
                    "Tok::TupleArray is only supported for element tuples with a dynamic \
                     field; an all-static element uses the inline (offset-free) layout"
                );
                let mut out = word_u64(items.len() as u64).to_vec();
                let mut off = (items.len() * 32) as u64;
                let mut tails = Vec::new();
                for fields in items {
                    out.extend_from_slice(&word_u64(off));
                    let enc = encode_tuple(fields);
                    off += enc.len() as u64;
                    tails.extend_from_slice(&enc);
                }
                out.extend_from_slice(&tails);
                out
            }
            _ => unreachable!("static token has no tail"),
        }
    }
}

/// `bytes`: length word ‖ data padded up to a 32-byte multiple.
pub fn encode_bytes(b: &[u8]) -> Vec<u8> {
    let mut out = word_u64(b.len() as u64).to_vec();
    out.extend_from_slice(b);
    let pad = (32 - (b.len() % 32)) % 32;
    out.extend(std::iter::repeat(0u8).take(pad));
    out
}

/// Encode a flat tuple `abi.encode(t0, t1, …)`: a head of one 32-byte slot per
/// token (value for static, offset for dynamic), then the concatenated tails.
/// This is the form for `abi.encode(a, b, c, …)` and for the INNER tuple of a
/// struct (no outer offset wrapper).
pub fn encode_tuple(toks: &[Tok]) -> Vec<u8> {
    let head_len = toks.len() * 32;
    let mut head = Vec::with_capacity(head_len);
    let mut tail = Vec::new();
    for t in toks {
        if t.is_dynamic() {
            let off = head_len + tail.len();
            head.extend_from_slice(&word_u64(off as u64));
            tail.extend_from_slice(&t.tail());
        } else {
            head.extend_from_slice(&t.head_static());
        }
    }
    head.extend_from_slice(&tail);
    head
}

/// Encode a SINGLE struct argument as Solidity's `abi.encode(structValue)`: a
/// leading 32-byte offset (`0x20`) to the tuple, then the tuple. This is the
/// layout `abi.decode(bytes, (Struct))` expects AND the layout hashed by
/// `keccak256(abi.encode(p))` in `openChannelDigest`.
pub fn encode_struct(toks: &[Tok]) -> Vec<u8> {
    let mut out = word_u64(0x20).to_vec();
    out.extend_from_slice(&encode_tuple(toks));
    out
}

/// `selector ‖ abi.encode(args…)` — a full external-call payload.
fn encode_call(signature: &str, args: &[Tok]) -> Vec<u8> {
    let mut out = keccak256(signature.as_bytes())[..4].to_vec();
    out.extend_from_slice(&encode_tuple(args));
    out
}

// ───────────────────────── bitcoin / SPV helpers ─────────────────────────────

/// Witness-stripped (LEGACY) serialization of `tx` — what `BitcoinTx.txid` /
/// `checkTxInclusion` expect (segwit serialization would hash to the wtxid).
pub fn legacy_bytes(tx: &Transaction) -> Vec<u8> {
    let mut stripped = tx.clone();
    for inp in &mut stripped.input {
        inp.witness = Witness::new();
    }
    let mut buf = Vec::new();
    stripped
        .consensus_encode(&mut buf)
        .expect("consensus encode to Vec is infallible");
    buf
}

/// Whether `tx` is a BOLT #3 COMMITMENT transaction — the EXACT discriminator the
/// contract's `BitcoinTx.isCommitmentTx` runs on-chain (the gate of
/// `recordForceClosePermissionless`): nLockTime's top byte is `0x20` AND the
/// (single funding) input's nSequence top byte is `0x80` (BOLT #3 obscured
/// commitment-number encoding: locktime = `0x20000000 | lower-24`, sequence =
/// `0x80000000 | upper-24`). A cooperative close (locktime 0), a splice (locktime =
/// a block height, top byte 0x00), and a swap-out delivery all FAIL this — so a
/// permissionless force-retire gated on it can never be abused by replaying one of
/// those to retire a LIVE channel.
///
/// The bridge runs it BEFORE submitting `recordForceClosePermissionless` so a
/// non-commitment spend (a coop close / splice / deliver — handled by the
/// participant-gated `recordClose`) is never misrouted to the permissionless
/// entrypoint (which would revert `NotForceClose` and waste gas).
pub fn is_commitment_tx(tx: &Transaction) -> bool {
    let locktime_top = tx.lock_time.to_consensus_u32() >> 24;
    // A commitment tx has exactly one (funding) input; an empty input list can't be
    // a commitment tx (and would also fail extractInput0Sequence on-chain).
    let seq_top = match tx.input.first() {
        Some(inp) => inp.sequence.to_consensus_u32() >> 24,
        None => return false,
    };
    locktime_top == 0x20 && seq_top == 0x80
}

/// Txid in INTERNAL byte order (the order the contract + merkle tree use).
pub fn txid_internal(txid: &Txid) -> [u8; 32] {
    txid.to_raw_hash().to_byte_array()
}

/// Serialize a block header (80 bytes) for the SPV gateway.
pub async fn serialize_header(
    esplora: &Esplora,
    hash: &BlockHash,
) -> anyhow::Result<Vec<u8>> {
    let header = esplora
        .client()
        .get_header_by_hash(hash)
        .await
        .with_context(|| format!("get_header_by_hash({hash})"))?;
    let mut buf = Vec::with_capacity(80);
    header
        .consensus_encode(&mut buf)
        .context("encode header")?;
    Ok(buf)
}

/// A transaction's SPV inclusion data, exactly as the contract folds it.
#[derive(Clone, Debug)]
pub struct TxInclusion {
    /// Raw LEGACY (witness-stripped) tx bytes.
    pub raw: Vec<u8>,
    /// Block hash in BE/display order (how `SPVGateway` keys stored headers).
    pub block_hash_be: [u8; 32],
    /// Block height.
    pub height: u64,
    /// Index of the tx within its block.
    pub tx_index: u64,
    /// Merkle branch (internal byte order) proving inclusion.
    pub merkle_proof: Vec<[u8; 32]>,
}

/// Fetch a confirmed tx + its inclusion proof. The proof is built from the
/// block's txids via [`merkle_branch`] (internal byte order, exactly as the
/// contract folds it). Errors if the tx is missing or unconfirmed.
pub async fn tx_inclusion(
    esplora: &Esplora,
    txid: &Txid,
) -> anyhow::Result<TxInclusion> {
    let client = esplora.client();
    let tx = client
        .get_tx(txid)
        .await
        .with_context(|| format!("get_tx({txid})"))?
        .with_context(|| format!("tx {txid} not found"))?;
    let raw = legacy_bytes(&tx);
    let status = client
        .get_tx_status(txid)
        .await
        .with_context(|| format!("get_tx_status({txid})"))?;
    let block_hash = status
        .block_hash
        .with_context(|| format!("tx {txid} is unconfirmed"))?;
    let height = status
        .block_height
        .with_context(|| format!("tx {txid} has no height"))? as u64;

    let txids: Vec<[u8; 32]> = client
        .get_block_txids(&block_hash)
        .await
        .with_context(|| format!("get_block_txids({block_hash})"))?
        .iter()
        .map(txid_internal)
        .collect();
    let index = txids
        .iter()
        .position(|t| t == &txid_internal(txid))
        .with_context(|| format!("tx {txid} not in block {block_hash}"))?;
    let (branch, _root) = merkle_branch(&txids, index);

    Ok(TxInclusion {
        raw,
        block_hash_be: block_hash_be(&block_hash),
        height,
        tx_index: index as u64,
        merkle_proof: branch,
    })
}

/// Locate the channel's key-path MuSig2 2-of-2 **P2TR** output (`0x5120||Q`) in the funding
/// tx, returning its `(vout, value_sats)`.
///
/// `Q` is recomputed from the channel's stored `(lp, hop)` 33-byte compressed
/// pubkeys via the proven [`crate::funding::channel_taproot_script_pubkey`]
/// (KeySort + KeyAgg + unspendable taproot tweak → `0x5120||Q`, byte-for-byte the
/// EVM mirror). This is the witness-FREE identification the M7 spec mandates: a
/// key-path taproot close carries only a 64-byte Schnorr signature (no
/// witnessScript), so the funding output can only be matched by its scriptPubKey
/// — never by parsing a spend witness.
pub fn funded_output_taproot(
    raw_funding_tx: &[u8],
    lp: &[u8; 33],
    hop: &[u8; 33],
) -> anyhow::Result<(u32, u64)> {
    let tx = Transaction::consensus_decode(&mut &raw_funding_tx[..])
        .context("decode funding tx")?;
    let spk = crate::funding::channel_taproot_script_pubkey(lp, hop);
    for (vout, out) in tx.output.iter().enumerate() {
        if out.script_pubkey.as_bytes() == spk.as_bytes() {
            return Ok((vout as u32, out.value.to_sat()));
        }
    }
    bail!("channel P2TR (0x5120||Q) output not found in funding tx")
}

// ─────────────────────── BTCChannels params / digest ─────────────────────────

/// `Types.OpenParams` — the channel-open parameters the contract verifies + the
/// LP signs over. Field order/types MUST match `Types.sol`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OpenParams {
    pub funding_block_hash_be: [u8; 32],
    pub funding_block_height: u64,
    pub funding_tx_index: u64,
    pub lp_pubkey: [u8; 33],
    pub hop_pubkey: [u8; 33],
    pub amount_sats: u64,
    /// SIMPLE-TAPROOT: the 32-byte x-only MuSig2 key-path aggregate `Q`. The
    /// channel funds a P2TR output `0x5120||Q`; the contract builds that script
    /// and byte-matches the funding output (no on-chain EC math). Computed via
    /// [`crate::funding::taproot_funding_aggregate_xonly`].
    pub funding_taproot: [u8; 32],
}

/// (E157/E138) `Types.OpenAuth` — the LP's consent, carried BY the open instead of
/// pre-registered. `registerDelegation` is GONE; this replaced it.
///
/// `lp_sig` is checked with `SignatureChecker`, so one path serves EOAs (ECDSA) and smart
/// wallets (ERC-1271). `btc_recipient_pop` is a BIP-340 signature BY `btc_recipient` over
/// `btcRecipientPoPDigest(lpEth)` — §E138 added it because registration proved the payout
/// key was ON THE CURVE but never that the LP CONTROLLED it, and close, splice-out and the
/// dead-man exit all pin to it, so a wrong key loses every escape at once.
#[derive(Clone, Debug)]
pub struct OpenAuth {
    pub lp_eth: Address,
    pub btc_recipient: [u8; 32],
    pub lp_sig: Vec<u8>,
    pub btc_recipient_pop: Vec<u8>,
}

impl OpenAuth {
    /// `(address,bytes32,bytes,bytes)` in `Types.OpenAuth` field order.
    pub fn tokens(&self) -> Vec<Tok> {
        vec![
            Tok::Address(self.lp_eth),
            Tok::FixedBytes32(self.btc_recipient),
            Tok::Bytes(self.lp_sig.clone()),
            Tok::Bytes(self.btc_recipient_pop.clone()),
        ]
    }
}

/// (E128/E156/E165) `Types.ExitArming` — a pre-signed dead-man exit shape.
///
/// ⚠️ MANDATORY AT OPEN. The fleet holds BOTH funding halves, so the LP has no funding key
/// and cannot sign anything, ever; its only escape is bytes the fleet pre-signed while
/// alive. Arming is therefore a CONSTRUCTION-TIME invariant — a channel cannot exist
/// without an escape — which is what let the LP-nominated fallback delete outright.
///
/// `prev_values`/`prev_scripts` are the prevout value + scriptPubKey for EVERY input of
/// `signed_exit_tx`, in input order: BIP-341 `Prevouts::All` commits to them and they live
/// in EARLIER transactions, so the chain cannot read them from this one. The contract
/// OVERWRITES the funding entry with what it already knows.
#[derive(Clone, Debug, Default)]
pub struct ExitArming {
    pub prev_values: Vec<u64>,
    pub prev_scripts: Vec<Vec<u8>>,
    pub cltv_deadline: u64,
    pub checkpoint_sats: u64,
    pub signed_exit_tx: Vec<u8>,
}

impl ExitArming {
    /// `(uint64[],bytes[],uint64,uint256,bytes)` in `Types.ExitArming` field order.
    pub fn tokens(&self) -> Vec<Tok> {
        vec![
            Tok::UintArray(self.prev_values.iter().copied().map(U256::from).collect()),
            Tok::BytesArray(self.prev_scripts.clone()),
            Tok::Uint(U256::from(self.cltv_deadline)),
            Tok::Uint(U256::from(self.checkpoint_sats)),
            Tok::Bytes(self.signed_exit_tx.clone()),
        ]
    }
}

impl OpenParams {
    /// The ABI token tuple `(bytes32,uint64,uint256,bytes,bytes,uint256,bytes32)`
    /// in `Types.OpenParams` field order (taproot `fundingTaproot` is the last).
    fn tokens(&self) -> Vec<Tok> {
        vec![
            Tok::FixedBytes32(self.funding_block_hash_be),
            Tok::Uint(U256::from(self.funding_block_height)),
            Tok::Uint(U256::from(self.funding_tx_index)),
            Tok::Bytes(self.lp_pubkey.to_vec()),
            Tok::Bytes(self.hop_pubkey.to_vec()),
            Tok::Uint(U256::from(self.amount_sats)),
            Tok::FixedBytes32(self.funding_taproot),
        ]
    }

    /// `keccak256(abi.encode(p))` — the inner struct hash used in the digest.
    fn abi_struct_hash(&self) -> [u8; 32] {
        keccak256(encode_struct(&self.tokens())).0
    }
}

/// Recompute `BTCChannels.openChannelDigest(p, rawFundingTx, hop)` (v2):
/// `keccak256(abi.encode(keccak256("BTCChannels.openChannel.v2"), chainId,
/// address(this), keccak256(rawFundingTx), keccak256(abi.encode(p)), hop))`.
/// This is the message the LP signs to authorize an open (`lpAuth`). MULTI-HOP: the
/// `hop` (the EVM address that will SUBMIT the open — the channel's owning hop) is
/// bound into the digest, so only that hop can open the LP's channel and a genuine
/// lpAuth cannot be replayed through a different submitter. For a self-hosted or
/// family-plan instance, `hop` is that instance's own EVM address.
/// (B) The digest an LP signs COLD to delegate channel operation — mirrors
/// `BTCChannels.delegationDigest(authority, btcRecipient, version)`. The SPA (MetaMask)
/// signs this once; `encode_register_delegation` relays the 65-byte r‖s‖v sig.
pub fn delegation_digest(
    chain_id: u64,
    btc_channels: Address,
    authority: Address,
    btc_recipient: [u8; 32],
    version: u64,
) -> [u8; 32] {
    let preimage = encode_tuple(&[
        Tok::FixedBytes32(keccak256("BTCChannels.delegation.v1").0),
        Tok::Uint(U256::from(chain_id)),
        Tok::Address(btc_channels),
        Tok::Address(authority),
        Tok::FixedBytes32(btc_recipient),
        Tok::Uint(U256::from(version)),
    ]);
    keccak256(preimage).0
}

pub fn open_channel_digest(
    chain_id: u64,
    btc_channels: Address,
    raw_funding_tx: &[u8],
    params: &OpenParams,
    hop: Address,
) -> [u8; 32] {
    let preimage = encode_tuple(&[
        Tok::FixedBytes32(keccak256("BTCChannels.openChannel.v2").0),
        Tok::Uint(U256::from(chain_id)),
        Tok::Address(btc_channels),
        Tok::FixedBytes32(keccak256(raw_funding_tx).0),
        Tok::FixedBytes32(params.abi_struct_hash()),
        Tok::Address(hop),
    ]);
    keccak256(preimage).0
}

/// Recompute `BTCChannels.spliceDigest(channelId, p, rawSpliceTx)`:
/// `keccak256(abi.encode(keccak256("BTCChannels.splice.v1"), chainId,
/// address(this), channelId, keccak256(rawSpliceTx), keccak256(abi.encode(p))))`.
/// The message the LP signs to authorize a splice (grow OR shrink). NOTE two
/// differences from [`open_channel_digest`]: (1) a distinct domain tag
/// (`splice.v1`), and (2) `channelId` is bound as a dedicated field, so consent is
/// specific to THIS channel + THIS new total and can't be replayed onto another
/// channel or amount. `params.amount_sats` is the NEW TOTAL funded amount.
pub fn splice_digest(
    chain_id: u64,
    btc_channels: Address,
    channel_id: [u8; 32],
    raw_splice_tx: &[u8],
    params: &OpenParams,
) -> [u8; 32] {
    let preimage = encode_tuple(&[
        Tok::FixedBytes32(keccak256("BTCChannels.splice.v1").0),
        Tok::Uint(U256::from(chain_id)),
        Tok::Address(btc_channels),
        Tok::FixedBytes32(channel_id),
        Tok::FixedBytes32(keccak256(raw_splice_tx).0),
        Tok::FixedBytes32(params.abi_struct_hash()),
    ]);
    keccak256(preimage).0
}

/// Recompute `BTCChannels.swapOutDeliverDigest(swapId, channelId, p, rawSpliceTx)`:
/// the LP-consent digest for an ON-CHAIN swap-out DELIVERY splice. A DISTINCT domain
/// tag from [`splice_digest`] (`swapOutDeliver.v1`) + an extra bound `swapId` field,
/// so a delivery lpAuth can ONLY drive `deliverSwapOutOnchain` — never replayed as a
/// plain `splice` (which would leave the swapId unfulfilled → a possible double-refund).
pub fn swap_out_deliver_digest(
    chain_id: u64,
    btc_channels: Address,
    swap_id: [u8; 32],
    channel_id: [u8; 32],
    raw_splice_tx: &[u8],
    params: &OpenParams,
) -> [u8; 32] {
    let preimage = encode_tuple(&[
        Tok::FixedBytes32(keccak256("BTCChannels.swapOutDeliver.v1").0),
        Tok::Uint(U256::from(chain_id)),
        Tok::Address(btc_channels),
        Tok::FixedBytes32(swap_id),
        Tok::FixedBytes32(channel_id),
        Tok::FixedBytes32(keccak256(raw_splice_tx).0),
        Tok::FixedBytes32(params.abi_struct_hash()),
    ]);
    keccak256(preimage).0
}

/// Sort two 33-byte funding pubkeys the way LDK's `make_funding_redeemscript`
/// (and `BitcoinTx.buildChannelRedeemScript`) order the 2-of-2 — by serialized
/// bytes ascending. `OpenParams.lpPubkey/hopPubkey` MUST be in this order so the
/// `channelId` computed at open matches the one the close driver recomputes from
/// the (already-sorted) witness script.
pub fn sort_funding_pubkeys(a: [u8; 33], b: [u8; 33]) -> ([u8; 33], [u8; 33]) {
    if a <= b {
        (a, b)
    } else {
        (b, a)
    }
}

/// Recompute the on-chain `channelId`:
/// `keccak256(abi.encode(p.lpPubkey, p.hopPubkey, fundingTxId, vout))`
/// (`ChannelLib.openChannelBody`). `funding_txid_internal` is the funding txid
/// in internal byte order; `vout` is the 2-of-2 output index.
pub fn channel_id(
    lp_pubkey: &[u8; 33],
    hop_pubkey: &[u8; 33],
    funding_txid_internal: [u8; 32],
    vout: u32,
) -> [u8; 32] {
    let preimage = encode_tuple(&[
        Tok::Bytes(lp_pubkey.to_vec()),
        Tok::Bytes(hop_pubkey.to_vec()),
        Tok::FixedBytes32(funding_txid_internal),
        Tok::Uint(U256::from(vout)),
    ]);
    keccak256(preimage).0
}

/// Derive the EVM address that owns a secp256k1 key: the low 20 bytes of
/// `keccak256(uncompressed pubkey without its 0x04 prefix, i.e. the 64-byte X‖Y)`.
/// The SINGLE audited home for this identity derivation — used by the EVM tx
/// signer (`LocalSigner`), the bridge's lpAuth recovery cross-check, and the LP
/// responder's `lp_eth`. (`bitcoin::secp256k1::PublicKey` unifies with the
/// standalone `secp256k1::PublicKey` — one crate instance, v0.29.)
pub fn evm_address_of(pk: &bitcoin::secp256k1::PublicKey) -> Address {
    let uncompressed = pk.serialize_uncompressed();
    Address::from_slice(&keccak256(&uncompressed[1..])[12..])
}

// ───────────────────────────── calldata builders ─────────────────────────────

/// `openChannel(OpenParams,bytes,bytes32[],bytes)` calldata. `lp_auth` is the
/// LP's 65-byte `r‖s‖v` ECDSA over [`open_channel_digest`].
/// (E178) `openChannel(OpenParams, bytes, bytes32[], OpenAuth, ExitArming[])`.
///
/// ⚠️ **THIS SIGNATURE DRIFTED AND THE DAEMON WOULD HAVE ENCODED A DEAD SELECTOR.** The old
/// form took a bare `address lpEth` and the comment described `registerDelegation` pinning
/// `btcRecipientOf` — but §E157 DELETED `registerDelegation` and folded the LP's consent
/// into `OpenAuth`, and §E165 made a pre-signed exit ladder mandatory at open. `forge`,
/// the test suite and `check-client-abis.py` were all green throughout, because the checker
/// only read `spa/`. It now reads this tree too (§E178) — do not hand-edit either this
/// string or the allowlist in `quid-bridge/src/evm_validating_signer.rs` without running it.
///
/// `auth` carries `lpEth` + the pinned payout key + the LP signature + the §E138
/// proof-of-possession. `exits` is the ladder: at least one shape, each fully verified
/// on-chain (structure + BIP-341 sighash + BIP-340 signature) before the channel exists.
pub fn encode_open_channel(
    params: &OpenParams,
    raw_funding_tx: &[u8],
    funding_merkle_proof: &[[u8; 32]],
    auth: &OpenAuth,
    exits: &[ExitArming],
) -> Vec<u8> {
    encode_call(
        SIG_OPEN_CHANNEL,
        &[
            Tok::Tuple(params.tokens()),
            Tok::Bytes(raw_funding_tx.to_vec()),
            Tok::FixedBytes32Array(funding_merkle_proof.to_vec()),
            Tok::Tuple(auth.tokens()),
            Tok::TupleArray(exits.iter().map(ExitArming::tokens).collect()),
        ],
    )
}

/// (B) `registerDelegation(address authority, bytes32 btcRecipient, uint256 version,
/// bytes sig)` — relays the LP's cold EIP-712 delegation. `authority` = a concrete hop
/// or THE Safe hopRegistry (fleet). `sig` is the LP's 65-byte r‖s‖v over `delegationDigest`.
pub fn encode_register_delegation(
    authority: Address,
    btc_recipient: [u8; 32],
    version: u64,
    sig: &[u8],
) -> Vec<u8> {
    encode_call(
        // NB: `version` is uint64 in the contract — the selector must say uint64 (the
        // calldata word is 32-byte-padded either way, but the 4-byte selector differs).
        "registerDelegation(address,bytes32,uint64,bytes)",
        &[
            Tok::Address(authority),
            Tok::FixedBytes32(btc_recipient),
            Tok::Uint(U256::from(version)),
            Tok::Bytes(sig.to_vec()),
        ],
    )
}

/// `splice(bytes32,OpenParams,bytes,bytes32[],bytes,uint256)` calldata. `lp_auth`
/// is the LP's 65-byte `r‖s‖v` ECDSA over [`splice_digest`]. `channel_id`
/// is the STABLE original channelId (keyed on the original funding outpoint), NOT
/// recomputed from the splice tx — a splice rotates only the live funding UTXO.
/// `params.amount_sats` is the new TOTAL: > current GROWS (adds liquidity),
/// < current SHRINKS (partial withdrawal). On a shrink the contract reads the LP's
/// BTC payout directly from the splice tx (P2WPKH to the LP's committed shutdown
/// key) to drive the delivered/native split — no attested balance needed. The
/// contract reverts if unchanged.
///
/// `fee_settle_sats`: on a GROW, the portion of the added liquidity the hop is
/// FUNDING in as this LP's accrued BTC-leg fees (`btcFeesOwedSats`). The contract
/// requires `fee_settle_sats <= grewBy` (can only clear fees actually spliced in) and
/// clamped-subtracts it from the LP's owed — the fees COMPOUND into `LP.pooled` (a bigger
/// POOLED share grows the LP's close payout, so `delivered` stays invariant). `0` for a
/// pure capacity splice. (B) NO `lpAuth`: `splice` is authorized on-chain by the channel
/// hop gate (channel.hop, fixed at open to a delegated hop) — the LP runs nothing.
pub fn encode_splice(
    channel_id: [u8; 32],
    params: &OpenParams,
    raw_splice_tx: &[u8],
    splice_merkle_proof: &[[u8; 32]],
    fee_settle_sats: u64,
) -> Vec<u8> {
    encode_call(
        SIG_SPLICE,
        &[
            Tok::FixedBytes32(channel_id),
            Tok::Tuple(params.tokens()),
            Tok::Bytes(raw_splice_tx.to_vec()),
            Tok::FixedBytes32Array(splice_merkle_proof.to_vec()),
            Tok::Uint(U256::from(fee_settle_sats)),
        ],
    )
}

/// (B) `deliverSwapOutOnchain(bytes32,bytes32,OpenParams,bytes,bytes32[],bytes)`
/// calldata — settles an on-chain swap-out: the SPV-proven splice-out tx that paid
/// the swapper's `swapper_script`. NO lpAuth under Option B: the fleet submits this as
/// the channel's HOP (`msg.sender == channels[channelId].hop`) and the delivery is
/// authenticated by the SPV-proven swapper payment + obligation pin, not a per-call LP
/// signature. `channel_id` is the STABLE original channelId.
pub fn encode_deliver_swap_out_onchain(
    swap_id: [u8; 32],
    channel_id: [u8; 32],
    params: &OpenParams,
    raw_splice_tx: &[u8],
    splice_merkle_proof: &[[u8; 32]],
    swapper_script: &[u8],
) -> Vec<u8> {
    encode_call(
        SIG_DELIVER_SWAP_OUT_ONCHAIN,
        &[
            Tok::FixedBytes32(swap_id),
            Tok::FixedBytes32(channel_id),
            Tok::Tuple(params.tokens()),
            Tok::Bytes(raw_splice_tx.to_vec()),
            Tok::FixedBytes32Array(splice_merkle_proof.to_vec()),
            Tok::Bytes(swapper_script.to_vec()),
        ],
    )
}

/// (#114 DEAD-MAN EXIT) `emitDeadManExit(bytes32,uint64,uint256,bytes)` calldata — the
/// fleet heartbeat that emits/refreshes a FULLY-signed, CLTV-timelocked unilateral-exit
/// tx for `channel_id`. `signed_exit_tx` is the raw consensus-serialized tx bytes from
/// [`crate::`]`..deadman_exit::presign_deadman_exit` (payout pinned to `btcRecipientOf`
/// INSIDE the signed bytes). On-chain records `cltv_deadline` (the liveness heartbeat)
/// and re-publishes the bytes in the `DeadManExitEmitted` event; no funds move.
/// AUTHORITY is the same (B) gate as `openChannel` (`_requireAttested` + delegated hop),
/// so the fleet submits this as the channel's HOP.
///
/// ⚠️ (E178/E165) THE FLAT FORM IS GONE. This took four flat arguments
/// (`bytes32,uint64,uint256,bytes`); §E165 replaced them with the channel's `OpenParams`
/// plus ONE `ExitArming` — the same struct `openChannel` arms the ladder with, so an exit
/// is verified identically whether it arrives at open or on a refresh, and there is only
/// one shape to keep in step. `cltv_deadline`/`checkpoint_sats`/`signed_exit_tx` are now
/// FIELDS of that struct rather than positional arguments.
///
/// The old NB about `uint64` still applies in spirit: the 4-byte selector is computed over
/// the EXPANDED tuple types, so a struct written as `tuple` — or a field whose width is
/// wrong — yields a selector no contract answers, with calldata that still looks plausible.
pub fn encode_emit_dead_man_exit(
    channel_id: [u8; 32],
    params: &OpenParams,
    exit: &ExitArming,
) -> Vec<u8> {
    encode_call(
        SIG_EMIT_DEAD_MAN_EXIT,
        &[
            Tok::FixedBytes32(channel_id),
            Tok::Tuple(params.tokens()),
            Tok::Tuple(exit.tokens()),
        ],
    )
}

/// `requestSwapOutOnchain(address,uint256,uint256,bytes32,bytes)` calldata — the
/// swapper's USD→BTC commit to an on-chain Bitcoin address. The SPA sends this in
/// production; this encoder is for the e2e + ABI symmetry. `swapper_script` is the
/// raw destination scriptPubKey (≤ 34 bytes).
pub fn encode_request_swap_out_onchain(
    token: Address,
    usd_amount: U256,
    min_sats: u64,
    swap_id: [u8; 32],
    swapper_script: &[u8],
) -> Vec<u8> {
    encode_call(
        SIG_REQUEST_SWAP_OUT_ONCHAIN,
        &[
            Tok::Address(token),
            Tok::Uint(usd_amount),
            Tok::Uint(U256::from(min_sats)),
            Tok::FixedBytes32(swap_id),
            Tok::Bytes(swapper_script.to_vec()),
        ],
    )
}

/// `recordClose(bytes32,bytes,bytes32,bytes32[],uint256)` calldata for a
/// COOPERATIVE close (`locktime == 0`).
///
/// ⚠️ (E178/E153) `close_params` IS NOT OPTIONAL AND WAS MISSING. `recordClose` gained an
/// `OpenParams` argument so it can reconstruct the channel's 2-of-2 and tell a SPLICE from
/// a CLOSE — which is what lets recording be PERMISSIONLESS instead of hop-only. Encoding
/// the old 5-argument form produced a selector no contract answers.
pub fn encode_record_close(
    channel_id: [u8; 32],
    close_params: &OpenParams,
    raw_close_tx: &[u8],
    close_block_hash_be: [u8; 32],
    merkle_proof: &[[u8; 32]],
    tx_index: u64,
) -> Vec<u8> {
    encode_call(
        SIG_RECORD_CLOSE,
        &[
            Tok::FixedBytes32(channel_id),
            Tok::Tuple(close_params.tokens()),
            Tok::Bytes(raw_close_tx.to_vec()),
            Tok::FixedBytes32(close_block_hash_be),
            Tok::FixedBytes32Array(merkle_proof.to_vec()),
            Tok::Uint(U256::from(tx_index)),
        ],
    )
}
// NOTE: recordForceClose was folded into recordClose (one SPV-gated recorder; the
// close tx's locktime selects the coop vs non-coop branch on-chain). The driver
// submits encode_record_close for BOTH; the EVM decides the settlement.

/// Encode the calldata for `recordForceClosePermissionless` — the PERMISSIONLESS
/// reconciliation of a unilateral/force close. The ABI is byte-identical to
/// `recordClose` (same 5 params), but the entrypoint is gated on-chain by
/// `BitcoinTx.isCommitmentTx` (so only a genuine BOLT #3 commitment-tx spend is
/// accepted, never a coop close / splice / deliver) and settles `delivered=0`
/// (lpPayout = the full funded amount), retiring the position to its on-chain
/// reality without minting anything.
///
/// WHY a SEPARATE entrypoint (vs `recordClose`): `recordClose` is participant-gated
/// (`msg.sender` must be the hop or the channel's `lpEth`). A force close is exactly
/// when the hop is dead/offline and the LP is incentivized to LEAVE the position
/// open (it keeps counting as QUI backing). The permissionless path lets ANY keeper
/// (here, the bridge reconciler) restore honest backing — and the `isCommitmentTx`
/// gate is what makes it safe to be permissionless.
pub fn encode_record_force_close_permissionless(
    channel_id: [u8; 32],
    raw_close_tx: &[u8],
    close_block_hash_be: [u8; 32],
    merkle_proof: &[[u8; 32]],
    tx_index: u64,
) -> Vec<u8> {
    encode_call(
        SIG_RECORD_FORCE_CLOSE_PERMISSIONLESS,
        &[
            Tok::FixedBytes32(channel_id),
            Tok::Bytes(raw_close_tx.to_vec()),
            Tok::FixedBytes32(close_block_hash_be),
            Tok::FixedBytes32Array(merkle_proof.to_vec()),
            Tok::Uint(U256::from(tx_index)),
        ],
    )
}

/// Build the canonical [`OpenParams`] for a confirmed funding tx, given the
/// channel's two 2-of-2 funding pubkeys (read from LDK via
/// `ChannelMonitor::funding_pubkeys`). Fetches the funding tx + its inclusion
/// proof, sorts the pubkeys into open/close `channelId` order, and verifies the
/// on-chain funding output's P2WSH equals the reconstructed 2-of-2 (so a wrong
/// pubkey pair is rejected here, before any signing/submission). Returns the
/// params plus the raw funding tx + merkle proof needed for
/// [`open_channel_digest`] / [`encode_open_channel`].
pub async fn build_open_params(
    esplora: &Esplora,
    funding_txid: &Txid,
    funding_vout: u32,
    pubkey_a: [u8; 33],
    pubkey_b: [u8; 33],
) -> anyhow::Result<(OpenParams, Vec<u8>, Vec<[u8; 32]>)> {
    let (k0, k1) = sort_funding_pubkeys(pubkey_a, pubkey_b);
    let incl = tx_inclusion(esplora, funding_txid)
        .await
        .context("funding inclusion proof")?;
    let tx = Transaction::consensus_decode(&mut &incl.raw[..]).context("decode funding tx")?;
    let out = tx
        .output
        .get(funding_vout as usize)
        .with_context(|| format!("funding vout {funding_vout} out of range"))?;
    // SIMPLE-TAPROOT: the funding output is the key-path MuSig2 P2TR `0x5120||Q`.
    // Recompute Q (+ the spk) from the sorted pubkeys via the proven aggregator and
    // verify the on-chain output matches — so a wrong pubkey pair is rejected here,
    // before any signing/submission. Q rides in OpenParams.fundingTaproot so the
    // EVM can build `0x5120||Q` and byte-match it (it does NO secp256k1 EC math).
    let funding_taproot = crate::funding::taproot_funding_aggregate_xonly(&k0, &k1);
    let expected_spk = crate::funding::channel_taproot_script_pubkey(&k0, &k1);
    ensure!(
        out.script_pubkey.as_bytes() == expected_spk.as_bytes(),
        "funding output P2TR (0x5120||Q) != reconstructed key-path aggregate (wrong funding pubkeys)"
    );
    let params = OpenParams {
        funding_block_hash_be: incl.block_hash_be,
        funding_block_height: incl.height,
        funding_tx_index: incl.tx_index,
        lp_pubkey: k0,
        hop_pubkey: k1,
        amount_sats: out.value.to_sat(),
        funding_taproot,
    };
    Ok((params, incl.raw, incl.merkle_proof))
}

/// Build the [`OpenParams`] for a confirmed SPLICE tx — the new, LARGER 2-of-2
/// output the splice pays to (the same funding pubkey pair; `amount_sats` = the
/// new TOTAL funded amount, which the on-chain `splice` requires to exceed
/// the channel's current total). The machinery is identical to
/// [`build_open_params`] — locate the reconstructed-2-of-2 output, verify its
/// on-chain P2WSH, fetch the inclusion proof — pointed at the splice tx + its
/// output index, so it is implemented by delegation. IMPORTANT: a splice does NOT
/// change the on-chain `channelId` (it is keyed on the ORIGINAL funding outpoint),
/// so the caller must pass the original channelId to [`splice_channel_digest`] /
/// [`encode_splice_channel`] — never recompute it from the splice outpoint.
pub async fn build_splice_params(
    esplora: &Esplora,
    splice_txid: &Txid,
    splice_vout: u32,
    pubkey_a: [u8; 33],
    pubkey_b: [u8; 33],
) -> anyhow::Result<(OpenParams, Vec<u8>, Vec<[u8; 32]>)> {
    build_open_params(esplora, splice_txid, splice_vout, pubkey_a, pubkey_b).await
}


/// (E178) Minimal well-formed `OpenAuth`/`ExitArming` for encoder-shape tests. The
/// VALUES are irrelevant here — these tests pin the ABI LAYOUT and the selector, and
/// the selector is checked against `SIG_*`, which `tools/check-client-abis.py` in turn
/// checks against the compiled contract. That three-step chain is what makes these
/// assertions non-circular: before §E178 they compared the encoder to a second copy of
/// the same literal, so both could drift together and the test still passed.
#[cfg(test)]
fn t_auth() -> OpenAuth {
    OpenAuth {
        lp_eth: Address::repeat_byte(0xCC),
        btc_recipient: [0x11u8; 32],
        lp_sig: vec![0x22u8; 65],
        btc_recipient_pop: vec![0x33u8; 64],
    }
}
#[cfg(test)]
fn t_exits() -> Vec<ExitArming> {
    vec![ExitArming {
        prev_values: vec![1_000u64, 2_000u64],
        prev_scripts: vec![vec![0x51, 0x20], vec![]],
        cltv_deadline: 0x0203,
        checkpoint_sats: 7,
        signed_exit_tx: vec![0xAAu8; 3], // odd length ⇒ exercises 32-byte padding
    }]
}
#[cfg(test)]
fn t_params() -> OpenParams {
    OpenParams {
        funding_block_hash_be: [0u8; 32],
        funding_block_height: 0,
        funding_tx_index: 0,
        lp_pubkey: [2u8; 33],
        hop_pubkey: [3u8; 33],
        amount_sats: 0,
        funding_taproot: [0u8; 32],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex_decode(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    fn hex_encode(b: &[u8]) -> String {
        let mut s = String::with_capacity(b.len() * 2);
        for x in b {
            s.push_str(&format!("{x:02x}"));
        }
        s
    }

    // GROUND TRUTH: keccak256(abi.encode(OpenParams)) exactly as Solidity emits
    // it in evm/test/AbiCheck.t.sol. Hash-equality over the whole encoding is a
    // byte-exactness proof — the lpAuth digest depends on exactly this.
    #[test]
    fn open_params_abi_matches_solidity() {
        let lp: [u8; 33] = hex_decode(
            "020102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
        )
        .try_into()
        .unwrap();
        let hop: [u8; 33] = hex_decode(
            "03a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0",
        )
        .try_into()
        .unwrap();
        let mut fbh = [0u8; 32];
        fbh.copy_from_slice(&hex_decode(
            "1111111111111111111111111111111111111111111111111111111111111111",
        ));
        let mut q = [0u8; 32];
        q.copy_from_slice(&hex_decode(
            "2222222222222222222222222222222222222222222222222222222222222222",
        ));
        let p = OpenParams {
            funding_block_hash_be: fbh,
            funding_block_height: 800001,
            funding_tx_index: 0,
            lp_pubkey: lp,
            hop_pubkey: hop,
            amount_sats: 1_000_000,
            funding_taproot: q,
        };
        assert_eq!(
            hex_encode(&p.abi_struct_hash()),
            // Ground truth from Solidity (BTCChannelsAuthTest.test_openparams_abi_ground_truth):
            // keccak256(abi.encode(p)) over the 7-field taproot OpenParams.
            "e5055c9a1fe82c0decd8413a97eb6579ded9e16299921d8cdf96d12078c52b2b",
            "keccak256(abi.encode(OpenParams)) must match Solidity"
        );
    }

    // bytes[] header batch element-offset math (same shape quid-bridge's
    // encode_add_header_batch builds).
    #[test]
    fn bytes_array_offsets() {
        let enc = Tok::BytesArray(vec![vec![0x11u8; 80], vec![0x22u8; 80]]).tail();
        let s = hex_encode(&enc);
        assert!(s.starts_with(
            "0000000000000000000000000000000000000000000000000000000000000002\
0000000000000000000000000000000000000000000000000000000000000040\
00000000000000000000000000000000000000000000000000000000000000c0\
0000000000000000000000000000000000000000000000000000000000000050"
        ));
    }

    // Function selectors must match keccak256(signature)[..4].
    #[test]
    fn selectors() {
        assert_eq!(
            hex_encode(&encode_record_close([0u8; 32], &t_params(), &[], [0u8; 32], &[], 0)[..4]),
            hex_encode(&keccak256(SIG_RECORD_CLOSE)[..4]),
        );
        assert_eq!(
            hex_encode(&encode_open_channel(
                &OpenParams {
                    funding_block_hash_be: [0u8; 32],
                    funding_block_height: 0,
                    funding_tx_index: 0,
                    lp_pubkey: [2u8; 33],
                    hop_pubkey: [3u8; 33],
                    amount_sats: 0,
                    funding_taproot: [0u8; 32],
                },
                &[],
                &[],
                &t_auth(),
                &t_exits(),
            )[..4]),
            hex_encode(
                &keccak256(
                    SIG_OPEN_CHANNEL
                )[..4]
            ),
        );
        // (#114) emitDeadManExit — uint64 cltvDeadline (selector, not word, distinguishes it).
        assert_eq!(
            hex_encode(&encode_emit_dead_man_exit([0u8; 32], &t_params(), &ExitArming::default())[..4]),
            hex_encode(&keccak256(SIG_EMIT_DEAD_MAN_EXIT)[..4]),
        );
    }

    // (#114) emitDeadManExit calldata: 3 static words (bytes32, uint64→word, uint256)
    // + 1 dynamic bytes ⇒ head is 4 words; word3 is the offset to the bytes = 0x80.
    #[test]
    fn emit_dead_man_exit_calldata_layout() {
        // ⚠️ (E178) THE SHAPE CHANGED: `emitDeadManExit(bytes32, OpenParams, ExitArming)`.
        // It used to be four FLAT arguments (`bytes32,uint64,uint256,bytes`), so the old
        // assertions read `cltvDeadline` out of word1 and `checkpointSats` out of word2.
        // Those are now FIELDS INSIDE the `ExitArming` tuple, and words 1 and 2 are the
        // OFFSETS to the two tuples — reading them as scalars is exactly the silent
        // mis-decode this test exists to catch.
        let cid = [0x11u8; 32];
        let exit = t_exits()[0].clone();
        let cd = encode_emit_dead_man_exit(cid, &t_params(), &exit);
        assert_eq!(cd.len() % 32, 4, "4-byte selector + 32-aligned body");
        let body = &cd[4..];
        assert_eq!(&body[0..32], &cid[..], "word0 = channelId (static, inline)");
        // Head = 3 words: one static + two dynamic offsets, so arg1's tail starts at 0x60.
        let off_params = U256::from_be_slice(&body[32..64]).to::<u64>() as usize;
        let off_exit = U256::from_be_slice(&body[64..96]).to::<u64>() as usize;
        assert_eq!(off_params, 0x60, "word1 = offset to the OpenParams tuple");
        assert!(off_exit > off_params, "word2 = offset to the ExitArming tuple, after it");
        // The ExitArming tail begins with its own 5-word head; field 2 (`cltvDeadline`) and
        // field 3 (`checkpointSats`) are STATIC, so they sit inline at words 2 and 3 of it.
        let et = &body[off_exit..];
        assert_eq!(U256::from_be_slice(&et[64..96]), U256::from(0x0203u64),
                   "ExitArming.cltvDeadline");
        assert_eq!(U256::from_be_slice(&et[96..128]), U256::from(7u64),
                   "ExitArming.checkpointSats");
        // …and `signedExitTx` is the last, dynamic, field: length then right-padded data.
        let off_tx = U256::from_be_slice(&et[128..160]).to::<u64>() as usize;
        assert_eq!(U256::from_be_slice(&et[off_tx..off_tx + 32]), U256::from(3u64),
                   "signedExitTx length = 3");
        assert_eq!(&et[off_tx + 32..off_tx + 35], &exit.signed_exit_tx[..], "signedExitTx data");
        assert_eq!(&et[off_tx + 35..off_tx + 64], &[0u8; 29], "right-padded to 32");
    }

    // (E178) openChannel calldata: FIVE top-level args, ALL dynamic — tuple, bytes,
    // bytes32[], tuple (OpenAuth), tuple[] (ExitArming ladder) — so the head is 5 words
    // and the first is the offset to arg0 = 0xA0 (5×32). It was 0x80 when the last arg
    // was a static `address lpEth`; that argument is gone (§E157).
    #[test]
    fn open_channel_calldata_layout() {
        let p = OpenParams {
            funding_block_hash_be: [0x11u8; 32],
            funding_block_height: 800001,
            funding_tx_index: 7,
            lp_pubkey: [2u8; 33],
            hop_pubkey: [3u8; 33],
            amount_sats: 1_000_000,
            funding_taproot: [0u8; 32],
        };
        let cd = encode_open_channel(&p, &[0xAAu8; 64], &[[0xBBu8; 32]], &t_auth(), &t_exits());
        // after the 4-byte selector: first head word = offset to arg0 (the tuple)
        // = 0xA0 (5 dynamic args × 32).
        let first_off = &cd[4..36];
        assert_eq!(
            hex_encode(first_off),
            "00000000000000000000000000000000000000000000000000000000000000a0",
        );
    }

    // The ABI encoders must not panic on extreme inputs (empty/huge bytes, empty
    // /large proofs, max ints) and must keep the right selector + structure.
    #[test]
    fn calldata_encoders_never_panic_on_extremes() {
        let p = OpenParams {
            funding_block_hash_be: [0u8; 32],
            funding_block_height: u64::MAX,
            funding_tx_index: u64::MAX,
            lp_pubkey: [2u8; 33],
            hop_pubkey: [3u8; 33],
            amount_sats: u64::MAX,
            funding_taproot: [0u8; 32],
        };
        let oc_sel =
            keccak256(SIG_OPEN_CHANNEL);
        let rc_sel = keccak256(SIG_RECORD_CLOSE);
        for proof_len in [0usize, 1, 12, 1000] {
            let proof = vec![[0xABu8; 32]; proof_len];
            let oc = encode_open_channel(&p, &[], &proof, &t_auth(), &t_exits());
            assert_eq!(&oc[..4], &oc_sel[..4]);
            // dynamic-tail length is always a 32-byte multiple (well-formed ABI).
            assert_eq!(oc.len() % 32, 4);
            let rc = encode_record_close([0u8; 32], &t_params(), &vec![0u8; 4096], [0u8; 32], &proof, u64::MAX);
            assert_eq!(&rc[..4], &rc_sel[..4]);
            assert_eq!(rc.len() % 32, 4);
        }
        // Empty Bytes / huge Bytes / nested tuple — encode_struct/tuple no panic.
        let _ = encode_struct(&[Tok::Bytes(vec![]), Tok::Bytes(vec![0xff; 9999])]);
        let _ = encode_tuple(&[Tok::Tuple(p.tokens()), Tok::FixedBytes32Array(vec![[0u8; 32]; 500])]);
        // digest + channelId with extreme values.
        let _ = open_channel_digest(u64::MAX, Address::repeat_byte(0xff), &vec![0xab; 10_000], &p, Address::repeat_byte(0x11));
        let _ = channel_id(&[0xff; 33], &[0x00; 33], [0xaa; 32], u32::MAX);
        // splice encoder + digest with extreme values — must not panic, right shape.
        let sp_sel = keccak256(
            SIG_SPLICE,
        );
        for proof_len in [0usize, 1, 12, 1000] {
            let proof = vec![[0xABu8; 32]; proof_len];
            let sp = encode_splice([0xCDu8; 32], &p, &vec![0u8; 4096], &proof, 0);
            assert_eq!(&sp[..4], &sp_sel[..4]);
            assert_eq!(sp.len() % 32, 4);
        }
        let _ = splice_digest(
            u64::MAX, Address::repeat_byte(0xff), [0x42; 32], &vec![0xab; 10_000], &p,
        );
    }

    // splice selector must match keccak256(signature)[..4].
    #[test]
    fn splice_selector() {
        let p = OpenParams {
            funding_block_hash_be: [0u8; 32],
            funding_block_height: 0,
            funding_tx_index: 0,
            lp_pubkey: [2u8; 33],
            hop_pubkey: [3u8; 33],
            amount_sats: 0,
            funding_taproot: [0u8; 32],
        };
        assert_eq!(
            hex_encode(&encode_splice([0u8; 32], &p, &[], &[], 0)[..4]),
            hex_encode(
                &keccak256(
                    SIG_SPLICE
                )[..4]
            ),
        );
    }

    // The splice digest must (a) be deterministic, (b) bind channelId + chainId,
    // and (c) be domain-separated from the open digest — so LP consent to a splice
    // can never be replayed onto another channel/amount or confused with an open.
    #[test]
    fn splice_digest_binds_channel_and_is_domain_separated() {
        let p = OpenParams {
            funding_block_hash_be: [0x11u8; 32],
            funding_block_height: 800_010,
            funding_tx_index: 3,
            lp_pubkey: [2u8; 33],
            hop_pubkey: [3u8; 33],
            amount_sats: 2_000_000,
            funding_taproot: [0u8; 32],
        };
        let raw = vec![0xABu8; 120];
        let addr = Address::repeat_byte(0x11);
        let cid_a = [0x42u8; 32];
        let cid_b = [0x43u8; 32];
        let d = splice_digest(1, addr, cid_a, &raw, &p);
        assert_eq!(d, splice_digest(1, addr, cid_a, &raw, &p)); // deterministic
        assert_ne!(d, splice_digest(1, addr, cid_b, &raw, &p)); // channelId bound
        assert_ne!(d, splice_digest(2, addr, cid_a, &raw, &p)); // chainId bound
        assert_ne!(d, open_channel_digest(1, addr, &raw, &p, Address::ZERO)); // domain-separated from open
    }

    // splice calldata: arg0 is a STATIC bytes32 (channelId, inlined in the head);
    // args are (channelId static, params dynamic, raw dynamic, proof dynamic,
    // feeSettleSats static) → head is 5 words, so word1 (the offset to the OpenParams
    // tuple) = 0xA0 (5 × 32). (B) lpAuth dropped.
    #[test]
    fn splice_calldata_layout() {
        let p = OpenParams {
            funding_block_hash_be: [0x22u8; 32],
            funding_block_height: 800_011,
            funding_tx_index: 9,
            lp_pubkey: [2u8; 33],
            hop_pubkey: [3u8; 33],
            amount_sats: 3_000_000,
            funding_taproot: [0u8; 32],
        };
        let cid = [0x7Au8; 32];
        let cd = encode_splice(cid, &p, &[0xAAu8; 64], &[[0xBBu8; 32]], 0);
        // head word0 = channelId (static, inlined verbatim).
        assert_eq!(&cd[4..36], &cid);
        // head word1 = offset to arg1 (the dynamic OpenParams tuple) = 0xA0: the head is
        // 5 words (channelId, params-offset, raw-offset, proof-offset, feeSettleSats) so
        // the first dynamic arg starts at 5 × 32.
        assert_eq!(
            hex_encode(&cd[36..68]),
            "00000000000000000000000000000000000000000000000000000000000000a0",
        );
    }

    // The on-chain swap-out DELIVERY digest must (a) be deterministic, (b) bind
    // swapId + channelId + chainId, and (c) be DOMAIN-SEPARATED from splice_digest —
    // so a delivery lpAuth can never be replayed as a plain splice (the contract
    // hardening that prevents a double-refund).
    #[test]
    fn swap_out_deliver_digest_binds_swap_and_is_domain_separated() {
        let p = OpenParams {
            funding_block_hash_be: [0x11u8; 32],
            funding_block_height: 800_010,
            funding_tx_index: 3,
            lp_pubkey: [2u8; 33],
            hop_pubkey: [3u8; 33],
            amount_sats: 1_500_000,
            funding_taproot: [0u8; 32],
        };
        let raw = vec![0xABu8; 120];
        let a = Address::repeat_byte(0x11);
        let (sid_a, sid_b) = ([0x42u8; 32], [0x43u8; 32]);
        let cid = [0x7Au8; 32];
        let d = swap_out_deliver_digest(1, a, sid_a, cid, &raw, &p);
        assert_eq!(d, swap_out_deliver_digest(1, a, sid_a, cid, &raw, &p)); // deterministic
        assert_ne!(d, swap_out_deliver_digest(1, a, sid_b, cid, &raw, &p)); // swapId bound
        assert_ne!(d, swap_out_deliver_digest(2, a, sid_a, cid, &raw, &p)); // chainId bound
        // CRITICAL: distinct from splice_digest over the same (channel, params, tx),
        // so a delivery lpAuth can't drive a plain `splice`.
        assert_ne!(d, splice_digest(1, a, cid, &raw, &p));
    }

    // deliverSwapOutOnchain selector matches keccak256(signature)[..4].
    #[test]
    fn deliver_swap_out_onchain_selector() {
        let p = OpenParams {
            funding_block_hash_be: [0u8; 32], funding_block_height: 0, funding_tx_index: 0,
            lp_pubkey: [2u8; 33], hop_pubkey: [3u8; 33], amount_sats: 0,
            funding_taproot: [0u8; 32],
        };
        let cd = encode_deliver_swap_out_onchain([1u8; 32], [2u8; 32], &p, &[], &[], &[0x00, 0x14]);
        let sig = SIG_DELIVER_SWAP_OUT_ONCHAIN;
        assert_eq!(hex_encode(&cd[..4]), hex_encode(&keccak256(sig)[..4]));
        assert_eq!(cd.len() % 32, 4); // well-formed
    }

    // requestSwapOutOnchain selector matches keccak256(signature)[..4].
    #[test]
    fn request_swap_out_onchain_selector() {
        let cd = encode_request_swap_out_onchain(
            Address::repeat_byte(0x11), U256::from(500_000u64), 0, [0xA1u8; 32], &[0x00, 0x14, 0x5A],
        );
        let sig = SIG_REQUEST_SWAP_OUT_ONCHAIN;
        assert_eq!(hex_encode(&cd[..4]), hex_encode(&keccak256(sig)[..4]));
        assert_eq!(cd.len() % 32, 4);
    }

    // ───────────────────── M7: taproot funding-output locator ─────────────────
    // A simple-taproot channel funds a P2TR `0x5120||Q` output (key-path MuSig2
    // 2-of-2), NOT a P2WSH 2-of-2. `funded_output_taproot` must locate that output
    // by its `0x5120||Q` scriptPubKey — recomputing Q from the channel's stored
    // (lp, hop) pubkeys via the proven `channel_taproot_script_pubkey`, NEVER by
    // parsing a witness (a key-path close has an empty witnessScript).
    #[test]
    fn taproot_funded_output_located_by_p2tr_spk() {
        use bitcoin::{absolute::LockTime, transaction::Version, Amount, ScriptBuf, TxOut};
        // BIP327 example key pair (distinct valid compressed secp256k1 points).
        let lp: [u8; 33] = hex_decode(
            "02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
        ).try_into().unwrap();
        let hop: [u8; 33] = hex_decode(
            "023590a94e768f8e1815c2f24b4d80a8e3149316c3518ce7b7ad338368d038ca66",
        ).try_into().unwrap();
        // The funding tx pays `0x5120||Q` (= channel_taproot_script_pubkey) at vout 1,
        // with a decoy P2WPKH at vout 0 (must NOT match — different length/prefix).
        let p2tr = crate::funding::channel_taproot_script_pubkey(&lp, &hop);
        let decoy = {
            let mut v = vec![0x00u8, 0x14];
            v.extend_from_slice(&[0x77u8; 20]);
            ScriptBuf::from(v)
        };
        let tx = Transaction {
            version: Version::TWO,
            lock_time: LockTime::ZERO,
            input: vec![],
            output: vec![
                TxOut { value: Amount::from_sat(5_000), script_pubkey: decoy },
                TxOut { value: Amount::from_sat(1_000_000), script_pubkey: p2tr },
            ],
        };
        let mut raw = Vec::new();
        tx.consensus_encode(&mut raw).unwrap();
        let (vout, sats) = funded_output_taproot(&raw, &lp, &hop).unwrap();
        assert_eq!(vout, 1, "P2TR funding output is at vout 1");
        assert_eq!(sats, 1_000_000);
        // Sorting symmetric: swapping the keys finds the same output.
        let (vout2, sats2) = funded_output_taproot(&raw, &hop, &lp).unwrap();
        assert_eq!((vout2, sats2), (vout, sats));
        // No P2TR output → Err (a P2WSH-only tx must not be mistaken for taproot).
        let p2wsh = crate::funding::p2wsh_script_pubkey(
            &crate::funding::channel_redeem_script(&lp, &hop));
        let only_wsh = Transaction {
            version: Version::TWO, lock_time: LockTime::ZERO, input: vec![],
            output: vec![TxOut { value: Amount::from_sat(7), script_pubkey: p2wsh }],
        };
        let mut raw_wsh = Vec::new();
        only_wsh.consensus_encode(&mut raw_wsh).unwrap();
        assert!(funded_output_taproot(&raw_wsh, &lp, &hop).is_err());
    }
}

// ───────────────────────────── property-based fuzz ────────────────────────────
//
// Generalizes the hand-rolled `*_never_panics*` unit tests above to thousands of
// generated inputs (with shrinking). The ABI encoders + digests take
// attacker-influenced field values, so we fuzz those for the structural
// invariant `calldata.len() % 32 == 4`.
#[cfg(test)]
mod proptests {
    use super::*;
    use proptest::prelude::*;

    fn arb_33() -> impl Strategy<Value = [u8; 33]> {
        (proptest::array::uniform32(any::<u8>()), any::<u8>()).prop_map(|(a, b)| {
            let mut out = [0u8; 33];
            out[..32].copy_from_slice(&a);
            out[32] = b;
            out
        })
    }

    prop_compose! {
        fn arb_open_params()(
            bhash in proptest::array::uniform32(any::<u8>()),
            height in any::<u64>(),
            tx_index in any::<u64>(),
            lp in arb_33(),
            hop in arb_33(),
            amount in any::<u64>(),
            q in proptest::array::uniform32(any::<u8>()),
        ) -> OpenParams {
            OpenParams {
                funding_block_hash_be: bhash,
                funding_block_height: height,
                funding_tx_index: tx_index,
                lp_pubkey: lp,
                hop_pubkey: hop,
                amount_sats: amount,
                funding_taproot: q,
            }
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(512))]

        // (P3) ABI calldata encoders: arbitrary OpenParams + arbitrary-length raw
        // tx + arbitrary proof depth ⇒ never panic, correct selector, and a
        // well-formed (len % 32 == 4) calldata body.
        #[test]
        fn open_channel_calldata_well_formed(
            p in arb_open_params(),
            raw in proptest::collection::vec(any::<u8>(), 0..300),
            proof_len in 0usize..40,
            lp in proptest::array::uniform20(any::<u8>()),
        ) {
            let proof = vec![[0xABu8; 32]; proof_len];
            let cd = encode_open_channel(&p, &raw, &proof, &t_auth(), &t_exits());
            prop_assert_eq!(&cd[..4], &keccak256(
                SIG_OPEN_CHANNEL
            )[..4]);
            prop_assert_eq!(cd.len() % 32, 4);
        }

        #[test]
        fn splice_calldata_well_formed(
            cid in proptest::array::uniform32(any::<u8>()),
            p in arb_open_params(),
            raw in proptest::collection::vec(any::<u8>(), 0..300),
            proof_len in 0usize..40,
        ) {
            let proof = vec![[0xABu8; 32]; proof_len];
            let cd = encode_splice(cid, &p, &raw, &proof, 0);
            prop_assert_eq!(&cd[..4], &keccak256(
                SIG_SPLICE
            )[..4]);
            prop_assert_eq!(cd.len() % 32, 4);
        }

        #[test]
        fn record_close_calldata_well_formed(
            cid in proptest::array::uniform32(any::<u8>()),
            raw in proptest::collection::vec(any::<u8>(), 0..300),
            bhash in proptest::array::uniform32(any::<u8>()),
            proof_len in 0usize..40,
            tx_index in any::<u64>(),
        ) {
            let proof = vec![[0xABu8; 32]; proof_len];
            let cd = encode_record_close(cid, &t_params(), &raw, bhash, &proof, tx_index);
            prop_assert_eq!(cd.len() % 32, 4);
        }

        // (P4) Digests + channelId over arbitrary inputs: never panic, deterministic.
        #[test]
        fn digests_never_panic(
            chain_id in any::<u64>(),
            addr in proptest::array::uniform20(any::<u8>()),
            cid in proptest::array::uniform32(any::<u8>()),
            raw in proptest::collection::vec(any::<u8>(), 0..300),
            p in arb_open_params(),
            txid_int in proptest::array::uniform32(any::<u8>()),
            vout in any::<u32>(),
        ) {
            let a = Address::from(addr);
            let od = open_channel_digest(chain_id, a, &raw, &p, a);
            prop_assert_eq!(od, open_channel_digest(chain_id, a, &raw, &p, a));
            let sd = splice_digest(chain_id, a, cid, &raw, &p);
            prop_assert_eq!(sd, splice_digest(chain_id, a, cid, &raw, &p));
            let c = channel_id(&p.lp_pubkey, &p.hop_pubkey, txid_int, vout);
            prop_assert_eq!(c, channel_id(&p.lp_pubkey, &p.hop_pubkey, txid_int, vout));
        }
    }
}
