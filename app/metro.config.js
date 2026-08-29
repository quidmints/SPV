const { getDefaultConfig } = require('expo/metro-config')

const config = getDefaultConfig(__dirname)

// Enable package.json "exports" field resolution.
// Required for @noble/hashes, @noble/curves, @noble/ciphers subpath imports
// e.g. '@noble/hashes/sha256', '@noble/curves/p256'
config.resolver.unstable_enablePackageExports = true

// Ship the identity wallet's OWN Noir circuits (assets/circuits/*.circuit) inside the bundle.
//
// They are ACIR artifacts built by evm/noir/codegen-verifiers.sh and, unlike upstream rarimo's
// circuits, are not published anywhere — so `downloadByteCode` has nothing to fetch.
//
// The `.circuit` extension is deliberate: these files ARE JSON, but Metro treats `.json` as SOURCE
// and would inline + parse a 3.7 MB object into the JS bundle at require time. Registering a
// distinct extension in assetExts keeps them as opaque assets, resolvable to a local URI via
// expo-asset and readable with expo-file-system — which is what the native prover wants anyway
// (it takes the bytecode as a string). See features/identity/sdk/circuits.ts.
config.resolver.assetExts = [...config.resolver.assetExts, 'circuit']

module.exports = config
