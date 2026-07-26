# QU!D production provisioning

> **The full end-to-end launch runbook (Solidity + Rust + the SGX-hardware tail)
> is [`PRODUCTION-LAUNCH.md`](./PRODUCTION-LAUNCH.md)** — start there. This file is
> the quick command/env reference it builds on. NOTE: prod/staging run the
> daemons **inside SGX** and the hop seed is **born-in-enclave** (so `QUID_SEED`
> is optional — see PRODUCTION-LAUNCH.md); the plain `run-hop.sh`/`run-lp.sh`
> flow below is the host/dev path.

Operational scripts to deploy the L1 contracts and run the two off-chain
services: the **hop** (the protocol's Lightning↔EVM node, one instance) and the
**LP** (liquidity providers, many — each funds BTC channels to the hop and
authorizes their on-chain open).

Provisioning order:

1. **Deploy the L1 contracts** — `deploy/deploy-l1.sh` (wraps
   `evm/src/DeployL1_s.sol:Deploy`). Deploys the full topology incl. SPVGateway
   (anchored at a Bitcoin checkpoint) + BTCChannels (with `hopNode` =
   `HOP_NODE_OPERATOR`). Record the printed addresses.
2. **Run the hop** — `deploy/run-hop.sh` (wraps `quid-bridge-daemon`). The hop
   drives swap-in/out settlement, the SPV header relayer, and the BTC-channel
   driver (`openChannel`/`recordClose`) + reconciler. Its hot key must equal the
   on-chain `hopNode` or every settle/open reverts `NotLP`.
3. **Onboard LPs** — `deploy/run-lp.sh` (wraps `quid-lp-daemon`). Each LP runs a
   node connected to the hop, funds a channel, and runs the lpAuth responder
   that signs each open the hop drives. The LP's EVM key only ever signs the
   off-chain `lpAuth` digest — it never sends EVM txs (the hop pays gas).

Copy the `*.env.example` templates, fill them in, and pass the path:

    cp deploy/deploy.env.example deploy/deploy.env   # edit
    BROADCAST=1 deploy/deploy-l1.sh deploy/deploy.env

    cp deploy/hop.env.example deploy/hop.env         # edit (addresses from step 1)
    deploy/run-hop.sh deploy/hop.env

    cp deploy/lp.env.example deploy/lp.env           # edit
    deploy/run-lp.sh deploy/lp.env

`*.env` files (your filled-in secrets) are git-ignored; only the `*.example`
templates are tracked.

## Local end-to-end against a real EVM (no mock)

`regtest/driver-e2e.sh` bootstraps anvil + foundry + bitcoind/electrs, deploys
`DriverE2E.s.sol` (real SPVGateway + BTCChannels), and runs the Rust driver
against it on regtest — see that script.
