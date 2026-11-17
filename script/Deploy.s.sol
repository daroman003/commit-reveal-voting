// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Election} from "../src/Election.sol";

/// Reads its settings from environment variables (see .env.example):
///   CANDIDATES       comma-separated names, e.g. "Alice,Bob,Carol"
///   VOTER_ROOT       Merkle root printed by tools/merkle.js
///   COMMIT_DURATION  seconds the commit phase lasts
///   REVEAL_DURATION  seconds the reveal phase lasts
contract Deploy is Script {
    function run() external returns (Election election) {
        string[] memory candidates = vm.envString("CANDIDATES", ",");
        bytes32 voterRoot = vm.envBytes32("VOTER_ROOT");
        uint64 commitDuration = uint64(vm.envUint("COMMIT_DURATION"));
        uint64 revealDuration = uint64(vm.envUint("REVEAL_DURATION"));

        vm.startBroadcast();
        election = new Election(candidates, voterRoot, commitDuration, revealDuration);
        vm.stopBroadcast();

        console.log("Election deployed at:", address(election));
        console.log("Commit deadline:", election.commitDeadline());
        console.log("Reveal deadline:", election.revealDeadline());
    }
}
