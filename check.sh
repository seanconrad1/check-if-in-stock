#!/usr/bin/env bash
#
# check.sh — Multi-target stock monitor.
#
# Reads targets.json, checks each product's availability, and sends a
# notification when an out-of-stock item comes back in stock. Sends each
# target only once per restock (state files), re-arming when it sells out.
#
# Per-target config (targets.json):
#   name      Friendly label used in logs/notifications
#   url       Product page URL
#   strategy  "shopify-js" (default) | "html"
#   notify    Array of channels, e.g. ["ntfy:my-topic"]
#
# Strategies:
#   shopify-js  Fetch <product-url>.js and read JSON `.available` (recommended;
#               works for any Shopify store, stable across theme changes).
#   html        Scrape the page for a non-disabled "btn--add-to-cart" button.
#
# Usage:
#   ./check.sh
#
# Exit codes:
#   0  ran successfully (per-target results logged)
#   2  configuration error (missing targets.json or python3)

set -uo pipefail

# --- Load configuration from .env if present ---------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

TARGETS_FILE="${TARGETS_FILE:-$SCRIPT_DIR/targets.json}"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.state}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 is required."; exit 2; }
[[ -f "$TARGETS_FILE" ]] || { log "ERROR: targets file not found: $TARGETS_FILE"; exit 2; }
mkdir -p "$STATE_DIR"

# --- Stock-check strategies ---------------------------------------------------
# Each echoes one of: in_stock | sold_out | error

check_shopify_js() {
  local url="$1" data avail
  data="$(curl -fsSL -A "$UA" "${url%/}.js" 2>/dev/null)" || { echo "error"; return; }
  avail="$(printf '%s' "$data" | python3 -c "import sys, json
try:
    print('yes' if json.load(sys.stdin).get('available') else 'no')
except Exception:
    print('error')" 2>/dev/null)"
  case "$avail" in
    yes) echo "in_stock" ;;
    no)  echo "sold_out" ;;
    *)   echo "error" ;;
  esac
}

check_html() {
  local url="$1" html total disabled
  html="$(curl -fsSL -A "$UA" "$url" 2>/dev/null)" || { echo "error"; return; }
  total="$( { grep -o 'btn--add-to-cart' <<<"$html" || true; } | wc -l | tr -d ' ')"
  disabled="$( { grep -o 'btn--add-to-cart btn--disabled' <<<"$html" || true; } | wc -l | tr -d ' ')"
  if (( total == 0 )); then echo "error"; return; fi
  if (( total > disabled )); then echo "in_stock"; else echo "sold_out"; fi
}

# --- Notification channels ----------------------------------------------------
# send_notification <name> <url> <channel>  -> returns 0 on success

send_notification() {
  local name="$1" url="$2" channel="$3"
  case "$channel" in
    ntfy:*)
      local topic="${channel#ntfy:}" code
      code="$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Title: Restock: $name" \
        -H "Priority: high" \
        -H "Tags: tada" \
        -H "Click: $url" \
        -d "Back in stock! $url" \
        "${NTFY_SERVER%/}/$topic")"
      [[ "$code" == "200" ]]
      ;;
    *)
      log "  WARN: unknown notify channel '$channel'"
      return 1
      ;;
  esac
}

# --- Iterate targets ----------------------------------------------------------
while IFS=$'\t' read -r name url strategy notify; do
  [[ -z "$url" ]] && continue
  strategy="${strategy:-shopify-js}"
  log "Checking: $name [$strategy]"

  case "$strategy" in
    shopify-js) status="$(check_shopify_js "$url")" ;;
    html)       status="$(check_html "$url")" ;;
    *)          log "  ERROR: unknown strategy '$strategy' — skipping."; continue ;;
  esac

  state_key="$(printf '%s' "$url" | shasum | awk '{print $1}')"
  state_file="$STATE_DIR/$state_key"

  case "$status" in
    error)
      log "  WARN: could not determine stock (fetch/parse error)."
      ;;
    sold_out)
      log "  Sold out."
      if [[ -f "$state_file" ]]; then rm -f "$state_file"; log "  Re-armed for next restock."; fi
      ;;
    in_stock)
      log "  IN STOCK! 🎉"
      if [[ -f "$state_file" ]]; then
        log "  Already notified — skipping. Delete $state_file to re-arm."
      else
        sent=0
        IFS=',' read -ra channels <<< "$notify"
        for ch in "${channels[@]}"; do
          [[ -z "$ch" ]] && continue
          if send_notification "$name" "$url" "$ch"; then
            log "  Notified via $ch"
            sent=1
          else
            log "  ERROR: notification failed for $ch"
          fi
        done
        if (( sent )); then touch "$state_file"; fi
      fi
      ;;
  esac
done < <(python3 -c "
import json, sys
try:
    targets = json.load(open('$TARGETS_FILE'))
except Exception as e:
    sys.stderr.write('Failed to parse targets.json: %s\n' % e)
    sys.exit(1)
for t in targets:
    url = t.get('url', '')
    if not url:
        continue
    name = t.get('name', '(unnamed)')
    strategy = t.get('strategy', 'shopify-js')
    notify = ','.join(t.get('notify', []))
    print('\t'.join([name, url, strategy, notify]))
")

exit 0
