
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILevVenue} from "./Interfaces.sol";
/// @dev §FOLD-BOOK — ONE declaration. They were declared in `LevBase` AND the old
///      the old `LevBookLib`; splitting the book across `RangeLib` and `BtcLib` would have made it FOUR.
///      File-level so every user imports the same selector.
/// @dev §E266 — ONE `WAD` for our tree; it lived in NINE places. Declared HERE and deliberately
///      NOT imported from a vendored file — a compilation restriction on such a file would
///      propagate to every importer (§E267).
uint256 constant WAD = 1e18;

error NotOpen();
error BadTarget();

/// @notice §E299 — eighteen errors that each had two or more identical declarations across the
///         contracts. File-level here means ONE declaration, and every holder keeps the error in
///         its own ABI because a file-level error still lands there for any contract that actually
///         reverts with it.
/// ⛔ THAT LAST CONDITION IS THE WHOLE SELECTION RULE, AND IT EXCLUDED TWENTY NAMES. Measured:
///         `Quid` and `Vault` import this file, never revert `NotOpen`, and `NotOpen` is NOT in
///         their ABIs — so importing is not enough, the contract has to revert with it. Twenty
///         duplicated errors exist precisely BECAUSE the declaring contract never reverts with
///         them: a delegatecalled library does (`BadPercent` in `RangeLib`, running in `Quid`'s
///         context), and the contract declares it only so clients can DECODE that revert. Moving
///         those would strip the error from the ABI while the revert kept firing, leaving callers
///         a bare 4-byte selector. They stay duplicated on purpose; the duplication is the ABI.
error AlreadyInitialized();
error AlreadyOpen();
error BadAsset();
error BadSPV();
error BtcChannelsPinned();
error BtcVaultPinned();
error ChannelKeysMismatch();
error GHOIsAaveWired();
error GHONotOnAAVE();
error InsufficientAllowance();
error InvalidParam();
error LevManagerPinned();
error NotBTCChannels();
error NotFlash();
error Reentrancy();
error Unauthorized();
error VenueNotAllowed();
error WrongRangeManager();


library Types {

    /// @notice One LP's isolated leverage position. §A.71: LevManager and BtcLevManager
    ///         declared this SEPARATELY with identical shape (only the equity field differed,
    ///         e0Eth vs e0Btc). ONE declaration now, per the shared-file rule.
    ///         ⚠️ FIELD ORDER IS ABI-VISIBLE: `pos` is a PUBLIC mapping, so its generated
    ///         getter is a 6-tuple. Reordering or retyping breaks every client that decodes it.
    /// §E358 — `uint64 targetLtvCapBps` REMOVED. IL-protect is a protocol-wide liability, so no LP
    /// carries a debt-to-collateral ratio of its own; the single `LevBase.TARGET_LTV_CAP_BPS` is the
    /// cap for the whole book. ⚠️ `pos` is PUBLIC, so this shrinks its generated getter from a
    /// 6-tuple to a 5-tuple — clients decode by position and must move with it.
    struct Pos { ILevVenue venue; uint128 ilBasisPx; uint128 entryEquity; uint syncKeyPx; bool open; }

    /// @notice Quid
    /// self-managed LP
    /// §RANGE-MERGE — ONE CONFIG FOR BOTH RANGES. `QuidLib.LevCfg{core,aux,weth}` and
    /// `BtcLib.BtcCfg{core,aux}` were the same struct with the ETH one carrying its asset and
    /// the BTC one re-reading WBTC from Aux on every use. One struct, and the asset is named
    /// because a range HAS one -- which is what let the two libraries' bodies stay identical
    /// underneath while their signatures diverged.
    struct RangeCfg { address core; address aux; address asset; }

    /// §RANGE-MERGE — the union of `QuidLib.LevP` and `BtcLib.LevParams`. Both already began
    /// with the SAME three price fields; the ETH one then carried `lm`+`gross` and the BTC one
    /// `mgr`+`gross` plus the two fee accumulators. `lm` and `mgr` were the same thing under two
    /// names (the range's lev manager), which is exactly the drift a shared type removes.
    /// Bundled as ONE memory pointer for the documented reason: these bodies run on the legacy
    /// stack (`via_ir = false`) and a pointer costs less than the fields would.
    struct RangeP {
        uint    spotPrice;
        uint    loPrice;
        uint    upPrice;
        address mgr;          // the range's lev manager (was `lm` on the ETH side)
        uint    gross;        // GROSS collateral target = net equity + debt-funded buffer
        uint    feesPerShare; // BTC side populated these; ETH refreshes bookmarks elsewhere
        uint    usdFees;
        /// (§BOOKMARK-OMITS-THE-COMPOUNDED-FEE) The LP's levered buffer (`levBuf`), captured BEFORE
        /// anything mutates `LP.pooled` so a bookmark refresh can rebuild the GROSS weight as
        /// `LP.pooled + buf` instead of trusting a stale local.
        /// ⚠️ IT LIVES IN THE STRUCT RATHER THAN AS A LOCAL BECAUSE `requestDeposit` IS AT THE
        /// LEGACY STACK LIMIT — one more local there is `Stack too deep`, and `via_ir` is off
        /// deliberately in this repo. One memory pointer costs less stack than one value.
        uint    buf;
    }



    /// @notice Quid LP deposit...
    /// MasterChef-style fee tracking
    struct Deposit { uint pooled;
        uint usd_owed;
        uint fees_tok;
        uint fees_usd;
    }

    /// @notice Native BTC channel — EVM funding/close ANCHOR only.
    ///
    /// Standard-LDK model: the channel's commitment state, revocation, HTLC
    /// resolution, and penalty enforcement all live on Bitcoin/BOLT (LDK
    /// justice txs + watchtowers), NOT on the EVM. The EVM keeps only what it
    /// needs to bridge the channel to the BTC pool position:
    ///   • open  — SPV-prove the 2-of-2 funding UTXO exists → credit the LP's
    ///             BTC pool position (Quid.requestDeposit).
    ///   • close — SPV-prove the funding UTXO was spent (cooperative close or
    ///             LP-refund) → retire the position (Quid.requestRedeem).
    ///
    /// There is deliberately NO commitRoot / latestCommitNum / revocationPoint
    /// / htlcListHash / redeemScriptHash / penalty machinery here — that was
    /// the EVM-anchored layer LDK makes redundant, and it forced a custom LDK
    /// fork. Disputes are Bitcoin-native.
    ///
    /// FIELDS:
    /// `amountSats` — the LP's locked sats == their BTC pool-backing position.
    /// `fundingTxId`/`fundingVout` — the funding UTXO (FIXED for the channel's
    /// EVM life; the EVM never tracks per-commitment respends — those are
    /// off-chain BOLT state). The close proof checks a tx spends this outpoint.
    /// `lpEth` — LP's Ethereum address (recovered signer of openChannel's
    /// lpAuth); owns the pool position and is the close recipient.
    /// `status`: 0 = open, 2 = closed.
    /// (No `hopEth`: it was always the global `hopNode` and never read — see
    /// ChannelLib. The counterparty is surfaced via the ChannelOpened event.)
    ///
    /// Standard LDK channel — NO `selfRefundTime`/CLTV-refund. Unilateral
    /// recovery is an LDK force-close on Bitcoin (commitment tx + justice), not a
    /// bespoke EVM-anchored timelock. The funding 2-of-2 uses the two PER-CHANNEL
    /// LDK funding pubkeys (lp + hop), sorted — matching `make_funding_redeemscript`.
    ///
    /// Identity fields surfaced only via the ChannelOpened event, not stored:
    /// lpPubkey, hopPubkey (33-byte each), fundingBlockHash, fundingBlockHeight.
    struct BTCChannel {
        uint    amountSats;
        bytes32 fundingTxId;
        address lpEth;
        uint32  fundingVout;
        uint8   status;
        // (E164) `hop` IS DELETED. It recorded which EVM address opened the channel and was the
        // SOLE authority for splice / swap-out delivery / dead-man refresh — the MULTI-HOP model,
        // where independent SGX instances coexisted and each channel had to remember its own.
        // With one node plus a hardcoded fallback (`MAIN_HOP`/`FALLBACK_HOP`, immutable), the
        // authorized set is a two-address constant, so per-channel storage bought nothing and
        // COST something: it made the fallback unable to operate any channel the main had opened
        // (§E163). Which of the two opened it survives in the `ChannelOpened` event.
        /// (E153) `keccak256(abi.encode(lpPubkey, hopPubkey))`, pinned at open.
        /// ⚠️ WHY THIS AND NOT A RE-DERIVATION OF `channelId`: `channelId` is
        /// `keccak256(lpPubkey, hopPubkey, fundingTxId, vout)` over the ORIGINAL funding
        /// outpoint, and `_verifySplice` ROTATES that outpoint — so after any splice the
        /// stored `fundingTxId`/`fundingVout` can no longer reproduce `channelId`, and a
        /// key check built on re-derivation fails for exactly the channels most likely to
        /// be closed. This binds the keys to the channel independently of rotation.
        /// It exists so `recordClose` can reconstruct the 2-of-2 and tell a SPLICE from a
        /// CLOSE — which is what lets recording be PERMISSIONLESS instead of restricted to
        /// the hop or the LP.
        bytes32 keysHash;
        /// (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD) The LP's `to_remote` TAPROOT OUTPUT KEY, derived
        /// ONCE at open from the LP's Lightning PAYMENT BASEPOINT and pinned for the channel's life.
        /// The output's scriptPubKey is `0x5120 || lpToRemoteKey`, which is how a force-close
        /// commitment transaction can be asked what it actually paid the LP.
        ///
        /// 🔑 WHY A BASEPOINT AND NOT `lpPubkey` OR `btcRecipientOf`. An LN commitment pays
        /// `to_remote`, which derives from the counterparty's PAYMENT BASEPOINT — not from the
        /// funding key and not from the cooperative-close payout script. And the basepoint is the
        /// only LP-side key that is stable for the channel's LIFE: `lpPubkey` is rotated by every
        /// splice (`new_funding_pubkey(prev_funding_txid)`, §SPLICE-ROTATES-BOTH-FUNDING-KEYS),
        /// whereas `compute_funding_key_tweak` is applied to the funding key ALONE — `pubkeys()`
        /// builds every basepoint from its own untweaked base key, and no LN operation rotates one.
        /// ⚠️ IT IS AN IDENTITY, NEVER AN AUTHORIZATION: the basepoint is public, so proving
        /// knowledge of it proves nothing. It is only ever used to LOCATE an output.
        bytes32 lpToRemoteKey;
    }

    /// @notice Params for BTCChannels.openChannel; lives here so ChannelLib can
    /// reference the same struct without a circular file dependency.
    /// `hopPubkey` is the hop's PER-CHANNEL LDK funding pubkey (33-byte) — the
    /// 2-of-2 uses the two per-channel keys, not a fixed hop identity key.
    ///
    /// the channel funds a key-path MuSig2 P2TR output
    /// `0x5120||fundingTaproot`. `fundingTaproot` is the 32-byte x-only key-path
    /// aggregate `Q = lift_x(KeyAgg(KeySort(lp,hop))) + H_TapTweak(agg)·G` (empty
    /// merkle root). The contract byte-matches the SPV-proven funding output against
    /// `0x5120||Q` AND proves `Q == TapTweak(KeyAgg(KeySort(lp,hop)))` on-chain via
    /// `BitcoinTx` (E129/E142), so both named keys are provably inside it.
    /// ⚠️ TWO CLAIMS THAT STOOD HERE ARE RETIRED, NOT RELOCATED: "the contract does NO
    /// secp256k1 EC math" is false, and "the LP's lpAuth signs the whole OpenParams"
    /// describes a mechanism removed when `openChannel` moved to `(…, address lpEth)` gated
    /// on `_authorizedHop` — `lpAuth` is not a parameter anywhere (E149). Q is bound by the
    /// EC proof now, not by consent to bytes
    /// — and spending the 2-of-2 still requires both parties' MuSig2 signatures
    /// (Bitcoin-enforced, SPV-verified at close). `lpPubkey`/`hopPubkey` remain the
    /// channel identity (channelId + btcRecipient derivation).
    struct OpenParams {
        bytes32 fundingBlockHash;
        uint64  fundingBlockHeight;
        uint    fundingTxIndex;
        bytes   lpPubkey;
        bytes   hopPubkey;
        uint    amountSats;
        bytes32 fundingTaproot;   // 32-byte x-only MuSig2 key-path aggregate Q
    }

    /// @notice (E157) The LP's consent, carried BY the open instead of pre-registered.
    ///
    /// `registerDelegation` existed to establish two things before any channel could open: WHO the
    /// `lpEth` behind a position is, and WHERE its BTC pays out. Both are supplied here and
    /// authenticated inline, so the standing registration — and every piece of state that existed
    /// only to keep it safe — deletes.
    ///
    /// 🔑 WHY THERE IS NO `version`. `delegationVersion` was a monotonic counter guarding a
    /// STANDING grant against replay and rollback. This signature is not standing: it commits to
    /// THIS channel's funding outpoint, and `_useOutpoint` already enforces that a confirmed
    /// funding UTXO backs at most one channel, ever. **Replaying it is not defeated by a counter,
    /// it is arithmetically impossible** — there is no second channel for the bytes to open.
    /// ⇒ The counter's other job (revocation) is also covered: an unused signature binds an
    /// outpoint the LP simply never funds, and a smart wallet can invalidate it by rotating owners.
    ///
    /// ⛔ THE PARAGRAPH THAT STOOD HERE DESCRIBED `lpSig` AS CHECKED WITH `SignatureChecker` —
    /// it described code that §E183 item 1 deleted, eight lines above the struct field that says
    /// so. There is no `lpSig` and no `isValidSignatureNow` anywhere in `evm/src`: the LP signs
    /// NOTHING on the EVM, so the EOA/smart-wallet split that one path existed to serve has no
    /// referent. Do not "restore" it — that would re-add a check for a signature that is gone.
    struct OpenAuth {
        bytes32 btcRecipient;  // x-only P2TR payout key, pinned + locked at open
        /// (E138) BIP-340 signature BY `btcRecipient` over `btcRecipientPoPDigest(lpEth)`.
        /// `_registerBtcRecipient` proves the key is ON THE CURVE (§E130), never that the holder
        /// CONTROLS it — and close, splice-out and the dead-man exit ALL pin to it, so a wrong
        /// key takes every escape at once and is found only after the sats are gone.
        ///
        /// 🔑 (§E183 item 1) THIS IS NOW THE ONLY LP CONSENT IN THE OPEN, AND IT IS A BITCOIN
        /// SIGNATURE. `lpEth` and `lpSig` are DELETED: the address is derived from `p.lpPubkey`
        /// (`ChannelLib.lpEthOf`) rather than supplied, and the EVM signature that used to bind
        /// the submitter and the payout is redundant — `_onlyHop()` binds the first (§E185) and
        /// this PoP binds the second, because its digest COMMITS TO `lpEth`. The LP therefore
        /// signs nothing on the EVM, which is what item 1 asked for.
        /// ⚠️ The previous comment here said this signature was "over `openAuthDigest(hop, …)`".
        /// It never was: `_requireRecipientPoP` verifies it over `btcRecipientPoPDigest(lpEth)`.
        bytes   btcRecipientPoP;
        /// (§FORCE-CLOSE-SKIPS-THE-STALE-GUARD) The LP's 33-byte COMPRESSED Lightning payment
        /// basepoint (`ChannelPublicKeys::payment_point`). Consumed at open to derive
        /// `BTCChannel.lpToRemoteKey` and NOT stored — the derived key is what the contract needs.
        ///
        /// ⚠️ IT LIVES IN `OpenAuth`, NOT `OpenParams`, AND THAT IS DELIBERATE. `OpenParams` is
        /// shared with `splice` / `emitDeadManExit` / `deliverSwapOutOnchain`, where this field
        /// would be dead calldata on every call; `OpenAuth` is the open-only LP-side bundle, which
        /// is exactly what this is. It also keeps `openChannel`'s parameter count unchanged (`B8`
        /// is already counting them).
        /// ⚠️ NOT CONSENT. Unlike `btcRecipientPoP` beside it, this carries no signature and proves
        /// nothing — see `BTCChannel.lpToRemoteKey`. Do not let its neighbours suggest otherwise.
        bytes   lpPaymentPoint;
    }

    /// @notice (E156) The pre-signed dead-man exit that ARMS a channel — supplied at `openChannel`
    /// and refreshed by `emitDeadManExit` for as long as the channel lives.
    ///
    /// ⚠️ WHY THIS IS MANDATORY AT OPEN AND NOT A LATER HEARTBEAT. The fleet holds BOTH funding
    /// halves (`quid-bridge/src/deadman_exit.rs`: *"the hop node's + the vault node's, same
    /// process"*), so the LP has **no funding key and cannot sign anything, ever**. Its only exit is
    /// bytes the fleet pre-signed while alive. The daemon used to produce those on its next
    /// heartbeat tick — its own header says *"a freshly-opened channel is picked up on the NEXT
    /// TICK"* — which left a window where `deadManDeadline == 0`: no exit existed, and if the fleet
    /// died inside it, **no party in the system could ever produce one.** The LP's sats sit in a
    /// 2-of-2 whose both halves died with the fleet.
    /// ⇒ Arming is a CONSTRUCTION-TIME INVARIANT: a channel cannot exist without an escape. That is
    /// what lets the LP-named fallback (E122) delete outright — the recovery story was never "a
    /// nominated hop acts", it was already "the CLTV matures and ANYONE broadcasts the public bytes".
    struct ExitArming {
        /// (E128) Prevout value + scriptPubKey for EVERY input of `signedExitTx`, in input order.
        /// BIP-341 `Prevouts::All` commits to them and they live in EARLIER transactions, so the
        /// chain cannot read them from this one. ⚠️ THE FUNDING ENTRY IS OVERWRITTEN by the
        /// contract with what it already knows — a hop that could supply it would sign a sighash
        /// over a DIFFERENT amount and pass. Only the freshness input's entry is honoured, and a
        /// wrong value there just makes verification fail.
        uint64[] prevValues;
        bytes[]  prevScripts;
        uint64 cltvDeadline;    // absolute BTC height the exit may first confirm at; > tip while alive
        uint   checkpointSats;  // the LP balance these bytes attest (feeds the stale-close guard)
        bytes  signedExitTx;    // the FULLY-signed CLTV exit paying btcRecipientOf
    }

    /// @notice (E159) Everything needed to PROVE an on-chain swap-in deposit. Bundled because the
    /// entrypoint otherwise exceeds the legacy stack, and the house fix is a struct, not `via_ir`.
    ///
    /// `userRefund` + `cltvHeight` are the swap's CLTV refund leaf — with one pinned internal key
    /// they ARE the per-swap identity, and together they determine the deposit address the contract
    /// recomputes. Supplying them wrongly derives a different address and the proof simply fails.
    /// (§T2) The swap-in's ECONOMIC TERMS, folded into ONE struct because they travel together and
    /// are hashed together. Three loose parameters (`seller`, `token`, `minDeliveredUsd`) were the
    /// slop this replaces; more importantly they were UNCOMMITTED — the deposit address bound the
    /// refund leaf and the CLTV height and nothing about what the seller was promised, so a hop
    /// could SPV-prove a genuine deposit and settle it under terms the seller never agreed.
    /// ⛔ **`minDeliveredUsd` WAS HERE AND COULD NOT BE (fixed 2026-08-19, same day it landed).**
    /// The floor is `swap_in_floor_usd(sats, pricePerBtc, slippageBps)` — it SCALES WITH THE SATS
    /// ACTUALLY DEPOSITED, which nobody knows when the address is derived, because the address must
    /// exist before the seller can pay it. Committing it made the address underivable and every
    /// settle would have reverted. **The RATE is what is fixed at registration**, so that is what
    /// the address commits — and the floor is then a pure function of it and the proven sats, which
    /// the contract computes itself. That is strictly stronger: the hop no longer SUPPLIES a floor
    /// at all, so there is nothing to substitute.
    struct Terms {
        address seller;
        address token;
        uint    pricePerBtc;   // stable units per BTC, as quoted to the seller
        uint16  slippageBps;   // tolerance below the quote (the fill settles at the oracle, which can land under spot)
    }

    struct DepositProof {
        bytes32   userRefund;    // x-only key of the deposit's CLTV refund leaf
        uint32    cltvHeight;    // absolute refund height in that leaf
        bytes32   blockHash;     // block the deposit is proven against
        uint      txIndex;
        bytes32[] merkleProof;
    }

    /// @notice routing. `asset` is the volatile side of the swap — WETH for the
    /// ETH pool, WBTC for the BTC pool.
    struct AuxContext {
        address asset;
        address vault;
        address core;
        bool nativeWETH;   // true only for ETH path (unwrap WETH → ETH on delivery)
    }

    struct RouteParams {
        // §DE-TICK — `spotPrice` removed. It carried a packed range-edge PRICE LIMIT for v4's
        // swap; settlement is at oracle bounded by inventory, so there is no limit to carry.
        bool    inputIsUsd;
        address token;
        uint    amount;
        uint    pooled;
        uint    fillPrice;
        address recipient;
        /// §E308 — the swapper's load-balance consent, carried with the trade it affects.
        bool    loadBalance;
    }

}



library SortedSetLib {
    struct Set {
        uint[] sortedArray;
        mapping(uint => bool) exists;
    }

    /// @notice Inserts a value while maintaining sorting order.
    function insert(Set storage self, uint value) internal {
        if (self.exists[value]) return; // Ignore duplicates

        self.exists[value] = true;
        (uint index, ) = binarySearch(self, value);

        self.sortedArray.push(0); // Expand array

        // Shift elements right to insert in the correct position
        for (uint i = self.sortedArray.length - 1; i > index; i--) {
            self.sortedArray[i] = self.sortedArray[i - 1];
        }
        self.sortedArray[index] = value;
    }

    /// @notice Removes a value and triggers automatic cleanup.
    function remove(Set storage self, uint value) internal {
        require(self.exists[value], "Value does not exist");

        (uint index, ) = binarySearch(self, value);
        require(index < self.sortedArray.length
         && self.sortedArray[index] == value, "Value not found");

        self.sortedArray[index] = type(uint).max; // Mark as deleted
        delete self.exists[value]; // ^ max is just a sentinel value

        compactArray(self); // Cleanup on every removal
    }

    /// @notice Binary search to find index for insertion or lookup.
    function binarySearch(Set storage self,
        uint value) internal view returns (uint, bool) {
        uint left = 0; uint right = self.sortedArray.length;

        while (left < right) {
            uint mid = left + (right - left) / 2;
            if (self.sortedArray[mid] == value) {
                return (mid, true); // Value found
            }
            else if (self.sortedArray[mid] < value) {
                left = mid + 1;
            }
            else {
                right = mid;
            }
        }
        return (left, false); // Value not found, return insertion index
    }

    /// @notice Performs automatic cleanup by removing all `0`s.
    function compactArray(Set storage self)
        internal { uint newLength = 0;

        uint[] memory newArray = new uint[](self.sortedArray.length);
        for (uint i = 0; i < self.sortedArray.length; i++) {
            if (self.sortedArray[i] != type(uint).max) {
                newArray[newLength] = self.sortedArray[i];
                newLength++;
            }
        }
        // Resize the array
        self.sortedArray = new uint[](newLength);
        for (uint i = 0; i < newLength; i++) {
            self.sortedArray[i] = newArray[i];
        }
    }

    /// @notice Returns the sorted set.
    function getSortedSet(Set storage self)
        internal view returns (uint[] memory) {
        return self.sortedArray;
    }
}
