// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Types} from "./imports/Types.sol";

/// @title  BandShares — the band's share token. ONE declaration of the per-LP state, TWO instances.
///
/// @notice §SLOP — THIS CONTRACT EXISTS TO DELETE TWELVE DUPLICATED STATE CONCEPTS. Measured on the
///         pre-fold tree, the same per-LP state was declared twice, once in `Vogue` (ETH) and once
///         in `Vault` (BTC), distinguished only by a `BTC` suffix:
///
///           autoManaged ∥ autoManagedBTC · lpShares ∥ lpSharesBTC · selfManaged ∥ selfManagedBtc
///           positions ∥ positionsBtc · ID ∥ ID_BTC · feesPerShare ∥ feesPerShareBTC
///           USD_FEES ∥ USD_FEES_BTC · levPooled ∥ levPooledBTC · levBuf ∥ levBufBTC
///           levBufferUsd ∥ levBufferUsdBTC · totalBuffer ∥ totalBufferBTC
///           LEV_MANAGER ∥ LEV_MANAGER_BTC
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
contract BandShares {
    // ─── identity: what makes the BTC suffix unwritable ───────────────────
    /// The band's volatile asset (WETH or WBTC). The instance IS the asset.
    address public immutable ASSET;
    /// The engine that owns this band's `POOLED`/ring/settlement.
    address public immutable ENGINE;
    /// The band's leverage manager. Was `LEV_MANAGER` ∥ `LEV_MANAGER_BTC`.
    address public LEV_MANAGER;

    string  public name;
    string  public symbol;
    /// 18 for ether, 8 for sats — read from the asset, never hardcoded per instance.
    uint8   public immutable decimals;

    // ─── the position book: `pooled` IS the balance ───────────────────────
    mapping(address => Types.Deposit) public autoManaged;
    /// In-range shares. The FIRST half of `totalSupply`.
    uint public lpShares;

    // ─── out-of-range boundary orders: the SECOND half of `totalSupply` ───
    mapping(uint => Types.SelfManaged) public selfManaged;
    mapping(address => uint[])         public positions;
    uint internal ID;
    /// Running total of out-of-range amounts, so `totalSupply` needs no iteration.
    uint public oorShares;

    // ─── fee accrual ──────────────────────────────────────────────────────
    uint public feesPerShare;
    uint public USD_FEES;
    uint public bookmark;
    uint public venueFeesPerShare;
    mapping(address => uint) public venueBm;

    // ─── leverage slices (debt-funded depth, never equity) ────────────────
    mapping(address => uint) public levPooled;
    mapping(address => uint) public levBuf;
    mapping(address => uint) public levBufferUsd;
    uint public totalLevPooled;
    uint public totalBuffer;

    // ─── recipient pinning ────────────────────────────────────────────────
    /// 🔴 KEEP. This looks like deletable ceremony and is the cross-LP-theft invariant:
    /// `BTCChannels.sol:477-496` — the contract cannot see WHO was paid, only how much reached the
    /// COMMITTED script. Unbinding it lets an LP route a withdrawal elsewhere, making
    /// `_lpFinalBalance` read 0 ⇒ `delivered = shrinkSats` ⇒ over-claim of the SHARED swap-out
    /// proceeds pool. ibiza analysed and rejected exactly this.
    mapping(address => address) public pinnedRecipient;
    mapping(address => address) public pendingRecipient;
    mapping(address => uint)    public recipientUnlockAt;

    /// Anti-same-block: `deposit → swap → withdraw` must not compose atomically to snipe a fee.
    mapping(address => uint) public lastDepositBlock;

    mapping(address => mapping(address => uint)) public allowance;

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    error NotEngine();
    error InsufficientAllowance();

    modifier onlyEngine() { if (msg.sender != ENGINE) revert NotEngine(); _; }

    constructor(address asset_, address engine_, uint8 decimals_, string memory n, string memory s) {
        ASSET = asset_; ENGINE = engine_; decimals = decimals_; name = n; symbol = s;
    }

    // ─── the share face ───────────────────────────────────────────────────

    /// @notice The band's underlying. One `asset()` per instance — which is what having instances
    ///         MEANS, and why ERC-4626 and this architecture stop fighting.
    function asset() external view returns (address) { return ASSET; }

    /// @notice In-range shares PLUS the out-of-range book. See the docblock: disjoint by
    ///         construction, so this is a sum and not a double-count.
    function totalSupply() external view returns (uint) { return lpShares + oorShares; }

    /// @notice The LP's principal in the band — already-compounded. Pending rewards are revealed by
    ///         `previewRedeem`/`pendingRewards`, not here.
    function balanceOf(address user) public view returns (uint) { return autoManaged[user].pooled; }

    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev The engine performs the position move; this contract owns the book, so the mutation
    ///      entry points are `onlyEngine`. That keeps ONE writer for `pooled`, which is the whole
    ///      reason the balance is not a second mapping.
    function moveShares(address from, address to, uint amount) external onlyEngine {
        emit Transfer(from, to, amount);
    }
}
