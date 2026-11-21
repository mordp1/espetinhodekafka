#!/usr/bin/env bash
# What the PLATFORM team hands to a TEAM so it can connect from outside the cluster. Output folder (default ./bundle-<user>):
#   ca.crt         the lab Root CA (PUBLIC): "trust anything signed by this". Same file for every team. Not a secret.
#   keystore.pem   the team's identity: private key + client certificate (signed by the Strimzi Clients CA). A SECRET: only that team.
#   client.properties   ready for kafka-*.sh / any Java client (PEM, no keytool/PKCS12 needed)
# Usage: client-bundle.sh <kafkauser> [outdir]
set -euo pipefail
USER_NAME="${1:?usage: client-bundle.sh <kafkauser> [outdir]}"
OUT="${2:-bundle-${USER_NAME}}"
CTX="${KUBE_CONTEXT:-kind-strimzi-day11}"
NS="${KAFKA_NS:-kafka}"
BOOTSTRAP="${BOOTSTRAP:-bootstrap.kafka.lab.test:443}"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

mkdir -p "$OUT"; chmod 700 "$OUT"
# the lab Root CA: the issuer of the certificate the brokers serve (cert-manager puts it in the Secret as ca.crt)
k get secret kafka-external-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$OUT/ca.crt"
# the team identity, created by the User Operator
k get secret "$USER_NAME" -o jsonpath='{.data.user\.key}' | base64 -d >  "$OUT/keystore.pem"
k get secret "$USER_NAME" -o jsonpath='{.data.user\.crt}' | base64 -d >> "$OUT/keystore.pem"
chmod 600 "$OUT/keystore.pem"
cat > "$OUT/client.properties" <<PROPS
bootstrap.servers=${BOOTSTRAP}
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=ca.crt
ssl.keystore.type=PEM
ssl.keystore.location=keystore.pem
PROPS
echo "bundle for ${USER_NAME} -> ${OUT}/  (ca.crt is public; keystore.pem is a SECRET)"
