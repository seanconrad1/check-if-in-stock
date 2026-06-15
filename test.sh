#!/usr/bin/env bash
#
# test.sh — Send a one-off test push notification to verify your ntfy setup.
# Uses the first ntfy channel found in targets.json (override with arg 2).
#
# Usage:
#   ./test.sh ["custom message"] [ntfy-topic]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
TARGETS_FILE="${TARGETS_FILE:-$SCRIPT_DIR/targets.json}"

# Topic: explicit arg wins, otherwise first ntfy channel in targets.json.
topic="${2:-}"
if [[ -z "$topic" && -f "$TARGETS_FILE" ]]; then
  topic="$(python3 -c "import json,sys
try:
    for t in json.load(open('$TARGETS_FILE')):
        for n in t.get('notify', []):
            if n.startswith('ntfy:'):
                print(n[5:]); sys.exit(0)
except Exception:
    pass" 2>/dev/null)"
fi

if [[ -z "$topic" ]]; then
  echo "ERROR: no ntfy topic found. Pass one: ./test.sh \"msg\" my-topic" >&2
  exit 2
fi

body="${1:-Test notification from checkIfSoldOut ✅}"

echo "Sending test notification to ${NTFY_SERVER%/}/${topic}..."
http_code="$(curl -s -o /tmp/ntfy_test_resp.json -w '%{http_code}' \
  -H "Title: checkIfSoldOut test" \
  -H "Tags: white_check_mark" \
  -d "${body}" \
  "${NTFY_SERVER%/}/${topic}")"

if [[ "$http_code" == "200" ]]; then
  echo "Success — notification sent. Check your phone."
else
  echo "ERROR: ntfy returned HTTP $http_code" >&2
  cat /tmp/ntfy_test_resp.json >&2
  echo >&2
  exit 1
fi
