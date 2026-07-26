//! (#114 / W.0) DEAD-MAN EXIT WATCHTOWER — a standalone, KEYLESS, hostable daemon.
//!
//! Run ≥3 REDUNDANT instances (foundation + LPs). Each independently polls the EVM for
//! matured `DeadManExitEmitted` events across ALL channels and broadcasts the already-
//! public signed bytes to a public Bitcoin mempool. NO key, NO signer, NO fleet state,
//! NO EigenLayer — it deliberately survives the fleet dying, which is the whole point of
//! a dead-man exit. This is the "runs without EigenLayer" liveness guarantee (§W W.0);
//! the AVS overlay (§W W.1+) only decentralizes the operator set on top of this.
//!
//! It reuses the exact keyless primitives of `quid-recover-exit` (the one-shot CLI) —
//! here wrapped in a discover-all + poll loop so one hosted process protects every LP.
//!
//! Usage:
//!   quid-watchtower --rpc <EVM_RPC_URL> --contract <BTCChannels_addr> \
//!                   --esplora <ESPLORA_BASE_URL> [--interval-secs 60] [--once]
//!
//!   --once   run a single pass and exit (for cron / testing) instead of looping.

use std::{thread, time::Duration};

use anyhow::{anyhow, Result};
use quid_bridge::recovery_broadcast::{watchtower_tick, RecoverOutcome};

fn arg(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1).cloned())
}

/// Lowercase hex of a 32-byte channel id (no external hex dep in the bin).
fn hexid(b: &[u8; 32]) -> String {
    let mut s = String::with_capacity(64);
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

fn main() {
    if let Err(e) = run() {
        eprintln!("quid-watchtower: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let rpc = arg(&args, "--rpc").ok_or_else(|| anyhow!("missing --rpc <EVM_RPC_URL>"))?;
    let contract =
        arg(&args, "--contract").ok_or_else(|| anyhow!("missing --contract <BTCChannels addr>"))?;
    let esplora =
        arg(&args, "--esplora").ok_or_else(|| anyhow!("missing --esplora <ESPLORA_BASE_URL>"))?;
    let interval = arg(&args, "--interval-secs")
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(60);
    let once = args.iter().any(|a| a == "--once");

    eprintln!(
        "quid-watchtower: keyless dead-man broadcaster — contract {contract}, poll {interval}s{}",
        if once { " (single pass)" } else { "" }
    );

    loop {
        match watchtower_tick(&rpc, &contract, &esplora) {
            Ok(results) => {
                let (mut watched, mut broadcast, mut live) = (0usize, 0usize, 0usize);
                for (ch, r) in &results {
                    watched += 1;
                    match r {
                        Ok(RecoverOutcome::Broadcast(txid)) => {
                            broadcast += 1;
                            // A dead-man fired: an LP's fleet went dark and we recovered it.
                            println!("BROADCAST channel 0x{} → btc txid {txid}", hexid(ch));
                        }
                        Ok(RecoverOutcome::NotMatured(_, _)) => live += 1, // fleet still alive
                        Ok(RecoverOutcome::NoExit) => {} // channel never armed an exit
                        Err(e) => eprintln!("  channel 0x{}: {e}", hexid(ch)),
                    }
                }
                println!(
                    "quid-watchtower tick: {watched} watched, {broadcast} broadcast, {live} still-live"
                );
            }
            // A whole-tick failure (RPC/Esplora down) must NOT kill the watchtower — log
            // and retry next interval; redundant instances cover a transient outage.
            Err(e) => eprintln!("quid-watchtower tick failed (retrying): {e:#}"),
        }
        if once {
            break;
        }
        thread::sleep(Duration::from_secs(interval));
    }
    Ok(())
}
