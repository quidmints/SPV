// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedRateFill} from "./imports/FixedRateFill.sol";

/// @title  BatchLedger — who owes what after a batched rebalance (§28, Phase 3 step 2)
///
/// @notice Settlement charges an ESTIMATE; the keeper's rebalance produces the REALISED cost; this
///         contract holds the difference until it is claimed. It exists because the two events are
///         separated in time BY DESIGN — the keeper batches so gas amortises — and a swapper has
///         usually left before their batch closes.
///
///         STANDALONE, NOT FOLDED INTO `Aux`, FOR A MEASURED REASON. `Aux` has 1,321 bytes of
///         EIP-170 margin today and is the natural home once v4 leaves (it is where `swap`/`swapTo`
///         live, so settlement would write this state locally). But the mapping-heavy accounting
///         below plus the claim path will not fit ALONGSIDE the v4 machinery that is still there.
///         ⇒ Keep it separate now, and fold it into `Aux` in the same cut that drops `SafeCallback`
///         — that is the change that frees the room. Folding earlier means measuring twice.
///
/// @dev    THE FLOW: `record` (per swap, from the settler) → `close` (once, from the keeper, with the
///         measured cost) → `claim` (per participant, whenever). Plus `forceRefund`, which is the
///         part that is easy to leave out and expensive to leave out.
contract BatchLedger {
    /// One participant's stake in a batch. `skewWad` is their contributed imbalance (the attribution
    /// key); `estimate` is what they were charged at settlement.
    struct Entry { uint128 skewWad; uint128 estimate; }

    struct Batch {
        uint64  openedAt;
        bool    closed;
        uint256 totalSkewWad;   // denominator for the pro-rata split
        uint256 totalEstimate;  // what was collected up front
        uint256 swapperPot;     // the swapper-attributed slice of realised cost (set on close)
    }

    /// @notice After this, an unclosed batch may be refunded by ANYONE. See `forceRefund`.
    uint64 public constant STRAND_TIMEOUT = 7 days;

    address public immutable SETTLER;   // the swap entry (Aux) — the only writer of `record`
    address public immutable KEEPER;    // the only closer

    uint256 public currentBatch;
    mapping(uint256 => Batch) public batches;
    mapping(uint256 => mapping(address => Entry)) public entryOf;
    /// Owed back to a participant. PULL, not push: the swapper has usually left, and a push payment
    /// in a loop over participants is both a gas bomb and a griefing surface (one reverting receiver
    /// blocks everyone else's true-up).
    mapping(address => uint256) public claimable;

    event Recorded(uint256 indexed batchId, address indexed who, uint256 skewWad, uint256 estimate);
    event Closed(uint256 indexed batchId, uint256 realisedCost, uint256 swapperPot, bool inRange);
    event Claimed(uint256 indexed batchId, address indexed who, uint256 owed, uint256 refund);
    event ForceRefunded(uint256 indexed batchId);

    error NotSettler();
    error NotKeeper();
    error BatchClosed();
    error BatchOpen();
    error NothingRecorded();
    error AlreadyClaimed();
    error NotStrandedYet();

    constructor(address settler, address keeper) { SETTLER = settler; KEEPER = keeper; }

    modifier onlySettler() { if (msg.sender != SETTLER) revert NotSettler(); _; }
    modifier onlyKeeper()  { if (msg.sender != KEEPER)  revert NotKeeper();  _; }

    /// @notice Record a swap's contributed imbalance and the estimate charged for it.
    /// @dev    Accumulates on repeat: the same address swapping twice in one batch has ONE entry with
    ///         both contributions summed, so it cannot claim twice off two rows.
    function record(address who, uint256 skewWad, uint256 estimate) external onlySettler {
        uint256 id = currentBatch;
        Batch storage b = batches[id];
        if (b.closed) revert BatchClosed();
        if (b.openedAt == 0) b.openedAt = uint64(block.timestamp);

        Entry storage e = entryOf[id][who];
        e.skewWad  += uint128(skewWad);
        e.estimate += uint128(estimate);
        b.totalSkewWad  += skewWad;
        b.totalEstimate += estimate;
        emit Recorded(id, who, skewWad, estimate);
    }

    /// @notice Close the batch with the MEASURED rebalance cost and open the next one.
    /// @param  realisedCost a BALANCE DELTA over the Curve legs — never a number the rebalance path
    ///         reports about itself. A cost the code self-reports cannot detect the case where the
    ///         rebalance silently moved nothing.
    /// @param  inRange whether the band was in range for this batch — selects the weight set, and
    ///         `splitCost` will not let it default.
    function close(
        uint256 realisedCost,
        FixedRateFill.Split calldata inRangeSplit,
        FixedRateFill.Split calldata oorSplit,
        bool inRange
    ) external onlyKeeper {
        uint256 id = currentBatch;
        Batch storage b = batches[id];
        if (b.closed) revert BatchClosed();
        if (b.totalSkewWad == 0) revert NothingRecorded();

        (uint256 swapperShare,,) = FixedRateFill.splitCost(realisedCost, inRangeSplit, oorSplit, inRange);
        b.swapperPot = swapperShare;
        b.closed = true;
        currentBatch = id + 1;
        emit Closed(id, realisedCost, swapperShare, inRange);
    }

    /// @notice Claim the true-up for `who` in a closed batch. Permissionless — anyone may trigger it
    ///         FOR a participant, since the result only ever credits that participant's own balance.
    /// @dev    Only the SWAPPER-ATTRIBUTED slice (`swapperPot`) is distributed here, pro-rata by
    ///         contributed skew. The LP and basket slices are not owed to anyone individually: they
    ///         fall to the fee lane and the basket respectively, which is what "they carry part of
    ///         the cost" MEANS. Distributing them here would be double-counting.
    function claim(uint256 id, address who) external {
        Batch storage b = batches[id];
        if (!b.closed) revert BatchOpen();
        Entry storage e = entryOf[id][who];
        if (e.skewWad == 0 && e.estimate == 0) revert AlreadyClaimed();

        (uint256 owed, uint256 refund) =
            FixedRateFill.trueUpShare(b.swapperPot, e.skewWad, b.totalSkewWad, e.estimate);

        // Zero the entry BEFORE crediting — this is the only re-entry surface here, and clearing
        // first makes a second claim hit the AlreadyClaimed guard rather than pay twice.
        delete entryOf[id][who];
        if (refund > 0) claimable[who] += refund;
        emit Claimed(id, who, owed, refund);
        // `owed` is surfaced, not collected: pulling more from a departed swapper is not possible,
        // so an under-estimate is absorbed. ⚠️ THAT MAKES THE ESTIMATE'S FLOOR LOAD-BEARING — if
        // estimates run systematically low, the shortfall lands on the fee lane rather than on the
        // causer, quietly inverting the decision this design is built on. Size the estimate to
        // over-collect, since only over-collection is refundable.
    }

    /// @notice Refund every participant's estimate if a batch was never closed.
    /// @dev    🔴 THE ANTI-STRANDING PATH, AND IT IS THE POINT OF THIS CONTRACT HAVING A DEADLINE AT
    ///         ALL. Without it a batch that never rebalances leaves its participants owed a true-up
    ///         that never arrives, and their estimate becomes a SILENT over-collection — no revert,
    ///         no event, just money that stopped being theirs. Permissionless and unconditional
    ///         after the timeout, so it does not depend on the keeper that already failed to run.
    ///         Marking it closed makes the batch terminal either way: a batch is settled or refunded,
    ///         never neither.
    function forceRefund(uint256 id) external {
        Batch storage b = batches[id];
        if (b.closed) revert BatchClosed();
        if (b.openedAt == 0) revert NothingRecorded();
        if (block.timestamp < b.openedAt + STRAND_TIMEOUT) revert NotStrandedYet();
        b.swapperPot = 0;      // nothing attributable: every participant gets their estimate back
        b.closed = true;
        if (id == currentBatch) currentBatch = id + 1;
        emit ForceRefunded(id);
    }
}
