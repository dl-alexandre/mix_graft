# Workspace Orchestration Flow

## Overview

This document defines the canonical operational flow for the workspace
orchestration system. It bridges human intent to materialized development
environments through declarative state transitions.

The system has three cooperating layers:

| Layer | Responsibility | Current Module |
|---|---|---|
| **Workspace** | Declarative state model, snapshots, diff | `Graft.Workspace` |
| **Graft** | Reconciliation engine — plans and executes transitions | `Graft.Plan` |
| **Graft** | Intelligence layer — discovery, scoring, opportunity tracking | (absorbs scripts) |

## The Flow

```
Intent
  → Discovery
    → Opportunity Graph
      → Workspace Requirements
        → Snapshot Generation (current)
          → Plan Generation (diff current → desired)
            → Validation
              → Materialization
                → Observation
                  → Repair (if drift)
                    → Teardown
```

## 1. Intent

The user (or agent) expresses a goal.

**Examples:**

- "I want to work on Phoenix auth bugs"
- "Fix the failing test in jason#203"
- "Explore good-first-issue opportunities in Ecto"
- "Validate my change across all downstream consumers"

**Resolution:**

```elixir
%Graft.Intent{
  capabilities: [:elixir, :phoenix, :auth],
  constraints: %{max_difficulty: :medium, time_available: "2h"},
  preferences: %{bug_vs_feature: :bug, needs_tests: true}
}
```

The system resolves this to:
- Target repos (from capability matching)
- Required skills
- Estimated effort

## 2. Discovery

Scan the workspace and external sources to find work matching the intent.

**Operations:**

- `Graft.Issues.sync` — fetch open issues from all workspace repos
- `Graft.PRs.sync` — fetch user's open PRs
- `Graft.Hex.sync` — fetch published versions, retirements

**Output:**

A `Workspace.Snapshot` with enriched data:

```elixir
%Workspace.Snapshot{
  github: %GithubState{
    issues: [%Issue{...}],
    prs: [%PR{...}]
  },
  hex: %HexState{
    packages: [%Package{...}]
  }
}
```

## 3. Opportunity Graph

Rank and connect discovered work into an opportunity graph.

**Nodes:** Issues, PRs, repos, capabilities
**Edges:** Dependencies, skill requirements, author relationships, temporal proximity

**Scoring:**

```elixir
%Graft.Opportunity{
  score: %Score{
    total: 72,
    signals: [
      %{label: "beginner-friendly label", score: 50},
      %{label: "help-wanted label", score: 35},
      %{label: "has reproduction", score: 10},
      ...
    ]
  },
  category: :ready_for_pr | :needs_investigation | :needs_skills | :blocked
}
```

**Categories:**

| Category | Meaning | Action |
|---|---|---|
| `ready_for_pr` | Clear scope, reproduction available, no blockers | Proceed to workspace prep |
| `needs_investigation` | Unclear fix, needs local exploration | Graft workspace, investigate |
| `needs_skills` | Requires capabilities user lacks | Suggest learning path or skip |
| `blocked` | Waiting on maintainer, design decision, or upstream fix | Defer, set reminder |
| `claimed` | Already has open PR (by anyone) | Skip or review existing PR |

## 4. Workspace Requirements

Determine what environment is needed to work on this opportunity.

**Analysis:**

- What repos need to be present?
- What dependency links are needed?
- What capabilities must be available?
- Is this a single-repo fix or cross-repo change?

**Output:**

```elixir
%Workspace.Requirements{
  repos: [:phoenix, :phoenix_ecto],
  links: [
    %{from: :phoenix_ecto, to: :phoenix, type: :path}
  ],
  capabilities: [:elixir, :ecto, :phoenix],
  ephemeral: true  # temporary workspace, not persistent
}
```

## 5. Snapshot Generation (Current)

Build the canonical `Workspace.Snapshot` of the current filesystem state.

**Process:**

1. Read `graft.exs` manifest (or auto-discover git repos)
2. Materialize each repo: exists?, has_mix_exs?, git state
3. Parse all `mix.exs` files for dependency tuples
4. Compute `Topology`: dependency graph, cycles, topological order
5. Enrich with external data (GitHub, Hex) if available

**Properties:**

- `id` — UUID for correlation across operations
- `schema_version` — for migration support
- `generated_at` — timestamp for staleness detection
- `topology` — pre-computed graph analysis
- `diagnostics` — validation errors, missing repos, cycle detection

**Serialization:**

Snapshots are JSON-serializable via `Workspace.Serializer`:

```elixir
json = Workspace.Serializer.to_json(snapshot)
{:ok, decoded} = Workspace.Serializer.from_json(json)
```

## 6. Plan Generation

Compute the diff between **current** snapshot and **desired** snapshot, then
build a `Graft.Plan`.

**Diff:**

```elixir
delta = Workspace.Diff.diff(current, desired)

%Delta{
  added: [%{path: [:repos, :phoenix], before: nil, after: repo}],
  removed: [],
  changed: [%{path: [:links, {:phoenix_ecto, :phoenix}], before: nil, after: link}]
}
```

**Plan:**

```elixir
plan = Graft.Plan.from_diff(current, desired)

%Graft.Plan{
  id: "plan-uuid",
  action: :attach,
  current: current_snapshot,
  desired: desired_snapshot,
  preconditions: [
    %Precondition{type: :repo_exists, target: "phoenix", expected: true}
  ],
  operations: [
    %Operation{type: :attach_repo, target: "phoenix"},
    %Operation{type: :create_link, target: "phoenix_ecto/phoenix"}
  ],
  rollback: [
    %Operation{type: :remove_link, target: "phoenix_ecto/phoenix"},
    %Operation{type: :detach_repo, target: "phoenix"}
  ]
}
```

**Verification:**

```elixir
{:ok, verified} = Graft.Plan.verify(plan)
# Checks all preconditions against filesystem
```

## 7. Validation

Validate that the plan is safe to execute.

**Checks:**

- [ ] All target repos exist (or can be cloned)
- [ ] No uncommitted changes in affected repos (or user confirms)
- [ ] No lock contention (`.graft/lock` available)
- [ ] No cyclic dependencies introduced
- [ ] All required capabilities available

**Modes:**

- `--dry-run` — verify only, no execution
- `--force` — skip some checks (with user confirmation)

## 8. Materialization

Execute the plan, transitioning the workspace to the desired state.

**Execution Model:**

1. Acquire workspace lock (`.graft/lock`)
2. Verify preconditions (recheck — state may have changed since planning)
3. Execute operations in dependency order (topological sort)
4. If any operation fails: execute rollback in reverse order
5. Release lock

**Atomicity:**

- Every file write goes through temp-file + rename
- Rollback is LIFO — last forward operation reversed first
- If rollback also fails: leave workspace in best-effort state, report for manual repair

## 9. Observation

After materialization, observe the resulting state.

**New Snapshot:**

```elixir
new_snapshot = Workspace.snapshot(root)
```

**Compare:**

```elixir
actual_diff = Workspace.Diff.diff(plan.desired, new_snapshot)

if Workspace.Diff.empty?(actual_diff) do
  :ok  # Materialization successful
else
  :drift_detected  # Something changed during execution
end
```

**Drift Sources:**

- External process modified repo during execution
- Git operation (rebase, merge) changed branch
- User manually edited files
- Network sync (Dropbox, etc.) touched files

## 10. Repair

If drift is detected, reconcile.

**Strategies:**

| Drift Type | Repair Action |
|---|---|
| File modified unexpectedly | Re-apply planned change, or alert user |
| Repo deleted | Re-clone if possible, or fail |
| New conflict introduced | Pause, present diff, let user resolve |
| Link broken (path no longer valid) | Re-run plan generation with current state |

**Repair is itself a plan:**

```elixir
repair_plan = Graft.Plan.from_diff(current, desired)
Graft.Plan.execute(repair_plan)
```

## 11. Teardown

When work is complete, return workspace to clean state.

**Modes:**

| Mode | Behavior |
|---|---|
| `detach` | Remove links, keep repos |
| `clean` | Remove links and unneeded repos |
| `preserve` | Keep everything as-is |

**Process:**

1. Verify tests pass (or user confirms failure is expected)
2. Verify no uncommitted changes (or user confirms)
3. Generate teardown plan (inverse of attach plan)
4. Execute teardown
5. Verify resulting snapshot matches expected base state

## Error Handling

Every step returns `{:ok, result} | {:error, Error.t()}`.

**Error Kinds:**

| Kind | Recovery |
|---|---|
| `discovery_failed` | Retry with backoff, or skip repo |
| `plan_precondition_failed` | Alert user, suggest manual fix |
| `execution_failed` | Rollback, or enter repair mode |
| `rollback_failed` | Alert user, leave workspace for manual repair |
| `drift_detected` | Re-plan, or alert user |
| `schema_mismatch` | Run migration, or alert user |

## State Machine

A Graft operation moves through states:

```
:draft
  → :planned (after diff computed)
    → :verified (after preconditions checked)
      → :executing (lock acquired)
        → :committed (all ops succeeded)
        → :rolled_back (failure, rollback succeeded)
        → :failed (failure, rollback also failed)
```

## Trust Guarantees

1. **Declarative state** — snapshots describe what exists, not how it was created
2. **Deterministic plans** — same input produces same operations (byte-stable)
3. **Atomic writes** — temp-file + rename for every filesystem mutation
4. **LIFO rollback** — failed operations unwind in reverse order
5. **Precondition verification** — state is rechecked immediately before execution
6. **Lock isolation** — only one graft operation per workspace at a time
7. **Schema versioning** — snapshots can migrate forward across versions
8. **Audit trail** — every plan, execution, and rollback is logged

## Future Directions

### Capability-Centric Matching

Instead of repo-centric discovery:

```elixir
%Graft.Intent{
  capabilities: [:elixir, :phoenix, :auth],
  constraints: %{time: "2h", max_repos: 3}
}

→ System resolves to:
  repos: [:phoenix, :phoenix_ecto, :ash_authentication]
  skills_needed: [:elixir, :phoenix, :ecto]
  workspace: generated
```

### Ephemeral Workspaces

Generate temporary workspaces for isolated exploration:

```elixir
mix graft.on phoenix --ephemeral --ttl 2h
# Creates /tmp/workspace-uuid/ with linked repos
# Auto-cleans after TTL or on teardown
```

### Fleet Operations

Apply same plan across multiple developer machines:

```elixir
# Share plan JSON, execute on remote workspace
mix graft.apply plan.json --remote ssh://dev-machine
```

### Agent Integration

Agents operate on the same snapshot model:

```elixir
# Agent reads snapshot, proposes plan, user approves
mix graft.opportunities --agent --json
# → Agent calls LLM, returns ranked list
# → User selects, system generates plan
# → User confirms, system executes
```

## Appendix: Data Types

### Workspace.Snapshot

```elixir
%Workspace.Snapshot{
  id: String.t(),                    # UUID
  schema_version: pos_integer(),      # Migration version
  root: Path.t(),                     # Workspace root
  generated_at: DateTime.t(),

  repos: [%Repo{name, path, exists?, has_mix_exs?}],
  deps: [%Dependency{repo, app, raw, source}],
  links: [%Link{repo, dep, hashes, preimage, replacement}],
  topology: %Topology{consumers, providers, order, cyclic?},

  git: [%GitState{repo, branch, sha, upstream, ahead, behind, dirty?}],
  prs: [%PullRequest{}],
  diagnostics: [%Diagnostic{severity, repo, kind, message}],

  validate_result: %ValidateResult{} | nil,
  github: map() | nil,
  hex: map() | nil
}
```

### Graft.Plan

```elixir
%Graft.Plan{
  id: String.t(),
  action: :attach | :detach | :repair | :migrate,
  status: :draft | :planned | :verified | :executing |
          :committed | :rolled_back | :failed,

  current: Workspace.Snapshot.t() | nil,
  desired: Workspace.Snapshot.t() | nil,

  preconditions: [%Precondition{type, target, expected, message}],
  operations: [%Operation{index, type, target, params, depends_on}],
  rollback: [%Operation{}],

  created_at: DateTime.t(),
  started_at: DateTime.t() | nil,
  completed_at: DateTime.t() | nil,
  error: Error.t() | nil
}
```

### Graft.Opportunity

```elixir
%Graft.Opportunity{
  id: String.t(),                    # "owner/repo#123"
  repo: Workspace.Repo.id(),
  issue: Issue.t() | nil,
  score: %Score{total, signals},
  category: :ready | :needs_investigation | :needs_skills | :blocked | :claimed,
  required_capabilities: [atom()],
  workspace_readiness: %{
    repo_cloned: boolean(),
    repo_linked: boolean(),
    deps_resolved: boolean(),
    tests_passing: boolean()
  }
}
```
