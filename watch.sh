#!/usr/bin/env bash
#
# watch.sh — Run check.sh on a loop at a fixed interval (for foreground use).
# check.sh handles per-target notify-once state, so this loop runs indefinitely.
# On a VPS, prefer cron instead of keeping this running.
#
# Usage:
#   ./watch.sh [interval_seconds]   # default: 300 (5 minutes)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL="${1:-300}"

echo "Watching every ${INTERVAL}s. Press Ctrl+C to stop."
while true; do
  "$SCRIPT_DIR/check.sh" || echo "Warning: check.sh returned an error. Will retry."
  sleep "$INTERVAL"
done
