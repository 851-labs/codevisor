#!/usr/bin/env bash

tier2_network_anchor="com.apple/codevisor-bench"
tier2_network_pf_token=""

network_reset() {
  sudo -n pfctl -q -a "$tier2_network_anchor" -F all 2>/dev/null || true
  sudo -n dnctl -q flush 2>/dev/null || true
  if [[ -n "$tier2_network_pf_token" ]]; then sudo -n pfctl -q -X "$tier2_network_pf_token" 2>/dev/null || true; fi
  tier2_network_pf_token=""
}

network_apply() {
  local network=$1
  network_reset
  case "$network" in
    N0) return 0 ;;
    N3) network_shape 1 0.01 1000 ;;
    *) say "unknown network $network"; return 1 ;;
  esac
}

network_shape() {
  local delay_ms=$1 loss=$2 capacity_mbit=$3
  sudo -n dnctl pipe 1 config bw "${capacity_mbit}Mbit/s" delay "$delay_ms" plr "$loss" >/dev/null || return 1
  sudo -n dnctl pipe 2 config bw "${capacity_mbit}Mbit/s" delay "$delay_ms" plr "$loss" >/dev/null || return 1
  printf '%s\n' \
    "dummynet in quick on en0 proto { tcp udp } from { $TIER2_HOST_IP $TIER2_APPLE_HOST } port != $TIER2_CLOCK_PORT to any pipe 1" \
    "dummynet out quick on en0 proto { tcp udp } from any to { $TIER2_HOST_IP $TIER2_APPLE_HOST } port != $TIER2_CLOCK_PORT pipe 2" |
    sudo -n pfctl -q -a "$tier2_network_anchor" -f - 2>/dev/null || return 1
  tier2_network_pf_token=$(sudo -n pfctl -E 2>&1 | awk '/Token/ { print $NF }')
  network_loaded || { say "dummynet rules or pipes didn't load"; return 1; }
}

network_loaded() {
  [[ -n "$tier2_network_pf_token" ]] &&
    sudo -n pfctl -a "$tier2_network_anchor" -s dummynet 2>/dev/null | grep -q "pipe 1" &&
    sudo -n dnctl list 2>/dev/null | grep -q "^00002:"
}

network_check() {
  local dir=$1
  bench calibrate --check c2 --responder "$TIER2_HOST_IP" --port "$TIER2_NETWORK_CHECK_PORT" --duration 5 \
    --interval 1 >"$dir/network-check.json" 2>/dev/null || true
}
