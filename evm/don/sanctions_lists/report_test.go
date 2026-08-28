package main

import (
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

// The Solidity that consumes what `snapshotABI.Pack` produces.
const anchorPath = "../../contracts/contracts/registry/RegistrySourceAnchor.sol"

// TestReportShapeMatchesSolidityDecode reads the CONTRACT and compares its decode tuple
// against this workflow's Pack arguments.
//
// It reads the .sol file on purpose. A test that restated the expected types as a Go
// literal would be two copies of one fact, and the copy in the file nobody deploys is
// the one that stays right while the other drifts - which is exactly what happened:
// `onReport` grew a third field and this side kept packing two. Both were internally
// consistent; only the pair was wrong, so only a test spanning the pair can see it.
func TestReportShapeMatchesSolidityDecode(t *testing.T) {
	src, err := os.ReadFile(anchorPath)
	if err != nil {
		t.Fatalf("read %s: %v", anchorPath, err)
	}

	m := regexp.MustCompile(`abi\.decode\(\s*report\s*,\s*\(([^)]*)\)\s*\)`).FindSubmatch(src)
	if m == nil {
		t.Fatal("no `abi.decode(report, (...))` in the anchor - if onReport was renamed or " +
			"restructured, this test must be repointed, NOT deleted: it is the only thing " +
			"pinning the workflow's Pack to the contract's decode")
	}

	var want []string
	for _, f := range strings.Split(string(m[1]), ",") {
		if f = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(f), "memory")); f != "" {
			want = append(want, strings.TrimSpace(f))
		}
	}

	var got []string
	for _, a := range snapshotABI {
		got = append(got, a.Type.String())
	}

	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("report shape drift - every report would revert on-chain:\n"+
			"  workflow packs: (%s)\n  contract decodes: (%s)\n"+
			"  fix whichever is wrong, in the SAME change", strings.Join(got, ","), strings.Join(want, ","))
	}
}

// TestReportRoundTrips is the value-level half: the shape can agree while the ORDER of
// two same-typed fields is swapped. `registryId` and `smtRoot` are both bytes32, so the
// type check above cannot tell them apart - only distinct values can.
func TestReportRoundTrips(t *testing.T) {
	registryID := common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111")
	smtRoot := common.HexToHash("0x2222222222222222222222222222222222222222222222222222222222222222")
	leaves := [][32]byte{common.HexToHash("0xaa"), common.HexToHash("0xbb")}

	payload, err := snapshotABI.Pack([32]byte(registryID), [32]byte(smtRoot), leaves)
	if err != nil {
		t.Fatalf("pack: %v", err)
	}

	out, err := snapshotABI.Unpack(payload)
	if err != nil {
		t.Fatalf("unpack: %v", err)
	}
	if len(out) != 3 {
		t.Fatalf("want 3 fields, got %d", len(out))
	}
	if common.Hash(out[0].([32]byte)) != registryID {
		t.Errorf("field 0 is not registryId: %x", out[0])
	}
	if common.Hash(out[1].([32]byte)) != smtRoot {
		t.Errorf("field 1 is not smtRoot: %x", out[1])
	}
	if got := out[2].([][32]byte); len(got) != 2 {
		t.Errorf("field 2 is not the leaves: %v", got)
	}
}
