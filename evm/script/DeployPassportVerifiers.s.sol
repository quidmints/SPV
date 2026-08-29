// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Registration2} from "../src/identity/registration/Registration2.sol";

/*
 * DEPLOY AND REGISTER THE PASSPORT VERIFIERS — the wiring whose absence makes `registerViaNoir`
 * revert for every document today (sec. 2.18gz-signer).
 *
 * WHAT WAS MISSING. `Registration2.passportVerifiers` is empty and nothing populated it: no deploy
 * script, no migration, and `Registration2Mock.mockAddPassportVerifier` was never called by any test.
 * `_getPassportVerifier` reverts on zero, so 88 correct, current bb 6.0 verifiers were bound to
 * nothing. This is the missing half - rarimo's `deploy/2_registration.migration.ts` plus
 * `10_setup.migration.ts`, neither of which came across with the fork.
 *
 * DATA-DRIVEN FROM THE MANIFEST, NOT AN 88-BRANCH SWITCH. Each verifier is deployed from its
 * compiled artifact via `vm.getCode`, so adding or retiring a profile changes
 * `passport-profiles.json` and nothing here. Importing 88 contracts to dispatch on a name would also
 * push this script past its own EIP-170 limit.
 *
 * ⚠️ IT MUST BE BATCHED, AND THAT IS NOT A STYLE CHOICE. Each verifier is ~24 KB. MEASURED, not
 * estimated: a three-profile window costs 12.9M gas in `test_deployScriptRegistersItsWindow`, so
 * ~4.3M per profile and roughly **380M for all 88** - about 10 mainnet blocks' worth. `START` and
 * `COUNT` select a window; the run is idempotent, so a window may be repeated safely after a failure
 * (re-registering the same key with a fresh address overwrites it with an equivalent verifier).
 *
 * ⚠️ THE KEY IS NOT INVENTED HERE. `zkType = keccak256("Z_NOIR_PASSPORT_" + profile)` is upstream's
 * scheme, recorded per profile in the manifest as `zk_type`, and this script ASSERTS the manifest's
 * value against its own keccak before registering. A mismatch would not fail loudly at run time - it
 * would bind verifiers under keys nothing ever looks up - so it is checked rather than trusted.
 *
 * ⚠️ WHAT THIS CANNOT DO: prove a document registers. That needs a real travel document, which this
 * repo does not have and does not fabricate. This wires the binding; it does not exercise the
 * cryptography.
 *
 * Usage:
 *   REGISTRATION=0x… forge script script/DeployPassportVerifiers.s.sol --rpc-url … --broadcast
 *   REGISTRATION=0x… START=0 COUNT=10 forge script … --broadcast     # one batch
 */
contract DeployPassportVerifiers is Script {
    string internal constant MANIFEST = "noir/passport-profiles.json";
    string internal constant PREFIX = "Z_NOIR_PASSPORT_";

    function run() external {
        address registrationAddr = vm.envAddress("REGISTRATION");
        Registration2 registration = Registration2(registrationAddr);

        string memory json = vm.readFile(MANIFEST);
        string[] memory names = vm.parseJsonKeys(json, ".profiles");

        uint256 start = vm.envOr("START", uint256(0));
        uint256 count = vm.envOr("COUNT", names.length);
        uint256 end = start + count > names.length ? names.length : start + count;

        console.log("registration:", registrationAddr);
        console.log("profiles in manifest:", names.length);
        console.log("registering window:", start, "..", end);

        // THE DEPLOYING KEY MUST ALREADY BE A StateKeeper OWNER, and this is checked FIRST rather
        // than discovered on the first `updateDependency`. `updateDependency` gates on
        // `stateKeeper.isOwner(msg.sender)`, and under `--broadcast` that sender is the deployer key,
        // NOT whoever deployed Registration2. Without this the run deploys a ~24 KB verifier, pays
        // for it, and only then reverts with "Registration: not an owner" - having burned the gas
        // and bound nothing.
        require(
            registration.stateKeeper().isOwner(msg.sender),
            "deployer is not a StateKeeper owner - add it with addOwners before running this"
        );

        vm.startBroadcast();

        for (uint256 i = start; i < end; ++i) {
            string memory name = names[i];
            bytes32 zkType = _checkedZkType(json, name);

            address verifier = _deploy(name);
            registration.updateDependency(
                Registration2.MethodId.AddPassportVerifier, abi.encode(zkType, verifier)
            );

            console.log(name, verifier);
        }

        vm.stopBroadcast();

        // READ BACK, IN A SEPARATE PASS. A collision or a silent overwrite only shows up after every
        // write in the window has landed - an earlier profile still resolving while a later one took
        // its slot. Checking each immediately after its own write would never see it.
        for (uint256 i = start; i < end; ++i) {
            bytes32 zkType = _checkedZkType(json, names[i]);
            require(
                registration.passportVerifiers(zkType) != address(0),
                string.concat("verifier did not resolve after registration: ", names[i])
            );
        }

        console.log("registered and verified:", end - start);
    }

    /// The manifest's recorded key, checked against this chain's own keccak before it is used.
    function _checkedZkType(string memory json, string memory name) internal pure returns (bytes32) {
        bytes32 recorded =
            vm.parseJsonBytes32(json, string.concat(".profiles.", _quote(name), ".zk_type"));
        bytes32 derived = keccak256(bytes(string.concat(PREFIX, name)));

        require(
            recorded == derived,
            string.concat("manifest zk_type disagrees with keccak(label) for ", name)
        );
        return derived;
    }

    /// Deploy a verifier from its compiled artifact. `vm.getCode` keeps this driven by the manifest
    /// rather than by 88 imports, which would not fit in this contract.
    function _deploy(string memory name) internal returns (address deployed) {
        string memory artifact =
            string.concat("NoirRegisterIdentity_", name, ".sol:NoirRegisterIdentity_", name);
        bytes memory creationCode = vm.getCode(artifact);

        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }

        require(deployed != address(0), string.concat("verifier deployment failed: ", name));
    }

    /// `parseJson`'s path syntax needs the key quoted, or a profile name would be read as a series
    /// of path segments at every underscore.
    function _quote(string memory key) internal pure returns (string memory) {
        return string.concat('["', key, '"]');
    }
}
