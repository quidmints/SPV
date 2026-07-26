# SPA deploy (Deno Deploy) — commit-pinned, address-pinned

The SPA's contract addresses come from the **committed** deployment record
`evm/deployments/l1.json` (written by `evm/src/DeployL1_s.sol` on every run —
dry-runs included; `deploy/deploy-l1.sh` is dry-run by default). The build inlines
`NEXT_PUBLIC_COMMIT` (= `git rev-parse HEAD`, next.config.js) and renders it as the
`BuildStamp` (landing footer + fixed corner of the `/app` dashboard, with
`data-commit` / `data-basket` attributes). A visitor verifies what they're running by:

1. reading the build stamp SHA on the site,
2. checking out that commit in the repo,
3. comparing `evm/deployments/l1.json` there against the addresses the app talks to
   (also embedded in the stamp's `title`/`data-basket`).

So the deployed commit MUST be the one that carries the final `l1.json` (and the
matching `evm/broadcast/DeployL1_s.sol/1/**/run-latest.json` — both are tracked,
NOT gitignored). Sequence for a release:

```sh
# 1. simulate the deploy (writes evm/deployments/l1.json + broadcast dry-run JSON)
cd evm && forge script src/DeployL1_s.sol:Deploy --rpc-url mainnet --skip 'test/**'
# 2. commit the deployment JSONs        3. broadcast for real (same deployer nonce!)
#    (any tx from the deployer between simulate and broadcast shifts the CREATE
#     nonces and invalidates the recorded addresses — re-run step 1 if so)
BROADCAST=1 deploy/deploy-l1.sh evm/.env
# 4. deno-deploy the SPA from that commit
cd spa && npm run build
deployctl deploy --project=<project> --include=.next,public,package.json \
  node_modules/.bin/next start   # or connect the repo in the Deno Deploy dashboard
```

Notes:
- `next.config.js` uses `output: 'standalone'`; Deno Deploy runs it via Node compat.
  If the environment has no `.git` (e.g. tarball deploy), pass the SHA explicitly:
  `NEXT_PUBLIC_COMMIT=$(git rev-parse HEAD) npm run build`.
- The only server route is `/api/market` (CoinGecko poll, cached 120 s); everything
  chain-facing is client-side against the pinned addresses.
- Local anvil-fork e2e still overrides addresses via `spa/.env.local`
  (`NEXT_PUBLIC_BASKET` etc.) — env wins over the committed JSON per address.
