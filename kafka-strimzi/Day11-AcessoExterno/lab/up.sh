#!/usr/bin/env bash
# Day 11 - builds the PLATFORM the Kafka cluster needs for external access. Idempotent: re-running upgrades in place.
#   kind (k8s 1.34) -> cert-manager (the lab PKI) -> trust-manager (CA distribution) -> Envoy Gateway (Gateway API) -> Strimzi operator
# Kafka itself is applied later, step by step, by the README (that is the lesson).
set -euo pipefail
cd "$(dirname "$0")/.."
CLUSTER=strimzi-day11
CTX="kind-${CLUSTER}"
K8S_IMAGE="kindest/node:v1.34.0"        # Strimzi 1.3.x needs Kubernetes >= 1.32
CERT_MANAGER=v1.21.3
TRUST_MANAGER=v0.26.0
ENVOY_GATEWAY=v1.10.0
STRIMZI=1.3.1

kind get clusters 2>/dev/null | grep -qx "${CLUSTER}" || kind create cluster --name "${CLUSTER}" --config kind-config.yaml --image "${K8S_IMAGE}"
h() { helm --kube-context "${CTX}" "$@"; }
k() { kubectl --context "${CTX}" "$@"; }

h repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
h repo add strimzi https://strimzi.io/charts/ >/dev/null 2>&1 || true
h repo update jetstack strimzi >/dev/null

h upgrade --install cert-manager jetstack/cert-manager --version "${CERT_MANAGER}" -n cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 5m
h upgrade --install trust-manager jetstack/trust-manager --version "${TRUST_MANAGER}" -n cert-manager \
  --set app.trust.namespace=cert-manager --wait --timeout 5m
# Envoy Gateway ships the Gateway API CRDs (incl. TLSRoute v1) in its chart
h upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "${ENVOY_GATEWAY}" -n envoy-gateway-system --create-namespace --wait --timeout 5m

k create namespace kafka --dry-run=client -o yaml | k apply -f - >/dev/null
h upgrade --install strimzi strimzi/strimzi-kafka-operator --version "${STRIMZI}" -n strimzi-operator --create-namespace \
  --set watchNamespaces="{kafka}" --wait --timeout 5m
echo "platform ready on context ${CTX}"
