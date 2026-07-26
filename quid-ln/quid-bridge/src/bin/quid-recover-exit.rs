//! (#114) `quid-recover-exit` — the STATELESS, KEYLESS dead-man-exit broadcaster.
//!
//! Reads the latest on-chain `DeadManExitEmitted` event for a channel and, if the
//! CLTV has matured (the fleet stopped its heartbeat), broadcasts the already-signed
//! exit tx to a public Bitcoin mempool. No key, no signing, no stored state — it only
//! publishes bytes that are already public on the EVM. The LP (or any watchtower /
//! keeper) runs this to recover the last checkpoint balance to `btcRecipientOf`.
//!
//! Usage:
//!   quid-recover-exit --rpc <EVM_RPC_URL> --contract <BTCChannels 0x…> \
//!                     --channel <channelId 0x… 32 bytes> --esplora <ESPLORA_BASE_URL> \
//!                     [--force]
//!
//! Exit status: 0 on Broadcast, 0 on NotMatured/NoExit (informational), 2 on error.

use anyhow::{anyhow, Context, Result};
use quid_bridge::recovery_broadcast::{recover_and_broadcast, RecoverOutcome};

fn arg(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
}

fn parse_channel_id(s: &str) -> Result<[u8; 32]> {
    let s = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s);
    let bytes = alloy_primitives::hex::decode(s).context("channel id hex")?;
    let arr: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("channel id must be exactly 32 bytes (got {})", bytes.len()))?;
    Ok(arr)
}

fn main() {
    if let Err(e) = run() {
        eprintln!("quid-recover-exit: error: {e:#}");
        std::process::exit(2);
    }
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let rpc = arg(&args, "--rpc").ok_or_else(|| anyhow!("missing --rpc <EVM_RPC_URL>"))?;
    let contract =
        arg(&args, "--contract").ok_or_else(|| anyhow!("missing --contract <BTCChannels addr>"))?;
    let channel = arg(&args, "--channel").ok_or_else(|| anyhow!("missing --channel <channelId>"))?;
    let esplora =
        arg(&args, "--esplora").ok_or_else(|| anyhow!("missing --esplora <ESPLORA_BASE_URL>"))?;
    let force = args.iter().any(|a| a == "--force");

    let channel_id = parse_channel_id(&channel)?;
    match recover_and_broadcast(&rpc, &contract, channel_id, &esplora, force)? {
        RecoverOutcome::NoExit => {
            println!("no dead-man exit has been emitted for this channel yet");
        }
        RecoverOutcome::NotMatured(tip, deadline) => {
            println!(
                "exit found but NOT broadcastable: bitcoin tip {tip} < CLTV deadline {deadline} \
                 (the fleet is still alive; re-run after the deadline). Use --force to override."
            );
        }
        RecoverOutcome::Broadcast(txid) => {
            println!("broadcast dead-man exit: txid {txid}");
        }
    }
    Ok(())
}
