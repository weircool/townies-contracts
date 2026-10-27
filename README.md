# WeirTownies contract

`src/WeirTownies.sol`: the ERC-721 for Weir Townies (town.weir.cool). OpenZeppelin v5.5.0 (`ERC721`,
`ERC721Enumerable`, `ERC2981`, `Ownable2Step`, `MerkleProof`, `ReentrancyGuard`), hand-written ERC-4906 events,
solc 0.8.26, cancun, optimizer 200 runs, `bytecode_hash = none`. Nothing upgradeable, no admin over sold tokens.

## Layout of token ids

Set once by the owner (`setLayout`) and frozen (`sealPools`) before any mint; the provenance hash in the constructor
seals which image sits at which id.

| range | who mints | how |
|---|---|---|
| `1 .. reserveSize` | owner (`ownerMint`) | the 1/1s and the team's share |
| role pools, in order | one per wallet (`mintRole(pool, proof)`) | the pool's Merkle root; first come until the pool is gone; free; open in both sale phases |
| general: `generalStart .. MAX_SUPPLY` | `mintAllowlist(qty, proof)` then `mintPublic(qty)` | `WALLET_CAP = 3` per wallet across both phases; allowlist free, public at `publicPrice` |

Role pools planned: Mayor (1), Judge, Auditor (500), Spaces Host; sizes decided before deploy. The IMD NFT and most
tier tokens live on Ethereum mainnet, so eligibility is a snapshot committed as a Merkle root, not an on-chain read.

Merkle leaf: `keccak256(bytes.concat(keccak256(abi.encode(address))))`, the OpenZeppelin `StandardMerkleTree`
encoding for `["address"]`; the app builds the trees with `@openzeppelin/merkle-tree`.

## After the sale

`endSale()` is one way: it closes the allowlist, public and role mints and the phase for good. The owner may then
`sweepGeneral` and `sweepPool` the ids nobody claimed, and `ownerMint` still completes the reserve, so the collection
can still reach its full size. `endSale` and both sweeps need the sealed layout like every other mint path.
`freezeMetadata()` is one way too: no more base URI or renderer changes. `setRenderer` only accepts a contract, and
`freezeMetadata` refuses to freeze on a renderer that cannot answer for a minted token. `renounceOwnership` always reverts; ownership moves in two steps only.
`setTreasury` carries the ERC-2981 receiver with it; the royalty is capped at 10%.

## Metadata and the renderer hook

`tokenURI` is `baseURI + id` (the app's `/api/meta/<id>`), so attributes can be live. The owner may later point
`setRenderer(address)` at a contract implementing `tokenURI(uint256)`; from then on metadata (and the art, as an
on-chain layer renderer) is served from chain, and `address(0)` switches back. Call `refreshAll()` after a switch
so marketplaces re-read. The hook is the door to on-chain art after mint without a new collection.

## Build and test

```
forge build
forge test -vvv
forge coverage
```

## Audit

The IMD swarm audits from a public repo URL and commit with foundry at the root; this folder is pushed to
`weircool/townies-contracts` as a subtree for that (steps `audit-imported-code` and `adversarial-review`, no `onchain`
key, objective "audit only, do not deploy"). Findings at medium or above are fixed here and re-audited.

## Deploy (owner only)

1. `cast wallet import townies-deployer --interactive` (keystore; no key in env or shell history). Fund it on
   Robinhood Chain (chain id 4663); a deploy costs well under 0.001 ETH there.
2. Env for the script: `OWNER`, `TREASURY`, `MAX_SUPPLY=3333`, `PROVENANCE_HASH`, `ALLOWLIST_PRICE_WEI=0`,
   `PUBLIC_PRICE_WEI`, `RH_RPC_URL` (publicnode or Alchemy; the official RPC refuses clients without an Origin header).
3. `forge script script/Deploy.s.sol --rpc-url $RH_RPC_URL --account townies-deployer --broadcast`
4. Verify on both explorers:
   - Blockscout: `forge verify-contract <addr> src/WeirTownies.sol:WeirTownies --chain-id 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --constructor-args $(cast abi-encode "constructor(address,address,uint256,bytes32,uint256,uint256)" ...)`
   - RobinScan (Etherscan V2): `--verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=4663" --etherscan-api-key $ETHERSCAN_KEY`
5. Configure with `script/Configure.s.sol` and `ACTION=layout | seal | roots | poolroot | baseuri | updater | reserve |
   phase | endsale | sweep` (see the file header): layout, inspect, seal, then the rest; `phase` last, on launch day.
6. `scripts/townies/manifest.ts` in the app writes `public/townies/manifest.json` + the ABI for the mint page.

Rehearse first with `MAX_SUPPLY=5`, a tiny price and a 3-address root on the real chain, then deploy for real.
