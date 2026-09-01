#!/usr/bin/env node
// Perena USD* with a mint authority we can actually sign for.
//
// ⚠️ THE ONE PLACE A FORK CANNOT BE FAITHFUL. `FL.4b` needs USD* balances to
//    deposit, and the real mint authority is Perena's — so `mintTo` fails with
//    OwnerMismatch and the second-registered-mint path has never run.
//
// The mint's ADDRESS, decimals and layout are what the program actually cares
// about (`registered_mints` pins the address; `to_accounting` reads decimals),
// and all three are preserved. Only `mint_authority` is rewritten, to the local
// payer. Supply is zeroed so freshly minted test balances are the whole supply
// rather than a fiction layered on mainnet's.
//
// SPL Mint layout, 82 bytes:
//   0..4   mint_authority COption tag (1 = Some)
//   4..36  mint_authority
//   36..44 supply (u64 LE)
//   44     decimals            45  is_initialized
//   46..50 freeze_authority COption tag        50..82 freeze_authority
import * as fs from "fs";
const [addr, payer, out] = process.argv.slice(2);
const RPC = process.env.FORK_URL || "https://api.mainnet-beta.solana.com";

const bs58 = (s) => {
  const A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let n = 0n; for (const c of s) n = n * 58n + BigInt(A.indexOf(c));
  const b = []; while (n > 0n) { b.unshift(Number(n & 255n)); n >>= 8n; }
  for (const c of s) { if (c === "1") b.unshift(0); else break; }
  return Buffer.from(b);
};

const r = await fetch(RPC, { method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "getAccountInfo",
    params: [addr, { encoding: "base64" }] }) });
const j = await r.json();
if (!j.result?.value) { console.error("no account", addr); process.exit(1); }
const v = j.result.value;
const d = Buffer.from(v.data[0], "base64");
if (d.length !== 82) { console.error("not an SPL mint:", d.length); process.exit(1); }

const auth = bs58(payer);
d.writeUInt32LE(1, 0);       // mint_authority = Some
auth.copy(d, 4);
d.writeBigUInt64LE(0n, 36);  // supply = 0

fs.writeFileSync(out, JSON.stringify({
  pubkey: addr,
  account: { lamports: v.lamports, data: [d.toString("base64"), "base64"],
             owner: v.owner, executable: false, rentEpoch: 0, space: 82 },
}, null, 2));
console.log(`  patched ${addr} → mint authority ${payer}, decimals ${d[44]}`);
