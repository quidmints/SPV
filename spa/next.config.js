// Build-time commit pin: the SPA is deployed from the commit that carries
// evm/deployments/l1.json, and the site surfaces this SHA (BuildStamp) so a
// visitor can confirm WHICH commit's JavaScript is running and cross-check the
// contract addresses against that commit's committed deployment record.
// CI/Deno Deploy can override via NEXT_PUBLIC_COMMIT when .git isn't present.
let commit = process.env.NEXT_PUBLIC_COMMIT || ''
if (!commit) {
  try { commit = require('child_process').execSync('git rev-parse HEAD').toString().trim() } catch { commit = 'unknown' }
}

/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  env: { NEXT_PUBLIC_COMMIT: commit },
  webpack: (config) => {
    config.watchOptions = {
      ...config.watchOptions,
      ignored: ['**/node_modules/**', '**/evm/**', '**/svm/**'],
    }
    // borsh references text-encoding-utf-8 + encoding for legacy Node support.
    // Modern Node has TextEncoder/TextDecoder built in, so these can be marked
    // false (resolved to empty modules at build time).
    config.resolve = config.resolve || {}
    config.resolve.fallback = {
      ...(config.resolve.fallback || {}),
      'text-encoding-utf-8': false,
      'encoding': false,
      // @coral-xyz/anchor's workspace module references these for the Node
      // CLI side (reading Anchor.toml). The frontend never executes that
      // codepath but webpack still tries to resolve the imports. Setting
      // false makes them no-ops in the browser bundle.
      'toml': false,
      'fs': false,
      'path': false,
    }
    return config
  },
}

module.exports = nextConfig
