#!/usr/bin/env bash
# DNS for the LAPTOP: one wildcard zone, *.lab.test -> 127.0.0.1 (where kind publishes :443). Runs dnsmasq in a container on UDP/TCP 5354.
#   dns-local.sh up | down | test
# Then tell macOS to ask it for *.lab.test (one-time, needs sudo - the script prints the commands, it does not run them):
#   sudo mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\nport 5354\n' | sudo tee /etc/resolver/lab.test
# Linux with systemd-resolved: resolvectl dns lo 127.0.0.1:5354 && resolvectl domain lo '~lab.test'
# The 2-line alternative (no container, still sudo):  echo '127.0.0.1 bootstrap.kafka.lab.test broker-0.kafka.lab.test broker-1.kafka.lab.test broker-2.kafka.lab.test' | sudo tee -a /etc/hosts
set -euo pipefail
NAME=lab-dns; PORT=5354
case "${1:-up}" in
  up)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --restart unless-stopped -p "127.0.0.1:${PORT}:53/udp" -p "127.0.0.1:${PORT}:53/tcp" alpine:3.20 \
      sh -c 'apk add -q dnsmasq && exec dnsmasq -k --no-resolv --no-hosts --address=/lab.test/127.0.0.1 --log-queries --log-facility=-' >/dev/null
    for _ in $(seq 1 20); do dig +short +time=1 +tries=1 @127.0.0.1 -p "$PORT" bootstrap.kafka.lab.test 2>/dev/null | grep -q . && break; sleep 1; done
    echo "dnsmasq up on 127.0.0.1:${PORT}. Now (once, sudo):"
    echo "  sudo mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\\nport ${PORT}\\n' | sudo tee /etc/resolver/lab.test" ;;
  down) docker rm -f "$NAME" >/dev/null 2>&1 || true; echo "dnsmasq removed (and: sudo rm -f /etc/resolver/lab.test)" ;;
  test)
    echo "dnsmasq direct:"; dig +short @127.0.0.1 -p "$PORT" bootstrap.kafka.lab.test broker-0.kafka.lab.test anything.lab.test
    echo "what the OS resolver says (needs /etc/resolver/lab.test):"; dscacheutil -q host -a name bootstrap.kafka.lab.test 2>/dev/null | grep -E "ip_address" || echo "  (not resolving through the OS yet)" ;;
esac
