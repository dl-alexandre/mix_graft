# Contrib

**Transactional workspace tooling for Elixir OSS contributors.**

Contrib treats a directory of cloned sibling Elixir repos as a single workspace. One command links them together for joint local development, one command puts them back. Every command derives from the same workspace snapshot, so `status`, `doctor`, `link`, `outdated`, and `pr.list` always see the same world.

> **Status:** pre-release. v0.1 (workspace status + transactional `link.on`/`link.off`) under active development. See [`docs/milestones/M1_LINKING.md`](docs/milestones/M1_LINKING.md).

## Why

If you maintain multiple sibling Elixir libraries — `phoenix` + `phoenix_live_view`, `jido` + `jido_ai` + `jido_chat`, anything with a hex package family — you've felt this pain:

- Edit `mix.exs` in repo B to use `path:` for repo A so you can test changes locally.
- Run `mix deps.unlock` and `mix deps.get`.
- Repeat for repos C and D, both of which also depend on A.
- Forget which files you edited.
- Accidentally commit a `path:` dep to a PR.

Contrib's `link.on` does this transitively, atomically, with bulletproof revert.

## What it does today

```bash
mix contrib.status                       # snapshot of sibling repos and dep state
mix contrib.link.on req_llm --dry-run    # plan a transactional dep rewrite
mix contrib.link.on req_llm              # execute it
mix contrib.link.off req_llm             # revert from recorded preimage
```

`--json` is supported on every command for agent and script consumption.

## Trust guarantees

- Never mutates outside the declared workspace.
- Never mutates without a dry-run-equivalent plan available.
- Every rewrite records a reversible preimage.
- Failed link operations roll back atomically.
- Snapshot generation is side-effect free.
- Structured JSON output is a first-class interface.
- State drift detected via SHA-256 hashes, not heuristics.

## What it is not

Contrib is **not** a monorepo replacement, package manager, CI orchestrator, deployment system, GitHub automation platform, polyglot workspace manager, or background daemon. It is local-first, git-native, Mix-native, snapshot-driven, and CLI-first. Anything outside that fence is intentionally out of scope.

## Installation

Once published:

```elixir
def deps do
  [{:contrib, "~> 0.1", only: :dev, runtime: false}]
end
```

## License

Apache-2.0. See [LICENSE](LICENSE).
