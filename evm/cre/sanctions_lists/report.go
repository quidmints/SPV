// sanctions_lists/report.go — the on-chain report encoding, deliberately UNTAGGED.
//
// `main.go` is `//go:build wasip1`, because it needs the CRE runtime. This file needs
// none of it: it is pure ABI shape. Splitting it out is what lets a test running on the
// DEVELOPER'S machine see `snapshotABI` at all.
//
// ⚠️ THAT SPLIT IS THE WHOLE POINT, AND IT WAS PAID FOR. While this lived in `main.go`,
// the arity here and the `abi.decode` in `RegistrySourceAnchor.onReport` could drift
// apart with nothing to catch it: the host-arch `go test` excluded `main.go` by build
// tag, so it compiled, passed, and proved NOTHING about this encoding. A field was added
// to the contract's decode and this Pack kept sending the old shape - every report would
// have reverted on-chain, at a cost measured in a live workflow run.
//
// `report_test.go` now pins the shape against the Solidity signature. Keep both in step.

package main

import "github.com/ethereum/go-ethereum/accounts/abi"

var (
	bytes32Type, _      = abi.NewType("bytes32", "", nil)
	bytes32ArrayType, _ = abi.NewType("bytes32[]", "", nil)
)

var snapshotABI = abi.Arguments{
	{Type: bytes32Type},      // registryId
	{Type: bytes32Type},      // smtRoot
	{Type: bytes32ArrayType}, // leaves
}

// ⚠️ THE SECOND FIELD IS A POSEIDON SMT ROOT, NOT THE KECCAK ONE, AND SWAPPING THEM IS SILENT.
//
//	smtRoot   Poseidon, sparse, keyed. The ONLY one a circuit can verify, and what the pool
//	          enforces. Built by BuildBlacklist from the document keys.
//	leaves    keccak, dense. Hashed on-chain into the transparency root; covers every designation.
//
// They cover different populations on purpose - see blacklist.go. Passing one where the other
// belongs type-checks, anchors, and leaves the pool enforcing a root no witness can satisfy.
