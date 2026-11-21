#!/usr/bin/env bash
# DNS INSIDE the cluster: makes pods resolve the SAME external names (bootstrap.kafka.lab.test, broker-N.kafka.lab.test) to the Gateway's
# Service. A team's application running in another namespace (or another cluster peered to this network) then uses exactly the same
# bootstrap + certificate as a laptop does. Adds one `rewrite` line to CoreDNS. Idempotent.
#   dns-cluster.sh        # apply          dns-cluster.sh remove
set -euo pipefail
CTX="${KUBE_CONTEXT:-kind-strimzi-day11}"
k() { kubectl --context "$CTX" "$@"; }
SVC=$(k -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=kafka-gateway -o jsonpath='{.items[0].metadata.name}')
RULE="rewrite name regex (.*)[.]kafka[.]lab[.]test ${SVC}.envoy-gateway-system.svc.cluster.local"
COREFILE=$(k -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -v 'kafka[.]lab[.]test' || true)
if [[ "${1:-apply}" == apply ]]; then
  COREFILE=$(printf '%s\n' "$COREFILE" | awk -v rule="    $RULE" '/^\.:53 \{/ {print; print rule; next} {print}')
fi
k -n kube-system create cm coredns --from-literal=Corefile="$COREFILE" --dry-run=client -o yaml | k replace -f - >/dev/null
k -n kube-system rollout restart deploy/coredns >/dev/null; k -n kube-system rollout status deploy/coredns --timeout=90s >/dev/null
echo "CoreDNS ${1:-apply}: *.kafka.lab.test -> ${SVC}.envoy-gateway-system"
