// Barrel for the wallet's SDK surface: the upstream package plus this fusion's own additions.
//
// src/sdk USED TO BE A VERBATIM COPY of @rarimo/rarime-rn-sdk's src/ (32 files). It existed at all
// because the package was unimportable — its `main`/`types` pointed at a build/ directory that was
// never produced, because `prepare` was a documented no-op and, underneath that, the package's own
// `npm install` failed on an ERESOLVE (typescript 7 vs @li0ard/tsemrtd's peer ^5). All of that is
// fixed upstream now, so the copy is gone: 32 files -> 6, and the 6 that remain are ones the
// package genuinely does not have. SDK fixes now arrive by `npm install`, not by hand-merging.
//
// Prefer importing shared types/classes from '@rarimo/rarime-rn-sdk' directly. This barrel is for
// consumers that want both surfaces behind one specifier.

export * from "@rarimo/rarime-rn-sdk";

// Explicit re-exports SHADOW the `export *` above — that is what resolves the name collision, and
// it is deliberate rather than incidental. Our Rarime is a SUPERSET of the package's: it adds
// `holderRegistrationAddress` and `generateRegistrationMaterial()` for OUR HolderRegistration
// contract (registerDocumentViaNoir / renewDocumentViaNoir / revokeDocumentViaSigner), which
// upstream's RegistrationSimple cannot express — its addBond forbids a second document per key.
// Anyone importing `Rarime` from this barrel must get ours, not upstream's.
export {
  Rarime,
  RarimeAPIConfiguration,
  RarimeConfiguration,
  RarimeContractsConfiguration,
  RarimeUserConfiguration,
} from "./Rarime";

// Ours alone — no upstream equivalent.
export * from "./HolderTree";
export * from "./Eudi";
export * from "./holder/HolderContracts";

// Side-effecting: registers withdraw_identity + title_holder with the SDK's circuit registry, so
// importing this barrel is enough to make NoirCircuitParams.fromName() find them.
export * from "./circuits";
