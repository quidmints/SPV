//go:build wasip1

// notary_registry/main.go — Ukraine notary registry CRE workflow.
//
// Periodically (cron-triggered) fetches Ukraine's Ministry of Justice notary registry bulk
// XML/zip export (ern.minjust.gov.ua / data.gov.ua open-data catalog), parses it into a leaf
// set, builds a keccak Merkle tree over it, and anchors the root on-chain via
// RegistrySourceAnchor.publishSnapshot
// (backend/contracts/contracts/registry/RegistrySourceAnchor.sol) - the SAME ERC-7812 evidence
// registry every other root in this fusion (rarime identity state, PP's ASP) anchors into.
//
// THE POINT of routing this through CRE rather than a single relayer script: multiple
// independent Chainlink DON nodes fetch the SAME bulk export and must produce a byte-identical
// result (http.SendRequest + cre.ConsensusIdenticalAggregation, the exact pattern used for
// vendor price fetches in old/keeper/my-workflow/main.go) before a report is generated - no
// single operator can substitute a tampered registry snapshot. This is "the concept... a
// public, authoritative government source, same pattern as the OFAC list": a periodically-
// refreshed, cross-verified snapshot, explicitly NOT a live query endpoint (the open-data
// format IS a bulk export - this workflow treats it as one, not as something to poll
// per-request).
//
// OPERATOR TODO before deploying:
//  1. Config.RegistryEndpointURL must be filled in with the exact bulk-export URL from the
//     data.gov.ua catalog entry / ern.minjust.gov.ua for this dataset - deliberately left
//     empty here rather than guessed, since the exact deep link needs confirming against the
//     live catalog (see PP-NOIR-FUSION.md's CRE integration note, 2026-07-24).
//  2. NotaryRecordXML's field tags are a reasonable PLACEHOLDER schema (registration number /
//     full name / region / status), not a verified one - confirm against a real downloaded
//     sample before trusting parse results.
//  3. RegistrySourceAnchor's REGISTRY_POSTMAN role must be granted to whatever address this
//     workflow's WriteReport call resolves to (see RegistrySourceAnchor.onReport's own doc
//     comment for the Forwarder-trust caveat).
//
// Nothing here has been built/simulated/deployed yet - same standing constraint as the rest of
// this session's circuit work (not running the toolchain without approval); this is written to
// the same real-code, not-yet-compiled-and-verified standard as backend/circuits/withdraw_identity.
//
// Build:    GOOS=wasip1 GOARCH=wasm go build -o notary_registry.wasm .
// Simulate: cre workflow simulate notary_registry --trigger-index 0
package main

import (
	"encoding/hex"
	"fmt"
	"log/slog"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
)

// ═══════════════════════════════════════════════════════════════════
//  Configuration
// ═══════════════════════════════════════════════════════════════════

type Config struct {
	ChainSelectorName     string `json:"chainSelectorName"`
	RegistryAnchorAddress string `json:"registryAnchorAddress"`

	// See OPERATOR TODO #1 above - deliberately left for the deployer to fill in, not guessed.
	RegistryEndpointURL string `json:"registryEndpointUrl"`

	// Which register this deployment scrapes. Selects the status vocabulary (see
	// statusVocabularies) and derives the on-chain registryId, so a deployment cannot scrape one
	// country's portal while publishing under another's identifier.
	RegistryKey string `json:"registryKey"`

	// Cron schedule (standard 5-field cron expression). Defaults to daily - matches the "not
	// necessarily real-time" framing this mechanism is built around; a bulk export doesn't
	// change intra-day, so polling more often than the source republishes it buys nothing.
	Schedule string `json:"schedule"`
}

func (c *Config) applyDefaults() {
	if c.Schedule == "" {
		c.Schedule = "0 0 * * *" // daily
	}
	if c.RegistryKey == "" {
		c.RegistryKey = defaultRegistryKey
	}
}

// keccak256("UA_NOTARY_REGISTRY") - the registryId RegistrySourceAnchor keys this list's
// snapshots under. A constant, not per-config, because it identifies the LIST, not a deployment.

// ═══════════════════════════════════════════════════════════════════
//  Registry schema (placeholder pending a real sample export - see OPERATOR TODO #2)
// ═══════════════════════════════════════════════════════════════════

// NotaryRecordXML is one entry as parsed from the bulk export. Field tags are a reasonable guess
// at the real schema's shape, NOT verified against a real downloaded file.
// and a .zip wrapping one, since open-data catalogs commonly serve bulk exports zipped.
func fetchAndParse(sr *http.SendRequester, url string) ([]NotaryRecordXML, error) {
	resp, err := sr.SendRequest(&http.Request{Url: url, Method: "GET"}).Await()
	if err != nil {
		return nil, fmt.Errorf("fetch registry export: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("fetch registry export: status %d", resp.StatusCode)
	}

	return parseRegistryExport(resp.Body)
}

// parseRegistryExport turns a raw export body into records. SEPARATED FROM THE FETCH so it can be
// tested without a DON, a network or a CRE runtime - this is the part that ROTS (sec. 2.15a: "a
// government portal changes its HTML and the scraper breaks"), and consensus does not protect it.
// cre.ConsensusIdenticalAggregation makes every node agree; it cannot make them agree CORRECTLY, so
// a parser that silently returns fewer notaries reaches consensus on a wrong answer.

//  ABI: RegistrySourceAnchor.onReport's decoded payload shape
//  (bytes32 registryId, bytes32[] leaves) - the CONTRACT computes and verifies the root from
//  these leaves on-chain (RegistrySourceAnchor._computeRoot); this workflow does not submit a
//  separately-claimed root at all, so there is no way for an on-chain root to end up
//  disconnected from a real, fully-available leaf set. `leaves` doubles as the on-chain data-
//  availability layer (emitted via SnapshotLeaves) - no IPFS or other external pinning
//  dependency; leaves are just the transaction's own calldata/event data, permanently replayable
//  by any full node.
// ═══════════════════════════════════════════════════════════════════

var (
	bytes32Type, _      = abi.NewType("bytes32", "", nil)
	bytes32ArrayType, _ = abi.NewType("bytes32[]", "", nil)
)

var snapshotABI = abi.Arguments{
	{Type: bytes32Type},      // registryId
	{Type: bytes32ArrayType}, // leaves
}

// ═══════════════════════════════════════════════════════════════════
//  Handler
// ═══════════════════════════════════════════════════════════════════

// The cron trigger's own payload (2nd param) is unused - onSchedule's job is entirely
// self-contained (fetch, aggregate, publish), it doesn't need anything the trigger carries.
func onSchedule(config *Config, runtime cre.Runtime, _ *cron.Payload) (string, error) {
	logger := runtime.Logger()

	chainSel, err := evm.ChainSelectorFromName(config.ChainSelectorName)
	if err != nil {
		return "", fmt.Errorf("unknown chain %s: %w", config.ChainSelectorName, err)
	}
	evmClient := &evm.Client{ChainSelector: chainSel}

	httpClient := &http.Client{}
	recordsPromise := http.SendRequest(config, runtime, httpClient,
		func(cfg *Config, lg *slog.Logger, sr *http.SendRequester) (*[]NotaryRecordXML, error) {
			records, err := fetchAndParse(sr, cfg.RegistryEndpointURL)
			if err != nil {
				return nil, err
			}
			return &records, nil
		},
		cre.ConsensusIdenticalAggregation[*[]NotaryRecordXML](),
	)

	recordsPtr, err := recordsPromise.Await()
	if err != nil || recordsPtr == nil {
		logger.Error(fmt.Sprintf("[notary_registry] fetch/consensus failed: %v", err))
		return "", fmt.Errorf("fetch/consensus failed: %w", err)
	}
	records := *recordsPtr

	// Only ACTIVE notaries are admitted as leaves - a suspended/terminated entry proves nothing
	// useful. This tree has no update/removal semantics of its own (unlike PP's LeanIMT or
	// rarime's SMT); each publish is a fresh full rebuild from the current export instead, so
	// dropped/reinstated entries are simply reflected in the next scheduled snapshot.
	// An unknown status ABORTS rather than silently omitting that notary (sec. 2.18ao). Publishing a
	// snapshot that quietly excludes someone is censorship by parse error; refusing to publish is a
	// visible outage that a human fixes.
	leaves, err := activeLeaves(records, config.RegistryKey)
	if err != nil {
		logger.Error(fmt.Sprintf("[notary_registry] %v", err))
		return "", err
	}
	if len(leaves) == 0 {
		err := fmt.Errorf("zero active notaries parsed from a %d-record export - refusing to publish an empty root", len(records))
		logger.Error(fmt.Sprintf("[notary_registry] %v", err))
		return "", err
	}
	// merkleRoot sorts `leaves` in place (Go slices share their backing array, so this reorders
	// the caller's slice too) - by the time we log/submit below, `leaves` is already the exact
	// strictly-ascending order RegistrySourceAnchor._computeRoot requires.
	root := merkleRoot(leaves)
	logger.Info(fmt.Sprintf("[notary_registry] %d active / %d total notaries, root=0x%x", len(leaves), len(records), root))

	// leaves ARE the on-chain data-availability layer (see the ABI comment above) - no IPFS CID,
	// no external pinning service. The contract recomputes and verifies this exact root from
	// `leaves` itself; `root` here is only used for the log line above, not submitted separately.
	payload, err := snapshotABI.Pack(registryIDFor(config.RegistryKey), leaves)
	if err != nil {
		return "", fmt.Errorf("abi pack failed: %w", err)
	}
	reportResp, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: payload,
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[notary_registry] GenerateReport failed: %v", err))
		return "", fmt.Errorf("GenerateReport: %w", err)
	}
	writeResp, err := evmClient.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  common.HexToAddress(config.RegistryAnchorAddress).Bytes(),
		Report:    reportResp,
		GasConfig: &evm.GasConfig{GasLimit: 300000},
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[notary_registry] WriteReport failed: %v", err))
		return "", fmt.Errorf("WriteReport: %w", err)
	}

	txHash := hex.EncodeToString(writeResp.TxHash)
	logger.Info(fmt.Sprintf("[notary_registry] anchored root 0x%x, tx %s", root, txHash))
	return txHash, nil
}

// ═══════════════════════════════════════════════════════════════════
//  Workflow initialization: cron trigger only - this mechanism is explicitly NOT a live query
//  endpoint (see the header comment), so it has no HTTP/log trigger, unlike my-workflow's
//  dual-trigger design.
// ═══════════════════════════════════════════════════════════════════

func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	config.applyDefaults()

	scheduleTrigger := cron.Trigger(&cron.Config{Schedule: config.Schedule})

	return cre.Workflow[*Config]{
		cre.Handler(scheduleTrigger, onSchedule),
	}, nil
}

func main() {
	wasm.NewRunner(cre.ParseJSON[Config]).Run(InitWorkflow)
}
