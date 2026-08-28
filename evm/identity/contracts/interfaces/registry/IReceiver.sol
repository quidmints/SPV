// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IERC165} from "@oz/utils/introspection/IERC165.sol";

/**
 * @title IReceiver
 * @notice The interface Chainlink's `KeystoneForwarder` requires of any contract it delivers CRE
 *         reports to. Mirrors `smartcontractkit/chainlink`'s own `IReceiver`.
 *
 * @dev WHY THIS FILE EXISTS AT ALL, since the repo already had a working-looking `onReport`:
 *      **the Forwarder ERC-165-probes the receiver BEFORE delivering.** Chainlink's docs state it
 *      plainly - "The KeystoneForwarder uses ERC165 to check if your contract supports the IReceiver
 *      interface before sending a report." `RegistrySourceAnchor` declared `onReport` but never
 *      advertised the interface, so the probe would answer false and **no report would ever be
 *      delivered**. Nothing on-chain would revert and no test would fail; the ingestion path would
 *      simply stay silent forever. See TODO sec. 2.18fg.
 *
 *      THE RETURN TYPE IS PART OF THE CONTRACT, even though the SELECTOR IS NOT. Solidity computes a
 *      selector from the parameter list alone, so a receiver returning values is still *callable* by
 *      the Forwarder - which is exactly why this defect could sit unnoticed. It is the ERC-165 probe,
 *      not the call, that rejects a non-conforming receiver.
 *
 *      `type(IReceiver).interfaceId` is the selector of `onReport` ALONE - Solidity excludes
 *      inherited functions from `interfaceId` - so this value matches Chainlink's despite the
 *      `IERC165` base.
 */
interface IReceiver is IERC165 {
    /**
     * @notice Deliver a CRE report.
     * @param metadata Fixed 109-byte header: version, executionId, timestamp, donId, donConfigVersion,
     *                 workflowId, workflowName, workflowOwner, reportId.
     * @param report   The workflow's ABI-encoded payload.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
