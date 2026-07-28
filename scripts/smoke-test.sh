#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
CITY="${CITY:-Warsaw}"
POP1="${POP1:-1863056}"
POP2="${POP2:-1870000}"

log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

assert_json_field_equals() {
  local json="$1"
  local key="$2"
  local expected="$3"
  python3 - <<'PYJSON' "$json" "$key" "$expected"
import json
import sys
payload = json.loads(sys.argv[1])
key = sys.argv[2]
expected = sys.argv[3]
actual = payload.get(key)
if str(actual) != expected:
    raise SystemExit(f"Mismatch for {key}: expected {expected}, got {actual}")
PYJSON
}

require curl
require python3

log "Checking /health"
health_response="$(curl -fsS "${BASE_URL}/health")"
assert_json_field_equals "$health_response" "status" "OK"
log "PASS /health"

log "Checking /health/ready"
ready_response="$(curl -fsS "${BASE_URL}/health/ready")"
assert_json_field_equals "$ready_response" "status" "OK"
log "PASS /health/ready"

log "Upsert city first value"
upsert_one="$(curl -fsS -X POST "${BASE_URL}/cities" -H "Content-Type: application/json" -d "{\"city\":\"${CITY}\",\"population\":${POP1}}")"
assert_json_field_equals "$upsert_one" "city" "$CITY"
assert_json_field_equals "$upsert_one" "population" "$POP1"
log "PASS first upsert"

log "Upsert city second value"
upsert_two="$(curl -fsS -X POST "${BASE_URL}/cities" -H "Content-Type: application/json" -d "{\"city\":\"${CITY}\",\"population\":${POP2}}")"
assert_json_field_equals "$upsert_two" "city" "$CITY"
assert_json_field_equals "$upsert_two" "population" "$POP2"
log "PASS second upsert"

log "Query city"
query_response="$(curl -fsS "${BASE_URL}/cities/${CITY}")"
assert_json_field_equals "$query_response" "city" "$CITY"
assert_json_field_equals "$query_response" "population" "$POP2"
log "PASS query"

log "Verify 404 for unknown city"
not_found_code="$(curl -sS -o /tmp/city-pop-not-found.json -w '%{http_code}' "${BASE_URL}/cities/Atlantis")"
[ "$not_found_code" = "404" ] || fail "Expected HTTP 404, got $not_found_code"
not_found_body="$(cat /tmp/city-pop-not-found.json)"
assert_json_field_equals "$not_found_body" "error" "city_not_found"
log "PASS 404 behavior"

log "Verify 422 for invalid payload"
invalid_code="$(curl -sS -o /tmp/city-pop-invalid.json -w '%{http_code}' -X POST "${BASE_URL}/cities" -H "Content-Type: application/json" -d '{"city":"Warsaw","population":-1}')"
[ "$invalid_code" = "422" ] || fail "Expected HTTP 422, got $invalid_code"
log "PASS 422 behavior"

log "All smoke tests passed"
