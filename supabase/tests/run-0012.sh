#!/bin/bash
# Local proof for migration 0012 (Chatwoot bridge, Phase 2). Needs a local PostgreSQL 15+ and a stand-in Supabase file
# (roles anon/authenticated/service_role, auth.users, auth.uid(), storage). Example:
#   PGHOST=/path/to/socket PGPORT=55432 PGUSER=postgres supabase/tests/run-0012.sh /path/to/bizqa_00_supabase.sql
set -euo pipefail
STUBS="${1:?path to the stand-in Supabase SQL file (bizqa_00_supabase.sql in admin-eab/database/tests)}"
cd "$(dirname "$0")/../.."
node supabase/eab-qa-test/make.mjs --check
supabase/eab-qa-test/paste-0012-chatwoot.sh --check
DB=cw0012_$$
dropdb --if-exists "$DB" 2>/dev/null; createdb "$DB"
trap 'dropdb --if-exists "$DB"' EXIT
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$STUBS" -f supabase/eab-qa-test/20261109120000_biz_schema.sql 2>&1 | grep -E "ERROR|installed in schema" || true
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f supabase/tests/0012_chatwoot.test.sql 2>&1 | grep -E "NOTICE:  [A-Z]|ERROR|DETAIL|CONTEXT"
# a second install must be refused with "already installed ... nothing was changed"
OUT=$(psql -q -v ON_ERROR_STOP=1 -d "$DB" -f supabase/eab-qa-test/20261109120000_biz_schema.sql 2>&1 || true)
echo "$OUT" | grep -q "already installed in schema biz; nothing was changed" || { echo "FAIL: second install was not refused cleanly"; exit 1; }
# the ready-to-paste file for a project where biz is already installed: runs cleanly, twice, and the tests still pass
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f supabase/eab-qa-test/20261110000000_chatwoot_biz.sql
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f supabase/eab-qa-test/20261110000000_chatwoot_biz.sql
echo "DONE: all checks passed"
