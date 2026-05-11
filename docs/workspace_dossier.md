# Workspace Dossier v1

## Purpose

A read-only durable workspace status model that summarises one active
workspace/session without adding new orchestration behaviour.

The dossier is deliberately **observational**: it reports what exists,
not what should happen next.  It is the canonical input for higher-level
intelligence layers (dashboards, alerting, fleet dispatch) and for human
operators who need a quick health check before running a graft.

## Scope

* One dossier per workspace snapshot.
* No mutating actions, no scheduling, no approvals, no safe-action
  dispatch — those belong to `Graft.Runner` and future fleet layers.
* Missing optional data degrades to `unknown` (never crashes).
* Output is stable, deterministic, and machine-readable (JSON).

## Fields

| Field | Type | Source / Owner | Description |
|---|---|---|---|
| `workspace_id` | `string` | `Workspace.Snapshot` | UUID of the canonical snapshot this dossier was built from. |
| `repo_path` | `string` | `Workspace.Snapshot` | Absolute path to the workspace root. |
| `project_name` | `string` \| `"unknown"` | Builder | Derived from the root directory basename (strips `workspace_` / `workspace-` prefix). |
| `branch` | `string` \| `"unknown"` | `GitState` | Branch of the first git repo in the snapshot. |
| `worktree_path` | `string` | `Workspace.Snapshot` | Same as `repo_path` in v1; may diverge in future worktree-aware workspaces. |
| `tmux_session` | `string` \| `"unknown"` | Builder | Detected from the `TMUX` environment variable (best-effort). |
| `agent_metadata` | `object` \| `{"state":"unknown"}` | Builder | Detected from `AGENT_PID` / `AGENT_NAME` environment variables. |
| `git_summary` | `object` | `GitState` | Aggregated counts: `repo_count`, `git_repos`, `dirty_count`, `detached_count`, `ahead_total`, `behind_total`, `in_progress_repos`. |
| `last_activity_at` | `ISO-8601` \| `"unknown"` | `Workspace.Snapshot` | `generated_at` of the source snapshot. |
| `health` | `[object]` | `Graft.Verify` | List of health issues surfaced by the invariant checker. |
| `status` | `"healthy"` \| `"degraded"` \| `"unknown"` \| `"stale"` | Builder | Derived from topology cycles, git errors, and dirty+in-progress repos. |
| `attention_flags` | `[string]` | Builder | Human-readable signals requiring attention (e.g. `uncommitted_changes`, `detached_head`, `branch_divergence`, `in_progress`, `git_error`, `cyclic_dependencies`). |
| `generated_at` | `ISO-8601` | Builder | Timestamp when the dossier was materialised. |

## Usage

### From the CLI

```bash
# Print a JSON dossier for the current directory
mix graft.workspace.dossier

# Print a JSON dossier for a specific workspace
mix graft.workspace.dossier --root /path/to/workspace
```

### From Elixir

```elixir
alias Graft.Workspace
alias Graft.Workspace.Dossier.Builder

{:ok, snapshot} = Workspace.snapshot("/path/to/workspace")
dossier = Builder.build(snapshot)
json = Jason.encode!(Dossier.to_map(dossier), pretty: true)
```

## JSON Example

```json
{
  "workspace_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "repo_path": "/Users/dev/oss",
  "project_name": "oss",
  "branch": "main",
  "worktree_path": "/Users/dev/oss",
  "tmux_session": "unknown",
  "agent_metadata": {"state": "unknown"},
  "git_summary": {
    "repo_count": 127,
    "git_repos": 127,
    "dirty_count": 3,
    "detached_count": 0,
    "ahead_total": 12,
    "behind_total": 4,
    "in_progress_repos": []
  },
  "last_activity_at": "2026-05-11T14:55:00Z",
  "health": [
    {"severity": "warn", "repo": "ecto", "kind": :branch_divergence, "message": "2 commits ahead of origin"}
  ],
  "status": "degraded",
  "attention_flags": ["uncommitted_changes", "branch_divergence"],
  "generated_at": "2026-05-11T14:55:01Z"
}
```

## Future Work

* **Session affinity**: link `tmux_session` to actual `tmux` socket / PID.
* **Agent heartbeat**: query a registered agent process instead of env vars.
* **Stale detection**: compare `last_activity_at` against a freshness threshold.
* **Fleet view**: aggregate multiple dossiers into a fleet-level summary.
