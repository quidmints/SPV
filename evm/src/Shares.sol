// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./imports/Types.sol";
import {ILevEquity} from "./imports/Interfaces.sol";   // §FOLD-LEVGROSS
import {LevManagerPinned, WrongRangeManager} from "./imports/Types.sol";   // §FOLD-PINLEV

/// @title  Shares — the range's share token. ONE declaration of the per-LP state, TWO instances.
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
/// @dev    ⛔ THIS FILE HAS NO `totalSupply` AND NO `oorShares` — it declares STATE and zero
///         functions. A previous version described a `totalSupply` spanning `lpShares + oorShares`;
///         neither half exists (`oorShares`: zero references in `evm/src` and `evm/test`). The live
///         face is `Quid.totalSupply() { return lpShares; }` — grep the SYMBOL, a line cite here
///         drifted within days. The out-of-range book (`selfManaged`/`positions`/`oorBook`) is
///         per-order with NO aggregate count, so boundary orders are absent from every share total
///         by construction. ⇒ §E255's "settle the `totalSupply` semantics first" blocker had no
///         subject; what blocks the merge is EIP-170, nothing here.
///
/// ⚠️ NOT YET WIRED. The state and the share face live here; the engine still owns the range
///    (`POOLED`, the ring, skew, settlement). Migration order is in
///    `docs/actionable/SPRINT.md §DOCS-FOLD/ONE-ENGINE-TWO-SHARE-TOKENS`.

/// @title  State — the 13 per-LP declarations both range managers had a private copy of
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
///         ⚠️ CORRECTED: the ERC-20 allowance machinery is declared ONLY in `Quid`, NOT here.
///         This file declares STATE and no functions at all — a previous version of this line
///         claimed a duplication across `Shares` and `Quid` that does not exist, in the one file
///         whose purpose is preventing duplication.
///         range's share face is `VBtc`, a separate token. Hoisting those five would collide with
///         Quid and give Vault a face it does not use. The range STATE is shared; the share FACE
///         is per-asset, and that asymmetry is real (§A.19b: vBTC has no bearer redemption).
abstract contract Shares {
    /// The range's leverage manager. GOV pin-once, then frozen.
    address public LEV_MANAGER;

    /// @notice §FOLD-PINLEV — ONE SETTER, TWO INSTANCES. `Quid.setLevManager` and
    ///         `Vault.setLevManager` were the same three statements — pin-once, key-check, assign —
    ///         against the `LEV_MANAGER` THIS contract already declares. Only two things genuinely
    ///         differed, and both are now the ONLY things a face supplies.
    /// @dev    ⚠️ THE AUTH ASYMMETRY IS REAL AND IS PRESERVED, NOT UNIFIED. ETH pins from `DEPLOYER`,
    ///         BTC from `Ownable`. Collapsing them to one model would either hand the BTC pin to an
    ///         address `Ownable` never granted, or make the ETH pin unreachable the moment ownership
    ///         is renounced — a live posture here (`docs/FAQ.md` Part 6). A virtual keeps the
    ///         difference DECLARED at each face instead of hidden in a shared branch.
    function _onlyPinner() internal view virtual;

    /// @dev The asset this range's manager must serve — the discriminator that used to be spelled
    ///      `isBTC`. It is the INSTANCE that carries it now, which is the whole point of the fold.
    function _rangeAsset() internal view virtual returns (address);

    /// @notice Pin the leverage manager. Pin-once: a second call reverts rather than re-pointing a
    ///         live money path at a new contract.
    function setLevManager(address m) external {
        _onlyPinner();
        if (LEV_MANAGER != address(0)) revert LevManagerPinned();
        if (ILevEquity(m).ORACLE_KEY() != _rangeAsset()) revert WrongRangeManager();
        LEV_MANAGER = m;
    }

    /// @notice §FOLD-LEVGROSS — ONE DEFINITION FOR BOTH RANGES. `Quid.levGrossNative` and
    ///         `Vault.levGrossNative` were the same three statements against the same `LEV_MANAGER`
    ///         slot that already lives HERE — a fail-open read of the lev book's gross collateral.
    ///         They differed only in whether the pin was copied to a local first.
    /// @dev    FAIL-OPEN IS LOAD-BEARING, NOT DEFENSIVE: this feeds the well skew's locked-inventory
    ///         basis, and a revert in a venue-iterating read must never brick a swap. Returning 0
    ///         relaxes the skew toward the base oracle curve — a pricing signal, not a backing gate.
    /// ⚠️      The unit is the RANGE'S OWN native one — wei on the ETH instance, sats on the BTC one.
    ///         It is not comparable across instances, and nothing should sum the two.
    function levGrossNative() external view returns (uint) {
        address m = LEV_MANAGER;
        if (m == address(0)) return 0;
        try ILevEquity(m).totalGrossCollateral() returns (uint g) { return g; } catch { return 0; }
    }

    // ─── the position book: `pooled` IS the LP's balance ───
    mapping(address => Types.Deposit) public autoManaged;
    /// In-range shares, against the engine's `POOLED`.
    uint public lpShares;

    // ─── §OOR-BOOK-DELETED (2026-08-29) — there is no out-of-range book any more ───
    // `selfManaged`, `positions`, `ID` and `oorBook` lived here: a struct, a per-owner id array and
    // a trigger-price sorted set, WRITTEN AT REST for orders that might never fill. A resting order
    // is now a signed intent (§OOR-AS-INTENT) and the only storage it touches is one consumed bit,
    // written AT THE FILL — `Quid.intentUsed[owner][nonce]`.
    // ⭐ AND THE DELETION IS A PRIVACY FIX AS MUCH AS A SIZE ONE: `selfManaged[id].owner` plus
    //   `positions[owner]` published a permanent, public link from an address to its intentions,
    //   for orders that may never fill — shrinking the anonymity set every withdrawer relies on,
    //   for no accounting benefit. The chain stores P&L attribution and withdrawability; a resting
    //   order is neither until it fills.
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

    /// The range's price anchor; bounds are `updateBounds(anchor, RANGE_DELTA)` about it.
    uint public RANGE_ANCHOR;
}
