#!/usr/bin/env bash
# Renders EVERY leaf (apps/<app>/<env>/<cluster>) exactly the way the ApplicationSet will:
#   chart/kafka-tenant + valueFiles [common, env (optional), cluster] + parameters app/env/cluster.
# Catches schema violations (forbidden operations, bad names, config outside the allow-list) before merge.
# Usage: ci/render-all.sh [--out DIR]    (needs: helm)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=""; [[ "${1:-}" == "--out" ]] && OUT="$2"
[[ -n "$OUT" ]] && mkdir -p "$OUT"
fail=0; n=0
for leaf in apps/*/*/*/values.yaml; do
  dir=$(dirname "$leaf"); cluster=$(basename "$dir"); env=$(basename "$(dirname "$dir")"); app=$(basename "$(dirname "$(dirname "$dir")")")
  [[ "$env" == "grants" ]] && continue
  files=(-f "apps/$app/values.yaml")
  [[ -f "apps/$app/$env/values.yaml" ]] && files+=(-f "apps/$app/$env/values.yaml")
  files+=(-f "$leaf")
  if rendered=$(helm template "$app-$env-$cluster" chart/kafka-tenant "${files[@]}" --set "app=$app,env=$env,cluster=$cluster" 2>&1); then
    echo "OK    $app/$env/$cluster ($(grep -c '^kind:' <<<"$rendered") resources)"
    [[ -n "$OUT" ]] && echo "$rendered" > "$OUT/$app-$env-$cluster.yaml"
    n=$((n+1))
  else
    echo "FAIL  $app/$env/$cluster"; sed 's/^/      /' <<<"$rendered"; fail=1
  fi
done
echo "rendered $n leaves"; exit $fail
