#!/usr/bin/env bash
# Checks the example routing tree with amtool (the same logic Alertmanager runs): "this label set must reach THESE receivers".
# Usage: ci/routing-tree/test.sh      (needs Docker; uses the same Alertmanager version as the lab)
set -euo pipefail
cd "$(dirname "$0")"
AM="${ALERTMANAGER_IMAGE:-quay.io/prometheus/alertmanager:v0.35.0}"
amtool() { docker run --rm -v "$PWD:/c:ro" --entrypoint amtool "$AM" "$@"; }

amtool check-config /c/alertmanager.yml
echo "== routing tree"; amtool config routes show --config.file=/c/alertmanager.yml

fail=0
t() {   # t "<expected receivers, comma separated>" label=value ...
  local want="$1"; shift
  local got; got=$(amtool config routes test --config.file=/c/alertmanager.yml "$@" | tr -d '\r')
  if [[ "$got" == "$want" ]]; then echo "OK    $*  ->  $got"; else echo "FAIL  $*  ->  got '$got', want '$want'"; fail=1; fi
}
t 'kafka-platform-pagerduty,kafka-platform-slack'  alertname=KafkaUnderMinIsrPartitions severity=critical team=kafka-platform namespace=kafka
t 'kafka-platform-slack'                            alertname=KafkaConsumerGroupLagHigh severity=warning team=kafka-platform namespace=kafka
t 'orders-team-slack,kafka-platform-pagerduty,kafka-platform-slack' alertname=OrderPipelineStalled severity=critical team=kafka-platform
t 'orders-team-slack,kafka-platform-slack'          alertname=OrderPipelineEndToEndLatencyHigh severity=warning team=kafka-platform
t 'kafka-platform-slack'                            alertname=KafkaTopicNotReady severity=warning team=kafka-platform namespace=kafka
t 'platform-default'                                alertname=KubeletDown severity=warning namespace=kube-system
t 'null'                                            alertname=Watchdog severity=none
exit $fail
