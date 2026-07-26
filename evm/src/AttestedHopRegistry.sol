// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The audited on-chain Intel DCAP quote verifier — Automata DCAP
///         Attestation (Trail of Bits-audited, 2025). Integrated by ADDRESS like
///         Chainlink/Aave; quote verification is NOT hand-rolled here.
/// @dev    Reference: github.com/automata-network/automata-dcap-attestation. The
///         entrypoint verifies a raw DCAP quote fully on-chain and returns the
///         verified quote body on success.
interface IDcapAttestation {
    function verifyAndAttestOnChain(bytes calldata rawQuote)
        external
        returns (bool success, bytes memory output);
}

/// @title  AttestedHopRegistry
/// @notice Gates *which addresses may act as a QU!D hop* by requiring on-chain
///         proof that they run an EXPECTED, honest enclave measurement (MRENCLAVE)
///         which CONTROLS the hop's EVM key.
///
///         WHY THIS EXISTS: the BTC swap pool (`Core.POOLED_USD_BTC`) is GLOBAL, so
///         a malicious hop dilutes EVERY LP's backing — it is not harm-isolated.
///         Off-chain per-LP attestation cannot protect a shared pool; the honesty
///         of every hop must be enforced at the contract, for everyone. This
///         registry is that enforcement point: a hop registers by submitting its
///         DCAP quote; the audited Automata verifier checks it; the registry then
///         confirms (a) the MRENCLAVE is a whitelisted, honest, reproducibly-built
///         measurement and (b) the quote's `reportData` binds THIS caller's EVM
///         address (the hop's born-in-enclave key). BTCChannels GATES the hop
///         money-paths (openChannel / settleSwapIn / emitDeadManExit) on
///         `isAttested(msg.sender)` via `_requireAttested`/`_authorizedHop` — this
///         wiring IS live. It is GOVERNANCE-ARMED: `_requireAttested` is a no-op while
///         `hopRegistry == 0`, so any deployment that has not yet pinned the live
///         registry via `setHopRegistry` falls back to the `openChannelsOf` gate (owns
///         an OPEN channel = has real BTC locked). Pinning requires the born-in-enclave
///         DCAP quote a hop submits to `registerHop`, which needs the enclave on real
///         SGX hardware (the identity-quote flow) — hence regtest/bootstrap runs armed
///         but unpinned. Do not read the paragraphs below as a live guarantee on a
///         deployment where the registry has not been pinned.
///
///         WHY A HOP CANNOT TURN ROGUE AFTER ATTESTATION: the hop's signing key is
///         born inside the enclave and sealed to its MRENCLAVE, so only that exact
///         measurement can unseal + sign for the registered address. Rogue code is
///         a DIFFERENT MRENCLAVE and cannot access the key — it can neither register
///         nor produce a valid tx from an attested address.
///
///         GOVERNANCE: `governance` (a Safe, n-of-m) governs ONLY the MRENCLAVE
///         whitelist — i.e. *which code* may be a hop — and the revocation list. It
///         moves NO funds. Adding a MRENCLAVE is a public tx, checkable against the
///         reproducible build (does the whitelisted measurement equal a build of the
///         published commit?), so a rogue upgrade is visible. The value-moving
///         contracts stay ownership-renounced; this is the one deliberate, bounded
///         governance surface.
contract AttestedHopRegistry {
    /// The audited on-chain DCAP verifier.
    IDcapAttestation public immutable VERIFIER;

    /// The Safe (n-of-m) that governs the measurement whitelist + revocations.
    address public governance;

    /// Whitelisted honest enclave measurements (MRENCLAVE ⇒ allowed).
    mapping(bytes32 => bool) public expectedMrenclave;

    /// Attested hops: address ⇒ the MRENCLAVE it registered under (0 ⇒ not attested).
    mapping(address => bytes32) public hopMrenclave;

    // --- Offsets into the Automata verified-output. FLAG: pin these against the
    // deployed Automata DCAP verifier VERSION at integration (v3/v4 differ). The
    // mock in the tests exercises the registry LOGIC at these offsets; the real
    // offsets must be confirmed against the audited verifier's output format.
    // The enclave report's MRENCLAVE (32B) and REPORTDATA (64B); we bind the hop's
    // 20-byte EVM address in reportData[32..52] (matches the enclave's identity
    // binding: reportData = TLS pk ‖ EVM addr).
    uint256 internal constant MRENCLAVE_OUT_OFF = 0x00;
    uint256 internal constant REPORTDATA_OUT_OFF = 0x20;
    uint256 internal constant EVM_ADDR_IN_REPORTDATA = 0x20; // reportData[32..52]

    event MrenclaveSet(bytes32 indexed mrenclave, bool allowed);
    event HopAttested(address indexed hop, bytes32 indexed mrenclave);
    event HopRevoked(address indexed hop);
    event GovernanceSet(address indexed governance);

    error NotGovernance();
    error QuoteInvalid();
    error MeasurementNotAllowed();
    error KeyBindingMismatch();
    error OutputTooShort();

    constructor(IDcapAttestation verifier, address gov) {
        VERIFIER = verifier;
        governance = gov;
        emit GovernanceSet(gov);
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    // --- Governance: the measurement whitelist (which code may be a hop) --------

    /// Allow/deny an enclave measurement. Public + auditable against the
    /// reproducible build. This is the ONLY value-adjacent governance lever.
    function setMrenclave(bytes32 mrenclave, bool allowed) external onlyGovernance {
        expectedMrenclave[mrenclave] = allowed;
        emit MrenclaveSet(mrenclave, allowed);
    }

    /// Hand governance to a successor (e.g. a timelock) or renounce (address(0)).
    function setGovernance(address gov) external onlyGovernance {
        governance = gov;
        emit GovernanceSet(gov);
    }

    /// Revoke an attested hop — the on-chain analogue of an enclave CRL, e.g. when
    /// a MRENCLAVE is later found vulnerable / on SGX TCB recovery. Also de-whitelist
    /// the measurement via `setMrenclave(m, false)` to stop re-registration.
    function revokeHop(address hop) external onlyGovernance {
        delete hopMrenclave[hop];
        emit HopRevoked(hop);
    }

    // --- Registration: prove you run whitelisted code that owns your address -----

    /// Register the CALLER as an attested hop. Reverts unless the DCAP quote
    /// verifies on-chain, its MRENCLAVE is whitelisted, and its reportData binds
    /// `msg.sender` (the hop's born-in-enclave EVM key). Idempotent re-registration
    /// (e.g. after a whitelisted upgrade + key migration) simply updates the record.
    function registerHop(bytes calldata rawQuote) external {
        (bool ok, bytes memory output) = VERIFIER.verifyAndAttestOnChain(rawQuote);
        if (!ok) revert QuoteInvalid();
        (bytes32 mrenclave, address boundAddr) = _parse(output);
        if (!expectedMrenclave[mrenclave]) revert MeasurementNotAllowed();
        if (boundAddr != msg.sender) revert KeyBindingMismatch();
        hopMrenclave[msg.sender] = mrenclave;
        emit HopAttested(msg.sender, mrenclave);
    }

    /// The gate BTCChannels calls on every hop-only action. True only while the
    /// hop's registered measurement is still whitelisted (so de-whitelisting a
    /// measurement instantly disables every hop running it).
    function isAttested(address hop) external view returns (bool) {
        bytes32 m = hopMrenclave[hop];
        return m != bytes32(0) && expectedMrenclave[m];
    }

    // --- Verified-output parsing (offsets flagged; pin at integration) ----------

    /// Extract (MRENCLAVE, bound EVM address) from the verifier's output.
    function _parse(bytes memory output)
        internal
        pure
        returns (bytes32 mrenclave, address boundAddr)
    {
        // Need MRENCLAVE (32B) + reportData's address slot (32 bytes into reportData,
        // 20-byte address). Require the output covers reportData[32..52].
        if (output.length < REPORTDATA_OUT_OFF + EVM_ADDR_IN_REPORTDATA + 20) {
            revert OutputTooShort();
        }
        assembly {
            // output data begins at output + 0x20 (skip the length word).
            let base := add(output, 0x20)
            mrenclave := mload(add(base, MRENCLAVE_OUT_OFF))
            // Load the 32-byte word at reportData[32..], then take the top 20 bytes
            // as the address (reportData[32..52]).
            let w := mload(add(base, add(REPORTDATA_OUT_OFF, EVM_ADDR_IN_REPORTDATA)))
            boundAddr := shr(96, w)
        }
    }
}
