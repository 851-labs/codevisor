#!/usr/bin/env bash

tier2_network_anchor="com.apple/codevisor-bench"
tier2_network_table="codevisor-bench-host"
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
    N3) network_shape 1 0.01 ;;
    N6) network_shape 25 0.001 bw 50Mbit/s queue 500Kbytes ;;
    *) say "unknown network $network"; return 1 ;;
  esac
}

network_rules() {
  local table="<$tier2_network_table>"
  printf '%s\n' \
    "table $table const { $TIER2_HOST_IP $TIER2_APPLE_HOST }" \
    "dummynet in quick on en0 proto { tcp udp } from $table port != $TIER2_CLOCK_PORT to any pipe 1" \
    "dummynet out quick on en0 proto { tcp udp } from any to $table port != $TIER2_CLOCK_PORT pipe 2" \
    "dummynet in quick on en0 proto icmp from $table to any pipe 1" \
    "dummynet out quick on en0 proto icmp from any to $table pipe 2"
}

network_shape() {
  local delay_ms=$1 loss=$2
  shift 2
  network_pipes "$delay_ms" "$loss" "$@" || return 1
  network_rules | network_load_rules
}

network_pipes() {
  local delay_ms=$1 loss=$2
  shift 2
  sudo -n dnctl pipe 1 config delay "$delay_ms" plr "$loss" "$@" >/dev/null || return 1
  sudo -n dnctl pipe 2 config delay "$delay_ms" plr "$loss" "$@" >/dev/null || return 1
}

network_load_rules() {
  sudo -n pfctl -q -a "$tier2_network_anchor" -f - 2>/dev/null || return 1
  [[ -n "$tier2_network_pf_token" ]] || tier2_network_pf_token=$(sudo -n pfctl -E 2>&1 | awk '/Token/ { print $NF }')
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
