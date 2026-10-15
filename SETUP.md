# Launch-source setup and safety checklist

## Scope and prerequisites

This is a portable build input, not a mainnet-ready security certification. Complete a
swarm audit, reviewed fixes, production-router checks and a Sepolia rehearsal first.
Read source permissions, launch fee policy and all irreversible operations.

No production snapshot, cutoff, wallet credentials, owner address or deployed addresses
are supplied. `test/fixtures/snapshot-sample.json` is synthetic and MUST NOT be used for
mainnet setup. Collect and validate the real snapshot privately in the working project.
The snapshot-fetching pipeline is deliberately not shipped here.

`launch/*.json` are drafts. Replace every REPLACE_WITH value; pin the reviewed public
repository and immutable 40-character commit using IMD /requests/import. Run the free
/requests/check before any quote/payment. Check current /requests/capabilities for fees,
chains, intake addresses and launch policy. Do not assume browser defaults match these drafts.

## Rehearsal and deployment order

1. Testnet only: deploy TestSeats before the other contracts. On Ethereum use the actual
   identity.md seat contract, not TestSeats.
2. Through the IMD contracts-only launch deploy InkPortraits, InkVault, InkLiquidity,
   InkRenderer, passing the explicit deployment owner to every owned contract.
3. Verify source, constructor arguments and actual owner addresses on-chain. The paying
   wallet and deployment owner can have different protocol fee entitlements.
4. Owner calls InkPortraits.setVault and InkPortraits.setRenderer with verified addresses.
5. Upload the original art with the upload script below. Test several complete tokenURI
   outputs and rendering in browsers/marketplaces, including escaping and preview behavior.
6. Separately launch INK + InkHook + the pool through IMD. Sepolia pairs with ETH; Ethereum
   pairs with IMD. Verify fixed 1 billion INK, 10% swarm, 10% initial pool and 80% to the vault.
   Verify the actual request has economics.poolBps 1000 and remainderTo the vault.
   Verify source pinning, hook permissions, token addresses, pool key and trading lock.
7. Owner calls InkVault.setInk and InkLiquidity.setPool with verified values.
8. Prepare production snapshot proofs, production website/API and an approved claim start.
   Verify vault INK funding and every setup precondition BEFORE InkVault.setup.
9. Owner calls InkVault.setup with the validated production root, approved start and
   liquidity address. This establishes the 24-hour claim window; do not do it early.
10. At the proper time after claims, call release and verify allocation/liquidity changes
    and trading. Test claim/pull/reveal/return and real router paths with small amounts.

Use actual deployed ABIs to prepare decoded transactions; the list above is not a batch
transaction or authorization to send one. Constructor or logic changes require fresh review.
Never shortcut the window, change economics or bypass a failure to meet a deadline.

## Original art upload — OWNER SIGNS

The script reads `art/original-art.js` relative to this repository root. It strips only
the module line `export default SwarmArt;`, then appends chunks to InkRenderer.
It does NOT initialize the vault or lock either contract.

Example for an owner who actually uses a Ledger:

```sh
# Substitute a verified address and RPC locally; never commit RPC credentials.
# This broadcasts real transactions: run only after review and with the correct owner/network.
RENDERER=VERIFIED_RENDERER_ADDRESS forge script script/UploadRenderer.s.sol \
  --rpc-url YOUR_RPC --ledger --broadcast
```

That signer flag is only an example, not a requirement to import a key or use Ledger.
Other wallets need an appropriate owner-signing route with the same decoded calls.
Do not put private keys in command flags or share them with agents.

The upload is multi-transaction and NOT automatically resumable. Check chunkCount and
existing script content first. Never rerun blindly after partial success: it would append
duplicate data. Reconcile exact uploaded chunks before proceeding.

After verifying every uploaded byte and complete rendered metadata, explicitly review
InkRenderer.lock() and InkPortraits.lockRenderer(). The former freezes art chunks and
preview-base configuration; the latter freezes the NFT's renderer selection. These
locks are irreversible. Ownership of other contracts is not removed by locking a renderer.

## Still outside this package

- Independent security review, adversarial economic analysis and production router proof.
- Real snapshot/cutoff validation and proof-serving infrastructure.
- Working website, API hosting, wallet transaction UX and marketplace still-image hosting.
- Owner-signed configuration, funded transactions, paid jobs and actual deployments.
- Swarm completion evidence and hackathon submission.
