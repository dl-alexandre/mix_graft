# Changelog

All notable changes to the `mix_graft` package will be documented in this file.
The public module namespace is `Graft` and the public Mix task namespace is
`mix graft.*`. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.1] - 2026-05-12

### Added
- Publish-ready Hex package under `mix_graft`, with OTP app `:mix_graft`.
- `mix graft.add` for cloning GitHub repositories into a workspace and recording sibling origins in `graft.exs`.
- `mix graft.list` for lightweight manifest inventory.
- `mix graft.status` with text and JSON output for sibling health, dependency counts, git posture, origin checks, and validation freshness.
- Transactional `mix graft.link.on` / `mix graft.link.off` for sibling path dependency linking with workspace locks, hash-anchored writes, state merging, and literal preimage restoration.
- `mix graft.validate` for topological validation runs and `mix graft.validate --quick` for lightweight manifest/path/git/origin checks.
- `mix graft.remove` for manifest-only sibling removal, with explicit guarded filesystem deletion via `--delete`.
- Agent-oriented usage guidance, trust guarantees, golden JSON fixtures, and a quickstart smoke script.
