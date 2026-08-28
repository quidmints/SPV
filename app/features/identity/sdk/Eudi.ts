// EUDI mapping shim — a CONCEPTUAL bridge showing how rarime's query proof lines up with
// OpenID4VP concepts. This is NOT built-to-spec EUDI compatibility and is NOT interoperable
// with real EUDI verifiers. Honest scope:
//   - emits a NON-STANDARD `zk-vp-noir` vp_token; spec requires ISO 18013-5 mdoc and/or SD-JWT VC
//   - `requestedClaims` is a 6-claim toy, not real DCQL / Presentation Exchange
//   - no OpenID4VCI (issuance), no trust framework (trusted lists, LoA, wallet/device attestation)
//   - a Noir/Groth16 SNARK is not (yet) a recognized EUDI proof type — ZK-for-EUDI is still forming
// Real EUDI support is a separate, large workstream. Kept here only as a design artifact mapping:
//   selector → DCQL claims · event_id → OpenID4VP nonce/RP binding · getEventNullifier → scoped
//   pseudonym · holder root → cnf holder-binding key · DG1 (MRZ) → PID attribute set

import { QueryProofParams } from "@rarimo/rarime-rn-sdk";
import { NoirZKProof } from "@rarimo/rarime-rn-sdk";

/** EUDI PID attribute names (eu.europa.ec.eudi.pid.1) we map rarime/DG1 onto. */
export enum PidClaim {
  FamilyName = "family_name",
  GivenName = "given_name",
  BirthDate = "birth_date",
  Nationality = "nationality",
  AgeOver18 = "age_over_18",
  ExpiryDate = "expiry_date",
}

/** The subset of an OpenID4VP authorization request this adapter consumes. The full wire type
 *  comes from the bridged EUDI verifier; kept minimal so the adapter stays format-light. */
export interface Openid4vpRequest {
  /** RP nonce → becomes the query proof `event_id`. */
  nonce: string;
  /** RP identifier (client_id) — folded into the scoped-pseudonym derivation. */
  clientId: string;
  /** Claims the RP asks for (DCQL / PE), as PID claim names. */
  requestedClaims: PidClaim[];
}

/** What Wallet Core assembles into the `vp_token`. */
export interface ZkVpToken {
  /** The rarime Noir proof + public signals (from generateQueryProof). */
  proof: NoirZKProof;
  /** Scoped per-RP pseudonym (holder binding), from Rarime.getEventNullifier(event_id). */
  pseudonym: string;
  /** Which PID claims this VP attests (the disclosed set). */
  disclosed: PidClaim[];
  /** The credential profile this VP conforms to. */
  format: "zk-vp-noir";
}

// Selector bit per claim. These bit positions are the SDK↔circuit contract for the
// `query_identity` disclosure selector — keep in lockstep with the forked circuit
// (circuits/query_identity). The selector is a bitmask choosing which DG1-derived outputs
// the proof reveals.
const SELECTOR_BIT: Record<PidClaim, number> = {
  [PidClaim.FamilyName]: 0,
  [PidClaim.GivenName]: 1,
  [PidClaim.BirthDate]: 2,
  [PidClaim.Nationality]: 3,
  [PidClaim.AgeOver18]: 4,
  [PidClaim.ExpiryDate]: 5,
};

/** Build the query-proof `selector` bitmask from the RP's requested claims. */
export function selectorForClaims(claims: PidClaim[]): string {
  let mask = 0n;
  for (const c of claims) mask |= 1n << BigInt(SELECTOR_BIT[c]);
  return mask.toString();
}

/** Translate an OpenID4VP request into rarime QueryProofParams. `base` carries the predicate
 *  bounds the verifier set (age / citizenship / validity windows); we override the RP-binding
 *  + disclosure selector. The caller then runs Rarime.generateQueryProof + getEventNullifier. */
export function requestToQueryParams(
  req: Openid4vpRequest,
  base: Omit<QueryProofParams, "eventId" | "selector">
): { params: QueryProofParams; eventId: bigint } {
  // event_id binds the proof (and its nullifier) to THIS request → no cross-RP linkage.
  const eventId = bindingToEventId(req.nonce, req.clientId);
  return {
    params: {
      ...base,
      eventId: eventId.toString(),
      selector: selectorForClaims(req.requestedClaims),
    },
    eventId,
  };
}

/** Assemble the ZK vp_token from a completed query proof + its scoped pseudonym. */
export function toVpToken(
  req: Openid4vpRequest,
  proof: NoirZKProof,
  pseudonym: string
): ZkVpToken {
  return { proof, pseudonym, disclosed: req.requestedClaims, format: "zk-vp-noir" };
}

/** Deterministic event_id from the RP binding (nonce + client_id), so the scoped pseudonym is
 *  reproducible from the request alone. Folds the two ASCII strings into a BN254-range bigint. */
function bindingToEventId(nonce: string, clientId: string): bigint {
  let h = 1469598103934665603n; // FNV-ish offset
  for (const ch of nonce + "|" + clientId) {
    h = (h ^ BigInt(ch.charCodeAt(0))) * 1099511628211n;
    h &= (1n << 252n) - 1n; // keep under the BN254 scalar field
  }
  return h;
}

// ── Notarial proof-of-title (DocumentType.NotarialTitle) — TYPE CONTRACT ONLY, NOT WORKING ────
//
// Deliberately kept SEPARATE from PidClaim/SELECTOR_BIT above, not merged into them. SELECTOR_BIT
// is a real SDK<->circuit contract: those bit positions correspond to actual output signals the
// forked `query_identity` circuit computes from DG1. A title document has neither that circuit nor
// that trust root — its authenticity is a notary's/registrar's signature over the document content,
// not a passport DSC/SOD chain — so inventing selector bits for it here would assert a working
// wire-up that does not exist. This section is the forward-looking shape only.
//
// NOT a confirmed, standardized EUDI attestation type — checked (2026-07) against the EUDI
// Architecture Reference Framework: EAAs are explicitly open-ended by design, so this is
// architecturally plausible under that framework, but no existing, ratified EUDI scheme for a
// title/ownership attestation was found. This is our own holder-tree's extension, not an
// implementation of an existing EUDI standard — the "EUDI" framing below is aspirational shape,
// not a claim of spec compliance.
//
// What IS reusable when this gets built: the generic ECDSA/RSA signature-verification primitives
// already in `noir_dl_lib/src/sigver/` (compiled + unit-tested this session under the target Noir
// 1.0/Honk toolchain — see PP-NOIR-FUSION.md) can verify a notary's signature over a title-document
// hash the same way they verify a passport DSC signature over SOD — the primitive is generic. What's
// NOT built: the title-document field schema, the notary/registrar public-key trust root (a single
// notary key? a state notarial registry? a Merkle-committed registry, mirroring the ASP/sanctions-
// exclusion pattern used elsewhere in this project?), and the circuit wiring itself.

/** Candidate claim names for a notarized proof-of-title document. NOT wired to any circuit selector
 *  — see the section note above. Shape-only, for when the title-verification circuit is built. */
export enum TitleClaim {
  PropertyOrAssetId = "property_or_asset_id",
  OwnerNameHash = "owner_name_hash",
  NotaryId = "notary_id",
  NotarizationDate = "notarization_date",
  JurisdictionCode = "jurisdiction_code",
  TitleType = "title_type", // e.g. "real_property" | "vehicle" | "other"
}

/** What a completed title-proof VP would look like. `format` is intentionally distinct from
 *  `ZkVpToken.format` ("zk-vp-noir") so a consumer can't accidentally treat this as a working,
 *  provable token — there is no circuit that can produce a "zk-vp-title-noir" proof today. */
export interface TitleVpTokenShape {
  disclosed: TitleClaim[];
  format: "zk-vp-title-noir-UNBUILT";
}
