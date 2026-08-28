// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/**
 * A CRE report metadata header, byte-for-byte the shape the consensus plugin emits.
 *
 * ONE DEFINITION, because two would defeat the purpose. `RegistrySourceAnchor.onReport` reads the
 * workflow ID at a fixed offset in this header, and a test that builds the header with the SAME
 * mistake the contract makes would agree with it and prove nothing. Keeping a single builder here
 * means every suite exercises one layout, and the offset is pinned in exactly one place.
 *
 * Layout, from the SDK this repo depends on (cre-sdk-go v1.15.0 `cre/report_fields.go`, citing
 * `chainlink-common pkg/capabilities/consensus/ocr3/types.Metadata`):
 *
 *   version 1 || executionId 32 || timestamp 4 || donId 4 || donConfigVersion 4 ||
 *   workflowId 32 || workflowName 10 || workflowOwner 20 || reportId 2   = 109 bytes
 */
contract CreReportMetadata {
    function _metadata(bytes32 workflowId_) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                uint8(1), // version
                keccak256('execution-id'), // executionId
                uint32(1_700_000_000), // timestamp
                uint32(7), // donId
                uint32(2), // donConfigVersion
                workflowId_,
                bytes10('wf-notary'),
                bytes20(uint160(0xBEEF)),
                bytes2(0xAB01)
            );
    }
}
