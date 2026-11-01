#!/usr/bin/env bash
# Seeds the in-cluster Git server with the two "repos" of this Day and leaves WORKING CLONES in lab/work/.
#   ../platform  -> http://git-server.git.svc/cgi-bin/git/platform.git   (repo #1: Strimzi + Kafka per region)
#   ../tenants   -> http://git-server.git.svc/cgi-bin/git/tenants.git    (repo #2: topics and users per team)
# Every "git commit / git push" of the scenarios is done inside lab/work/<repo>.   Re-running RESETS both repos.
set -euo pipefail
cd "$(dirname "$0")"
CTX="${KUBE_CONTEXT:-kind-strimzi-day9}"
PORT=18080
kubectl --context "$CTX" -n git rollout status deploy/git-server --timeout=180s

kubectl --context "$CTX" -n git port-forward svc/git-server "$PORT:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do curl -fs "http://localhost:$PORT/cgi-bin/git/platform.git/info/refs?service=git-upload-pack" >/dev/null && break; sleep 1; done

mkdir -p work
for repo in platform tenants; do
  dest="work/${repo}"
  [[ -n "${repo}" && -d "${dest}" ]] && rm -rf "${dest}"
  cp -R "../${repo}" "${dest}"
  rm -rf "${dest}/ci/.venv"
  git -C "${dest}" init -q -b main
  git -C "${dest}" add -A
  git -C "${dest}" -c user.name=lab -c user.email=lab@example.com commit -q -m "seed: ${repo}"
  git -C "${dest}" remote add origin "http://localhost:${PORT}/cgi-bin/git/${repo}.git"
  git -C "${dest}" push -q --force -u origin main
  echo "pushed ${repo} -> http://git-server.git.svc/cgi-bin/git/${repo}.git (from inside the cluster)"
done
