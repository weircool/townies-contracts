// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {WeirTownies} from "../src/WeirTownies.sol";

/// Post-deploy settings, one action per run, chosen by ACTION:
///   layout    RESERVE_SIZE, POOL_SIZES ("1,120,500,80" in id order: Mayor, Judge, Auditor, Spaces Host),
///             POOL_ROOTS ("0x..,0x..,..")   (check generalStart afterwards)
///   seal      freezes the layout; its own run so the layout can be inspected first
///   roots     ALLOWLIST_ROOT (bytes32)
///   poolroot  POOL_INDEX, POOL_ROOT
///   baseuri   BASE_URI ("https://town.weir.cool/api/meta/")
///   updater   UPDATER (address)
///   phase     PHASE (0 closed, 1 allowlist, 2 public)
///   reserve   RESERVE_TO (address), RESERVE_QTY
///   endsale   closes minting for good
///   sweep     SWEEP_TO, SWEEP_QTY (general) or SWEEP_POOL too (one pool)
/// Always: TOWNIES (the contract address). Run by the owner with --account townies-deployer --broadcast.
contract Configure is Script {
    function run() external {
        WeirTownies t = WeirTownies(vm.envAddress("TOWNIES"));
        string memory action = vm.envString("ACTION");
        vm.startBroadcast();
        if (eq(action, "layout")) {
            uint256[] memory sizesU = vm.envUint("POOL_SIZES", ",");
            bytes32[] memory roots = vm.envBytes32("POOL_ROOTS", ",");
            uint32[] memory sizes = new uint32[](sizesU.length);
            for (uint256 i = 0; i < sizesU.length; i++) sizes[i] = SafeCast.toUint32(sizesU[i]);
            t.setLayout(SafeCast.toUint32(vm.envUint("RESERVE_SIZE")), sizes, roots);
            console.log("layout set, not sealed; general starts at", t.generalStart());
        } else if (eq(action, "seal")) {
            t.sealPools();
            console.log("layout sealed; general starts at", t.generalStart());
        } else if (eq(action, "roots")) {
            t.setAllowlistRoot(vm.envBytes32("ALLOWLIST_ROOT"));
        } else if (eq(action, "poolroot")) {
            t.setPoolRoot(vm.envUint("POOL_INDEX"), vm.envBytes32("POOL_ROOT"));
        } else if (eq(action, "baseuri")) {
            t.setBaseURI(vm.envString("BASE_URI"));
        } else if (eq(action, "updater")) {
            t.setUpdater(vm.envAddress("UPDATER"));
        } else if (eq(action, "phase")) {
            t.setPhase(WeirTownies.Phase(vm.envUint("PHASE")));
        } else if (eq(action, "reserve")) {
            t.ownerMint(vm.envAddress("RESERVE_TO"), SafeCast.toUint32(vm.envUint("RESERVE_QTY")));
        } else if (eq(action, "endsale")) {
            t.endSale();
        } else if (eq(action, "sweep")) {
            if (vm.envOr("SWEEP_POOL", uint256(type(uint256).max)) != type(uint256).max) {
                t.sweepPool(vm.envUint("SWEEP_POOL"), vm.envAddress("SWEEP_TO"), SafeCast.toUint32(vm.envUint("SWEEP_QTY")));
            } else {
                t.sweepGeneral(vm.envAddress("SWEEP_TO"), SafeCast.toUint32(vm.envUint("SWEEP_QTY")));
            }
        } else {
            revert("unknown ACTION");
        }
        vm.stopBroadcast();
    }

    function eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
