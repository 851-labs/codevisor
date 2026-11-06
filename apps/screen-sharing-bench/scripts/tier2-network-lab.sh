#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/tier2-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tier2-network.sh"
mkdir -p "$results"
trap network_reset EXIT
pings=${TIER2_NETWORK_LAB_PINGS:-300}

rules_with_address_list() {
  local hosts="{ $TIER2_HOST_IP $TIER2_APPLE_HOST }"
  printf '%s\n' \
    "dummynet in quick on en0 proto { tcp udp } from $hosts port != $TIER2_CLOCK_PORT to any pipe 1" \
    "dummynet out quick on en0 proto { tcp udp } from any to $hosts port != $TIER2_CLOCK_PORT pipe 2" \
    "dummynet in quick on en0 proto icmp from $hosts to any pipe 1" \
    "dummynet out quick on en0 proto icmp from any to $hosts pipe 2"
}

measure() {
  local label=$1 log="$results/ping-$1.txt"
  ping -c "$pings" -i 0.1 -W 1000 "$TIER2_HOST_IP" >"$log" 2>&1 || true
  sudo -n pfctl -a "$tier2_network_anchor" -s dummynet >"$results/rules-$label.txt" 2>&1 || true
  sudo -n pfctl -a "$tier2_network_anchor" -t "$tier2_network_table" -T show >"$results/table-$label.txt" 2>&1 || true
  local rules received
  rules=$(grep -c "^dummynet" "$results/rules-$label.txt" || true)
  received=$(grep -c "time=" "$log" || true)
  sed -n 's/.*time=\([0-9.]*\) ms.*/\1/p' "$log" | sort -n | awk -v label="$label" -v sent="$pings" \
    -v received="$received" -v rules="$rules" '
    { rtt[NR] = $1 }
    END {
      loss = 100 * (sent - received) / sent
      printf "| %s | %d | %d | %.1f | %.3f | %.3f | %.3f | %.3f |\n", label, rules, sent, loss,
        rtt[1], rtt[int((NR + 1) * 0.5)], rtt[int((NR + 1) * 0.95)], rtt[NR]
    }'
}

echo "## Tier 2 networks as realized on croissant (ping to tamale, $pings at 0.1 s)"
echo
echo "| Network | pf rules | Sent | Lost % | RTT min ms | p50 | p95 | max |"
echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
network_reset
measure N0
network_pipes 1 0.01 && rules_with_address_list | network_load_rules && measure N3-listed-rules
network_reset
network_pipes 1 0 && network_rules | network_load_rules && measure N3-delay-only
network_reset
network_apply N3 && measure N3
network_reset
network_apply N6 && measure N6
