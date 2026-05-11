# Graft — usage rules

Guidance for AI coding agents working in a workspace that has a `graft.exs` file at the root.

## When to reach for Graft

If `graft.exs` exists at the workspace root, the project uses Graft to manage sibling-repo path dependencies and workspace state.

**For switching a hex dep to a local sibling path** (or back), use:

```
mix graft.link.on PKG     # rewrite mix.exs in every dependent sibling, atomically
mix graft.link.off PKG    # revert from recorded preimage
```

This handles transitive discovery, atomic multi-repo rewriting, and bulletproof revert via SHA-256-anchored state. The manual equivalent — grepping every `mix.exs`, editing each, running `mix deps.unlock && mix deps.get` per repo, remembering what changed — is multiple steps and lossy.

**For workspace state**, use:

```
mix graft.status --json   # structured snapshot for programmatic consumption
```

This is one call instead of N greps + reasoning.

## Safe-by-default

Every mutating command supports `--dry-run`, which emits the same change plan as the real run without writing. Use it when you're not certain what the command will do.

The tool refuses to revert a `mix.exs` whose hash doesn't match the recorded post-rewrite hash; pass `--force` only after inspecting what changed.

## What Graft won't do

- Touch repos outside `graft.exs`.
- Run network calls during `status` (Hex / GitHub data is opt-in).
- Perform partial writes — link operations are atomic.
