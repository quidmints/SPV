// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {InsufficientAllowance} from "./imports/Types.sol";  // §E299: file-level errors
import {IVBtcRange} from "./imports/Interfaces.sol";
import {BitcoinTx} from "./imports/BitcoinTx.sol";

/// @title  VBtc — the ERC-20 face of the BTC range's shares. vBTC IS sats AND vBTC IS the share.
///
/// @notice ⭐ §R-9 + §R-vBTC (owner ruling, 2026-09-09) — **THE TOKEN IS THE SHARES.** *"this is a
///         strange 7540 where there really is no `asset()` and shares dichotomy in the 4626 sense.
///         the token is the shares… as an lp you have lp shares as well, that is a share of fees.
///         so as long as the btc is locked its earning fees. if you transfer the vbtc to someone
///         else, the share of fees transfers with it."*
///
///         ⇒ **THIS CONTRACT HOLDS NO BALANCES.** `balanceOf` and `totalSupply` are PROJECTIONS of
///         the BTC range's own book (`Vault.autoManaged[u].pooled` and `Vault.lpShares`), exactly as
///         `Quid`'s ERC-20 face projects the ETH range's, and `transfer` MOVES THE POSITION — which
///         is the only way the owner's sentence above can be true: a balances mapping beside
///         `pooled` would be one quantity written twice, and a transfer of it would move the claim
///         while leaving the fee stream behind. The only state left here is `allowance`, which is
///         genuinely the token's (it authorises a spender, not a position).
///
///         ⇒ **AND THE MINT/BURN PAIR IS GONE WITH THE BALANCES.** There is no `mintTo`/`burnFrom`
///         to point at the wrong account, because supply is not a second thing that has to be kept
///         in step with the range: every sat of channel-locked BTC is credited as `pooled` by
///         `Vault.requestDeposit` and retired by `Vault.resize`/`requestRedeem`, so
///         `Σ outstanding vBTC == Σ channel-locked BTC` HOLDS BY CONSTRUCTION rather than by a
///         guard that could be forgotten at a new call site (standing rule 17: make the bad state
///         unconstructible, don't make it detectable).
///
///         ⇒ **ELIGIBILITY IS ALL CHANNEL-LOCKED BTC, NOT THE LEVERED SLICE.** vBTC used to be
///         minted ONLY inside `exposeBtcToLev`, and only to `LEV_MANAGER`. Both are fixed: the
///         levered slice is now just a non-transferable SUBSET MARKER over the LP's own shares
///         (`levPooled`, enforced by the `plainNet` cap in `BtcLib.transferSharesBody`), and the
///         lev manager holds nothing at any point.
///
/// @notice WHY THIS CONTRACT STILL EXISTS AT ALL, and it is NOT privacy (§ETHVENUE-GHOSTS). The
///         discriminator between `VEth` — deleted — and `VBtc` — kept — is WHETHER AN ERC-20
///         UNDERLYING ALREADY EXISTS. On the ETH side one does: WETH is a real token, so the ETH
///         range names `asset() = WETH` and IS the 4626 outright. On the BTC side there is none —
///         the underlying is LN-custodied NATIVE BTC, which has no EVM token — so the BTC range
///         needs an ERC-20 face of its own. `Quid` can BE its face because it is itself a contract
///         LPs address; the BTC range's face has to be a separate address only because venues and
///         integrators take a token address, not because it owns anything the range does not.
///
/// @dev    `asset()` returns WBTC and that is still honest: it is a PRICING HANDLE (the venue
///         prices sats via `getTWAPforAsset(WBTC)`), never a redeemable underlying and never held.
///         The conversions are the identity because vBTC IS sats, which is also why `decimals` is 8.
contract VBtc {
    string public constant name     = "QuidMint vBTC";
    string public constant symbol   = "vBTC";
    /// vBTC IS sats, so the 4626 valuation below is a pure identity and this must stay 8.
    uint8  public constant decimals = 8;

    /// The BTC range manager. It owns the book this token is a face over, so it is the ONLY address
    /// permitted to move a position. Immutable: share authority is not a runtime setting.
    address public immutable VAULT;
    /// `asset()` handle for the 4626 face — the venue prices vBTC against WBTC via `getTWAPforAsset`.
    address public immutable WBTC;

    /// The token's ONE piece of own state: who may spend on whose behalf. Balances are the range's.
    mapping(address => mapping(address => uint)) public allowance;

    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
    /// @notice §R-vBTC — a holder retired `sats` of shares against a Bitcoin payout to `p2trScript`.
    ///         The script is emitted rather than stored: the obligation is the hop's to fulfil from
    ///         channel capacity, and an on-chain claim ledger would be the reservation variable the
    ///         owner refused (rule 23). The burn is what bounds it — you cannot retire shares twice.
    event Redeemed(address indexed holder, uint sats, bytes p2trScript);

    /// §E254 (2026-08-18) — a short ALLOWANCE must not be reported as a short BALANCE: a diagnosis
    /// that points the reader at the wrong account. `InsufficientAllowance` is the file-level one.
    error BadPayoutKey();

    constructor(address vault, address wbtc) { VAULT = vault; WBTC = wbtc; }

    // ─────────────────────── the projection (no balances live here) ───────────────────────

    /// @notice Supply == the range's share total. One number, read where it is written.
    function totalSupply() public view returns (uint) { return IVBtcRange(VAULT).totalShares(); }

    /// @notice Balance == the holder's position, fees already compounded in. `pendingRewards` on the
    ///         range is the disclosure surface for what has accrued but not yet been crystallised.
    function balanceOf(address user) public view returns (uint) {
        return IVBtcRange(VAULT).sharesOf(user);
    }

    /// @notice 4626 valuation face. vBTC IS sats => shares == assets, a pure identity; the venue
    ///         applies the BTC price itself. `asset()` is a pricing handle (see the header), which
    ///         is the whole of what a `asset()`-less 7540 can honestly return.
    function asset() external view returns (address) { return WBTC; }
    function convertToAssets(uint shares) external pure returns (uint) { return shares; }
    function convertToShares(uint assets) external pure returns (uint) { return assets; }

    // ─────────────────────────────────── movement ───────────────────────────────────
    // Both entrypoints delegate the whole move to the range, which crystallises BOTH parties' fees
    // before principal moves (so the moved sats carry no past claim) and caps the amount at the
    // FREE, non-levered slice. The range reverts on a short balance; nothing is checked twice here.

    function transfer(address to, uint amt) external returns (bool) {
        IVBtcRange(VAULT).transferShares(msg.sender, to, amt);
        emit Transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint amt) external returns (bool) {
        uint allowed = allowance[from][msg.sender];
        if (allowed != type(uint).max) {
            if (allowed < amt) revert InsufficientAllowance();
            unchecked { allowance[from][msg.sender] = allowed - amt; }
        }
        IVBtcRange(VAULT).transferShares(from, to, amt);
        emit Transfer(from, to, amt);
        return true;
    }

    function approve(address spender, uint amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    /// @notice ⭐ §R-vBTC — RETIRE `sats` OF SHARES AGAINST A BITCOIN PAYOUT TO `p2trKey`.
    ///
    ///         This is the entrypoint the header used to forbid, and the owner lifted the ⛔:
    ///         *"claim is fungible but the amount is the amount… how could it ever possibly
    ///         overclaim?"* The old objection was cross-LP theft through over-claiming the shared
    ///         swap-out proceeds pool. It was aimed at the wrong end of the pipe: vBTC is a
    ///         pro-rata claim on ONE pool of channel-locked BTC, so redeeming against any channel's
    ///         BTC is the DESIGN. Theft would require vBTC that no locked BTC backs, and that is a
    ///         MINT-side property — here, the fact that shares only ever come from a channel
    ///         funding transaction `BTCChannels` observed.
    ///
    ///         Redemption and swap-out delivery DO draw on the same sats, and that is also the
    ///         design (owner, 2026-09-09): one pool, two exit paths, the way an AMM's withdrawals
    ///         and its swaps both consume the same depth. Whoever draws first gets the sats; the
    ///         other waits for capacity. ⛔ Do NOT add a reservation, a pending-claim ledger or a
    ///         `deliverableBTC` subtraction to arbitrate that — the burn already bounds it, and the
    ///         extra variable is what rule 23 refuses.
    ///
    /// @param  p2trKey the x-only BIP-340 key to pay. VERIFIED ON THE CURVE, because ~half of all
    ///         32-byte typos land on a valid x-coordinate and the other half do not: an off-curve
    ///         destination is BTC paid to a script nobody can ever spend, and the failure is
    ///         otherwise silent (§E130 established exactly this for `setBtcRecipient`). The
    ///         scriptPubKey is BUILT here from the proven key — `0x5120||Q`, the same one
    ///         `BitcoinTx` builds everywhere else — so there is no caller-supplied blob to shape-check.
    function redeemVBtc(uint sats, bytes32 p2trKey) external returns (bool) {
        if (!BitcoinTx.isValidXOnlyKey(p2trKey)) revert BadPayoutKey();
        IVBtcRange(VAULT).redeemVBtc(msg.sender, sats);
        emit Transfer(msg.sender, address(0), sats);
        emit Redeemed(msg.sender, sats, BitcoinTx.buildTaprootScriptPubKey(p2trKey));
        return true;
    }
}
