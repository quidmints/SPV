# secure-recovery — our Expo native module (NEW, ours)

Native biometric unlock + key management. **Ours** — sits alongside the vendored
`@rarimo` SDKs; do **NOT** fork either SDK to host this. See `SCOPE.md` §7.3.

## Model 2, not Model 1
- **Day-to-day unlock:** native Face ID / Android BiometricPrompt (Class 3) **unlocks**
  an enclave-held seed. No fuzzy extractor. Hardware liveness for free.
- **Fresh-device recovery:** delegated to **rarime passport + password** (stronger than a
  fuzzy-extracted face, both work on a new device). EUDI Gap #9.
- **Face→key fuzzy extractor (Model 1): NOT built.** Only revisit if a hardware-attested
  face must itself be a standalone fresh-device factor (argued worse than the two above).

## Layout
```
src/
  index.ts      # public TS API: enroll() / unlock() / recover()
  keystore.ts   # Model 2: enclave-backed seed encryption
  recovery.ts   # factor orchestration (face-unlock, passport, password)
ios/            # Swift: LAContext + liveness + Secure Enclave
android/        # Kotlin: BiometricPrompt + StrongBox + liveness
```
Expo module packaging, mirroring rarime's, so it drops into the same RN app.
