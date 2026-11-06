#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/tier2-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tier2-network.sh"
mkdir -p "$results"
trap network_reset EXIT
pings=${TIER2_NETWORK_LAB_PINGS:-600}

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

release_stale_references() {
  local token
  sudo -n pfctl -s References 2>/dev/null | tee "$results/references-before.txt" |
    awk 'tolower($0) ~ /token/ { for (i = 1; i <= NF; i++) if (tolower($i) ~ /^token/) column = i; next }
      column && /pfctl/ { print $column }' | while read -r token; do
    sudo -n pfctl -q -X "$token" 2>/dev/null || true
  done
  sudo -n pfctl -s References >"$results/references-after.txt" 2>&1 || true
}

release_stale_references
echo "pf enable references held by pfctl before: $(grep -c pfctl "$results/references-before.txt" || true), after: \
$(grep -c pfctl "$results/references-after.txt" || true)"
echo
echo "## Tier 2 networks as realized on croissant (ping to tamale, $pings at 0.1 s)"
echo
echo "| Network | pf rules | Sent | Lost % | RTT min ms | p50 | p95 | max |"
echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
network_reset
measure N0
network_pipes 1 0 && network_load_rules < <(network_rules) && measure N3-delay-only
network_reset
network_apply N3 && measure N3
network_reset
network_apply N6 && measure N6
