// ════════════════════════════════════════════════════════════════════════
//   DB — SQLite storage + prepared queries.
//
//   Two tables:
//     • events  — one row per indexed log. UNIQUE(tx_hash, log_index) makes
//                 ingestion idempotent: a reorg re-scan re-INSERTs the same
//                 (tx,log) keys, and the upsert overwrites block_hash/values
//                 in place rather than duplicating. That is what lets us
//                 re-scan from the cursor every poll without double-counting.
//     • cursor  — single-row marker of the last block we've treated as final
//                 (head - CONFIRMATIONS). Stored separately so the indexer
//                 can resume after a restart without re-backfilling.
//
//   `kind` is 'transfer' (ERC20) or 'channel_open' / 'channel_close'
//   (BTCChannels). For transfers, amount_raw is the token value; for channel
//   events it's the sats (uint), decimals=0. amount_raw is stored as TEXT
//   (decimal string) because uint256 can exceed JS/SQLite-INTEGER range.
// ════════════════════════════════════════════════════════════════════════

import Database from 'better-sqlite3'

export type EventKind = 'transfer' | 'channel_open' | 'channel_close'

export interface EventRow {
  block_number: number
  block_hash: string
  tx_hash: string
  log_index: number
  kind: EventKind
  token: string        // ERC20 contract (transfer) or btcChannels addr (channel)
  from_addr: string    // lowercased; '' for channel events
  to_addr: string      // lowercased; '' for channel events
  amount_raw: string   // decimal string (uint256-safe)
  decimals: number
  ts: number           // block timestamp (unix seconds)
}

const CURSOR_ID = 1

// Prepared statements live in a bag assigned in the constructor — class-field
// initializers run before the constructor body, so `this.db` isn't ready there;
// preparing in the constructor (after migrate) keeps init order correct.
interface Stmts {
  upsert: Database.Statement
  deleteRange: Database.Statement
  getCursor: Database.Statement
  setCursor: Database.Statement
  transfersInWindow: Database.Statement
  channelEventsInWindow: Database.Statement
  firstBlockAtOrAfterTs: Database.Statement
  minBlock: Database.Statement
}

export class Db {
  private db: Database.Database
  private stmts: Stmts

  constructor(path: string) {
    this.db = new Database(path)
    // WAL: concurrent reads (API) while the indexer writes; durable enough.
    this.db.pragma('journal_mode = WAL')
    this.db.pragma('synchronous = NORMAL')
    this.migrate()
    this.stmts = this.prepareAll()
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS events (
        block_number INTEGER NOT NULL,
        block_hash   TEXT    NOT NULL,
        tx_hash      TEXT    NOT NULL,
        log_index    INTEGER NOT NULL,
        kind         TEXT    NOT NULL,
        token        TEXT    NOT NULL,
        from_addr    TEXT    NOT NULL,
        to_addr      TEXT    NOT NULL,
        amount_raw   TEXT    NOT NULL,
        decimals     INTEGER NOT NULL,
        ts           INTEGER NOT NULL,
        UNIQUE(tx_hash, log_index)
      );
      CREATE INDEX IF NOT EXISTS idx_events_block ON events(block_number);
      CREATE INDEX IF NOT EXISTS idx_events_ts    ON events(ts);
      CREATE INDEX IF NOT EXISTS idx_events_kind  ON events(kind);

      CREATE TABLE IF NOT EXISTS cursor (
        id          INTEGER PRIMARY KEY,
        last_block  INTEGER NOT NULL
      );
    `)
  }

  private prepareAll(): Stmts {
    return {
      // Idempotent upsert. ON CONFLICT(tx_hash,log_index) overwrites in place so
      // a reorg re-scan corrects block_hash/block_number/value, no duplicate row.
      upsert: this.db.prepare(`
        INSERT INTO events
          (block_number, block_hash, tx_hash, log_index, kind, token, from_addr, to_addr, amount_raw, decimals, ts)
        VALUES
          (@block_number, @block_hash, @tx_hash, @log_index, @kind, @token, @from_addr, @to_addr, @amount_raw, @decimals, @ts)
        ON CONFLICT(tx_hash, log_index) DO UPDATE SET
          block_number = excluded.block_number,
          block_hash   = excluded.block_hash,
          kind         = excluded.kind,
          token        = excluded.token,
          from_addr    = excluded.from_addr,
          to_addr      = excluded.to_addr,
          amount_raw   = excluded.amount_raw,
          decimals     = excluded.decimals,
          ts           = excluded.ts
      `),
      deleteRange: this.db.prepare(
        `DELETE FROM events WHERE block_number >= ? AND block_number <= ?`),
      getCursor: this.db.prepare(`SELECT last_block FROM cursor WHERE id = ?`),
      setCursor: this.db.prepare(`
        INSERT INTO cursor (id, last_block) VALUES (?, ?)
        ON CONFLICT(id) DO UPDATE SET last_block = excluded.last_block
      `),
      transfersInWindow: this.db.prepare(`
        SELECT token, from_addr, to_addr, amount_raw
        FROM events
        WHERE kind = 'transfer'
          AND block_number > ? AND block_number <= ?
      `),
      channelEventsInWindow: this.db.prepare(`
        SELECT kind, amount_raw
        FROM events
        WHERE (kind = 'channel_open' OR kind = 'channel_close')
          AND block_number > ? AND block_number <= ?
      `),
      firstBlockAtOrAfterTs: this.db.prepare(`
        SELECT MIN(block_number) AS b FROM events WHERE ts >= ?
      `),
      minBlock: this.db.prepare(`SELECT MIN(block_number) AS b FROM events`),
    }
  }

  upsertEvents(rows: EventRow[]): void {
    if (rows.length === 0) return
    const tx = this.db.transaction((batch: EventRow[]) => {
      for (const r of batch) this.stmts.upsert.run(r)
    })
    tx(rows)
  }

  // Drop rows in [from,to] — kept for a deeper-than-CONFIRMATIONS reorg
  // recovery; the unique-key dedup path doesn't need it for normal operation.
  deleteRange(fromBlock: number, toBlock: number): void {
    this.stmts.deleteRange.run(fromBlock, toBlock)
  }

  getCursor(): number | null {
    const row = this.stmts.getCursor.get(CURSOR_ID) as { last_block: number } | undefined
    return row ? row.last_block : null
  }

  setCursor(block: number): void {
    this.stmts.setCursor.run(CURSOR_ID, block)
  }

  // ── Aggregation queries ────────────────────────────────────────────────
  // SQLite has no bigint SUM and amount_raw is uint256-as-TEXT, so we pull the
  // rows for a window and fold them with BigInt in the aggregator.

  transfersInBlockWindow(fromExclusive: number, toInclusive: number): Array<{
    token: string; from_addr: string; to_addr: string; amount_raw: string
  }> {
    return this.stmts.transfersInWindow.all(fromExclusive, toInclusive) as Array<{
      token: string; from_addr: string; to_addr: string; amount_raw: string
    }>
  }

  channelEventsInBlockWindow(fromExclusive: number, toInclusive: number): Array<{
    kind: EventKind; amount_raw: string
  }> {
    return this.stmts.channelEventsInWindow.all(fromExclusive, toInclusive) as Array<{
      kind: EventKind; amount_raw: string
    }>
  }

  // Lowest block_number with ts >= the given unix second — turns a "last N
  // hours" window into a block window using the timestamps we stored.
  firstBlockAtOrAfterTs(ts: number): number | null {
    const row = this.stmts.firstBlockAtOrAfterTs.get(ts) as { b: number | null } | undefined
    return row && row.b !== null ? row.b : null
  }

  minBlock(): number | null {
    const row = this.stmts.minBlock.get() as { b: number | null } | undefined
    return row && row.b !== null ? row.b : null
  }

  close(): void {
    this.db.close()
  }
}
