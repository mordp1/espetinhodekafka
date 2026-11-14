#!/usr/bin/env bash
# What a PR must pass BEFORE the alerts/dashboards reach Prometheus/Grafana. Runs locally and in CI (needs: kubectl, docker, python3, jq).
#   1. kustomize renders                      (a typo in kustomization.yaml fails here, not in the cluster)
#   2. dashboards are valid JSON              (a broken JSON means the Grafana sidecar silently skips the ConfigMap)
#   3. promtool check rules                   (PromQL syntax, templates in annotations)
#   4. promtool test rules                    (UNIT TESTS: "given these series, THIS alert must fire / must stay quiet")
# Usage (from the repo root):  ci/validate.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PROMTOOL_IMAGE="${PROMTOOL_IMAGE:-quay.io/prometheus/prometheus:v3.16.0}"   # same version as the Prometheus in the cluster
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "== 1. kustomize build"
kubectl kustomize manifests/observability > "$WORK/rendered.yaml"
echo "   OK ($(grep -c '^kind:' "$WORK/rendered.yaml") resources)"

echo "== 2. dashboards are valid JSON"
for f in manifests/observability/dashboards/*.json; do jq empty "$f" && echo "   OK $(basename "$f")"; done

echo "== 3. promtool check rules"
python3 -m venv "$WORK/venv" >/dev/null && "$WORK/venv/bin/pip" install -q -r ci/requirements.txt
"$WORK/venv/bin/python" ci/extract_rules.py < "$WORK/rendered.yaml" > "$WORK/rules.yml"
docker run --rm -v "$WORK:/w:ro" --entrypoint promtool "$PROMTOOL_IMAGE" check rules /w/rules.yml

echo "== 4. promtool test rules (unit tests)"
cp ci/tests/*.yml "$WORK/"
docker run --rm -v "$WORK:/w:ro" -w /w --entrypoint promtool "$PROMTOOL_IMAGE" test rules /w/rules_test.yml
echo "ALL GOOD"
