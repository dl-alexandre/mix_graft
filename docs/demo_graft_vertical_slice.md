# Graft Vertical Slice Demo

## Command

```bash
mix graft.graft.demo --repo <path> --name <name> [--root <path>] [--json]
```

## Flow

The demo exercises the complete graft loop in one command:

1. **Snapshot (current)** — Build an empty workspace snapshot rooted at a temp directory.
2. **Snapshot (desired)** — Build a workspace snapshot containing the specified repo as a `:managed` entry.
3. **Diff** — Compute structural delta between current and desired.
4. **Plan** — Generate a declarative graft plan (`:attach` action) from the diff.
5. **Verify** — Check real prerequisites:
   - Source repo path exists
   - Source repo is a git repository
   - Graft root is confined to temp dir or current working directory
   - No destructive overlap at materialization path
6. **Materialize** — Create a symlink from `<graft_root>/<name>` → `<repo_path>`.
7. **Observe** — Check drift between materialized state and desired state.
8. **Teardown** — Remove the symlink. The source repo is **never** touched.

## Output

### Human-readable (default)

```
═══════════════════════════════════════════════════════════════
 GRAFT VERTICAL SLICE DEMO
═══════════════════════════════════════════════════════════════

  Current snapshot id : <uuid>
  Desired snapshot id   : <uuid>

  Diff:
    added    : 2
    removed  : 0
    changed  : 0
    same     : 0

  Plan:
    id          : <id>
    action      : attach
    operations  : 2

  Verification:
    status  : PASS

  Materialization:
    path    : /tmp/.../<name>
    ok      : true

  Drift (observed vs desired):
    result  : <name>: no drift
    ok      : true

  Teardown:
    ok      : true

═══════════════════════════════════════════════════════════════
```

### JSON (`--json`)

```json
{
  "current_snapshot_id": "...",
  "desired_snapshot_id": "...",
  "diff": {"added": 2, "removed": 0, "changed": 0, "same": 0},
  "plan": {"id": "...", "action": "attach", "operations_count": 2},
  "verification": {"ok": true, "status": "verified", "message": "..."},
  "materialized_path": "/tmp/.../name",
  "materialization_ok": true,
  "drift": "name: no drift",
  "drift_ok": true,
  "teardown_ok": true,
  "graft_root": "/tmp/...",
  "repo_path": "/path/to/repo",
  "repo_name": "name"
}
```

## Guarantees

* **Source-repo immutability**: The source repository is never modified. Only a symlink is created inside the graft root.
* **Graft-root confinement**: Materialization is refused if the graft root escapes the temp directory or the current working directory.
* **Idempotency**: Running materialization twice is safe — if the correct symlink already exists, it is a no-op.
* **Clean teardown**: After the demo completes, no symlinks remain in the graft root. The graft root directory itself may remain (empty) but contains no managed entries.
* **Git validation**: The demo refuses to operate on non-git directories, ensuring the target is a real repository.

## Known Limitations

* **Local paths only**: Remote git URLs are parsed but return `{:error, :unsupported_remote_repo}`. Cloning from remotes is not implemented.
* **Symlinks only**: Materialization uses symbolic links. Copy-based or hard-link materialization is not supported.
* **Single repo**: The demo handles one repo at a time. Multi-repo grafts require orchestration at a higher level.
* **No rollback on failure**: If materialization fails after partial progress, manual cleanup of the graft root may be required.
* **No persistent state**: The demo does not write `.graft/state.json` or any other persistent metadata. It is purely ephemeral.
* **Plan verification bypass**: The standard `Graft.Plan.verify/1` checks preconditions against the current snapshot, which is empty in the demo. The demo therefore uses custom verification that checks real filesystem prerequisites instead.

## Files

| File | Purpose |
|------|---------|
| `lib/mix/tasks/graft.demo.ex` | CLI entrypoint |
| `lib/graft/graft/materializer.ex` | Filesystem materialization (symlink creation) |
| `lib/graft/graft/teardown.ex` | Safe removal of managed entries |
| `lib/graft/graft/drift.ex` | Observed-vs-desired state classification |
| `test/mix/tasks/graft.graft.demo_test.exs` | End-to-end tests |
