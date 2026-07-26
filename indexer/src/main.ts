// ════════════════════════════════════════════════════════════════════════
//   MAIN — wire config → db → indexer loop + api server.
//
//   `npm start`            backfill, then live-poll, and serve the API.
//   `npm run backfill`     (--backfill-only) backfill to head-CONFIRMATIONS and
//                          exit, without entering the live loop or serving.
// ════════════════════════════════════════════════════════════════════════

import { loadConfig, protocolAddrs, ZERO_ADDR } from './config'
import { Db } from './db'
import { Indexer } from './indexer'
import { startApi } from './api'

async function run(): Promise<void> {
  const backfillOnly = process.argv.includes('--backfill-only')
  const cfg = loadConfig()

  console.log('[main] QU!D indexer starting')
  console.log(`[main] rpc=${cfg.rpcUrl} db=${cfg.dbPath} startBlock=${cfg.startBlock} conf=${cfg.confirmations} chunk=${cfg.chunkSize}`)
  const prot = protocolAddrs(cfg)
  if (prot.length === 0) {
    console.warn('[main] WARNING: no protocol contract addresses set (all 0x0). ' +
      'Transfers cannot be attributed to the protocol — set QUID_BASKET/QUID_AUX/QUID_VOGUE ' +
      'post-deploy. The indexer will run but record zero stable/ETH flow until then.')
  }
  if (cfg.contracts.btcChannels === ZERO_ADDR) {
    console.warn('[main] WARNING: QUID_BTC_CHANNELS unset (0x0) — BTC sats flow will be zero.')
  }

  const db = new Db(cfg.dbPath)
  const indexer = new Indexer(cfg, db)

  if (backfillOnly) {
    await indexer.start(true)
    db.close()
    return
  }

  // Live mode: serve immediately (health reflects backfill progress), then run
  // the indexer. start() backfills first, then enters the poll loop.
  const server = startApi(cfg, db, indexer)

  const shutdown = () => {
    console.log('[main] shutting down')
    indexer.stop()
    server.close()
    db.close()
    process.exit(0)
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)

  await indexer.start(false)
}

run().catch(err => {
  console.error('[main] fatal:', err)
  process.exit(1)
})
