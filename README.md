# Graft

**Transactional workspace tooling for Elixir OSS contributors.**

Graft treats a directory of cloned sibling Elixir repos as a single workspace. One command links them together for joint local development, one command puts them back. Every command derives from the same workspace snapshot, so `status`, `link.on`, `link.off`, and (eventually) `doctor`, `outdated`, `pr.list` always see the same world.

> **Status:** pre-release. M1 (status + transactional `link.on`/`link.off` + locking + state versioning) is feature-frozen. Public JSON contracts are pinned by golden tests. See [`docs/milestones/M1_LINKING.md`](docs/milestones/M1_LINKING.md).

## Why

If you maintain multiple sibling Elixir libraries — `phoenix` + `phoenix_live_view`, `jido` + `jido_ai` + `jido_chat`, any hex package family — you've felt this pain:

- Edit `mix.exs` in repo B to use `path:` for repo A so you can test changes locally.
- Repeat for repos C and D, both of which also depend on A.
- Forget which files you edited.
- Accidentally commit a `path:` dep to a PR.

Graft's `link.on` does this transitively, atomically, with bulletproof revert.

## Install (development)

Graft is not yet published. Use it from source:

```bash
git clone https://github.com/dl-alexandre/graft.git
cd graft
mix deps.get
mix compile
```

Then from any workspace directory containing a `graft.exs`:

```bash
mix graft.status --root path/to/workspace
```

(When published, install as a dev-only dep:)

```elixir
def deps do
  [{:graft, "~> 0.1", only: :dev, runtime: false}]
end
```

## Manifest: `graft.exs`

Drop a `graft.exs` file at the workspace root that declares the sibling repos:

```elixir
%{
  root: ".",
  siblings: [
    %{name: :req_llm,   path: "req_llm"},
    %{name: :jido,      path: "jido"},
    %{name: :jido_ai,   path: "jido_ai"},
    %{name: :jido_chat, path: "jido_chat"}
  ]
}
```

- `root` — workspace root, interpreted relative to the manifest file. Use `"."`.
- `siblings[].name` — atom; the OTP application name of that repo.
- `siblings[].path` — directory name under `root`; must resolve inside `root`.

Sibling directories that don't exist yet (or lack a `mix.exs`) are still valid manifest entries — `status` will surface them as missing.

## Commands

### `mix graft.status`

Snapshots the workspace and prints per-sibling status, dep counts, and live git posture (branch, upstream, ahead/behind, dirty/in-progress).

```text
$ mix graft.status
Graft workspace
Root: /Users/me/oss
Repos: 4

jido
  status: ok
  git: main ↑ origin/main
  deps: hex=0 path=0 git=0 unknown=0

jido_ai
  status: ok
  git: feature/extract-provider ↑ origin/feature/extract-provider (3 ahead) dirty
  deps: hex=2 path=1 git=0 unknown=0

jido_chat
  status: ok
  git: main ↑ origin/main (1 behind)
  deps: hex=3 path=0 git=0 unknown=0

req_llm
  status: ok
  git: main (no upstream)
  deps: hex=4 path=0 git=0 unknown=0
```

The header includes a `Validation:` line that consults `.graft/validate.result.json` if present — showing pass/fail, the target closure, and a `[stale]` flag if any affected `mix.exs` has changed since the last run.

The git line collapses six signals into one human-readable summary:

- branch name (or `detached`)
- upstream tracking (`↑ origin/branch` or `(no upstream)`)
- ahead/behind commit counts
- working-tree state (`dirty`)
- in-progress operations (`merge`, `rebase`, `cherry_pick`, `revert`, `bisect`)

JSON mode emits the full structured `git` record per repo (`is_git_repo`, `branch`, `upstream`, `ahead`, `behind`, `dirty`, `detached_head`, `head_sha`, `in_progress`):

```bash
mix graft.status --json | jq '.repos[] | {name, git}'
```

The JSON contract is pinned by golden tests. `Graft.GitState` is the underlying read-only inspector — observational only, no caching, no background refresh, no mutation. Agents can call it directly to read git posture for any path.

### `mix graft.link.on TARGET [TARGET …]`

Rewrites every consumer's `mix.exs` dep tuple for `TARGET` from `{:target, "~> ..."}` (or git) into `{:target, path: "../target"}`. The closure is **transitive** — if `req_llm` is the target and `jido_ai` depends on `req_llm` and `jido_chat` depends on `jido_ai`, all three rewrites land in one plan.

```bash
mix graft.link.on req_llm --dry-run         # show the plan, write nothing
mix graft.link.on req_llm                   # apply transactionally
mix graft.link.on req_llm --json            # agent-friendly output
```

Behavior:

1. Compute a plan (hashes recorded for every consumer mix.exs).
2. Acquire the workspace lock at `.graft/lock`.
3. Verify every consumer's current hash matches the plan's pre-rewrite hash.
4. Apply each literal `String.replace` atomically (write-tmp + rename).
5. Verify each post-write hash matches the plan's proposed hash.
6. Merge new entries into `.graft/state.json` (preserving entries for other targets).
7. Release the lock.

If anything fails, every applied write is rolled back to its byte-identical preimage and the lock is released.

### `mix graft.validate TARGET [TARGET …]`

Runs `mix deps.get → mix compile --warnings-as-errors → mix test` across the target and every consumer that depends on it, in topological dependency order. Answers a single question:

> did my cross-repo change actually work?

```bash
mix graft.validate req_llm                 # run; text; fail-fast
mix graft.validate req_llm --dry-run       # show plan only, no execution
mix graft.validate req_llm --json          # JSONL stream for agents
mix graft.validate req_llm --continue      # run every repo even after a failure
```

Behavior:

- **Closure** — target + every transitive consumer in `workspace.deps`. Same closure shape link.on uses.
- **Execution order** — topological: dependencies validate before their consumers, alphabetic within a layer. The first compile failure surfaces at the *root cause*, not at a downstream symptom.
- **No lock** — validate doesn't acquire `.graft/lock`. It only touches `_build/`, `deps/`, and `mix.lock`, none of which are part of Graft's mutation trust contract. Running `link.on req_llm && contrib.validate req_llm` from one shell is the common case and must not deadlock.
- **Fail-fast by default** — the first failure halts further work. Every downstream repo is reported as `:skipped`, not `:failed`. `--continue` runs every repo regardless.
- **Single first-failure pointer** — the result envelope's `first_failure` field is the earliest topological failure: one place to look first, not a list.
- **JSONL stream** — `--json` emits newline-delimited JSON events: `plan_started`, `repo_planned` × N, `validation_planned` × M, `plan_completed`, then (during a real run) `command` × M, then `run_result`. Agents can act on partial streams; a killed run leaves a well-formed prefix.
- **Run log** — full merged stdout+stderr of every command is written to `.graft/validate.log`. The JSON envelope's `output_tail` is the last ~20 lines per command; the log has everything.
- **Result persistence** — every completed run (pass or fail) writes `.graft/validate.result.json` atomically. It's a lean envelope: verdict, per-repo statuses, headline first failure, schema version, and a `mix.exs` fingerprint per affected repo. Dry-runs do not write. Corruption is not fatal — `Workspace.snapshot/1` treats unreadable files as "no validation recorded" rather than refusing to operate.
- **Staleness** — the persisted result's fingerprint lets any consumer call `Graft.Validate.ResultFile.stale?(workspace, persisted)` to detect whether the validated state is still current. `mix graft.status` consults it automatically and marks stale validations.

Exit code is 0 iff `passed == true`. A pre-flight refusal (unknown target, no manifest) is non-zero but distinct from a validation failure — the JSON envelope's `passed` and `first_failure` fields make the distinction.

### `mix graft.link.off TARGET [TARGET …]`

Restores the recorded preimages for `TARGET` from `.graft/state.json`. Restoration is always **literal** — Graft never reasons about AST shape on the way out.

```bash
mix graft.link.off req_llm --dry-run
mix graft.link.off req_llm
mix graft.link.off req_llm --json
```

If the file's current hash differs from the recorded post-link hash (someone hand-edited it), `link.off` aborts before mutating with a `:off_hash_mismatch` error. State entries are pruned only after successful restoration; when no entries remain, `.graft/state.json` is deleted.

## Trust guarantees

These are first-class promises, not implementation niceties. They're checked by tests and pinned by golden JSON fixtures.

See [`docs/trust_guarantees.md`](docs/trust_guarantees.md) for the full document — each guarantee tied to a concrete failure scenario, plus an honest "when to use scripts instead" decision rule. Summary:

- **Workspace fence** — no mutation ever lands outside the declared workspace root, both at plan time and at apply time.
- **Pre-flight refusal** — if `.graft/state.json` is unreadable (malformed JSON, unsupported version, unknown atom, missing field), `link.on` refuses to mutate any file. Returns `:corrupt_state` with the underlying cause.
- **Hash-anchored writes** — every mix.exs rewrite verifies pre- and post-write SHA-256 against the plan. Drift between planning and applying triggers `:runner_hash_mismatch` and aborts before *any* file is touched.
- **Literal preimage restore** — `link.off` replaces the recorded path-link tuple with the byte-identical original dep tuple. No AST round-trip, no inverse rewrite, no reformatting.
- **Atomic file writes** — every change goes through write-temp + rename, atomic on POSIX within a filesystem.
- **LIFO transactional rollback** — if any consumer write or the state save fails, prior writes are restored byte-for-byte from in-memory preimages in reverse order. End state is either "all committed and state saved" or "nothing changed."
- **Single-writer lock** — `.graft/lock` is acquired before any mutation via `O_CREAT | O_EXCL`. A second concurrent invocation fails fast with `:workspace_locked`. Lock is released on success, error, *and* raise.
- **State merge, not state overwrite** — `link.on` of one target preserves recorded entries for every other target. Re-running `link.on` for an already-linked target is a deterministic byte-identical no-op.
- **Deterministic output** — repos, deps, plan changes, state entries, and JSON keys are sorted at every level. Identical input yields identical bytes (modulo `generated_at`).
- **Structured machine-readable errors** — every user-visible failure surfaces as `%Graft.Error{kind, message, details}`. The JSON contract for these is frozen by golden tests.

## Current limitations

The architectural surface is intentionally narrow at M1. Known gaps:

- **Single-target `Plan.build` for shared consumers** — building one plan with multiple targets where two targets share the same consumer relies on independent before-hashes. Run targets in separate `link.on` invocations (state merging handles accumulation).
- **No `mix deps.unlock` / `mix deps.get`** — Graft only rewrites `mix.exs`. You'll still run those yourself after a link change (intentional; we don't shell out to Mix).
- **No git integration** — Graft never touches `.git`. Stash, commit, or revert as you'd normally do.
- **No stale-lock detection** — if a process crashes mid-run, the `.graft/lock` file remains. Remove it manually after confirming no other Graft process is running. Liveness checks are deferred.
- **No concurrency on a single workspace** — by design. The lock is the boundary.
- **No `link.off` --force** — hash mismatch is a hard abort. Inspect the file, decide what's right, restore manually if needed.
- **Hardcoded validate sequence** — `deps.get`, `compile --warnings-as-errors`, `test`. A future iteration will read an optional `:validate` key from `graft.exs` for project-configured commands.
- **No streaming during a single mix command** — validate captures merged stdout+stderr and emits the JSONL `command` event when the command finishes. Live per-line streaming during execution is deferred. The run log gets the full transcript regardless.
- **No retries, no parallelism, no caching, no `--watch`** — validate runs once, sequentially, top-to-bottom. By design.
- **State schema is v1** — `state.json` is versioned; `:state_unsupported_version` is raised if you point Graft at a state file from a future schema. A `migrate/1` dispatcher will land alongside v2.

## What it is not

Graft is **not** a monorepo replacement, package manager, CI orchestrator, deployment system, GitHub automation platform, polyglot workspace manager, or background daemon. It is local-first, git-native, Mix-native, snapshot-driven, and CLI-first. Anything outside that fence is intentionally out of scope.

## License

Apache-2.0. See [LICENSE](LICENSE).
