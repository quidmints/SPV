// IdentityVault — one holder key, MANY documents. The "one-key-multiple-documents" core
// (multi-citizenship + renewed/revoked/expired passports). See app contracts: HolderStateKeeper.
//
// Model:
//   device-enclave RootSeed  ──►  sk_identity  ──►  holder root (profileKey)  ──►  many document leaves
//     (one BIP39 mnemonic, see        (derived)       (Poseidon(pubkey(sk)))        passport · national ID · ...
//      identity/root.ts; ALSO roots
//      the Privacy Pool notes)
//
// All documents bind to the SAME holder key, so multi-citizenship = register N passports under
// one key; renewal = register the new passport + supersede the old, holder key unchanged.
// The holder secret is NOT independent randomness — it is derived from the same enclave RootSeed
// that derives the PP note master keys (rarime↔PP fusion: one seed recovers identity + funds).
//
// WHAT IS REAL HERE: holder-key lifecycle, the document set + status management, and
// add/renew/revoke DO call OUR HolderRegistration (registerDocumentViaNoir/renewDocumentViaNoir/
// revokeDocumentViaSigner) at OUR deployed HolderStateKeeper, not upstream RegistrationSimple —
// via Rarime.generateRegistrationMaterial (on-device Noir proof + the SAME backend
// SOD-verification call upstream's own registerIdentity uses, since HolderRegistration reuses
// RegistrationSimple's signer set and signed-data format) + Rarime.submitViaRelayer (the same
// generic registration-relayer endpoint, pointed at OUR contract instead of upstream's).
// revokeDocument's signature is a required caller input, not auto-obtained (see its own docstring
// — no backend endpoint for revocation signing exists yet).
//
// STILL NOT DONE: the "is this document CURRENT" query proof needs the forked query_identity
// Noir circuit to actually be wired to this holder-tree's leaf convention (dgCommit/seq/
// timestamp) — it isn't yet (tracked in backend/circuits/PP-NOIR-FUSION.md). The on-chain state
// (this file drives) is correct and tested; the circuit-side consumption of it is the remaining
// gap, not this file.

import { JsonRpcProvider } from "ethers";
import { Rarime, RarimeConfiguration } from "../sdk/Rarime";
import { RarimePassport, DocumentStatus } from "@rarimo/rarime-rn-sdk";
import { HolderRoot, DocumentType, LeafStatus } from "../sdk/HolderTree";
import { getOrCreateRootMnemonic, deriveSkIdentity, deriveProfileMasterKeys } from "./root";
import type { MasterKeys } from "../pp/notes";
import { discoverNotes, DiscoveryResult, DiscoveryOptions } from "../pp/discovery";
import { toPaddedHex32 } from "@rarimo/rarime-rn-sdk";
import {
  holderStateKeeper,
  getHolderDocuments,
  getDocumentBond,
  encodeRegisterDocument,
  encodeRenewDocument,
  encodeRevokeDocument,
  DocStatus,
  DOC_TYPE,
} from "../sdk/holder/HolderContracts";

/** A document held under the single holder key. `documentKey` is the on-chain key
 *  (Poseidon-derived passport key, hex). */
export interface StoredDocument {
  documentKey: string;
  docType: DocumentType;
  /** Issuing country (ISO-3166), the multi-citizenship discriminator. */
  country?: string;
  registeredAt?: number;
  /** Passport expiry (epoch seconds) — drives the "expired" status. */
  notAfter?: number;
  status: LeafStatus;
  /** id returned by the registration relayer, if any. */
  registrationId?: string;
  /** The PassportStruct fields cached at registration time. Required to revoke a LOST/STOLEN
   *  document later, when the physical passport is no longer available to re-derive them from —
   *  revocation needs the full struct to reconstruct the signed-data for signature verification,
   *  and "lost/stolen" is the primary revocation use case, so this cannot depend on having the
   *  original document again. */
  passportStruct?: {
    dgCommit: bigint;
    dg1Hash: string;
    publicKey: string;
    passportHash: string;
    verifier: string;
  };
}

/** Persistence the host app provides for the document set (e.g. async-storage). The holder secret
 *  is NOT stored here — it is derived from the enclave RootSeed (see identity/root.ts). */
export interface IdentityVaultStore {
  getDocuments(): Promise<StoredDocument[]>;
  setDocuments(docs: StoredDocument[]): Promise<void>;
}

/** Config minus the user key — the key is the vault's durable holder secret, managed here. */
export type IdentityVaultConfig = Omit<RarimeConfiguration, "userConfiguration">;

export class IdentityVault {
  constructor(
    private readonly config: IdentityVaultConfig,
    private readonly store: IdentityVaultStore,
  ) {}

  // ── Holder key (the ONE key) ──────────────────────────────────────────────────────────────

  /** The durable holder secret (sk_identity), derived from the device-enclave RootSeed.
   *  Same seed that derives the PP note master keys — see ppMasterKeys(). */
  async ensureHolderSecret(): Promise<string> {
    return deriveSkIdentity(await getOrCreateRootMnemonic());
  }

  /** Privacy Pool note master keys, derived from the SAME enclave RootSeed as sk_identity.
   *  This is the rarime↔PP fusion: one seed → identity AND all privacy-pool notes. */
  async ppMasterKeys(): Promise<MasterKeys> {
    return deriveProfileMasterKeys(await getOrCreateRootMnemonic());
  }

  /** Recover this holder's Privacy Pool notes for a pool/scope by scanning on-chain events and
   *  re-deriving from the enclave seed (HD-wallet-style; no server-side note storage). Returns the
   *  notes with spent status + spendable balance. */
  async discoverPoolNotes(
    poolAddress: string,
    scope: bigint,
    opts?: DiscoveryOptions,
  ): Promise<DiscoveryResult> {
    const provider = new JsonRpcProvider(this.config.apiConfiguration.jsonRpcEvmUrl);
    return discoverNotes(provider, poolAddress, await this.ppMasterKeys(), scope, opts);
  }

  /** The durable holder root (profileKey) every document binds to. */
  async holderRoot(): Promise<HolderRoot> {
    return HolderRoot.fromIdentitySecret(await this.ensureHolderSecret());
  }

  /** A Rarime instance bound to the single holder secret. */
  private async rarime(): Promise<Rarime> {
    return new Rarime({
      ...this.config,
      userConfiguration: { userPrivateKey: await this.ensureHolderSecret() },
    });
  }

  // ── Documents (MANY) ──────────────────────────────────────────────────────────────────────

  async listDocuments(): Promise<StoredDocument[]> {
    return this.store.getDocuments();
  }

  /**
   * Read the holder's documents straight from OUR HolderStateKeeper (the source of truth):
   * every leaf ever bound under this holder root, with its on-chain status. This is the real
   * multi-document enumeration (multi-citizenship + superseded/revoked visible).
   */
  async documentsOnChain(): Promise<StoredDocument[]> {
    const root = await this.holderRoot();
    const provider = new JsonRpcProvider(this.config.apiConfiguration.jsonRpcEvmUrl);
    const sk = holderStateKeeper(this.config.contractsConfiguration.stateKeeperAddress, provider);

    const keys = await getHolderDocuments(sk, "0x" + root.profileKey);
    const out: StoredDocument[] = [];
    for (const documentKey of keys) {
      const b = await getDocumentBond(sk, documentKey);
      out.push({
        documentKey,
        docType: docTypeFromHash(b.docType),
        notAfter: b.notAfter > 0n ? Number(b.notAfter) : undefined,
        registeredAt: Number(b.issueTimestamp),
        status: leafStatusFromChain(b.status),
      });
    }
    return out;
  }

  /** Reconcile the local store with on-chain truth (statuses, newly-seen documents). */
  async syncFromChain(): Promise<StoredDocument[]> {
    const chain = await this.documentsOnChain();
    const local = await this.store.getDocuments();
    // chain status wins; keep local-only fields (country) where we have them.
    const byKey = new Map(local.map((d) => [d.documentKey, d]));
    const merged = chain.map((c) => ({ ...byKey.get(c.documentKey), ...c }));
    await this.store.setDocuments(merged);
    return merged;
  }

  /** Current = registered, not superseded/revoked, not past expiry. */
  async currentDocuments(nowSec = nowSeconds()): Promise<StoredDocument[]> {
    return (await this.listDocuments()).filter(
      (d) => d.status === LeafStatus.Current && !isExpired(d, nowSec),
    );
  }

  /** Documents grouped by issuing country — the multi-citizenship view. */
  async citizenships(): Promise<string[]> {
    const set = new Set<string>();
    for (const d of await this.currentDocuments()) if (d.country) set.add(d.country);
    return [...set];
  }

  /**
   * Add (register) a NEW document under the holder key. Repeatable with different passports →
   * multi-citizenship. Calls OUR HolderRegistration.registerDocumentViaNoir at OUR deployed
   * HolderStateKeeper — NOT upstream RegistrationSimple (whose addBond forbids a 2nd doc per
   * key). Proof generation + the backend signer signature reuse Rarime.generateRegistrationMaterial
   * (the exact same on-device Noir prover + SOD-verification backend call upstream's own
   * registerIdentity uses — HolderRegistration deliberately reuses RegistrationSimple's signer
   * set and signed-data format, so this material is valid here too, verified field-for-field
   * against buildLiteRegisterCalldata).
   */
  async addDocument(
    passport: RarimePassport,
    docType: DocumentType,
    opts: { country?: string; notAfter?: number } = {},
  ): Promise<StoredDocument> {
    // Check for a duplicate BEFORE any network/relayer call — documentKey is a pure local
    // derivation from the passport's own DG1 data, so this costs nothing and fails fast instead
    // of paying for an on-chain registration attempt that we then discard locally.
    const documentKey = toPaddedHex32(passport.getPassportKey());
    const docs = await this.store.getDocuments();
    if (docs.some((d) => d.documentKey === documentKey)) {
      throw new Error("IdentityVault: document already in this vault");
    }

    const rarime = await this.rarime();

    const status = await rarime.getDocumentStatus(passport);
    if (status === DocumentStatus.RegisteredWithOtherPk) {
      throw new Error("IdentityVault: document is bound to a different holder key");
    }

    const root = await this.holderRoot();
    const material = await rarime.generateRegistrationMaterial(passport);

    const calldata = encodeRegisterDocument({
      holderRoot: "0x" + root.profileKey,
      passport: material.passport,
      docType: docTypeToHash(docType),
      notAfter: BigInt(opts.notAfter ?? 0),
      signature: material.signature,
      zkPoints: material.zkPoints,
    });
    const registrationId = await rarime.submitViaRelayer(
      calldata,
      this.config.contractsConfiguration.holderRegistrationAddress,
    );

    const doc: StoredDocument = {
      documentKey,
      docType,
      country: opts.country,
      notAfter: opts.notAfter,
      registeredAt: nowSeconds(),
      status: LeafStatus.Current,
      registrationId,
      passportStruct: material.passport,
    };

    await this.store.setDocuments([...docs, doc]);
    return doc;
  }

  /**
   * Renew: supersede `oldDocumentKey` and bind `newPassport` under the SAME holder key, via
   * HolderRegistration.renewDocumentViaNoir — atomic supersede-old + bind-new on-chain, with the
   * new document's Noir proof (binding its DG1 to `holderRoot`) serving as the link proof that
   * both documents belong to one holder. Identity continuity is preserved (holder root
   * unchanged) — pseudonyms/state carry over.
   */
  async renewDocument(
    oldDocumentKey: string,
    newPassport: RarimePassport,
    docType: DocumentType,
    opts: { country?: string; notAfter?: number } = {},
  ): Promise<StoredDocument> {
    const docs = await this.store.getDocuments();
    const old = docs.find((d) => d.documentKey === oldDocumentKey);
    if (!old) throw new Error("IdentityVault: old document not found");
    if (old.status !== LeafStatus.Current) {
      throw new Error(`IdentityVault: old document is not current (status: ${old.status}) — cannot renew`);
    }

    const rarime = await this.rarime();
    const root = await this.holderRoot();
    const material = await rarime.generateRegistrationMaterial(newPassport);

    const calldata = encodeRenewDocument({
      oldDocumentKey,
      holderRoot: "0x" + root.profileKey,
      newPassport: material.passport,
      newDocType: docTypeToHash(docType),
      newNotAfter: BigInt(opts.notAfter ?? 0),
      signature: material.signature,
      zkPoints: material.zkPoints,
    });
    const registrationId = await rarime.submitViaRelayer(
      calldata,
      this.config.contractsConfiguration.holderRegistrationAddress,
    );

    const fresh: StoredDocument = {
      documentKey: toPaddedHex32(newPassport.getPassportKey()),
      docType,
      country: opts.country,
      notAfter: opts.notAfter,
      registeredAt: nowSeconds(),
      status: LeafStatus.Current,
      registrationId,
      passportStruct: material.passport,
    };
    await this.store.setDocuments([...docs, fresh]);

    const updated = (await this.store.getDocuments()).map((d) =>
      d.documentKey === oldDocumentKey ? { ...d, status: LeafStatus.Superseded } : d,
    );
    await this.store.setDocuments(updated);
    return fresh;
  }

  /**
   * Revoke a document (lost/stolen/compromised) via HolderRegistration.revokeDocumentViaSigner.
   * Needs no Noir proof (unlike register/renew) — only a backend signer signature over the
   * document being revoked. IMPORTANT: this signature is over a REVOKE-specific message
   * (HolderRegistration._buildRevokeSignedData), NOT the same signed-data format
   * register/renew use — deliberately domain-separated (fixed 2026-07-24) so a deterministic
   * signer doesn't produce a byte-identical signature for both, which the contract's anti-replay
   * check would then reject as already-consumed at registration time. Whoever implements the
   * backend revocation-signing endpoint must sign
   * keccak256("HolderRegistration revoke prefix", registrationContractAddress, passportHash,
   * dgCommit, publicKey, verifier), not the register/renew signed-data format.
   * `signature` is a REQUIRED caller-supplied input: no backend endpoint for producing a
   * revocation signature exists in this SDK yet (revocation wasn't part of upstream's flow at
   * all), so this cannot silently obtain one the way addDocument/renewDocument do — a dedicated
   * revocation-signing endpoint is separate, unstarted backend work.
   *
   * Requires the document to have been registered via THIS vault (so `passportStruct` was cached
   * at registration time) — a document only known via documentsOnChain()/syncFromChain() cannot
   * be revoked through this method, since the full PassportStruct isn't recoverable from chain
   * state alone and revocation must not depend on still having the original (possibly lost/
   * stolen) physical document.
   */
  async revokeDocument(documentKey: string, signature: string): Promise<void> {
    const docs = await this.store.getDocuments();
    const doc = docs.find((d) => d.documentKey === documentKey);
    if (!doc) throw new Error("IdentityVault: document not found");
    if (!doc.passportStruct) {
      throw new Error(
        "IdentityVault: document has no cached passport struct (not registered via this vault) — cannot revoke",
      );
    }

    const rarime = await this.rarime();
    const calldata = encodeRevokeDocument({ passport: doc.passportStruct, signature });
    await rarime.submitViaRelayer(calldata, this.config.contractsConfiguration.holderRegistrationAddress);

    const updated = docs.map((d) =>
      d.documentKey === documentKey ? { ...d, status: LeafStatus.Revoked } : d,
    );
    await this.store.setDocuments(updated);
  }
}

/** Forward: DocumentType enum -> on-chain docType hash (keccak of the name). Symmetric with
 *  docTypeFromHash below. */
function docTypeToHash(docType: DocumentType): string {
  switch (docType) {
    case DocumentType.Passport:
      return DOC_TYPE.PASSPORT;
    case DocumentType.NationalId:
      return DOC_TYPE.NATIONAL_ID;
    case DocumentType.Mdl:
      return DOC_TYPE.MDL;
    case DocumentType.EudiPid:
      return DOC_TYPE.EUDI_PID;
    case DocumentType.NotarialTitle:
      return DOC_TYPE.NOTARIAL_TITLE;
  }
}

/** Reverse the on-chain docType hash (keccak of the name) back to the DocumentType enum.
 *  Throws on an unrecognized hash rather than defaulting to Passport — silently mislabeling an
 *  unknown on-chain doc type (e.g. a NotarialTitle) as a Passport would corrupt citizenship
 *  counting and any trust decision keyed off docType, which is worse than a loud failure. */
function docTypeFromHash(hash: string): DocumentType {
  const h = hash.toLowerCase();
  if (h === DOC_TYPE.PASSPORT.toLowerCase()) return DocumentType.Passport;
  if (h === DOC_TYPE.NATIONAL_ID.toLowerCase()) return DocumentType.NationalId;
  if (h === DOC_TYPE.MDL.toLowerCase()) return DocumentType.Mdl;
  if (h === DOC_TYPE.EUDI_PID.toLowerCase()) return DocumentType.EudiPid;
  if (h === DOC_TYPE.NOTARIAL_TITLE.toLowerCase()) return DocumentType.NotarialTitle;
  throw new Error(`IdentityVault: unrecognized on-chain docType hash: ${hash}`);
}

/** Map the on-chain DocStatus to the wallet's LeafStatus. */
function leafStatusFromChain(s: DocStatus): LeafStatus {
  if (s === DocStatus.Current) return LeafStatus.Current;
  if (s === DocStatus.Superseded) return LeafStatus.Superseded;
  return LeafStatus.Revoked; // Revoked or None → non-current
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

function isExpired(d: StoredDocument, nowSec: number): boolean {
  return d.notAfter !== undefined && d.notAfter > 0 && d.notAfter < nowSec;
}
