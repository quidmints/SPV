// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title  VBtc — the EVM face of LN-custodied BTC, segregated out of `Vault` (§J.2).
///
/// @notice WHAT MOVED AND WHY. `Vault` used to carry this ERC-20 face itself ("vBTC == the merged
///         Vault"), which made the Morpho market's `collateralToken` the Vault address. That merge was
///         a deliberate optimisation — `exposeBtcToLev` reclassifies the LP's ALREADY-BANKED channel
///         BTC in one frame with no mint/transferFrom roundtrip — but it also fused two unrelated
///         responsibilities: the TOKEN (supply, balances, transferability) and the BAND ACCOUNTING
///         (`autoManaged`, `levPooled`). This contract owns the first; `Vault` keeps the second.
///
///         THE SPLIT IS EXACT, not a re-design. `Vault.exposeBtcToLev` still performs the whole
///         funded→lev reclassification and its `InsufficientChannelBtc` check — the ONLY thing it
///         delegates here is the supply mutation. `LP.pooled` remains untouched, so the single-count
///         property that made the merge worth having is preserved.
///
///         WHY SEGREGATION IS A PREREQUISITE, NOT COSMETICS (§A.19b + §A.45). vBTC has no BEARER
///         REDEMPTION today, held in place by one invariant: "the LP never receives loose vBTC (that
///         would double-claim the same channel BTC)". That single rule is what blocks BOTH an open
///         Morpho/Euler market (a liquidator who seizes vBTC has no way to exit) AND the privacy story
///         (no bearer instrument). Swap-out already proves the protocol can pay an arbitrary P2TR
///         address whose owner has no channel — so what is missing is an ENTRYPOINT plus a
///         SOURCE-OF-FUNDS rule, not a capability.
///         This contract is where both belong: a future `redeemVBtc(sats, p2trScript)` and the
///         aggregate invariant that must replace the blunt rule — Sigma outstanding vBTC <= Sigma free
///         channel capacity — are SUPPLY-level properties, and supply lives HERE. Putting them in
///         `Vault` would bury a bearer-token invariant inside band accounting.
///
/// 🔴 STOP — DO NOT IMPLEMENT `redeemVBtc(sats, p2trScript)` ON THE STRENGTH OF THE PARAGRAPH ABOVE.
///    Added 2026-08-07. The consuming repo analysed exactly that design and rejected it as a THEFT
///    VECTOR. `../ibiza/TODO.md` §2.4d, quoting `BTCChannels.sol:477-496`:
///      "We REJECT any other output: without this, a malicious LP could route its withdrawal to a
///       script != btcRecipientOf, making `_lpFinalBalance` read 0 -> `delivered = shrinkSats` ->
///       OVER-CLAIM THE SHARED SWAP-OUT PROCEEDS POOL (CROSS-LP THEFT)."
///    The chain cannot see WHO was paid, only HOW MUCH reached the committed script. `btcRecipientOf`
///    (the LP's upfront-shutdown P2TR key) is ONE source of truth for BOTH cooperative-close
///    attribution and the splice path. Paying a caller-supplied script makes `delivered` forgeable.
///    ibiza's verdict: "Unbinding it to gain anonymity would trade a cryptoeconomic invariant for a
///    privacy property — the wrong direction."
///
///    ⚠️ AND THE PREMISE ABOVE IS ITSELF UNVERIFIED. "Swap-out already proves the protocol can pay an
///    arbitrary P2TR address" — the whole "it's only a missing ENTRYPOINT" argument rests on the
///    swap-out path and an LP-WITHDRAWAL path having the same attribution guarantees. That equivalence
///    has never been established, and the quote above indicates they differ. Prove it before building.
///
///    ⚠️ THE PRIVACY MOTIVE IS ALSO GONE. ibiza §2.4d: "vBTC through PP — RULED OUT… NOBODY EVER HOLDS
///    vBTC" — `exposeBtcToLev` mints to the LevManager, not the LP, which supplies it as venue
///    collateral and burns it on close. There is no holder population to form an anonymity set from.
///    ⇒ What REMAINS live from the paragraph above is only the OTHER blocker: an open Morpho/Euler
///    market, where a liquidator who seizes vBTC has no way to exit. Solve that on its own terms.
///    Neither repo references the other, so nothing in SPV surfaces this — hence the warning here,
///    in the file whose header makes the proposal.
contract VBtc {
    string public constant name     = "QuidMint vBTC";
    string public constant symbol   = "vBTC";
    /// vBTC IS sats, so the 4626 valuation below is a pure identity and this must stay 8.
    uint8  public constant decimals = 8;

    uint public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    /// The ONLY address permitted to move supply. Immutable: supply authority is not a runtime setting.
    address public immutable VAULT;
    /// `asset()` handle for the 4626 face — the venue prices vBTC against WBTC via `getTWAPforAsset`.
    address public immutable WBTC;

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    error NotVault();
    error InsufficientBalance();

    constructor(address vault, address wbtc) { VAULT = vault; WBTC = wbtc; }

    modifier onlyVault() { if (msg.sender != VAULT) revert NotVault(); _; }

    /// @notice 4626 valuation face. vBTC IS sats => shares == assets, a pure identity; the venue applies
    ///         the BTC price itself. Kept as a face (not a real vault) because there is nothing to
    ///         convert — the "shares" ARE the underlying unit.
    function asset() external view returns (address) { return WBTC; }
    function convertToAssets(uint shares) external pure returns (uint) { return shares; }
    function convertToShares(uint assets) external pure returns (uint) { return assets; }

    function transfer(address to, uint amt) external returns (bool) {
        uint bal = balanceOf[msg.sender];
        if (bal < amt) revert InsufficientBalance();
        unchecked { balanceOf[msg.sender] = bal - amt; }
        balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint amt) external returns (bool) {
        uint allowed = allowance[from][msg.sender];
        if (allowed != type(uint).max) {
            if (allowed < amt) revert InsufficientBalance();
            unchecked { allowance[from][msg.sender] = allowed - amt; }
        }
        uint bal = balanceOf[from];
        if (bal < amt) revert InsufficientBalance();
        unchecked { balanceOf[from] = bal - amt; }
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
        return true;
    }

    function approve(address spender, uint amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    /// @notice Supply mutations — Vault-only. The Vault performs the funded->lev band reclassification
    ///         and its channel-depth check FIRST; these only move the token face, so vBTC is still only
    ///         ever minted against real, already-banked channel BTC and never conjured.
    function mintTo(address to, uint sats) external onlyVault {
        balanceOf[to] += sats;
        totalSupply   += sats;
        emit Transfer(address(0), to, sats);
    }

    function burnFrom(address from, uint sats) external onlyVault {
        uint bal = balanceOf[from];
        if (bal < sats) revert InsufficientBalance();
        unchecked { balanceOf[from] = bal - sats; totalSupply -= sats; }
        emit Transfer(from, address(0), sats);
    }
}
