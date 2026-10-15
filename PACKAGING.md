# Explicit packaging differences

- All production src/**/*.sol and all test function bodies are unchanged.
- Original art bytes are unchanged at art/original-art.js.
- UploadRenderer and InkRenderer test: only the art file path changes.
- SnapshotProofs test: only its provenance comment changes; test logic is unchanged.
- foundry.toml: sibling web-app read permission removed; package-local permissions retained.
- Snapshot fixture replaced with invented deterministic 2,000-seat tree and four proofs.
  Generated offline with OpenZeppelin StandardMerkleTree 1.0.8; no production data fetched.
- Trait fixture copied exactly; these are synthetic generated cases, not live metrics.
- Audit includes upload script and art because the full tests require them; it omits launch drafts.
- Launch adds draft requests and setup instructions, not private release configuration.
- Validation uses two disposable isolated copies. No workflow, RPC, key or paid API is used.
- No original workspace source/tests/fixtures are rewritten by this builder.
- Source provenance and SHA256SUMS identify every retained file.
- No blanket owner-source license was added; dependency notices are preserved.
