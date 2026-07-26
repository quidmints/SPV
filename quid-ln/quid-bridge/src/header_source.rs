//! Production [`BtcHeaderSource`] — the SPV relayer's Bitcoin header feed
//! (including reorg recovery). Wraps the hop's shared `Esplora` async client.
//!
//! The relayer calls these methods on `tokio::task::spawn_blocking`, so they run
//! on a BLOCKING thread (not an async context). We therefore `Handle::block_on`
//! the async esplora calls — valid (and the standard pattern) from a
//! spawn_blocking thread on a multi-thread runtime.

use std::sync::Arc;

use bitcoin::consensus::Encodable;
use quid_ln::esplora::Esplora;
use tokio::runtime::Handle;

use crate::relayer::BtcHeaderSource;

/// Esplora-backed header source for the SPV relayer.
pub struct EsploraHeaderSource {
    esplora: Arc<Esplora>,
    rt: Handle,
}

impl EsploraHeaderSource {
    /// `rt` is the daemon's runtime handle (used to drive the async esplora client
    /// from the relayer's blocking threads).
    pub fn new(esplora: Arc<Esplora>, rt: Handle) -> Self {
        Self { esplora, rt }
    }

    fn block_hash(&self, height: u64) -> anyhow::Result<bitcoin::BlockHash> {
        let h = u32::try_from(height)
            .map_err(|_| anyhow::anyhow!("height {height} overflows u32"))?;
        let client = self.esplora.client();
        self.rt
            .block_on(async { client.get_block_hash(h).await })
            .map_err(|e| anyhow::anyhow!("esplora get_block_hash({height}): {e}"))
    }
}

impl BtcHeaderSource for EsploraHeaderSource {
    fn tip_height(&self) -> anyhow::Result<u64> {
        let client = self.esplora.client();
        let h = self
            .rt
            .block_on(async { client.get_height().await })
            .map_err(|e| anyhow::anyhow!("esplora get_height: {e}"))?;
        Ok(h as u64)
    }

    fn header_at(&self, height: u64) -> anyhow::Result<[u8; 80]> {
        let bh = self.block_hash(height)?;
        let client = self.esplora.client();
        let header = self
            .rt
            .block_on(async { client.get_header_by_hash(&bh).await })
            .map_err(|e| anyhow::anyhow!("esplora get_header_by_hash: {e}"))?;
        let mut buf = Vec::with_capacity(80);
        header
            .consensus_encode(&mut buf)
            .map_err(|e| anyhow::anyhow!("encode header: {e}"))?;
        <[u8; 80]>::try_from(buf.as_slice())
            .map_err(|_| anyhow::anyhow!("block header not 80 bytes (got {})", buf.len()))
    }

    fn block_hash_be(&self, height: u64) -> anyhow::Result<[u8; 32]> {
        // Reuse the hop's audited BE-hash helper (matches how the SPVGateway keys
        // blocks — `parseBlockHeader(true)`).
        Ok(quid_hop::spv::block_hash_be(&self.block_hash(height)?))
    }
}
