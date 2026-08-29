// MUST BE FIRST — `index.js` imports this before `expo-router/entry`.
//
// The identity wallet arrived from ibiza with its own `polyfills.ts`, imported as the first
// statement of its `index.ts`. That entry file did not come across in the merge, so the import
// was silently lost and only quick-crypto's `install()` remained. ibiza had already been bitten
// by exactly this once (its sec. 2.18bd: `polyfills.ts` existed and nothing imported it), which
// is why its comment called the position load-bearing rather than stylistic. Both halves now
// live here, so there is one polyfill entry and no second file to forget.
//
// `global.Buffer` is the one that bites: `features/identity/sdk/Rarime.ts` uses bare
// `Buffer.from` / `Buffer.concat`, and `install()` does not provide it.
//
// `react-native-get-random-values` installs `crypto.getRandomValues`, which
// `features/identity/identity/entropy.ts` refuses to generate a seed without.
import 'react-native-get-random-values'
import 'react-native-url-polyfill/auto'
import { Buffer } from 'buffer'
import { install } from 'react-native-quick-crypto'

install()

global.Buffer = global.Buffer ?? Buffer
