// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title Election - commit-reveal voting with a Merkle allowlist
/// @notice Voters first submit a hash of their vote (commit phase), then open it
///         (reveal phase). Nobody can see how anyone voted until reveals begin.
/// @dev All configuration is fixed at deployment. There is no owner and no
///      admin function, so nobody can change candidates, voters or deadlines
///      once the election is live.
contract Election {
    enum Phase {
        Commit,
        Reveal,
        Finished
    }

    error BadConfig();
    error NotInPhase(Phase expected, Phase actual);
    error NotEligible();
    error EmptyCommitment();
    error AlreadyCommitted();
    error NoCommitment();
    error AlreadyRevealed();
    error InvalidCandidate();
    error CommitmentMismatch();

    event Committed(address indexed voter);
    event Revealed(address indexed voter, uint256 indexed candidateId);

    /// @notice Merkle root of the eligible voter addresses.
    bytes32 public immutable voterRoot;
    /// @notice Timestamp at which the commit phase ends and reveals begin.
    uint64 public immutable commitDeadline;
    /// @notice Timestamp at which the reveal phase ends and results are final.
    uint64 public immutable revealDeadline;

    string[] private _candidates;
    uint256[] private _tally;

    mapping(address voter => bytes32 commitment) public commitments;
    mapping(address voter => bool) public revealed;

    uint256 public totalCommitted;
    uint256 public totalRevealed;

    constructor(string[] memory candidateNames, bytes32 voterRoot_, uint64 commitDuration, uint64 revealDuration) {
        if (candidateNames.length < 2 || voterRoot_ == bytes32(0) || commitDuration == 0 || revealDuration == 0) {
            revert BadConfig();
        }

        for (uint256 i = 0; i < candidateNames.length; i++) {
            _candidates.push(candidateNames[i]);
            _tally.push(0);
        }

        voterRoot = voterRoot_;
        commitDeadline = uint64(block.timestamp) + commitDuration;
        revealDeadline = commitDeadline + revealDuration;
    }

    // ------------------------------------------------------------------
    // Voting
    // ------------------------------------------------------------------

    /// @notice Submit a hidden vote. One commitment per eligible address; it cannot be changed.
    /// @param commitment Output of `computeCommitment(msg.sender, candidateId, salt)`.
    /// @param proof Merkle proof that msg.sender is on the voter allowlist.
    function commit(bytes32 commitment, bytes32[] calldata proof) external {
        _requirePhase(Phase.Commit);
        if (commitment == bytes32(0)) revert EmptyCommitment();
        if (commitments[msg.sender] != bytes32(0)) revert AlreadyCommitted();

        // Double-hashed leaf: matches OpenZeppelin's StandardMerkleTree and
        // prevents an internal tree node from being passed off as a leaf.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender))));
        if (!MerkleProof.verify(proof, voterRoot, leaf)) revert NotEligible();

        commitments[msg.sender] = commitment;
        totalCommitted++;

        emit Committed(msg.sender);
    }

    /// @notice Open a commitment and have the vote counted.
    function reveal(uint256 candidateId, bytes32 salt) external {
        _requirePhase(Phase.Reveal);

        bytes32 commitment = commitments[msg.sender];
        if (commitment == bytes32(0)) revert NoCommitment();
        if (revealed[msg.sender]) revert AlreadyRevealed();
        if (candidateId >= _candidates.length) revert InvalidCandidate();
        if (computeCommitment(msg.sender, candidateId, salt) != commitment) revert CommitmentMismatch();

        revealed[msg.sender] = true;
        _tally[candidateId]++;
        totalRevealed++;

        emit Revealed(msg.sender, candidateId);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The hash a voter must submit in `commit`.
    /// @dev Bound to the chain, this contract and the voter, so a commitment
    ///      cannot be replayed on another chain or election, or copied and
    ///      revealed by a different voter.
    ///      Compute this locally (see README). Asking a public RPC node to
    ///      run it tells that node your vote.
    function computeCommitment(address voter, uint256 candidateId, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), voter, candidateId, salt));
    }

    function phase() public view returns (Phase) {
        if (block.timestamp < commitDeadline) return Phase.Commit;
        if (block.timestamp < revealDeadline) return Phase.Reveal;
        return Phase.Finished;
    }

    function candidateCount() external view returns (uint256) {
        return _candidates.length;
    }

    function candidateName(uint256 candidateId) external view returns (string memory) {
        if (candidateId >= _candidates.length) revert InvalidCandidate();
        return _candidates[candidateId];
    }

    /// @notice Vote counts per candidate. Partial until the election is Finished.
    function results() external view returns (uint256[] memory) {
        return _tally;
    }

    /// @notice Candidate id(s) with the most votes. More than one id means a tie.
    function winners() external view returns (uint256[] memory ids) {
        _requirePhase(Phase.Finished);

        uint256 best = 0;
        uint256 count = 0;
        for (uint256 i = 0; i < _tally.length; i++) {
            if (_tally[i] > best) {
                best = _tally[i];
                count = 1;
            } else if (_tally[i] == best) {
                count++;
            }
        }

        ids = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _tally.length; i++) {
            if (_tally[i] == best) ids[j++] = i;
        }
    }

    function _requirePhase(Phase expected) private view {
        Phase actual = phase();
        if (actual != expected) revert NotInPhase(expected, actual);
    }
}
