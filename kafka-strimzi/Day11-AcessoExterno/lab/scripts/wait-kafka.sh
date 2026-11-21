#!/usr/bin/env bash
# Waits until the Kafka cluster is Ready AND the brokers have stopped rolling (all pods Ready, the newest one up for >= QUIET seconds).
# Kafka "Ready=True" alone is not enough here: during a rolling update the CR stays Ready while one broker restarts.
set -euo pipefail
# EXPECT_ROLL=1: first wait for a roll to START. The Cluster Operator only notices a changed Secret on its next reconciliation (~1 min),
# so right after a certificate change the brokers look "quiet" even though a restart is coming.
CTX="${KUBE_CONTEXT:-kind-strimzi-day11}"; QUIET="${QUIET:-45}"; TIMEOUT="${TIMEOUT:-900}"; EXPECT_ROLL="${EXPECT_ROLL:-0}"; seen_roll=0
k() { kubectl --context "$CTX" -n kafka "$@"; }
start=$(date +%s)
while true; do
  ready=$(k get kafka my-cluster -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  pods=$(k get pods -l strimzi.io/name=my-cluster-kafka -o json | python3 -c '
import sys, json, datetime
items = json.load(sys.stdin)["items"]
ok = [p for p in items if all(c.get("ready") for c in p["status"].get("containerStatuses", []))]
ages = []
for p in items:
    for c in p["status"].get("containerStatuses", []):
        t = c.get("state", {}).get("running", {}).get("startedAt")
        if t: ages.append((datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(t.replace("Z","+00:00"))).total_seconds())
print(len(ok), len(items), int(min(ages)) if ages else 0)')
  set -- $pods
  [[ "$3" -lt "$QUIET" ]] && seen_roll=1
  if [[ "$EXPECT_ROLL" == 1 && "$seen_roll" == 0 ]]; then sleep 5; (( $(date +%s) - start > TIMEOUT )) && { echo "timeout: no roll started" >&2; exit 1; }; continue; fi
  if [[ "$ready" == "True" && "$1" -ge 3 && "$1" == "$2" && "$3" -ge "$QUIET" ]]; then echo "kafka ready (${1}/${2} brokers, quiet for ${3}s)"; exit 0; fi
  (( $(date +%s) - start > TIMEOUT )) && { echo "timeout: ready=$ready brokers=$1/$2 newest_age=${3}s" >&2; exit 1; }
  sleep 5
done
