// Holder-rooted credential tree — the 1-key=N-document fix. See SCOPE.md §7.8.
//
// Replaces the flat "one profileKey ≈ one passport" model with a 2-level tree:
//
//   holder root (durable)  =  profileKey = Poseidon(pubkey(sk_identity))
//        │                     ↑ all continuity binds HERE: scoped pseudonyms, nullifiers,
//        │                       one-person-ness, card-state — NOT the document.
//        ├── document leaf: passport      (docType, attrCommit, validity, status)
//        ├── document leaf: national ID
//        ├── document leaf: EUDI PID
//        └── document leaf: passport'      ← renewal supersedes the old passport leaf
//
// MANY leaves → many documents, one holder. RENEWAL = add new leaf + supersede old under the
// same root, with a link proof that both share the holder root, so identity/pseudonyms/card
// state persist across a passport swap (no re-onboarding).
//
// SCOPE NOTE: the tree STRUCTURE + renewal/revocation/link-proof live in the forked Rarimo
// contracts (PoseidonSMT, RegistrationSimple) + Noir circuits (§7.5 substrate) — NOT here.
// This file is the SDK-side model + the deterministic key/index derivation that is computable
// today (mirrors Rarime.getSMTProofIndex / RarimeUtils.getProfileKey). Methods that need the
// forked contract surface are marked NEEDS-FORKED-SUBSTRATE.

import { Poseidon } from "@iden3/js-crypto";
import { RarimeUtils } from "@rarimo/rarime-rn-sdk";
import { toPaddedHex32 } from "@rarimo/rarime-rn-sdk";

/** The kinds of document that can hang under one holder root. The tree/leaf model is document-
 *  type-agnostic (a leaf is just docType + attrCommit + validity + status) — adding a type here
 *  is a type-system change only. Per-type CIRCUIT verification is separate, per-type work; see
 *  Eudi.ts for the honest built-vs-unbuilt split (passport has a working query circuit today;
 *  NotarialTitle does not yet). */
export enum DocumentType {
  Passport = "PASSPORT",
  NationalId = "NATIONAL_ID",
  Mdl = "MDL",
  EudiPid = "EUDI_PID",
  /** A notarized proof-of-title document (property deed, vehicle title, certificate of
   *  ownership, etc.) — authenticated by a notary's/registrar's signature over the document
   *  content, NOT a government biometric passport chip. Structurally different trust root and
   *  document schema from the passport/national-ID/mdl/PID types above.
   *
   *  NOT a confirmed, standardized EUDI attestation type — checked (2026-07) against the EUDI
   *  Architecture Reference Framework: EAAs (Electronic Attestations of Attributes) are an
   *  explicitly open-ended category by design ("tickets, social passes, loyalty cards... driving
   *  licenses to diplomas"), so a title/ownership attestation is architecturally plausible under
   *  that framework, but no existing, ratified EUDI scheme for one was found. This is our own
   *  holder-tree's document-type extension (the tree/leaf model doesn't require EUDI's blessing to
   *  add a type — see the enum's own doc comment), not an implementation of an existing EUDI
   *  standard. */
  NotarialTitle = "NOTARIAL_TITLE",
}

/** Per-leaf lifecycle (distinct from RarimePassport.DocumentStatus, which is the old
 *  flat-registration view). */
export enum LeafStatus {
  Current = "CURRENT",
  Superseded = "SUPERSEDED", // replaced by a renewal under the same holder root
  Revoked = "REVOKED",
}

/** One document bound under the holder root. `attrCommit` is the document's attribute/DG
 *  commitment (e.g. rarime's `dgCommit`); `leafIndex` is its SMT index. */
export interface DocumentLeaf {
  docType: DocumentType;
  /** SMT leaf index = Poseidon(documentKey, holderRoot). */
  leafIndex: string;
  /** Commitment over the document's attributes (rarime `dgCommit`, or mdoc/SD-JWT digest). */
  attrCommit: string;
  /** Validity window from the document (epoch seconds), for renewal/expiry logic. */
  notAfter?: number;
  status: LeafStatus;
}

/** The durable holder identity that survives document renewal. Bind nullifiers/pseudonyms/
 *  card-state to THIS, never to a leaf. */
export class HolderRoot {
  /** profileKey — the on-chain `activeIdentity`. */
  readonly profileKey: string;

  private constructor(profileKey: string) {
    this.profileKey = profileKey;
  }

  /** Derive the holder root from the identity secret (same derivation as the rest of rarime,
   *  so this is consistent with on-chain `activeIdentity`). */
  static fromIdentitySecret(skIdentityHex: string): HolderRoot {
    const sk = skIdentityHex.startsWith("0x") ? skIdentityHex.slice(2) : skIdentityHex;
    return new HolderRoot(RarimeUtils.getProfileKey(sk));
  }

  /** SMT leaf index for a document under this holder root. Mirrors Rarime.getSMTProofIndex,
   *  generalized from "passportKey" to any documentKey so N documents share one root. */
  leafIndex(documentKey: bigint): string {
    return toPaddedHex32(Poseidon.hash([documentKey, BigInt("0x" + this.profileKey)]));
  }
}
