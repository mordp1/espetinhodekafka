#!/usr/bin/env bash
# Runs a Kafka CLI tool in a container, the way an EXTERNAL team would use it, against the lab through the Gateway on :443.
#   kafka-client.sh <bundle-dir> <tool> [args...]       e.g.  kafka-client.sh bundle-team-orders kafka-topics.sh --list
# DNS: a container does not see your /etc/hosts, so the 4 lab names are mapped to the host (where kind publishes :443) with --add-host.
# On your laptop, the equivalent is README part 2, step 2 (/etc/hosts or dnsmasq): after that you can run the tools natively.
set -euo pipefail
# <bundle-dir> may be `none` for plaintext listeners (scenario A)
if [[ "${1:?usage: kafka-client.sh <bundle-dir|none> <tool> [args...]}" == none ]]; then BUNDLE=""; else BUNDLE="$(cd "$1" && pwd)"; fi; shift
TOOL="${1:?tool}"; shift
HOSTS=(${HOSTS:-bootstrap broker-0 broker-1 broker-2})   # scenario D drops names on purpose, to show the "only bootstrap resolves" failure
ARGS=(); for h in "${HOSTS[@]}"; do ARGS+=(--add-host "${h}.kafka.lab.test:host-gateway"); done
# extra --add-host (scenario B uses it to point a name that is NOT in the certificate at the same Gateway)
[[ -n "${EXTRA_HOST:-}" ]] && ARGS+=(--add-host "${EXTRA_HOST}:host-gateway")
[[ -n "$BUNDLE" ]] && ARGS+=(-v "${BUNDLE}:/bundle:ro" -w /bundle)
docker run --rm -i "${ARGS[@]}" "${KAFKA_IMAGE:-apache/kafka:4.3.0}" "/opt/kafka/bin/${TOOL}" "$@"
