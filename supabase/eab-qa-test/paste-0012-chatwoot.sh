#!/bin/bash
# Writes supabase/eab-qa-test/20261110000000_chatwoot_biz.sql: migration 0012 for a project where schema "biz" is ALREADY
# installed (the main biz_schema file refuses a second run). Same conversion make.mjs does: public. -> biz.
#   supabase/eab-qa-test/paste-0012-chatwoot.sh          writes it
#   supabase/eab-qa-test/paste-0012-chatwoot.sh --check  exits 1 if it is out of date
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=supabase/eab-qa-test/20261110000000_chatwoot_biz.sql
GEN=$( { echo "-- GENERATED from supabase/migrations/0012_chatwoot.sql (schema biz). Paste in the SQL editor of the project where biz is installed."
  echo "-- Safe to run twice. Touches only the chatwoot_* tables and functions."
  sed -E 's/\bpublic\./biz./g; s/search_path = public\b/search_path = biz, public/g' supabase/migrations/0012_chatwoot.sql; } )
if [ "${1:-}" = "--check" ]; then [ "$GEN" = "$(cat "$OUT")" ] && echo "up to date" || { echo "$OUT is out of date"; exit 1; }
else printf '%s\n' "$GEN" > "$OUT"; echo "wrote $OUT"; fi
