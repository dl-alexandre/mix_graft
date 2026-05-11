# Graft Safety Model

## Ownership: External vs Managed

Every repo in a workspace snapshot carries an `ownership` field:

* `:external` — The repo is the **source of truth**. It lives outside the
  graft root (often in a permanent location like `~/src` or a cloned
  upstream checkout). The materializer never writes to `:external` repos;
  they are only observed.
* `:managed` — The repo is a **materialized entry** inside the graft root.
  It is typically a symlink pointing to an `:external` source. The
  materializer creates it; the teardown removes it.

### Invariant

> Teardown **never** deletes `:external` repos. It only removes `:managed`
> entries inside the graft root.

## Root Confinement

All filesystem side effects are gated by `Graft.Safety`.

### Rule

A graft root must be physically inside **one** of:

1. The system temp directory (`System.tmp_dir!/0`)
2. The current working directory (`File.cwd!/0`)

### Rationale

This prevents accidental writes to system directories (`/`, `/usr`,
`/home`, `/etc`) or other users' home directories if a malformed path
is passed to the CLI or constructed from user input.

### Enforcement

`Safety.allowed_root?/1` is called by:

* `Materializer.materialize_repo/2`
* `Teardown.teardown_repo/2`

No other module re-implements this check.

## Path Traversal Prevention

Repo names are validated before they are joined with the graft root.

### Rejected patterns

* Empty string
* `..` (parent directory)
* `/` or `\` (directory separators)

### Enforcement

`Safety.valid_repo_name?/1` → `Safety.resolve_managed_path/2`

Returns `{:ok, resolved_path}` or `{:error, Error.t()}`.

## Symlink-Only Materialization (v1)

The materializer creates **symbolic links**, never copies or moves files.

### Why symlinks?

* **Non-destructive**: The source repo is untouched.
* **Atomic-ish**: `File.ln_s/2` either succeeds or fails; there is no
  partial state.
* **Observable**: A symlink is easy to inspect (`File.read_link/1`) and
  easy to remove (`File.rm/1`).

### Idempotency

If the correct symlink already exists, `materialize_repo/2` returns
`{:ok, ...}` without modifying anything.

If a path already exists but is **not** the expected symlink, the
materializer returns an error rather than overwriting.

## Teardown Hardening

Teardown uses a strict allow-list of removable path types:

| Path type | Action | Rationale |
|---|---|---|
| Symlink | Remove | This is what materialization created. |
| Empty directory | Remove | Parent directories created by `File.mkdir_p!/1`. |
| Non-empty directory | **Refuse** | Could be a real project or user data. |
| Regular file | **Refuse** | Not created by the materializer. |

### Error on refusal

Teardown returns `{:error, %Error{kind: :runner_rollback_failed}}` and
leaves the path untouched. The caller must decide whether to abort or
escalate to manual cleanup.

## Known Limitations

1. **Remote repos**: Cloning from a git URL is not supported. Only
   local paths may be materialized.
2. **Copy-based materialization**: Hard links or full directory copies
   are not implemented. Symlinks require the source to remain
   accessible at its original path.
3. **Cross-device symlinks**: If the graft root and the source repo are
   on different filesystems, `File.ln_s/2` may fail. A future version
   could fall back to bind mounts or shallow copies.
4. **Windows**: Symbolic links on Windows may require elevated
   privileges. The materializer does not detect or handle this.
5. **No persistent state**: The demo does not write `.graft/state.json`
   or any other metadata. Restarting a failed graft requires
   reconstructing the plan from scratch.
6. **Plan verification gap**: The standard `Graft.Plan.verify/1` checks
   preconditions against the `current` snapshot, which is empty in the
   demo. The demo uses custom verification (`verify_demo_prerequisites/3`)
   instead. This will be unified once the plan module understands
   external-vs-managed source paths natively.
