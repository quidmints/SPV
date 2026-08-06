# §J.2 — the vault faces: move per-band STATE into `VEth`/`VBtc`, invert the reads

**Status: OPEN, never properly landed.** Scoped 2026-08-06 at the owner's direction (*"some of those
functions are applicable to both veth and vbtc and perhaps some state needs to move out of vogue and
into those contracts, so vogue should read state from those contracts… it needs its own solid effort"*).

This file is the brief for that effort. It is measured, not recalled — every claim below cites
`file:line` as of the commit that added this file.

---

## What actually exists today

**`VEth` / `VBtc` hold ZERO state.** `VEth` is 17 functions, all of them pass-throughs, and every
view delegates outward: `totalSupply()` → `VOGUE.lpShares()`, `balanceOf(u)` → `VOGUE.balanceOf(u)`,
`convertToShares/Assets` → `VOGUE.*`, `transfer*` → `VOGUE.transferSharesFor(...)`. `VBtc` is the
same shape. **The dependency points the wrong way**: the face reads the engine, so the engine still
owns the identity it was supposed to give up.

**The per-band state is split across two contracts, asymmetrically:**

| band | where its state lives | fields |
|---|---|---|
| ETH | **`Vogue.sol`** | `lpShares` `:142`, `feesPerShare` `:140`, `USD_FEES` `:109`, `venueFeesPerShare` `:150`, `venueBm` `:151`, `levPooled` `:162`, `levBuf` `:169`, `levBufferUsd` `:179`, `totalLevPooled` `:155`, `totalBuffer` `:171`, `autoManaged` `:208`, `ethfiBacked` `:84` |
| BTC | **`Vault.sol`** | `lpSharesBTC` `:165`, `feesPerShareBTC` `:166`, `USD_FEES_BTC` `:167` |

So ETH-band state sits on `Vogue` and BTC-band state sits on `Vault`, while the two contracts NAMED
for the bands hold nothing. That asymmetry is the residual matter — not a stray wrapper block.

**And neither `Vogue` nor `VEth` is a valid ERC-4626** (see QUEUE's §J.2 entry): the six mutators
(`deposit` `:1356`/`:1365`, `mint` `:1379`/`:1385`, `redeem` `:1407`, `withdraw` `:1422`) stayed on
`Vogue`, which is no longer an ERC-20; `VEth` has the ERC-20 and the views but no mutators, and
advertises `maxDeposit = type(uint).max` `:70` / `previewDeposit` `:72` with **no `deposit` to call**.

---

## The shape of the work

**1. Move per-band state into its face.** ETH fields out of `Vogue` into `VEth`; the three BTC
fields out of `Vault` into `VBtc`. `Vogue`/`Vault` then READ from the faces instead of owning.

**2. Factor what is common into one shared base.** The owner's point that *"some of those functions
are applicable to both"* is the load-bearing half — these are identical in both bands and must not be
written twice: share accounting (`balanceOf`, `totalSupply`, `convertToShares/Assets`,
`transferSharesFor`), fee accrual (`feesPerShare` + `USD_FEES` and their pending math), and the
recipient-pinning trio (`pinnedRecipient` `:223`, `pendingRecipient` `:224`, `recipientUnlockAt`
`:225`, `RECIPIENT_TIMELOCK` `:226`). One base contract, two instantiations. Per the standing rule,
one declaration — not a copy per band.

**3. Resolve the 4626 fork** (blocking, tracked in QUEUE §J.2). Either `VEth`/`VBtc` FORWARD to
`Vogue`'s mutators, or the mutators move. See constraint C1.

---

## Constraints — price the design against all four BEFORE writing code

**C1 · `../ibiza` pins four signatures.** `PP-SPV-BUFFER-DESIGN.md:24` states, under *"Confirmed,
not assumed"*, that ibiza depends on `Vogue.deposit(uint,address[,uint8])` and
`Vogue.withdraw(uint,address,address)` being plain external functions **on `Vogue`**. ibiza consumes
SPV as a pinned submodule and is not in this working tree. ⇒ **The ENTRY POINTS must stay on
`Vogue`.** Only state and identity move. This is what makes "have `VEth` forward" the cheap option.

**C2 · EIP-170, and it cuts in our favour.** `Vogue` is at 24,166 bytes with **+410 of margin**
(`d4abf93`), and `forge test` does NOT enforce the limit — only `forge build --sizes` does. Moving
state and its accessors OFF `Vogue` is a size WIN on the contract that needs it, paid for in bytes on
`VEth`/`VBtc`, which are small. Measure `--sizes` for all four contracts before and after.

**C3 · Gas, and this is the axis most likely to regress.** Today `Vogue` reads its band state with
`SLOAD`. After the move it would read across a contract boundary — `SLOAD` → external `CALL` — on
paths that run per deposit, per withdraw, and per fee settlement. **That is a money-path cost on the
hottest functions in the repo**, and it is the axis nobody would measure by default. Benchmark the
deposit/withdraw/settle trio before and after; if the delta is material, the answer may be that
`Vogue` keeps a cached mirror and the face owns the canonical copy, or that the faces are libraries
rather than contracts.

**C4 · Storage layout — the window is NOW.** Moving state changes slot layout, which is free while
nothing is deployed and expensive-to-impossible afterwards. None of these contracts are deployed yet.
⇒ **This refactor gets cheaper never.** It should land before any deploy, and that is the strongest
argument for doing it as its own effort rather than deferring again.

---

## Verification the effort must produce

- `forge build --sizes` for `Vogue`, `Vault`, `VEth`, `VBtc`, before and after (C2).
- A gas benchmark of deposit / withdraw / fee-settle, before and after (C3).
- The FULL suite, not `--match-path` — a scoped run is not verification here, because share
  accounting and fee accrual touch nearly every test.
- `tools/check-client-abis.py` — `forge` + `tsc` green does not mean the TypeScript clients survive
  a moved identity.
- A 4626 conformance check against whichever contract ends up claiming the interface: it must have
  BOTH the ERC-20 surface and the four mutators, or it is not a vault.

## What this effort must NOT do

Do not close §J.2 on the identity having moved. That is precisely the error made on 2026-08-05 —
the projection face existed, so the item was marked done, while the state it was supposed to own
stayed behind. **The test of completion is that the faces OWN state and `Vogue` reads from them**,
not that the faces exist.
