// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {Types, InsufficientAllowance} from "./imports/Types.sol";  // §E299: file-level errors

/// @title  VBtc — the EVM face of LN-custodied BTC, segregated out of `Vault` (§J.2).
///
/// @notice WHAT MOVED AND WHY. `Vault` used to carry this ERC-20 face itself ("vBTC == the merged
///         Vault"), which made the Morpho market's `collateralToken` the Vault address. That merge was
///         a deliberate optimisation — `exposeBtcToLev` reclassifies the LP's ALREADY-BANKED channel
///         BTC in one frame with no mint/transferFrom roundtrip — but it also fused two unrelated
///         responsibilities: the TOKEN (supply, balances, transferability) and the RANGE ACCOUNTING
///         (`autoManaged`, `levPooled`). This contract owns the first; `Vault` keeps the second.
///
///         THE SPLIT IS EXACT, not a re-design. `Vault.exposeBtcToLev` still performs the whole
///         funded→lev reclassification and its `InsufficientChannelBtc` check — the ONLY thing it
///         delegates here is the supply mutation. `LP.pooled` remains untouched, so the single-count
///         property that made the merge worth having is preserved.
///
///         WHY THIS CONTRACT EXISTS, and it is NOT the reason the header used to give (§ETHVENUE-GHOSTS). The
///         discriminator between `VEth` — deleted — and `VBtc` — kept — is simply WHETHER AN ERC-20
///         UNDERLYING ALREADY EXISTS. On the ETH side one does: WETH is a real token, independently
///         held and redeemable, so the ETH range names `asset() = WETH` and IS the 4626 outright,
///         leaving `VEth` no job. On the BTC side there is none: the underlying is LN-custodied
///         NATIVE BTC, which has no EVM token, and WBTC is only a pricing handle the venue reads
///         through `getTWAPforAsset` — it is never held. So the BTC range must MINT the synthetic
///         underlying it points `asset()` at, and that is what vBTC is.
///         ⇒ `VBtc` survives because THE BTC RANGE HAS NO UNDERLYING UNLESS IT MINTS ONE — not
///         because anyone holds it, custodies it, or anonymises it. An asymmetry with a real
///         reason, and one that survives the §J.2 one-implementation-two-instances merge rather
///         than being dissolved by it. ⚠️ Follow-on to settle when that merge lands: `asset()`
///         below returns WBTC as a pricing handle, but under this design vBTC IS the range's asset
///         rather than having one. Do not carry that accessor across unexamined.
///
/// 🔴 THE HEADER USED TO JUSTIFY THIS CONTRACT ON PRIVACY GROUNDS AND PROPOSE `redeemVBtc(sats,
///    p2trScript)`. BOTH ARE RETIRED. Corrected 2026-08-23; the argument is recorded here rather
///    than deleted, because a proposal that only *sounds* retired gets re-proposed.
///
///    WHAT IT SAID: that segregation was "a prerequisite, not cosmetics" (§A.19b + §A.45) because
///    "the LP never receives loose vBTC" blocks BOTH an open Morpho/Euler market AND the privacy
///    story; that swap-out "already proves the protocol can pay an arbitrary P2TR address whose
///    owner has no channel"; and that a future `redeemVBtc(sats, p2trScript)` plus the aggregate
///    invariant Sigma outstanding vBTC <= Sigma free channel capacity therefore belonged here.
///
///    WHY THE FEATURE IS DEAD — IT IS A THEFT VECTOR. The consuming repo analysed exactly that
///    design and rejected it. `../ibiza/TODO.md` §2.4d, quoting `BTCChannels.sol:477-496`:
///      "We REJECT any other output: without this, a malicious LP could route its withdrawal to a
///       script != btcRecipientOf, making `_lpFinalBalance` read 0 -> `delivered = shrinkSats` ->
///       OVER-CLAIM THE SHARED SWAP-OUT PROCEEDS POOL (CROSS-LP THEFT)."
///    The chain cannot see WHO was paid, only HOW MUCH reached the committed script. `btcRecipientOf`
///    (the LP's upfront-shutdown P2TR key) is ONE source of truth for BOTH cooperative-close
///    attribution and the splice path. Paying a caller-supplied script makes `delivered` forgeable.
///    ibiza's verdict: "Unbinding it to gain anonymity would trade a cryptoeconomic invariant for a
///    privacy property — the wrong direction."
///    ⚠️ AND ITS PREMISE WAS NEVER CHECKED. "Swap-out already proves the protocol can pay an
///    arbitrary P2TR address" — the whole "it's only a missing ENTRYPOINT" argument rests on the
///    swap-out path and an LP-WITHDRAWAL path having the same attribution guarantees. That
///    equivalence has never been established, and the quote above indicates they differ.
///
///    WHY THE PRIVACY MOTIVE IS DEAD. ibiza §2.4d: "vBTC through PP — RULED OUT… NOBODY EVER HOLDS
///    vBTC" — `exposeBtcToLev` mints to the LevManager, not the LP, which supplies it as venue
///    collateral and burns it on close. There is no holder population to form an anonymity set
///    from, so there is nothing to anonymise.
///
///    ⇒ ONE THING FROM THAT PARAGRAPH IS STILL LIVE, and it is a BLOCKER, not a reason to exist:
///    an open Morpho/Euler market, where a liquidator who seizes vBTC has no way to exit. Solve
///    that on its own terms. Do NOT delete `VBtc` on privacy grounds either — the reason above is
///    load-bearing and independent. Neither repo references the other, so nothing in SPV surfaces
///    ibiza's verdict; hence the record here, in the file whose header made the proposal.
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
    /// §E254 (2026-08-18) — `transferFrom` reverted `InsufficientBalance()` when the ALLOWANCE was
    /// short, and this error did not exist. A caller holding plenty of tokens but under-approved was
    /// told their BALANCE was insufficient: a diagnosis that is not merely unhelpful but points the
    /// reader at the wrong account. `Quid` already distinguishes the two.

    constructor(address vault, address wbtc) { VAULT = vault; WBTC = wbtc; }

    /// @dev §MODFOLD — body in a `private view` helper, modifier kept as the jump. A modifier is
    ///      INLINED at every use site, so the two supply mutators carried two copies of the
    ///      immutable load + compare + revert; now one routine and two jumps (CLAUDE.md rule 8c).
    ///      Two sites is the break-even end of that trade, not the profitable end — it is done for
    ///      the same reason as `Vault`'s: ONE declaration of the rule, in one place, so the gate
    ///      cannot drift between mint and burn. The MODIFIER stays rather than calling
    ///      `_onlyVault()` from each body, because a modifier is positionally first by
    ///      construction and `burnFrom` reads `balanceOf[from]` immediately.
    function _onlyVault() private view { if (msg.sender != VAULT) revert NotVault(); }
    modifier onlyVault() { _onlyVault(); _; }

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
            if (allowed < amt) revert InsufficientAllowance();
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

    /// @notice Supply mutations — Vault-only. The Vault performs the funded->lev range reclassification
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
