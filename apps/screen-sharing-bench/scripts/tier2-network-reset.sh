#!/usr/bin/env bash
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/tier2-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tier2-network.sh"
network_reset
