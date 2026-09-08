# `app/` — the QU!D mobile wallet

An [Expo](https://expo.dev) / React Native app (`expo-router`, file-based routes under `app/app/`).
It is the phone-side client for QU!D. `spa/` is the browser surface; this is the wallet.

**The protocol itself is specified in [`../spec.md`](../spec.md) — read that first.** Nothing in
this file describes protocol behaviour; where this README and the contracts in `../evm/src`
disagree, the contracts win.

## What is in here

| path | what it holds |
|---|---|
| `app/` | The route tree. `index` → `LoginScreen`, `home` → `HomeScreen`, `identity` → the identity wallet. |
| `components/` | The screens those routes mount, plus `app-providers.tsx` (the provider stack). |
| `context/`, `hooks/` | Wallet connection (`useWallet`, `useAuth`) and the Solana program hooks. |
| `constants/` | Generated tables — the Anchor IDL (`quid.json`) and the ticker map. |
| `features/account/`, `features/network/` | Solana account and cluster UI. |
| `features/identity/` | The passport / identity stack — **deferred scope**, with its own TODO. |
| `features/identity/chain/` | An EVM read/encode client (ABIs, encoders, P&L and flow reconstruction, the BIP-341 taproot deposit-address verifier). See the warning below. |
| `scripts/` | `setup-testnet.sh` and `initialize.js` — operator helpers, not part of the app bundle. |

⚠️ **`features/identity/chain/` is a fork of `../spa/src/lib/`, and it has no importer.** Every
module there except `taproot.ts`/`keys.ts`/`schnorr.ts` is a copy of the SPA's equivalent that did
not receive the SPA's later corrections, and nothing outside the directory imports any of it. Do not
treat it as the app's live chain layer until it is either re-synced with `spa/src/lib` or deleted.

## Running it

```sh
npm install        # once; the native modules are heavy
npx expo start     # Metro; then open on a device, emulator or Expo Go
npm run android    # or: npm run ios — a native run, needs the platform toolchain
npm run build      # tsc --noEmit, then `expo prebuild -p android`
npm run ci         # the above plus lint + prettier checks
```

There is **no `npm test`**. The `*.test.ts` files under `features/` are Node `node:test` suites
written as ESM, while this package is `"type": "commonjs"` — they are run out-of-band, not by a
script in here. Do not read a green build as evidence those tests passed.

## Where the real docs are

| question | go to |
|---|---|
| What is the protocol? | `../spec.md` |
| How do I work in this tree? | `../CLAUDE.md` |
| What is the status of X? | `../docs/actionable/SPRINT.md` |
| What must a front end enforce? | `../spa/FRONTEND-TODO.md` |
