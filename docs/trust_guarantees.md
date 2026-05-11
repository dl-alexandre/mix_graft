# Trust Guarantees

Why Graft exists and what it actually promises.

## Scripts vs. Graft

A directory of shell scripts can do everything Graft does today. `link.on` is `sed -i` plus a JSON file. `validate` is a bash loop. `status` is `for d in */; do git -C $d status; done`. If you're a solo contributor on three repos and your scripts work, you don't need Graft. Scripts are faster to build, faster to debug, and faster to throw away.

The honest framing:

- **Scripts optimize for convenience.** Fewer lines of code, fewer abstractions, do the thing now.
- **Graft optimizes for trust.** Same operation, but with evidence, rollback, hash anchoring, and a frozen contract you can hand to an agent.

You pay for trust up front in code complexity. You collect on it the first time something goes wrong and you have to recover, or the first time an agent needs to read structured output, or the first time the workspace grows past what your scripts' implicit assumptions can hold.

This document names the trust properties Graft provides. Each one is tied to a concrete failure scenario. If none of those scenarios feel real to you, the substrate isn't earning its keep for your workflow — keep the scripts. If even one does, the rest of this doc explains the trade.

---

## Guarantees

### 1. Workspace snapshot is the source of truth

**Without it.** Two commands disagree about the workspace. `status` shows three repos; the script that opens PRs sees a fourth one because someone `git clone`d while the run was in flight. The agent retries against the second state and the first one's plan is now stale. You don't know which view is correct.

**Graft's guarantee.** Every command derives from a single `Workspace.snapshot/1` value. The snapshot is a side-effect-free, immutable struct. Two commands run from the same snapshot see byte-identical inputs — repos, deps, git state, manifest entries. Different snapshots have different `generated_at` timestamps; everything else is deterministic.

**For humans.** When `status` says four repos and `link.on` operates on four repos, they mean the same four repos.

**For agents.** An agent can capture a snapshot once, reason about it offline, and act on it with confidence. The plan it builds is replayable from that snapshot.

---

### 2. Mutations are planned before applied

**Without it.** A script rewrites `mix.exs` while you're reading its output. You see "✓ done" before you see "✗ failed on repo 4." Now repos 1-3 have been rewritten and you have to figure out which by hand.

**Graft's guarantee.** Every mutation passes through a `Plan` phase that is pure: filesystem reads only, no writes. The plan is a value you can inspect with `--dry-run`, render as JSON, save, replay. The Runner consumes a plan; it never decides what to mutate.

**For humans.** `--dry-run` is real, not theater. The bytes the dry-run shows are the bytes that will be written.

**For agents.** An agent can build a plan, present it for approval, and only apply it when authorized. The planning and applying steps are separable artifacts.

---

### 3. File changes are hash-anchored

**Without it.** You compute a rewrite at 10:01. You apply it at 10:03. In between, your editor auto-saves the file with one whitespace change. The rewrite silently produces a syntactically valid but semantically wrong result, and you don't notice until tests fail in CI four hours later.

**Graft's guarantee.** Every planned change carries the SHA-256 of the file's contents at plan time and the SHA-256 of the expected post-rewrite contents. The Runner verifies both before writing. Any drift — yours, your editor's, a teammate's — aborts before mutation with `:runner_hash_mismatch`.

**For humans.** Tampering between plan and apply is detected, named, and refused.

**For agents.** An agent that observes a hash mismatch knows the workspace moved out from under its plan. It can rebuild from a fresh snapshot rather than apply stale assumptions.

---

### 4. Mutation application is atomic where possible

**Without it.** A script gets killed (Ctrl-C, OOM, power) mid-write. The file is truncated. The next run reads a half-file and produces unpredictable behavior.

**Graft's guarantee.** Every file write goes through write-tmp + `File.rename/2`, which is atomic on POSIX within a filesystem. A killed run either left the file untouched or left it in the new state — never in between. Temp files are cleaned up on success and on failure.

**For humans.** Interrupting `mix graft.link.on` with Ctrl-C will not corrupt a `mix.exs`.

**For agents.** Concurrent inspection of the workspace will never observe a half-written file.

---

### 5. Rollback is LIFO and byte-identical

**Without it.** The script applied 4 of 6 rewrites, then failed on the 5th. You have no preimage stored. You either `git checkout` (losing any uncommitted edits) or you reconstruct the original deps by hand from memory.

**Graft's guarantee.** Every applied write stores the in-memory preimage in a rollback stack. On any subsequent failure — another write, a hash mismatch, a state-save failure — the stack is unwound in LIFO order and every written file is restored to byte-identical preimage. Tests verify byte equality, not "looks right."

**For humans.** A failed `link.on` leaves the workspace exactly as it was. You don't run `git status` after a failure wondering what changed.

**For agents.** An agent driving a long sequence of mutations can recover deterministically. The post-failure state is the pre-run state.

---

### 6. Validation emits machine-readable JSON

**Without it.** Your script's "test failed in repo 3" output is a string. The agent that consumed it has to parse English to know what failed, then re-run things to figure out where.

**Graft's guarantee.** `mix graft.validate --json` emits newline-delimited JSON events: `plan_started`, `repo_planned`, `validation_planned`, `plan_completed`, then `command` per finished command, then `run_result` with a single `first_failure` pointer. Failure categories are enumerated atoms (`:deps_unresolvable`, `:compile_error`, `:test_failure`, `:command_not_found`).

**For humans.** Pipe to `jq`. Filter for failures. Build dashboards. No string scraping.

**For agents.** Branch on `failure_category`, dispatch fixes by `repo + command`, partial streams are parseable up to the interruption point. The agent never has to re-derive what the tool already knew.

---

### 7. JSON contracts are golden-test pinned

**Without it.** You write an agent prompt that parses `result.outcome.first_failure.repo`. Six months later, a refactor renames the field to `first_failure.repo_name`. Every prompt that consumed it silently breaks.

**Graft's guarantee.** Every public JSON contract (`status`, `link.on` plan + result, `link.off` plan + result, `validate` plan + result, structured errors) is pinned by a golden file in `test/golden/`. Renaming, adding, or removing a field requires regenerating the golden — which surfaces the change in the diff. Changes are visible, intentional, and reviewable.

**For humans.** The integration scripts you wrote against today's JSON output will still work tomorrow.

**For agents.** Prompts that consume Graft output have a stable contract. Breaking changes appear as test diffs, not as silent prompt regressions.

---

### 8. Commands share one workspace model

**Without it.** Three scripts each parse `mix.exs` slightly differently. `link.on` finds the dep, `validate` doesn't, `pr.draft` finds it again. You spend an hour debugging which script's heuristic is right.

**Graft's guarantee.** `Workspace.snapshot/1` is the only path to a workspace model. Every command — `status`, `link.on`, `link.off`, `validate` — consumes the same snapshot struct, the same `Repo` records, the same dep parsing, the same git state. Internal heuristics are not allowed to diverge because there is only one place they live.

**For humans.** When `status` says a repo has 2 hex deps, `link.on` will operate on the same 2 hex deps.

**For agents.** One snapshot answers every question. An agent doesn't have to reconcile views from three different command outputs.

---

### 9. Failures produce inspectable evidence

**Without it.** A test fails. The script printed 3000 lines of output and exited 1. The relevant 8 lines are in there somewhere. You scroll up.

**Graft's guarantee.** Every failed validation command writes its full transcript to `.graft/validate.log`. The JSON envelope carries the last ~20 lines as `output_tail`, a failure category, the exact `argv` that ran, and the repo path. The `first_failure` field points at the earliest topological failure — one place to look, not a list to triage. Errors are structured `%Graft.Error{kind, message, details}` everywhere, with `kind` as an enumerated atom for agent branching.

**For humans.** One pointer. One log path. One place to look.

**For agents.** Failure evidence is structured, scoped, and persistent across runs. An agent can quote exact failing argv into a remediation prompt rather than approximating it.

---

### 10. Trust boundaries are explicit

**Without it.** A script mutates wherever it can write. A bug in a path computation rewrites a config file in your home directory. You don't notice until your shell breaks.

**Graft's guarantee.** Every mutation is fenced to the declared workspace root, enforced both at plan time and at apply time (defense in depth). A `.graft/lock` file prevents two mutating commands from running concurrently in the same workspace, acquired via `O_CREAT | O_EXCL` and released on success, failure, *and* raise. Corrupt `.graft/state.json` causes `link.on` to refuse mutation pre-flight rather than overwrite it. State schema versions are checked; unsupported versions abort.

**For humans.** Graft cannot write outside the workspace, even with a bug in path computation. It cannot run twice at once. It cannot overwrite state it can't read.

**For agents.** The mutation surface is bounded. An agent can reason about what's writable without enumerating every code path.

---

## Non-goals

Naming what Graft is not, so the substrate framing isn't read as scope expansion:

- **Not a replacement for every shell script.** Your script that opens a new branch, makes a commit, and pushes is fine. Graft doesn't try to subsume it.
- **Not a generic task runner.** It runs `mix deps.get / compile / test` in a specific topological order for a specific reason. It is not `make`, not `just`, not a CI engine.
- **Not a package manager.** It rewrites `mix.exs` deps in place. Hex, the lockfile, and `mix deps.get` remain the source of truth.
- **Not an agent brain.** It is a substrate an agent operates *through*. It does not plan contributions, write commit messages, or decide what to fix. Those belong to the intelligence layer above it.
- **Not useful if the workspace is tiny and scripts are sufficient.** Below the inflection point where coordination overhead exceeds tooling overhead, scripts win. That's a real outcome.

---

## Decision rule

Use scripts when:

- The workspace has 1–3 repos.
- You are the only contributor.
- Mutations are simple and easily undone manually (`git checkout`).
- No agent or external script consumes the output.
- Speed and convenience matter more than recovery and evidence.

Use Graft when:

- The cost of a bad mutation is high — uncommitted work in multiple repos, a half-rewritten state, a corrupted dep graph.
- An agent consumes structured output and needs a stable contract.
- Multiple repos depend on each other and execution order matters.
- Multiple contributors share the workspace and concurrent runs are possible.
- You've been burned at least once by a script that swallowed an error or left the workspace half-mutated.

The cleanest test: **the third time you reach for `git status` to confirm a script's output, you're past the inflection point.** Substrates exist to remove that confirmation cost. If the cost isn't real for you yet, the substrate isn't worth its weight yet.

---

Graft's job is to make the safe path the default path. Not to be clever. Not to be comprehensive. To be the boring, inspectable, replayable foundation underneath the parts of OSS contribution that actually move fast — the human judgment and the agent reasoning. The substrate isn't where the value comes from. It's where the value can stop being lost.
