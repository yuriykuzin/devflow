#!/bin/bash
# sandbox-list.sh — list active sandboxes in a formatted table
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$SCRIPT_DIR/sandbox-registry.sh"

JSON=$("$REGISTRY" list 2>/dev/null) || JSON="{}"

if [ "$JSON" = "{}" ] || [ -z "$JSON" ]; then
  echo "No active sandboxes."
  exit 0
fi

# Output format flag
FORMAT="${1:-table}"

if [ "$FORMAT" = "--json" ]; then
  echo "$JSON" | jq .
  exit 0
fi

# Table output
printf "%-24s %-40s %-8s %-8s %-14s\n" "ID" "BRANCH" "AGENT" "DJANGO" "STATUS"
printf "%-24s %-40s %-8s %-8s %-14s\n" "------------------------" "----------------------------------------" "--------" "--------" "--------------"

echo "$JSON" | jq -r '
  to_entries[] |
  [
    .key,
    (.value.branch // "-"),
    (.value.agent // "-"),
    (if .value.ports.django then ":" + (.value.ports.django | tostring) else "-" end),
    (.value.status // "-")
  ] | @tsv
' | while IFS=$'\t' read -r id branch agent port status; do
  printf "%-24s %-40s %-8s %-8s %-14s\n" "$id" "$branch" "$agent" "$port" "$status"
done
