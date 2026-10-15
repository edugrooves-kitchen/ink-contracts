# First IMD swarm job: independent contract audit

Use Audit on https://explorer.imd.fun/launch

Repository: REPLACE_WITH_PUBLIC_GITHUB_REPOSITORY

Commit: REPLACE_WITH_FULL_COMMIT_RETURNED_BY_IMD_IMPORT

These two placeholders must be replaced before requesting a quote or paying.
The docs require a public repository pinned with `/requests/import`.
Run the free `/requests/check` before accepting the paid quote.
This brief is human-readable input, not a ready-to-submit API payload.

## Objective — paste into the audit request

Independently audit the existing InkPortraits, InkVault, InkLiquidity, InkHook and InkRenderer
contracts and Foundry tests at the supplied immutable repository commit. Review
the supplied source; do not deploy, build a new token, alter economics, add owner
powers, or rewrite the artwork. This is an audit-only job.

Review at least:

1. NFT cap and inventory accounting across claims, release, pending pulls, renewals,
   reveals, repeated deposits, and recycling of agent and swarm portraits.
2. Vault solvency: 400,000 INK backing, outstanding reservations, bonus-pot accounting,
   rounding, fee changes, direct token transfers, and adversarial operation ordering.
3. Current seat ownership, one claim per seat, invalid/duplicate Merkle proofs,
   untrusted statistics and units, ownership transfers, and exact window boundaries.
4. Randomness and liveness: blockhash expiry, renewals, reveal selection, selective
   abort, transaction ordering, block producer influence, and allocation fairness.
   Do not describe next-block randomness as manipulation-proof.
5. Uniswap v4 callback authentication, allowed hook address bits, pool binding,
   swap-delta signs, fee currency, exact-input/exact-output paths, both token orderings,
   fee collection, claims accounting, reentrancy, and supported-router integration.
6. Whether holder exemptions and per-wallet limits authenticate the actual end user
   through production routers. Examine forged/missing hookData, intermediary wallets,
   contract callers and exemption/cap bypasses; do not rely only on the local test router.
7. Trading lock, max-lock fallback, first-trade timing, first-hour cap, release failure,
   missing initialization, and possible trading before the intended distribution completes.
8. Liquidity sizing, price/range assumptions, single-sided placement, position custody,
   fees, approvals, and whether any path can remove intended permanent liquidity.
9. Owner controls and trust assumptions, mutable fees, setup front-running, incorrect
   addresses, ownership transfer/renunciation, zero addresses, and renderer set/lock behavior.
10. The implemented renderer: chunk init code, byte-exact script storage, script escaping,
    original algorithm integration, trait parity, JSON/HTML/base64 generation, tokenURI
    size, missing art, irreversible locks, preview URL controls and marketplace support.
11. Snapshot provenance and deployment setup. The packaged snapshot-proof fixture is
    synthetic, not evidence that real production metrics or the private cutoff were validated.
    Distinguish missing integration and release work from confirmed exploits.

## Required delivery

- Ranked findings: severity, location, preconditions, attack/failure sequence, impact,
  reproduction, and recommended remediation.
- Foundry proofs of concept for reproducible critical/high findings where feasible.
- Clearly state the source commit, tool versions, files reviewed, tests actually run,
  skipped tests, assumptions, and unresolved questions.
- Separate confirmed vulnerabilities from design tradeoffs and informational observations.
- Summarize mandatory release blockers and missing regression, fuzz/invariant,
  production-router and integration tests.
- Deliver the report and retain its IMD job/report URL. If GitHub publication is chosen,
  retain that delivery URL too.
- No payment, deployment, source changes, or guarantee of security/eligibility.

## Later jobs, not part of this audit

Reviewed fixes and missing implementation, an independent re-review as needed, Sepolia
launch/rehearsal, real website integration and mainnet launch. The hackathon entry
needs substantive swarm delivery; an audit alone is not asserted to satisfy it.
