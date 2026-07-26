//! Static bridge configuration — everything chain-specific is injected here, so
//! the same daemon binary runs against any L1/L2. Nothing is hardcoded.

use alloy_primitives::Address;

/// Configuration for the EVM-sender bridge daemon.
#[derive(Clone, Debug)]
pub struct BridgeConfig {
    /// JSON-RPC endpoint of the target EVM chain. The legacy single-endpoint
    /// field; still honored for back-compat. The EFFECTIVE endpoint list is
    /// `rpc_endpoint_list()` (which falls back to `[rpc_url]` when `rpc_urls` is
    /// empty), so a single-node deployment keeps working unchanged.
    pub rpc_url: String,
    /// Multi-endpoint quorum transport (removes single-RPC trust for the hot
    /// wallet). `rpc_urls[0]` is the PRIMARY — expected to be the self-hosted
    /// node; the rest are cross-check endpoints. EMPTY ⇒ fall back to `[rpc_url]`
    /// (back-compat). See `QuorumJsonRpc` for how spend-gating reads are agreed.
    /// Serde default = empty (so a config file written before this field loads).
    pub rpc_urls: Vec<String>,
    /// How many endpoints must return BYTE-IDENTICAL values for a spend-gating
    /// read (eth_call/getLogs at a pinned block, chainId, blockByHash) before the
    /// daemon acts on it; below quorum the read fails SAFE (defer/retry). Must be
    /// in `[1, effective_len]`. Serde default = 1 (single-node / self-host-only).
    pub rpc_quorum: usize,
    /// EIP-155 chain id (signed-tx replay protection).
    pub chain_id: u64,
    /// The `BTCChannels` contract the hop settles against.
    pub btc_channels: Address,
    /// Confirmations before an EVM tx is treated as final (the swap-out burn
    /// gate; mirrors `quid_hop::swap::evm_final`).
    pub min_confirmations: u64,
    /// Inbound-HTLC CLTV headroom (blocks) required before STARTING a settle.
    /// Below this, fail the HTLC fast rather than deliver USD we can't claim the
    /// BTC for in time (settle-then-claim step 0). Must cover worst-case settle
    /// latency + on-chain confirmation budget + a fee-spike/pinning margin.
    pub min_cltv_headroom_blocks: u32,
    /// Transient-RPC-error retries before leaving the HTLC pending (it then times
    /// out and the seller reclaims — never a silent loss).
    pub settle_max_retries: u32,
    /// Backoff between settle retries.
    pub retry_backoff_secs: u64,

    // --- EIP-1559 gas + receipt polling (settle tx) --- //
    /// `maxFeePerGas` CEILING for a tx (wei). This is a safety cap, NOT the fee we
    /// actually pay: each tx starts from the network's suggested `eth_gasPrice`
    /// (×`fee_bump_pct`/100 per replacement) and is clamped to this ceiling, so a
    /// base-fee spike escalates the fee toward the cap instead of silently
    /// stranding the tx in the mempool.
    pub max_fee_per_gas: u128,
    /// `maxPriorityFeePerGas` floor for a tx (wei). Replacements bump this too.
    pub max_priority_fee_per_gas: u128,
    /// Gas limit for the settle tx.
    pub gas_limit: u64,
    /// How many times to poll for the settle-tx receipt before giving up
    /// (treated as a transient error → retried by the sender loop).
    pub receipt_poll_attempts: u32,
    /// Delay between receipt polls.
    pub receipt_poll_secs: u64,
    /// Same-nonce fee-bump (replace-by-fee) attempts before declaring a tx
    /// unmineable. After each receipt-poll window with no receipt, the tx is
    /// re-signed at the SAME nonce with a higher fee and re-broadcast, so one
    /// underpriced tx can't wedge the shared `onlyHop` nonce. 0 disables
    /// bumping (single shot).
    pub fee_bump_attempts: u32,
    /// Per-replacement fee multiplier, in percent (≥ 113 to clear the node's
    /// +12.5% replace-by-fee floor). E.g. 125 = +25% each bump.
    pub fee_bump_pct: u32,
    /// Settle receipt must be buried under this many EVM confirmations before the
    /// swap-in BTC is claimed — the mirror of the swap-out finality gate. Claiming
    /// on a 0-conf receipt risks an EVM reorg that reverts the settle on the new
    /// branch, leaving the hop having taken BTC with no USD delivered.
    pub settle_min_confirmations: u64,
    /// Max block span per `eth_getLogs` query. After downtime the watcher's
    /// [cursor, tip] gap can exceed provider range/log caps and be rejected
    /// outright; the watchers chunk the scan into spans of at most this many
    /// blocks so a large catch-up still makes progress (L-4).
    pub max_log_block_span: u64,

    // --- on-chain swap-out watcher --- //
    /// Delay between `eth_getLogs` polls for `SwapOutRequestedOnchain`.
    pub swap_out_poll_secs: u64,

    // --- BTC Vault --- //
    /// The `Vault` contract (`btcFeesOwedSats` ledger + the fee-flush target). (The
    /// separate LP-fee settler was retired; fees compound in-channel.)
    pub btc_vault: Address,

    // --- SPV header relayer --- //
    /// The `SPVGateway` contract the relayer feeds Bitcoin headers to.
    pub spv_gateway: Address,
    /// Max headers per `addBlockHeaderBatch` submission.
    pub relay_batch_max: u64,
    /// Gas limit for a header-batch submission (scales with batch size).
    pub relay_gas_limit: u64,
    /// Delay between relayer polls.
    pub relay_poll_secs: u64,
    /// Max Bitcoin-reorg depth the relayer recovers from. On a header-batch
    /// revert (the source's best chain diverged below the gateway head), the
    /// relayer walks back up to this many blocks to find the fork point where the
    /// source hash still matches a block the gateway knows, then resubmits the
    /// competing branch from there so the gateway can reorg. A reorg deeper
    /// than this needs manual intervention (logged loudly).
    pub relay_reorg_lookback: u64,
    /// How often (seconds) the channel reconciler re-scans LDK monitors vs
    /// on-chain state to drive any missed `openChannel`/`recordClose` (the
    /// restart/failure safety net for the event-driven channel driver).
    pub channel_reconcile_secs: u64,
    /// H-4 (tiered ceilings + relayer-defer): the SPV header relayer shares the
    /// hop's single hot key/nonce with the time-critical swap settlers. Under a
    /// swap burst the relayer's header tx can queue behind theirs. To keep
    /// settlement (HTLC deadlines) ahead of header relay (which tolerates minutes
    /// — Bitcoin blocks are ~10 min), the relayer DEFERS a round when in-flight
    /// swap settlements reach this count. A TIER below the swap-out concurrency
    /// ceiling (`MAX_CONCURRENT_SWAP_OUTS`) so the relayer yields FIRST; bounded
    /// swaps drain and the relayer resumes. 0 = never defer.
    pub relayer_defer_inflight: usize,
}

impl BridgeConfig {
    /// The EFFECTIVE JSON-RPC endpoint list the daemon builds its quorum transport
    /// from. Back-compat: an empty `rpc_urls` falls back to the single `rpc_url`,
    /// so an existing single-node config (or one that only sets `rpc_url`) is
    /// unchanged. `[0]` is the primary (self-hosted) node.
    pub fn rpc_endpoint_list(&self) -> Vec<String> {
        if self.rpc_urls.is_empty() {
            vec![self.rpc_url.clone()]
        } else {
            self.rpc_urls.clone()
        }
    }

    /// Validate the cross-field invariants the docs above state but nothing else
    /// enforces. A bare struct let several footguns through (the prior audit's
    /// M-A/M-D): a priority fee above the max-fee ceiling (silently clamped), a
    /// fee-bump percent too small to clear the node's replace-by-fee floor (so a
    /// bump is rejected as underpriced), or zeroed gas/conf/poll knobs. The daemon
    /// MUST call this at startup and refuse to run on error.
    pub fn validate(&self) -> Result<(), String> {
        if self.chain_id == 0 {
            return Err("chain_id must be nonzero (EIP-155 replay protection)".into());
        }
        // A zero contract address would silently sign txs to / read logs from the
        // null address. verify_btc_channels_has_code catches a code-less
        // btc_channels at startup, but the others are never code-checked.
        if self.btc_channels == Address::ZERO
            || self.btc_vault == Address::ZERO
            || self.spv_gateway == Address::ZERO
        {
            return Err("btc_channels / btc_vault / spv_gateway must be nonzero addresses".into());
        }
        if self.max_fee_per_gas == 0 {
            return Err("max_fee_per_gas must be > 0".into());
        }
        if self.max_priority_fee_per_gas > self.max_fee_per_gas {
            return Err(format!(
                "max_priority_fee_per_gas ({}) must be <= max_fee_per_gas ({}); the \
                 priority fee is silently clamped to the ceiling otherwise",
                self.max_priority_fee_per_gas, self.max_fee_per_gas
            ));
        }
        // A replace-by-fee must raise the fee by the node's pricebump floor (geth/
        // reth default 10%); we require ≥12.5% headroom, so the bump percent must
        // be at least ~113% or no replacement is ever accepted.
        if self.fee_bump_pct < 113 {
            return Err(format!(
                "fee_bump_pct ({}) must be >= 113 to clear the ~12.5% replace-by-fee floor",
                self.fee_bump_pct
            ));
        }
        if self.gas_limit == 0 || self.relay_gas_limit == 0 {
            return Err("gas_limit and relay_gas_limit must be > 0".into());
        }
        if self.min_confirmations == 0 || self.settle_min_confirmations == 0 {
            return Err("min_confirmations and settle_min_confirmations must be >= 1".into());
        }
        if self.receipt_poll_attempts == 0 {
            return Err("receipt_poll_attempts must be >= 1".into());
        }
        if self.relay_batch_max == 0 {
            return Err("relay_batch_max must be >= 1".into());
        }
        if self.max_log_block_span == 0 {
            return Err("max_log_block_span must be >= 1".into());
        }
        // L-3: the watcher loops `sleep(Duration::from_secs(poll_secs))` between
        // polls; a 0 interval hot-spins the loop — pegging a core and hammering the
        // RPC with no delay. (Tests construct BridgeConfig directly with 0 for
        // instant loops and never call validate(), so flooring here is prod-only.)
        if self.swap_out_poll_secs == 0
            || self.relay_poll_secs == 0
        {
            return Err(
                "swap_out_poll_secs / relay_poll_secs must be >= 1 \
                 (a 0 interval hot-spins the watcher loop)"
                    .into(),
            );
        }
        // Multi-endpoint quorum transport bounds (single-RPC-trust removal). The
        // effective list (rpc_urls, or [rpc_url] for back-compat) must be non-empty
        // and the quorum must fit within it. Single-node / self-host-only is allowed
        // (len == 1 ⇒ quorum 1); we do NOT require quorum >= 2 at len >= 3 — that's
        // an operator policy choice, not a correctness invariant.
        let effective = self.rpc_endpoint_list();
        if effective.is_empty() || effective.iter().all(|u| u.trim().is_empty()) {
            return Err(
                "no JSON-RPC endpoint configured (set rpc_url or rpc_urls)".into(),
            );
        }
        let len = effective.len();
        if self.rpc_quorum < 1 {
            return Err("rpc_quorum must be >= 1".into());
        }
        if self.rpc_quorum > len {
            return Err(format!(
                "rpc_quorum ({}) exceeds the {} configured RPC endpoint(s)",
                self.rpc_quorum, len
            ));
        }
        if len == 1 && self.rpc_quorum != 1 {
            return Err(format!(
                "single RPC endpoint requires rpc_quorum == 1 (got {})",
                self.rpc_quorum
            ));
        }
        Ok(())
    }

    /// STAGING/PROD hardening (untrusted-host M11). The fund-gating AGREEMENT reads
    /// (`btcRecipientOf`, `swapInUsed`, `pendingOnchainSwapOut`, `freshnessSeq`,
    /// `lpFeePaid`, `migrationNonceUsed`) are only meaningful if a MAJORITY of
    /// INDEPENDENTLY-operated endpoints must concur. Base `validate()` permits a single
    /// endpoint (self-host, host trusted); under an untrusted host that is single-host
    /// trust — the host forges every read (redirect fee payouts, claim BTC without USD,
    /// slip a rolled-back monitor). So staging/prod additionally require:
    ///   * `>= 2` endpoints,
    ///   * `rpc_quorum >= 2` (agreement over one endpoint is not agreement), and
    ///   * a STRICT MAJORITY (`2*quorum > len`) so no two DISJOINT quorums can each
    ///     "agree" on conflicting data (a host running half the endpoints can't split-brain).
    /// This upgrades the H-2 boot warning to a fail-closed invariant. Full closure of the
    /// EVM path (contract-addr / chain-id bound into MRENCLAVE, not host env) remains the
    /// architectural residual — see the "EVM key into enclave" M11 item.
    pub fn validate_hardened(&self) -> Result<(), String> {
        self.validate()?;
        let len = self.rpc_endpoint_list().len();
        if len < 2 {
            return Err(format!(
                "staging/prod requires >= 2 independently-operated RPC endpoints (got \
                 {len}); a single host-controlled endpoint defeats the agreement reads"
            ));
        }
        if self.rpc_quorum < 2 {
            return Err(format!(
                "staging/prod requires rpc_quorum >= 2 (got {}); agreement over one \
                 endpoint is single-host trust",
                self.rpc_quorum
            ));
        }
        if 2 * self.rpc_quorum <= len {
            return Err(format!(
                "staging/prod requires a STRICT MAJORITY quorum (2*{} > {} endpoints) so \
                 two disjoint endpoint sets cannot each 'agree' on conflicting data",
                self.rpc_quorum, len
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid() -> BridgeConfig {
        BridgeConfig {
            rpc_url: "http://localhost:8545".into(),
            rpc_urls: Vec::new(),
            rpc_quorum: 1,
            chain_id: 8453,
            btc_channels: Address::repeat_byte(0xBC),
            min_confirmations: 6,
            min_cltv_headroom_blocks: 40,
            settle_max_retries: 3,
            retry_backoff_secs: 0,
            max_fee_per_gas: 1_000_000_000,
            max_priority_fee_per_gas: 1_000_000,
            gas_limit: 300_000,
            receipt_poll_attempts: 3,
            receipt_poll_secs: 1,
            fee_bump_attempts: 3,
            fee_bump_pct: 125,
            settle_min_confirmations: 2,
            max_log_block_span: 10_000,
            swap_out_poll_secs: 5,
            btc_vault: Address::repeat_byte(0xFA),
            spv_gateway: Address::repeat_byte(0x5B),
            relay_batch_max: 100,
            relay_gas_limit: 5_000_000,
            relay_poll_secs: 5,
            relay_reorg_lookback: 144,
            channel_reconcile_secs: 300,
            // Defer header relay once 20 swap settlements are in flight — a tier
            // below MAX_CONCURRENT_SWAP_OUTS (30) so the relayer yields its nonce
            // to time-critical settlement first.
            relayer_defer_inflight: 20,
        }
    }

    #[test]
    fn valid_config_passes() {
        assert!(valid().validate().is_ok());
    }

    #[test]
    fn priority_above_ceiling_rejected() {
        let mut c = valid();
        c.max_priority_fee_per_gas = c.max_fee_per_gas + 1;
        assert!(c.validate().is_err(), "priority > ceiling must be rejected");
    }

    #[test]
    fn fee_bump_pct_too_small_rejected() {
        let mut c = valid();
        c.fee_bump_pct = 105; // < 113 → can't clear the RBF floor
        assert!(c.validate().is_err());
    }

    #[test]
    fn zero_poll_interval_rejected() {
        // L-3: a 0 watcher poll interval hot-spins the loop.
        for set in [
            |c: &mut BridgeConfig| c.swap_out_poll_secs = 0,
            |c: &mut BridgeConfig| c.relay_poll_secs = 0,
        ] {
            let mut c = valid();
            set(&mut c);
            assert!(c.validate().is_err(), "a 0 poll interval must be rejected");
        }
    }

    #[test]
    fn zero_confirmations_rejected() {
        let mut c = valid();
        c.settle_min_confirmations = 0;
        assert!(c.validate().is_err());
    }

    #[test]
    fn rpc_endpoint_list_falls_back_to_rpc_url() {
        let c = valid(); // rpc_urls empty
        assert_eq!(c.rpc_endpoint_list(), vec!["http://localhost:8545".to_string()]);
        let mut c2 = valid();
        c2.rpc_urls = vec!["a".into(), "b".into()];
        assert_eq!(c2.rpc_endpoint_list(), vec!["a".to_string(), "b".to_string()]);
    }

    #[test]
    fn single_endpoint_requires_quorum_one() {
        let mut c = valid(); // one effective endpoint (rpc_url)
        c.rpc_quorum = 2;
        assert!(c.validate().is_err(), "quorum 2 with one endpoint must be rejected");
        c.rpc_quorum = 1;
        assert!(c.validate().is_ok());
    }

    #[test]
    fn quorum_must_fit_endpoint_count() {
        let mut c = valid();
        c.rpc_urls = vec!["a".into(), "b".into(), "c".into()];
        c.rpc_quorum = 2;
        assert!(c.validate().is_ok(), "2-of-3 is valid");
        c.rpc_quorum = 4;
        assert!(c.validate().is_err(), "quorum > endpoints rejected");
        c.rpc_quorum = 0;
        assert!(c.validate().is_err(), "quorum < 1 rejected");
    }

    #[test]
    fn hardened_requires_strict_majority_multi_endpoint() {
        // Single endpoint / quorum 1: fine for base validate (self-host), REJECTED hardened.
        let mut c = valid();
        assert!(c.validate().is_ok());
        assert!(
            c.validate_hardened().is_err(),
            "single host-controlled endpoint must be rejected in staging/prod"
        );
        // 2-of-2 → strict majority (2*2 > 2) → OK.
        c.rpc_urls = vec!["http://a".into(), "http://b".into()];
        c.rpc_quorum = 2;
        assert!(c.validate_hardened().is_ok(), "2-of-2 is a strict majority");
        // 2-of-3 → strict majority (2*2 > 3) → OK.
        c.rpc_urls = vec!["http://a".into(), "http://b".into(), "http://c".into()];
        c.rpc_quorum = 2;
        assert!(c.validate_hardened().is_ok(), "2-of-3 is a strict majority");
        // 2-of-4 → NOT a strict majority (2*2 == 4): disjoint {a,b}/{c,d} could each
        // "agree" → host split-brain. REJECTED.
        c.rpc_urls = vec!["a".into(), "b".into(), "c".into(), "d".into()];
        c.rpc_quorum = 2;
        assert!(c.validate_hardened().is_err(), "2-of-4 is not a strict majority");
        // 3-of-4 → strict majority (2*3 > 4) → OK.
        c.rpc_quorum = 3;
        assert!(c.validate_hardened().is_ok(), "3-of-4 is a strict majority");
    }

    #[test]
    fn empty_effective_list_rejected() {
        let mut c = valid();
        c.rpc_url = String::new();
        c.rpc_urls = Vec::new(); // effective = [""] → all-empty
        assert!(c.validate().is_err(), "no endpoint configured must be rejected");
    }
}
