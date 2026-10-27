// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {WeirTownies} from "../src/WeirTownies.sol";

/// Deploys WeirTownies. Every input is an env var so nothing is hard-coded in a public repo:
///   OWNER, TREASURY (addresses), MAX_SUPPLY (3333), PROVENANCE_HASH (bytes32 from art/townies/provenance.json),
///   ALLOWLIST_PRICE_WEI (0), PUBLIC_PRICE_WEI.
/// Run by the owner: forge script script/Deploy.s.sol --rpc-url $RH_RPC_URL --account townies-deployer --broadcast
contract Deploy is Script {
    function run() external returns (WeirTownies t) {
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        uint256 maxSupply = vm.envUint("MAX_SUPPLY");
        bytes32 provenance = vm.envBytes32("PROVENANCE_HASH");
        uint256 allowlistPrice = vm.envUint("ALLOWLIST_PRICE_WEI");
        uint256 publicPrice = vm.envUint("PUBLIC_PRICE_WEI");
        vm.startBroadcast();
        t = new WeirTownies(owner, treasury, maxSupply, provenance, allowlistPrice, publicPrice);
        vm.stopBroadcast();
        console.log("WeirTownies at", address(t));
        console.log("owner", owner);
        console.log("maxSupply", maxSupply);
    }
}
