module ibiza/notary-registry-cre

go 1.25.3

// go.mod for the CRE notary-registry workflow. `go mod tidy` + `go build ./...` run and confirmed
// green on 2026-07-25 (see go.sum) - main.go compiles clean against every pin below.
//
// DEPENDENCY FRESHNESS PASS (2026-07-25): bumped to the latest STABLE (non-capdev/-rc/-alpha)
// tags as of this check - go-ethereum v1.16.4 -> v1.17.4; cre-sdk-go core v1.0.0 -> v1.15.0;
// http capability v1.0.0-beta.0 -> v1.4.0 (exited beta since this session's main.go was written
// against old/keeper's reference code); cron capability -> v1.3.0 (its own latest stable tag -
// an earlier pass incorrectly bumped it to v1.4.0, which only exists for http/evm as
// v1.4.0-capdev.1 for cron, a non-stable capdev tag; caught by `go mod tidy` itself failing to
// resolve it, not by inspection); evm capability -> v1.0.0-beta.15 (still beta upstream, no
// stable tag exists yet).
require (
	github.com/ethereum/go-ethereum v1.17.4
	github.com/smartcontractkit/cre-sdk-go v1.15.0
	github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm v1.0.0-beta.15
	github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http v1.4.0
	github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron v1.3.0
)

require (
	github.com/ProjectZKM/Ziren/crates/go-runtime/zkvm_runtime v0.0.0-20251001021608-1fe7b43fc4d6 // indirect
	github.com/davecgh/go-spew v1.1.2-0.20180830191138-d8f796af33cc // indirect
	github.com/decred/dcrd/dcrec/secp256k1/v4 v4.0.1 // indirect
	github.com/go-viper/mapstructure/v2 v2.4.0 // indirect
	github.com/holiman/uint256 v1.3.2 // indirect
	github.com/pmezard/go-difflib v1.0.1-0.20181226105442-5d4384ee4fb2 // indirect
	github.com/shopspring/decimal v1.4.0 // indirect
	github.com/smartcontractkit/chainlink-protos/cre/go v0.0.0-20260707203317-661b54b51a33 // indirect
	github.com/stretchr/testify v1.11.1 // indirect
	golang.org/x/sys v0.41.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)
