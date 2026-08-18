// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./imports/Types.sol";

/// @title  Shares — the band's share token. ONE declaration of the per-LP state, TWO instances.
///
/// @notice §SLOP — THIS CONTRACT EXISTS TO DELETE TWELVE DUPLICATED STATE CONCEPTS. Measured on the
///         pre-fold tree, the same per-LP state was declared twice, once in `Quid` (ETH) and once
///         in `Vault` (BTC), distinguished only by a `BTC` suffix:
///
///           autoManaged ∥ autoManaged · lpShares ∥ lpShares · selfManaged ∥ selfManaged
///           positions ∥ positions · ID ∥ ID · feesPerShare ∥ feesPerShare
///           USD_FEES ∥ USD_FEES · levPooled ∥ levPooled · levBuf ∥ levBuf
///           levBufferUsd ∥ levBufferUsd · totalBuffer ∥ totalBuffer
///           LEV_MANAGER ∥ LEV_MANAGER
///
///         The suffix existed ONLY because both copies sat in contracts that each hardcoded their
///         asset. That is the `isBTC` argument one level down: a source-level selector
///         standing in for what having instances means. Here the CONTRACT IDENTITY carries the
///         asset, so the suffix cannot be written — there is one `feesPerShare`, and two of it.
///
/// @dev    WHY THE BALANCE IS HAND-ROLLED AND MUST STAY THAT WAY (this is the one place standing
///         rule 8 does not apply). `balanceOf(user)` IS `autoManaged[user].pooled` — the balance is
///         the LP POSITION, and a transfer moves position state (fee bookmarks, lev slice), not a
///         number. Inheriting solmate/OZ's ERC20 would introduce a SECOND balance source that must
///         be kept in sync with `pooled`: precisely the drift class this refactor exists to delete.
///         Only the allowance machinery is stock, and that is not worth a base class.
///
/// @dev    `totalSupply` SPANS BOTH POSITION KINDS. `lpShares` is the in-range book (against the
///         engine's `POOLED`); the remainder is the out-of-range boundary orders. They are DISJOINT
///         BY CONSTRUCTION — `sizeOorUsd` requires a boundary order to sit wholly outside the active
///         band — so the sum cannot double-count. Anything reading `totalSupply` as "depth in the
///         band" is reading it wrong.
///
/// ⚠️ NOT YET WIRED. The state and the share face live here; the engine still owns the band
///    (`POOLED`, the ring, skew, settlement). Migration order is in
///    `docs/actionable/ONE-ENGINE-TWO-SHARE-TOKENS.md`.

/// @title  State — the 13 per-LP declarations both band managers had a private copy of
///
/// @notice §E252. `Quid` (ETH) and `Vault` (BTC) each declared these THIRTEEN names, and a
///         declaration-by-declaration diff showed them BYTE-IDENTICAL — same types, same visibility,
///         differing only in the order they appeared in their own file. One declaration now, two
///         instances, which is the same argument `Core` already won one level down.
///
/// @dev    ⚠️ WHAT THIS BUYS IS NOT BYTECODE — IT IS STORAGE LAYOUT, and that distinction is the
///         whole point. State variables emit no runtime code, so hoisting them frees ZERO bytes
///         (unlike the function-body extractions in §E241/§E245, which freed ~100–514 B each).
///         What it buys is that both managers now lay these members out IDENTICALLY, in the same
///         order, at the same slots relative to the base — which is the PRECONDITION for one
///         implementation with two instances. Merging the managers while their slots disagreed
///         would produce two contracts that cannot share an implementation at all.
///
/// @dev    ⚠️ DELIBERATELY EXCLUDES THE ERC-20 FACE. `name`, `symbol`, `decimals`, `totalSupply`
///         and `allowance` are declared in `Shares` AND in `Quid`, but NOT in `Vault` — the BTC
///         band's share face is `VBtc`, a separate token. Hoisting those five would collide with
///         Quid and give Vault a face it does not use. The band STATE is shared; the share FACE
///         is per-asset, and that asymmetry is real (§A.19b: vBTC has no bearer redemption).
abstract contract State {
    /// The band's leverage manager. GOV pin-once, then frozen.
    address public LEV_MANAGER;

    // ─── the position book: `pooled` IS the LP's balance ───
    mapping(address => Types.Deposit) public autoManaged;
    /// In-range shares, against the engine's `POOLED`.
    uint public lpShares;

    // ─── out-of-range boundary orders (disjoint from the in-range book by construction) ───
    mapping(uint => Types.SelfManaged) public selfManaged;
    mapping(address => uint[])         public positions;
    uint internal ID;

    // ─── fee accumulators — PER-SHARE, not dollars (see CLAUDE.md: multiply back by the
    //     credit site's own share base before reading either as an amount) ───
    uint public feesPerShare;
    uint public USD_FEES;

    // ─── the levered slice: SUBSET MARKERS over `autoManaged[lp].pooled`, never a second
    //     bucket (§E250 verified every consumer subtracts via `plainNet` and none adds) ───
    mapping(address => uint) public levPooled;
    mapping(address => uint) public levBuf;
    mapping(address => uint) public levBufferUsd;
    uint public totalBuffer;

    /// The band's price anchor; bounds are `updateBounds(anchor, BAND_DELTA)` about it.
    uint public BAND_ANCHOR;
}
