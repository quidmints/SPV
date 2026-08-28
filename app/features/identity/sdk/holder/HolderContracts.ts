// ethers bindings for OUR forked holder-tree contracts (app/contracts/holder).
// ABIs match the compiled artifacts exactly. See HOLDER-TREE-NOTES + IdentityVault.

import { Contract, Interface, ContractRunner, id } from "ethers";

// @contract HolderStateKeeper
export const HOLDER_STATE_KEEPER_ABI = [
  "function getDocument(bytes32 documentKey) view returns (tuple(bytes32 holderRoot, bytes32 docType, uint64 issueTimestamp, uint64 notAfter, uint64 seq, uint8 status))",
  "function getHolderDocuments(bytes32 holderRoot) view returns (bytes32[])",
  "function getActiveDocumentCount(bytes32 holderRoot) view returns (uint256)",
] as const;

const PASSPORT_TUPLE =
  "tuple(uint256 dgCommit, bytes32 dg1Hash, bytes32 publicKey, bytes32 passportHash, address verifier)";

// @contract HolderRegistration
export const HOLDER_REGISTRATION_ABI = [
  `function registerDocumentViaNoir(uint256 holderRoot, ${PASSPORT_TUPLE} passport, bytes32 docType, uint64 notAfter, bytes signature, bytes zkPoints)`,
  `function renewDocumentViaNoir(bytes32 oldDocumentKey, uint256 holderRoot, ${PASSPORT_TUPLE} newPassport, bytes32 newDocType, uint64 newNotAfter, bytes signature, bytes zkPoints)`,
  `function revokeDocumentViaSigner(${PASSPORT_TUPLE} passport, bytes signature)`,
] as const;

/** On-chain document lifecycle (mirrors HolderStateKeeper.DocStatus). */
export enum DocStatus {
  None = 0,
  Current = 1,
  Superseded = 2,
  Revoked = 3,
}

/** A document bond, as returned by HolderStateKeeper.getDocument. */
export interface DocumentBond {
  holderRoot: string;
  docType: string;
  issueTimestamp: bigint;
  notAfter: bigint;
  seq: bigint;
  status: DocStatus;
}

/** The Passport calldata struct shared by the registration entrypoints. */
export interface PassportStruct {
  dgCommit: bigint;
  dg1Hash: string;
  publicKey: string;
  passportHash: string;
  verifier: string;
}

export function holderStateKeeper(address: string, runner: ContractRunner): Contract {
  return new Contract(address, HOLDER_STATE_KEEPER_ABI as unknown as string[], runner);
}

export function holderRegistration(address: string, runner: ContractRunner): Contract {
  return new Contract(address, HOLDER_REGISTRATION_ABI as unknown as string[], runner);
}

/** Read one document bond and normalize the named tuple into a typed object. */
export async function getDocumentBond(
  stateKeeper: Contract,
  documentKey: string,
): Promise<DocumentBond> {
  const d = await stateKeeper.getDocument(documentKey);
  return {
    holderRoot: d.holderRoot,
    docType: d.docType,
    issueTimestamp: BigInt(d.issueTimestamp),
    notAfter: BigInt(d.notAfter),
    seq: BigInt(d.seq),
    status: Number(d.status) as DocStatus,
  };
}

/** All document keys ever bound under a holder root (any status). */
export async function getHolderDocuments(
  stateKeeper: Contract,
  holderRoot: string,
): Promise<string[]> {
  return stateKeeper.getHolderDocuments(holderRoot);
}

/** Build registerDocumentViaNoir calldata (for relayer submission to HolderRegistration). */
export function encodeRegisterDocument(args: {
  holderRoot: string; // 0x… (== profileKey)
  passport: PassportStruct;
  docType: string; // bytes32 (keccak of "PASSPORT" etc.)
  notAfter: bigint;
  signature: string; // backend signer sig over the signed-data
  zkPoints: string; // serialized Noir register proof
}): string {
  const iface = new Interface(HOLDER_REGISTRATION_ABI as unknown as string[]);
  return iface.encodeFunctionData("registerDocumentViaNoir", [
    BigInt(args.holderRoot),
    [
      args.passport.dgCommit,
      args.passport.dg1Hash,
      args.passport.publicKey,
      args.passport.passportHash,
      args.passport.verifier,
    ],
    args.docType,
    args.notAfter,
    args.signature,
    args.zkPoints,
  ]);
}

/** Build renewDocumentViaNoir calldata (for relayer submission to HolderRegistration). */
export function encodeRenewDocument(args: {
  oldDocumentKey: string; // bytes32
  holderRoot: string; // 0x… (== profileKey)
  newPassport: PassportStruct;
  newDocType: string; // bytes32
  newNotAfter: bigint;
  signature: string; // backend signer sig over the signed-data (new passport)
  zkPoints: string; // serialized Noir register proof (new passport, bound to holderRoot)
}): string {
  const iface = new Interface(HOLDER_REGISTRATION_ABI as unknown as string[]);
  return iface.encodeFunctionData("renewDocumentViaNoir", [
    args.oldDocumentKey,
    BigInt(args.holderRoot),
    [
      args.newPassport.dgCommit,
      args.newPassport.dg1Hash,
      args.newPassport.publicKey,
      args.newPassport.passportHash,
      args.newPassport.verifier,
    ],
    args.newDocType,
    args.newNotAfter,
    args.signature,
    args.zkPoints,
  ]);
}

/** Build revokeDocumentViaSigner calldata (for relayer submission to HolderRegistration).
 *  Unlike register/renew, this needs NO Noir proof — only a backend signer signature over the
 *  document being revoked. No backend endpoint for producing that signature exists in this SDK
 *  yet (revocation wasn't part of upstream's flow), so `signature` is an explicit caller-supplied
 *  input, not something this function or IdentityVault can silently obtain. */
export function encodeRevokeDocument(args: {
  passport: PassportStruct;
  signature: string;
}): string {
  const iface = new Interface(HOLDER_REGISTRATION_ABI as unknown as string[]);
  return iface.encodeFunctionData("revokeDocumentViaSigner", [
    [
      args.passport.dgCommit,
      args.passport.dg1Hash,
      args.passport.publicKey,
      args.passport.passportHash,
      args.passport.verifier,
    ],
    args.signature,
  ]);
}

/** docType bytes32 = keccak256(utf8(name)) — matches HolderStateKeeper.DOC_PASSPORT etc.
 *  (`ethers.id(s)` == keccak256(toUtf8Bytes(s)).) Single source of truth, always in sync. */
export const DOC_TYPE = {
  PASSPORT: id("PASSPORT"),
  NATIONAL_ID: id("NATIONAL_ID"),
  MDL: id("MDL"),
  EUDI_PID: id("EUDI_PID"),
  NOTARIAL_TITLE: id("NOTARIAL_TITLE"),
} as const;
