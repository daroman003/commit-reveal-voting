// Builds the voter allowlist Merkle tree.
//
//   node tools/merkle.js voters.json
//
// Input:  a JSON array of voter addresses.
// Output: prints the Merkle root (use it as VOTER_ROOT when deploying) and
//         writes proofs.json, mapping each lowercase address to its proof.

const fs = require("fs");
const { StandardMerkleTree } = require("@openzeppelin/merkle-tree");

const inputPath = process.argv[2] || "voters.json";
const voters = JSON.parse(fs.readFileSync(inputPath, "utf8"));

if (!Array.isArray(voters) || voters.length === 0) {
  console.error(`${inputPath} must be a non-empty JSON array of addresses`);
  process.exit(1);
}

const unique = new Set(voters.map((a) => a.toLowerCase()));
if (unique.size !== voters.length) {
  console.error("Duplicate addresses found in the voter list");
  process.exit(1);
}

const tree = StandardMerkleTree.of(
  voters.map((address) => [address]),
  ["address"]
);

const proofs = {};
for (const [index, [address]] of tree.entries()) {
  proofs[address.toLowerCase()] = tree.getProof(index);
}

fs.writeFileSync("proofs.json", JSON.stringify({ root: tree.root, proofs }, null, 2));

console.log("Voters:     ", voters.length);
console.log("Merkle root:", tree.root);
console.log("Proofs written to proofs.json");
