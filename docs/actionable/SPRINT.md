# SPRINT — what is NOT finished

Everything below was worked on in this thread and is **open**. Finished work is not listed; it is in
`QUEUE.md` with its evidence. **Start here, then read the named `QUEUE.md` row for the measurements.**

⚠️ Two rules this sprint exists because of:
- **A green test whose gas number exceeds a block is not a pass** (§E232 — cost a reverted commit).
- **Five of six full-suite runs this session were void** (endpoint noise). Screen `403`, `429`,
  `database error`, `error sending request`, `could not instantiate forked` — *all five* — and read
  the **exit code**, not the screen counts: `exit=2` is forge refusing its arguments, i.e. zero tests
  ran and every counter reads clean.

---

## 🔴 P0 — a live defect on the money path

### 1. The observation ring is circular (§E222, §E232)
`Core:841/:951` write the ring from `AUX.getTWAPforAsset`, which **reads that same ring** and anchors
to Chainlink. The ring records itself plus Chainlink, so `twapResolve`'s deviation test and
`BasketLib.isManipulated` compare one source against a smoothed copy of itself. **Nothing reverts —
the guards compute, they have lost the ability to disagree.**

**Kick off from:** `ExternalTwap.curvePriceWad` — already written, ~single storage read.
- **ETH:** `price_oracle(1)` on `CURVE_TRICRYPTO_USDC` (**k=1 is WETH — k=0 is WBTC**; the old
  comment was off by one, corrected in `6e442a4c`).
- **Bound:** derived, **37–74 bps** (`ma_time = 600s` vs our 1800s window ⇒ ~300s lag difference ⇒
  ~18.5 bps at 1σ). **Do NOT inherit `TWAP_MAX_DEVIATION_BPS = 500`** — that is ~27σ here and would
  never fire.
- **BTC:** gets **nothing**. Curve quotes WBTC, so the wrapper objection survives the change of
  venue. The check is **deleted**, not pointed at a wrapper — see §3 below.
- **The read must not be able to halt the band:** raw `staticcall`, and any failure skips the write.
  The ring goes stale, σ² decays to unmeasured, §E213's sentinel prices at the ceiling. Degrade,
  never halt. (1inch was rejected here: `getRate` iterates 14 oracles and costs **31.7M gas**,
  above the block limit — §E232.)

---

## 🟠 P1 — decisions that block other work

### 2. `calcFeeL1` needs TWO changes or neither (§E209, §E227)
It compares a **weight-blind** numerator against a **weight-aware** baseline — a $1k leg and a $1M
leg at the same rate score identically. **But it saturates at a 0.30pp spread**, so a
marginal-contribution rewrite alone produces the same number on nearly every real input. Fix the
dimension **and** recalibrate `MAX_FEE`/scaling together, or the "fix" is invisible.

### 3. BTC has no wrapper-free observation, and that is structural (§E221, §E223, §E224)
Native BTC has **no EVM presence**, so every on-chain "BTC" price is a wrapper. The anchor is already
clean (Chainlink `"BTC / USD"`). What is open: `VBtc.asset()` returns **WBTC** while vBTC **is** the
ERC-20 the async 7540 points at — `Vault` has no `asset()` at all, and `VBtc`'s three 4626 accessors
have **zero call sites**. Decide: delete them and give the band manager `asset() = vBTC`.
- The `WBTC/BTC` feed (`0xfdFD…BB23`, currently **1.00039110** = 3.91 bps) is **wired nowhere**, so
  the basis is unmeasured. It is the direct instrument if a depeg detector is wanted.

### 4. `swapFeePpm() = 420` is now our policy, not v4's tier (§E226)
It used to mirror `k.fee = 420` and be harvested by `_handleCollect`. With v4 gone **the fill charges
it**, so it must be justified on its own terms. Never has been.

---

## 🟡 P2 — the folds, with measured feasibility

### 5. Core + Vogue → one contract (§E217, §E219, §E231)
`Core` 10,073 + `Vogue` 21,925 = **31,998, over EIP-170 by 7,422** as a naive sum. But the EthVenue
fold measured **1,984 bytes against 3,836 standalone (~52%)**, because a separate contract carries
dispatch and interface overhead that vanishes. At that ratio ≈ **27,135, over by ~2,559**.
⚠️ **52% is NOT linear** — the saving is mostly fixed overhead, so it is optimistic for large
contracts. The only honest number comes from doing the fold.
⚠️ **The merged manager carries a permanent ETH-only appendage:** ETH venue custody has no BTC
counterpart (BTC custody is Lightning, not 4626 venues), so it is not a symmetric merge.

### 6. LevManager + BtcLevManager → one contract, two instances
23,753 + 20,617 = **44,370, over by 19,794** naively; at 52% ≈ **34,416, over by ~9,840**. The sum
**double-counts `LevBase`**, which is `abstract` and therefore inlined into both bytecodes. Overlap
measured: **16 shared function names, 33 ETH-only, 15 BTC-only**. `LevBase` and `LevVenueBase` are
**not** duplicates — manager-base vs venue-base, different layers.

### 7. Ring sizing (§E207)
`Observation[65535]`, sole reader asks for **9**. Storage is sparse so it costs nothing at deploy;
the real win is that `65535` is **not a power of two**, so `% 65535` emits a full `MOD` on the swap
hot path where `[32]` emits `AND`. *(The v4-cut branch sized it 1024 — verify what landed.)*

---

## 🟢 P3 — smaller, unblocked

### 8. The remaining `Alles.t.sol` clusters (§E230)
33 fail, **identical before and after the v4 cut** — pre-existing, not the cut's residue. Three roots:
**24 × `OverCommitted()`** (owned by the `BackingGateSplit` thread — a silent `basketUsd` drift the
newly-armed gate exposed; do not double-fix), **6 × `priming funded POOLED_USD: 0 <= 0`**, and
**6 × arithmetic underflow**. The last two are **unclaimed**.

### 9. BOLD's route and its depeg exemption (§E216, §E224)
BOLD is `stables[13]`, a full basket member, and `_routableStable(BOLD) == false` — so a real basket
leg is **skipped and refunded** by `consolidate` rather than routed, against a pool holding **~$7.0M
quoting at par** (`0xEFc65163…`, **BOLD idx 0 / USDC idx 1**). Separately it is the only stable with
no depeg feed, and `getDepegSeverityBps` returns **0 = healthy** for an unfeeded stable — a
fail-open. Decide whether that is a property of the instrument or a feed nobody found.

### 10. v4-core dependency removal
Backed out once as premature — **11 symbols across 7 files** still need it (`IPoolManager`×3,
`PoolKey`×2, `Currency`×2, `StateLibrary`, `SafeCallback`, `PoolIdLibrary`, `BalanceDelta`).
Order: retire the last `SafeCallback` user → relocate `FullMath` (pure math, nothing v4 about it,
pinning the whole library) → the pool-shaped types go with the last interfaces.

### 11. A `redeemVBtc` entrypoint is cheap — but NOT with a script parameter (§verified)
`VBtc.sol:18-28` claims swap-out "proves the protocol can pay an arbitrary P2TR". **It does not.**
`requestSwapOutOnchain` takes **no destination argument**; it builds
`_lpPayoutScript(msg.sender)` from `btcRecipientOf`, which `setBtcRecipient` gates on a
possession proof and locks for channel LPs. So redeem reusing `_lpPayoutScript` is **safe and adds no
surface**; the `p2trScript` parameter is the entire cost and is what ibiza rejected as cross-LP theft.
**Fix that header — it currently argues for the rejected design.**

---

## Environment facts that cost time this session

- **`BTCChannels` and `Vogue` trade places as the binding contract** (24,438/138 → 23,760/816 while
  `Vogue` went 21,925 → 24,018/558). **Re-measure before planning any addition; never quote a margin
  from this file.**
- **`///` natspec on a file-level constant is a COMPILE ERROR**, not a lint warning.
- **`--match-path` cannot be passed twice** — forge exits `2` and runs nothing.
- **A shared tree eats uncommitted work.** Three sets of edits were lost to other threads'
  `autostash` this session, once *between* a green build and reading its result. **Commit first.**
