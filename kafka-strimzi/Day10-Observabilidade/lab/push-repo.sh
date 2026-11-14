#!/usr/bin/env bash
# Seeds the in-cluster Git server with the GitOps repo of this Day (../gitops) and leaves a WORKING CLONE in lab/work/observability.
#   ../gitops  -> http://git-server.git.svc/cgi-bin/git/observability.git   (what ArgoCD watches)
# Every "git commit / git push" of the scenarios is done inside lab/work/observability.   Re-running RESETS the repo.
set -euo pipefail
cd "$(dirname "$0")"
CTX="${KUBE_CONTEXT:-kind-strimzi-day10}"
PORT=18080
kubectl --context "$CTX" -n git rollout status deploy/git-server --timeout=180s

kubectl --context "$CTX" -n git port-forward svc/git-server "$PORT:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do curl -fs "http://localhost:$PORT/cgi-bin/git/observability.git/info/refs?service=git-upload-pack" >/dev/null && break; sleep 1; done

dest="work/observability"
[[ -d "${dest}" ]] && rm -rf "${dest}"
mkdir -p work
cp -R ../gitops "${dest}"
git -C "${dest}" init -q -b main
git -C "${dest}" add -A
git -C "${dest}" -c user.name=lab -c user.email=lab@example.com commit -q -m "seed: observability platform"
git -C "${dest}" remote add origin "http://localhost:${PORT}/cgi-bin/git/observability.git"
git -C "${dest}" push -q --force -u origin main
echo "pushed observability -> http://git-server.git.svc/cgi-bin/git/observability.git (from inside the cluster)"
