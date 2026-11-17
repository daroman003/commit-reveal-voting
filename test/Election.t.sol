// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Election} from "../src/Election.sol";

contract ElectionTest is Test {
    Election internal election;

    address[4] internal voters;
    bytes32[4] internal leaves;
    bytes32 internal n01;
    bytes32 internal n23;
    bytes32 internal root;

    address internal outsider;

    uint64 internal constant COMMIT_DURATION = 1 days;
    uint64 internal constant REVEAL_DURATION = 1 days;
    bytes32 internal constant SALT = keccak256("test salt");

    function setUp() public {
        outsider = makeAddr("outsider");
        voters[0] = makeAddr("voter0");
        voters[1] = makeAddr("voter1");
        voters[2] = makeAddr("voter2");
        voters[3] = makeAddr("voter3");

        // Four-leaf Merkle tree built the same way OpenZeppelin does it.
        for (uint256 i = 0; i < 4; i++) {
            leaves[i] = _leaf(voters[i]);
        }
        n01 = _hashPair(leaves[0], leaves[1]);
        n23 = _hashPair(leaves[2], leaves[3]);
        root = _hashPair(n01, n23);

        election = new Election(_names(), root, COMMIT_DURATION, REVEAL_DURATION);
    }

    // ------------------------------------------------------------------
    // Normal flow
    // ------------------------------------------------------------------

    function test_HappyPath() public {
        _commit(0, 1, SALT);
        _commit(1, 1, SALT);
        _commit(2, 0, SALT);
        assertEq(election.totalCommitted(), 3);

        _toRevealPhase();
        _reveal(0, 1, SALT);
        _reveal(1, 1, SALT);
        _reveal(2, 0, SALT);
        assertEq(election.totalRevealed(), 3);

        _toFinished();
        uint256[] memory tally = election.results();
        assertEq(tally[0], 1);
        assertEq(tally[1], 2);
        assertEq(tally[2], 0);

        uint256[] memory ids = election.winners();
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);
    }

    function test_TieReturnsAllWinners() public {
        _commit(0, 0, SALT);
        _commit(1, 2, SALT);
        _toRevealPhase();
        _reveal(0, 0, SALT);
        _reveal(1, 2, SALT);
        _toFinished();

        uint256[] memory ids = election.winners();
        assertEq(ids.length, 2);
        assertEq(ids[0], 0);
        assertEq(ids[1], 2);
    }

    function test_UnrevealedCommitmentsAreNotCounted() public {
        _commit(0, 0, SALT);
        _commit(1, 1, SALT);
        _toRevealPhase();
        _reveal(0, 0, SALT);
        _toFinished();

        uint256[] memory tally = election.results();
        assertEq(tally[0], 1);
        assertEq(tally[1], 0);
    }

    function test_PhaseFollowsDeadlines() public {
        assertEq(uint256(election.phase()), uint256(Election.Phase.Commit));
        vm.warp(election.commitDeadline() - 1);
        assertEq(uint256(election.phase()), uint256(Election.Phase.Commit));
        vm.warp(election.commitDeadline());
        assertEq(uint256(election.phase()), uint256(Election.Phase.Reveal));
        vm.warp(election.revealDeadline());
        assertEq(uint256(election.phase()), uint256(Election.Phase.Finished));
    }

    // ------------------------------------------------------------------
    // Attack: voting without being eligible
    // ------------------------------------------------------------------

    function test_RevertWhen_OutsiderUsesSomeoneElsesProof() public {
        bytes32 c = election.computeCommitment(outsider, 0, SALT);
        vm.expectRevert(Election.NotEligible.selector);
        vm.prank(outsider);
        election.commit(c, _proof(0));
    }

    function test_RevertWhen_OutsiderUsesEmptyProof() public {
        bytes32 c = election.computeCommitment(outsider, 0, SALT);
        vm.expectRevert(Election.NotEligible.selector);
        vm.prank(outsider);
        election.commit(c, new bytes32[](0));
    }

    function test_RevertWhen_EligibleVoterUsesWrongProof() public {
        bytes32 c = election.computeCommitment(voters[0], 0, SALT);
        vm.expectRevert(Election.NotEligible.selector);
        vm.prank(voters[0]);
        election.commit(c, _proof(2));
    }

    // ------------------------------------------------------------------
    // Attack: voting more than once
    // ------------------------------------------------------------------

    function test_RevertWhen_DoubleCommit() public {
        _commit(0, 0, SALT);

        bytes32 c = election.computeCommitment(voters[0], 1, SALT);
        vm.expectRevert(Election.AlreadyCommitted.selector);
        vm.prank(voters[0]);
        election.commit(c, _proof(0));
    }

    function test_RevertWhen_DoubleReveal() public {
        _commit(0, 0, SALT);
        _toRevealPhase();
        _reveal(0, 0, SALT);

        vm.expectRevert(Election.AlreadyRevealed.selector);
        vm.prank(voters[0]);
        election.reveal(0, SALT);

        assertEq(election.results()[0], 1);
    }

    // ------------------------------------------------------------------
    // Attack: acting outside the allowed phase
    // ------------------------------------------------------------------

    function test_RevertWhen_CommitAfterDeadline() public {
        _toRevealPhase();
        bytes32 c = election.computeCommitment(voters[0], 0, SALT);
        vm.expectRevert(
            abi.encodeWithSelector(Election.NotInPhase.selector, Election.Phase.Commit, Election.Phase.Reveal)
        );
        vm.prank(voters[0]);
        election.commit(c, _proof(0));
    }

    function test_RevertWhen_RevealDuringCommitPhase() public {
        _commit(0, 0, SALT);
        vm.expectRevert(
            abi.encodeWithSelector(Election.NotInPhase.selector, Election.Phase.Reveal, Election.Phase.Commit)
        );
        vm.prank(voters[0]);
        election.reveal(0, SALT);
    }

    function test_RevertWhen_RevealAfterDeadline() public {
        _commit(0, 0, SALT);
        _toFinished();
        vm.expectRevert(
            abi.encodeWithSelector(Election.NotInPhase.selector, Election.Phase.Reveal, Election.Phase.Finished)
        );
        vm.prank(voters[0]);
        election.reveal(0, SALT);
    }

    function test_RevertWhen_WinnersCalledBeforeFinished() public {
        vm.expectRevert(
            abi.encodeWithSelector(Election.NotInPhase.selector, Election.Phase.Finished, Election.Phase.Commit)
        );
        election.winners();
    }

    // ------------------------------------------------------------------
    // Attack: changing or stealing a vote at reveal time
    // ------------------------------------------------------------------

    function test_RevertWhen_RevealDifferentCandidate() public {
        _commit(0, 0, SALT);
        _toRevealPhase();
        vm.expectRevert(Election.CommitmentMismatch.selector);
        vm.prank(voters[0]);
        election.reveal(1, SALT);
    }

    function test_RevertWhen_RevealWrongSalt() public {
        _commit(0, 0, SALT);
        _toRevealPhase();
        vm.expectRevert(Election.CommitmentMismatch.selector);
        vm.prank(voters[0]);
        election.reveal(0, keccak256("wrong salt"));
    }

    function test_RevertWhen_RevealWithoutCommit() public {
        _toRevealPhase();
        vm.expectRevert(Election.NoCommitment.selector);
        vm.prank(voters[0]);
        election.reveal(0, SALT);
    }

    function test_RevertWhen_CommittedCandidateDoesNotExist() public {
        _commit(0, 99, SALT);
        _toRevealPhase();
        vm.expectRevert(Election.InvalidCandidate.selector);
        vm.prank(voters[0]);
        election.reveal(99, SALT);
    }

    /// A voter copies another voter's commitment from the chain, waits for
    /// them to reveal, then tries to reuse the now-public candidate and salt.
    function test_RevertWhen_CopiedCommitmentIsRevealed() public {
        _commit(0, 1, SALT);
        bytes32 copied = election.commitments(voters[0]);

        vm.prank(voters[1]);
        election.commit(copied, _proof(1));

        _toRevealPhase();
        _reveal(0, 1, SALT);

        vm.expectRevert(Election.CommitmentMismatch.selector);
        vm.prank(voters[1]);
        election.reveal(1, SALT);

        assertEq(election.results()[1], 1);
    }

    function test_RevertWhen_EmptyCommitment() public {
        vm.expectRevert(Election.EmptyCommitment.selector);
        vm.prank(voters[0]);
        election.commit(bytes32(0), _proof(0));
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// Only the exact (candidate, salt) that was committed can be revealed.
    function testFuzz_OnlyExactOpeningReveals(uint256 candidate, bytes32 salt, uint256 otherCandidate, bytes32 otherSalt)
        public
    {
        candidate = bound(candidate, 0, 2);
        otherCandidate = bound(otherCandidate, 0, 2);
        vm.assume(candidate != otherCandidate || salt != otherSalt);

        _commit(0, candidate, salt);
        _toRevealPhase();

        vm.expectRevert(Election.CommitmentMismatch.selector);
        vm.prank(voters[0]);
        election.reveal(otherCandidate, otherSalt);

        _reveal(0, candidate, salt);
        assertEq(election.results()[candidate], 1);
        assertEq(election.totalRevealed(), 1);
    }

    /// Addresses outside the allowlist can never commit, whatever proof they send.
    function testFuzz_NonVoterCannotCommit(address stranger, bytes32[] calldata proof) public {
        for (uint256 i = 0; i < 4; i++) {
            vm.assume(stranger != voters[i]);
        }
        vm.assume(proof.length <= 8);

        vm.expectRevert(Election.NotEligible.selector);
        vm.prank(stranger);
        election.commit(keccak256("anything"), proof);
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    function test_RevertWhen_FewerThanTwoCandidates() public {
        string[] memory one = new string[](1);
        one[0] = "Only";
        vm.expectRevert(Election.BadConfig.selector);
        new Election(one, root, COMMIT_DURATION, REVEAL_DURATION);
    }

    function test_RevertWhen_ZeroRootOrDurations() public {
        string[] memory names = _names();

        vm.expectRevert(Election.BadConfig.selector);
        new Election(names, bytes32(0), COMMIT_DURATION, REVEAL_DURATION);

        vm.expectRevert(Election.BadConfig.selector);
        new Election(names, root, 0, REVEAL_DURATION);

        vm.expectRevert(Election.BadConfig.selector);
        new Election(names, root, COMMIT_DURATION, 0);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _names() internal pure returns (string[] memory names) {
        names = new string[](3);
        names[0] = "Alice";
        names[1] = "Bob";
        names[2] = "Carol";
    }

    function _commit(uint256 voterIndex, uint256 candidate, bytes32 salt) internal {
        address voter = voters[voterIndex];
        bytes32 c = election.computeCommitment(voter, candidate, salt);
        bytes32[] memory proof = _proof(voterIndex);
        vm.prank(voter);
        election.commit(c, proof);
    }

    function _reveal(uint256 voterIndex, uint256 candidate, bytes32 salt) internal {
        vm.prank(voters[voterIndex]);
        election.reveal(candidate, salt);
    }

    function _toRevealPhase() internal {
        vm.warp(election.commitDeadline());
    }

    function _toFinished() internal {
        vm.warp(election.revealDeadline());
    }

    function _leaf(address voter) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(voter))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proof(uint256 voterIndex) internal view returns (bytes32[] memory proof) {
        proof = new bytes32[](2);
        if (voterIndex == 0) {
            proof[0] = leaves[1];
            proof[1] = n23;
        } else if (voterIndex == 1) {
            proof[0] = leaves[0];
            proof[1] = n23;
        } else if (voterIndex == 2) {
            proof[0] = leaves[3];
            proof[1] = n01;
        } else {
            proof[0] = leaves[2];
            proof[1] = n01;
        }
    }
}
