//go:build wasip1

// sanctions_lists/main.go — the CRE workflow that anchors a published sanctions list.
//
// The sanctions half of TODO.md sec. 2.5's closed predicate set. Cron-triggered, it fetches ONE
// declared list's published export, decodes it into a leaf set, builds a keccak Merkle tree and
// anchors the root on-chain via RegistrySourceAnchor.publishSnapshot — the same ERC-7812 evidence
// registry every other root in this fusion anchors into. Structurally a sibling of
// notary_registry/main.go; read that first, this deliberately mirrors it rather than inventing a
// second shape.
//
// ONE LIST PER DEPLOYMENT. `Config.RegistryKey` names which — `OFAC_SDN` (US), `UK_OFSI_CONSOLIDATED`
// (UK), `UN_SC_CONSOLIDATED` (UN). Everything jurisdiction-specific is declared in `sources.go`;
// this file is the same for all of them. Two lists in one root would let membership in "some
// sanctions list" stand in for designation under a SPECIFIC legal regime, which no relying party
// could check — the same reasoning `notary_registry` uses for one jurisdiction per deployment.
//
// WHY CRE AND NOT A RELAYER SCRIPT. Every DON node fetches the SAME export independently and must
// produce a BYTE-IDENTICAL result (http.SendRequest + cre.ConsensusIdenticalAggregation) before a
// report is generated. That is the property that makes this an ANCHORED EXTERNAL AUTHORITY rather
// than an operator's opinion, which is the whole justification for admitting "listed by an
// authority" into a closed predicate set that is otherwise deliberately tiny. A single relayer could
// substitute a tampered snapshot and nobody could tell; this cannot. What consensus does NOT cover
// is whether the DECODER is right — see sources.go, and its tests.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
// WHAT THIS WORKFLOW DOES NOT DO, AND MUST NOT BE ASSUMED TO DO.
//
// It anchors "here is list L at time T". It does NOT revoke anybody, and it CANNOT: the missing
// step is the link from "person P is on the list" to "holderRoot H belongs to person P". That
// mapping does not exist on-chain by construction — the entire point of the identity ASP is that a
// holderRoot reveals nothing about who its owner is.
//
// So a sanctions hit cannot be turned into a revocation by this workflow alone. Whoever performed
// the original identity check is the only party holding that correspondence, and any design that
// resolves it has to answer a privacy question this file cannot: WHO is allowed to learn that
// holderRoot H is person P, and what stops them asserting it falsely? Deliberately left open here
// rather than papered over with a plausible-looking mechanism — see TODO.md sec. 2.5.
//
// The honest shape of the remaining work is an ATTESTER CONTRACT holding the RevocationRegistry's
// sanctions predicate, which accepts a proof that some identity is in the anchored set and revokes
// on that basis. Deploy it as a CONTRACT, never an EOA: the registry's attester is immutable, so a
// contract's internal key rotation is the only way to recover from a key compromise (sec. 2.5a).
//
// AND WHAT IT CANNOT PROVE EVEN THEN: all three declared lists are `membershipMeansListed`, so
// DELISTING is an absence claim and a keccak Merkle root cannot prove absence (sec. 2.18bp). An
// attester built on this can revoke on a hit; nothing here can reinstate on a removal. That is a
// property of what the authorities publish, not of our design, and it must not be papered over.
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// OPERATOR TODO before deploying:
//  1. Config.RegistryKey must name a declared source. THE URL IS NO LONGER AN OPERATOR INPUT —
//     it is `SourceSpec.PublishedAt`, compiled in, so there is nothing to compare and nothing to get
//     wrong. See the note on `PublishedAt` in sources.go for why the config indirection was dropped.
//  2. RegistrySourceAnchor's REGISTRY_POSTMAN role must be granted to the address this workflow's
//     WriteReport resolves to (see RegistrySourceAnchor.onReport's Forwarder-trust note), and a
//     workflow version must be PINNED AND ACTIVE or `_publishSnapshot` reverts NoActiveWorkflow.
//  3. Decide the linkage question above BEFORE wiring any attester. Anchoring a list is safe and
//     useful on its own; revoking on it is not, until that is answered.
//
// NOT BUILT OR SIMULATED against a live DON — no deployed environment exists yet. It compiles:
//
//	GOOS=wasip1 GOARCH=wasm go build ./...
//
// and the logic it calls is host-testable: `go test ./...`.
// Simulate: cre workflow simulate sanctions_lists --trigger-index 0
package main

import (
	"encoding/hex"
	"fmt"
	"log/slog"
	"strings"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
)

type Config struct {
	ChainSelectorName     string `json:"chainSelectorName"`
	RegistryAnchorAddress string `json:"registryAnchorAddress"`

	// Which declared list this deployment anchors. See `sources` in sources.go.
	RegistryKey string `json:"registryKey"`

	// Standard 5-field cron. Defaults to daily: the authorities republish on their own schedules, so
	// polling more often than they change buys nothing and only widens the window in which nodes
	// could observe different bytes mid-publish.
	Schedule string `json:"schedule"`
}

func (c *Config) applyDefaults() {
	if c.Schedule == "" {
		c.Schedule = "0 0 * * *" // daily
	}
}

// ═══════════════════════════════════════════════════════════════════
//  Fetch (node mode - every DON node runs this independently)
// ═══════════════════════════════════════════════════════════════════

// fetchAndDecode is the only part of the pipeline that touches the network; everything it hands on
// lives in sources.go and is tested on the host.
//
// NOTHING RE-SORTS THE DECODED ROWS. Consensus requires every node to produce identical output from
// identical bytes, and document order already is that — a re-sort would add a comparison that must
// itself be total (the version this replaced sorted by uid with `sort.Slice`, which is not stable,
// so equal keys ordered arbitrarily). The ordering that actually matters is over LEAVES, and
// `snapshotLeaves` owns it because the CONTRACT requires it.
// Snapshot is everything one fetch yields: the source's own health signals, and the payload.
//
// ⚠️ ONE STRUCT BECAUSE IT IS ONE CONSENSUS ROUND. Every DON node must agree on identical bytes, so
// fetching twice would mean two rounds over two responses that a mid-publish update could make
// differ - and the second round would fail consensus for a reason having nothing to do with either
// payload. Decoding both views from ONE body removes that failure mode by construction.
type Snapshot struct {
	// Subjects are the designations. NOT anchored any more - see blacklist.go on why a name tree
	// cannot be consumed - but still decoded, because `AlwaysPresent` and the manifest count are the
	// only checks that catch a SCHEMA CHANGE upstream. A feed that silently renamed a field would
	// otherwise publish an empty key set and look healthy.
	Subjects []ListedSubject
	// Passports are the rows the predicate can actually key.
	Passports []PassportRow
}

func fetchAndDecode(sr *http.SendRequester, registryKey, url string, ids IdentifierSet) (Snapshot, error) {
	resp, err := sr.SendRequest(&http.Request{Url: url, Method: "GET"}).Await()
	if err != nil {
		return Snapshot{}, fmt.Errorf("%s fetch: %w", registryKey, err)
	}

	subjects, err := decodeSubjects(registryKey, resp.Body)
	if err != nil {
		return Snapshot{}, err
	}

	// A source with no identifier set declared yields no keys. That is a real state - not every
	// register publishes document numbers - and it must be visible rather than inferred from an
	// empty tree, so the caller checks it.
	var passports []PassportRow
	if ids.Path != "" {
		listed, err := decodeIdentifiers(resp.Body, ids)
		if err != nil {
			return Snapshot{}, fmt.Errorf("%s identifiers: %w", registryKey, err)
		}
		passports = make([]PassportRow, 0, len(listed))
		for _, l := range listed {
			passports = append(passports, PassportRow{Number: l.Value, Country: l.Country})
		}
	}
	return Snapshot{Subjects: subjects, Passports: passports}, nil
}

// ═══════════════════════════════════════════════════════════════════
//  Handler
// ═══════════════════════════════════════════════════════════════════

func onSchedule(config *Config, runtime cre.Runtime, _ *cron.Payload) (string, error) {
	logger := runtime.Logger()

	chainSel, err := evm.ChainSelectorFromName(config.ChainSelectorName)
	if err != nil {
		return "", fmt.Errorf("unknown chain %s: %w", config.ChainSelectorName, err)
	}

	// Resolve the source BEFORE fetching: an undeclared registry key must fail without spending a
	// DON-wide HTTP round trip, and the error names the omission rather than a parse failure
	// downstream of it.
	spec, err := sourceFor(config.RegistryKey)
	if err != nil {
		return "", err
	}
	httpClient := &http.Client{}

	snapshotPromise := http.SendRequest(config, runtime, httpClient,
		func(cfg *Config, lg *slog.Logger, sr *http.SendRequester) (*Snapshot, error) {
			// `spec` is captured, not re-resolved: it was already validated above, and a second
			// lookup would need an error path that cannot be reached.
			out, err := fetchAndDecode(sr, cfg.RegistryKey, spec.PublishedAt, spec.Identifiers)
			if err != nil {
				return nil, err
			}
			return &out, nil
		},
		cre.ConsensusIdenticalAggregation[*Snapshot](),
	)

	snapshot, err := snapshotPromise.Await()
	if err != nil || snapshot == nil {
		logger.Error(fmt.Sprintf("[%s] fetch/consensus failed: %v", spec.Key, err))
		return "", fmt.Errorf("fetch/consensus failed: %w", err)
	}

	// TWO TREES, AND THEY COVER DIFFERENT POPULATIONS - which is why they are not redundant and
	// must not be collapsed into one. It was tried:
	//
	//	leaves   EVERY designation, keyed by name. The transparency artefact, and the only thing
	//	         UK_OFSI and UN_SC can publish at all - neither register carries document numbers.
	//	smtRoot  only designations the PREDICATE can key. What the pool enforces.
	//
	// ⛔ MAKING THE LEAVES THE KEYS LOOKED LIKE AN ELEGANT COLLAPSE AND WAS A SILENT REGRESSION:
	// those two registries would have anchored an EMPTY leaf set and a zero root while continuing to
	// report success. A tree of names cannot be consumed by a predicate, and a tree of keys cannot
	// represent a register that publishes no keys. Both statements are true at once.
	bl, err := BuildBlacklist(snapshot.Passports)
	if err != nil {
		return "", fmt.Errorf("%s blacklist: %w", spec.Key, err)
	}

	leaves := snapshotLeaves(spec.Key, snapshot.Subjects)
	root, err := merkleRoot(leaves)
	if err != nil {
		return "", fmt.Errorf("%s root: %w", spec.Key, err)
	}

	registryID := registryIDFor(spec.Key)
	logger.Info(fmt.Sprintf("[%s] %d designations -> %d leaves, %d keyed -> smt %s, root %s",
		spec.Key, len(snapshot.Subjects), len(leaves), len(bl.Leaves),
		common.BytesToHash(bl.SmtRoot[:]).Hex(), common.BytesToHash(root[:]).Hex()))

	// ⚠️ SKIPS ARE LOGGED AT WARN, EVERY RUN, WITH A REASON. For an EXCLUSION predicate a row that
	// could not be keyed is a FALSE NEGATIVE - that person's document is absent from the tree, so
	// their withdrawal passes. The publication proceeds anyway, because failing it over one
	// unmappable country would halt every withdrawal instead; the trade is only defensible while the
	// omissions are visible, so this is the one place that makes them so.
	if len(bl.Skipped) > 0 {
		logger.Warn(fmt.Sprintf("[%s] %d listed rows could not be keyed and are NOT enforced",
			spec.Key, len(bl.Skipped)))
		for _, sk := range bl.Skipped {
			logger.Warn(fmt.Sprintf("[%s]   %s: %s", spec.Key, sk.Number, sk.Reason))
		}
	}

	// A source that declares identifiers and yields none is a schema change wearing a healthy face:
	// the tree would be empty, and an empty exclusion tree admits EVERYONE. The pool refuses a zero
	// root, so this would halt withdrawals rather than open them - but it must fail HERE, naming the
	// cause, rather than downstream as an unexplained halt.
	if spec.Identifiers.Path != "" && len(bl.Leaves) == 0 {
		return "", fmt.Errorf(
			"%s declares identifiers at %q but keyed none of %d designations - the schema has changed",
			spec.Key, spec.Identifiers.Path, len(snapshot.Subjects))
	}

	payload, err := snapshotABI.Pack(registryID, bl.SmtRoot, leaves)
	if err != nil {
		return "", fmt.Errorf("abi pack: %w", err)
	}

	reportResp, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: payload,
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[%s] GenerateReport failed: %v", spec.Key, err))
		return "", fmt.Errorf("GenerateReport: %w", err)
	}

	evmClient := &evm.Client{ChainSelector: chainSel}

	// DO NOT PUBLISH AS A WORKFLOW THE CONTRACT HAS NOT PINNED (sec. 2.18cq).
	if err := assertPinnedWorkflow(runtime, evmClient, config, reportResp, logger, spec.Key); err != nil {
		return "", err
	}

	writeResp, err := evmClient.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  common.HexToAddress(config.RegistryAnchorAddress).Bytes(),
		Report:    reportResp,
		GasConfig: &evm.GasConfig{GasLimit: 300000},
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[%s] WriteReport failed: %v", spec.Key, err))
		return "", fmt.Errorf("WriteReport: %w", err)
	}

	return fmt.Sprintf("%s anchored %d leaves, %d enforceable keys (%d unkeyable), tx %x",
		spec.Key, len(leaves), len(bl.Leaves), len(bl.Skipped), writeResp.TxHash), nil
}

// activeWorkflowIDSelector is `keccak256("activeWorkflowId()")[:4]` - derived rather than pasted, so
// a rename on the contract side surfaces as a failing call instead of a silently wrong four bytes.
var activeWorkflowIDSelector = crypto.Keccak256([]byte("activeWorkflowId()"))[:4]

// assertPinnedWorkflow refuses to publish when the workflow that produced this report is not the one
// `RegistrySourceAnchor` currently pins.
//
// BE EXACT ABOUT WHAT THIS IS, BECAUSE IT IS EASY TO OVERSELL. **It is not a defence against rogue
// code.** Rogue code deletes this function. A workflow cannot attest to its own integrity - anything
// it computes about itself, a modified copy computes differently. The ENFORCEMENT lives in the
// contract, which compares the workflow ID in the report metadata against its pin and rejects a
// mismatch (sec. 2.18ck); that check is on the other side of the trust boundary and cannot be edited
// by whoever changed the workflow.
//
// WHAT IT IS FOR, then. This workflow runs on a CRON. Without the check, a deployment that is stale or
// was never pinned discovers the problem only when the transaction reverts - and then repeats that
// discovery, at gas, on every tick. Failing here converts a recurring on-chain revert into one clear
// refusal at the source, before anything is spent, and names both IDs so the fix is obvious.
//
// SO IT IS AN OPERATIONAL GUARD, NOT A SECURITY ONE, and the distinction is the same one sec. 2.18cp
// had to make about the postman: what a party can be trusted to do is not the same question as what
// the system will accept.
func assertPinnedWorkflow(
	runtime cre.Runtime,
	evmClient *evm.Client,
	config *Config,
	report *cre.Report,
	logger *slog.Logger,
	registryKey string,
) error {
	ours := report.WorkflowID()

	reply, err := evmClient.CallContract(runtime, &evm.CallContractRequest{
		Call: &evm.CallMsg{
			To:   common.HexToAddress(config.RegistryAnchorAddress).Bytes(),
			Data: activeWorkflowIDSelector,
		},
	}).Await()
	if err != nil {
		// FAIL CLOSED. An unreadable pin is not evidence of a good one, and publishing anyway would
		// make the check decoration in exactly the conditions it exists for.
		logger.Error(fmt.Sprintf("[%s] could not read activeWorkflowId: %v", registryKey, err))
		return fmt.Errorf("read activeWorkflowId: %w", err)
	}
	if len(reply.Data) < 32 {
		return fmt.Errorf("activeWorkflowId returned %d bytes, want 32", len(reply.Data))
	}

	// A bytes32 return is right-padded into a 32-byte word; the ID is the whole word.
	active := hex.EncodeToString(reply.Data[len(reply.Data)-32:])

	if active == strings.Repeat("0", 64) {
		return fmt.Errorf("no workflow is pinned yet - refusing to publish %s", registryKey)
	}
	if !strings.EqualFold(active, ours) {
		logger.Error(fmt.Sprintf("[%s] REFUSING TO PUBLISH: this workflow is %s, the anchor pins %s",
			registryKey, ours, active))
		return fmt.Errorf("workflow %s is not the pinned workflow %s", ours, active)
	}
	return nil
}

func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	config.applyDefaults()

	scheduleTrigger := cron.Trigger(&cron.Config{Schedule: config.Schedule})
	return cre.Workflow[*Config]{cre.Handler(scheduleTrigger, onSchedule)}, nil
}

func main() {
	wasm.NewRunner(cre.ParseJSON[Config]).Run(InitWorkflow)
}
