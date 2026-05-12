#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/graft-quickstart-smoke.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

echo "workspace: $ROOT"

mkdir -p "$ROOT/flow"
git init "$ROOT/flow" >/dev/null
git -C "$ROOT/flow" remote add origin "https://github.com/elixir-lang/flow.git"

cat >"$ROOT/flow/mix.exs" <<'EOF'
defmodule Flow.MixProject do
  use Mix.Project
  def project, do: [app: :flow, version: "0.1.0", deps: []]
end
EOF

mix graft.add elixir-lang/flow --to-manifest --root "$ROOT"
mix graft.list --root "$ROOT"
mix graft.validate --quick --root "$ROOT"
mix graft.status --root "$ROOT"
mix graft.remove flow --root "$ROOT"

echo "smoke: ok"
