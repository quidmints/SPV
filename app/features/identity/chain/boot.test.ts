// Run: node --test src/chain/boot.test.ts
//
// These assert the two rules the wiring exists to ENFORCE, not the plumbing. Plumbing that is
// wrong fails loudly on first use; these two fail silently and late.
import test from 'node:test'
import assert from 'node:assert'
import { ethers } from 'ethers'

import { bootChain, useLocalKey, useExternalWallet, clearSigner } from './boot.ts'
import { hasRpc } from './eth.ts'
import { CONTRACTS, setContracts } from './chains.ts'
import { protectionEnabled, signerKind, PROTECT, sendTx } from './protect.ts'
import { normaliseKey, evmAddressFromXOnly } from './keys.ts'

const KEY = ethers.keccak256(ethers.toUtf8Bytes('boot-fixture'))

test('the chain layer is inert until it is booted', () => {
  clearSigner()
  assert.strictEqual(signerKind(), null)
  assert.strictEqual(protectionEnabled(), false)
})

test('bootChain installs the read transport and the relay, in that order', () => {
  clearSigner()
  bootChain({ rpcUrl: 'http://127.0.0.1:8545', relayUrl: 'http://127.0.0.1:9999', relayName: 'test relay' })
  assert.strictEqual(hasRpc(), true)
  assert.strictEqual(PROTECT.url, 'http://127.0.0.1:9999')
  assert.strictEqual(PROTECT.name, 'test relay')
})

test('🔑 a locally installed key is NORMALISED, so its two identities agree by construction', () => {
  clearSigner()
  bootChain({ rpcUrl: 'http://127.0.0.1:8545' })
  const k = useLocalKey(KEY)

  assert.strictEqual(signerKind(), 'local')
  // The address the app shows and the x-only key a swap-in commits to are ONE point. This is the
  // half-of-all-users bug, closed at the only site that can install a key.
  assert.strictEqual(evmAddressFromXOnly(k.xOnly), k.evmAddress)
  assert.strictEqual(new ethers.Wallet(k.privateKey).address, k.evmAddress)
  // And it really did normalise rather than pass the raw key through.
  assert.strictEqual(k.privateKey, normaliseKey(KEY).privateKey)
})

test('🔑 an external wallet is supported and reports its cost honestly', async () => {
  clearSigner()
  bootChain({ rpcUrl: 'http://127.0.0.1:8545' })

  let asked: any = null
  useExternalWallet({
    async request(args) { asked = args; return '0x' + 'ab'.repeat(32) },
  })

  assert.strictEqual(signerKind(), 'external')
  // Not a failure state — the honest answer, because the wallet owns its own broadcast.
  assert.strictEqual(protectionEnabled(), false)

  const hash = await sendTx({ to: '0x' + '11'.repeat(20), data: '0xdeadbeef' })
  assert.strictEqual(asked.method, 'eth_sendTransaction', 'must pass through, not re-sign')
  assert.strictEqual(hash, '0x' + 'ab'.repeat(32))
})

test('switching custody does not leave the previous signer installed', () => {
  clearSigner()
  bootChain({ rpcUrl: 'http://127.0.0.1:8545' })
  useLocalKey(KEY)
  assert.strictEqual(signerKind(), 'local')
  useExternalWallet({ async request() { return '0x' } })
  assert.strictEqual(signerKind(), 'external')
  clearSigner()
  assert.strictEqual(signerKind(), null)
})

test('a write with no signer refuses rather than silently doing nothing', async () => {
  clearSigner()
  bootChain({ rpcUrl: 'http://127.0.0.1:8545' })
  await assert.rejects(() => sendTx({ to: '0x' + '11'.repeat(20) }), /no signer installed/)
})

test('addresses are injected at boot, and a malformed one is refused not zeroed', () => {
  clearSigner()
  const aux = '0x' + '1'.repeat(40)
  bootChain({ rpcUrl: 'http://127.0.0.1:8545', contracts: { aux } })
  assert.strictEqual(CONTRACTS.aux, aux)

  // ⚠️ A typo'd address coerced to ZERO would read as "not deployed" and render an empty screen
  // — a config bug wearing a chain bug's clothes. It must throw instead.
  assert.throws(() => setContracts({ basket: '0xnope' }), /not a 20-byte address/)
  assert.strictEqual(CONTRACTS.basket, '0x0000000000000000000000000000000000000000')
})

test('unset addresses stay zero, which the read path treats as not-deployed', () => {
  assert.strictEqual(CONTRACTS.vogue, '0x0000000000000000000000000000000000000000')
  // and the public token facts are defaulted, not injected
  assert.match(CONTRACTS.weth, /^0xC02aaA39/)
})
