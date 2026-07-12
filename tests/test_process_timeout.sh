#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/process_timeout.py"
PYTHON="${ESP_IDF_CY_PYTHON_BIN:-python3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "PASS=$1"; }
fail() { echo "FAIL=$1" >&2; exit 1; }
wait_gone() {
  pid="$1"; tries=0
  while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 30 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

"$PYTHON" -m py_compile "$HELPER" || fail syntax
grep -q 'taskkill.exe' "$HELPER" || fail windows-taskkill-missing
grep -q 'CREATE_NEW_PROCESS_GROUP' "$HELPER" || fail windows-process-group-missing
grep -q 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE' "$HELPER" || fail windows-job-object-missing
! grep -q 'if have timeout' "$ROOT/scripts/lib.sh" || fail nonuniform-timeout-path
pass cross-platform-static
for bad in nan inf; do
  set +e
  "$PYTHON" "$HELPER" "$bad" -- bash -c 'sleep 30' >/dev/null 2>&1
  RC=$?
  set -e
  [ "$RC" -eq 64 ] || fail "non-finite-timeout:$bad:$RC"
done
pass finite-timeout

started="$(date +%s)"
"$PYTHON" "$HELPER" 5 -- bash -c 'exit 0' || fail fast-child-rc
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 2 ] || fail "fast-child-slow:$elapsed"
pass fast-child

set +e
"$PYTHON" "$HELPER" 5 -- bash -c 'kill -TERM $$' >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 143 ] || fail "signal-return-code:$RC"
pass signal-return-code

# TERM-ignoring helper + grandchild must be killed as one group and normalize
# to rc124; inherited stdout must not keep command substitution open.
set +e
started="$(date +%s)"
OUT="$(PID_FILE="$TMP/grandchild.pid" "$PYTHON" "$HELPER" 1 -- bash -c \
  'trap "" TERM; sleep 30 & echo $! >"$PID_FILE"; wait' 2>&1)"
RC=$?
set -e
elapsed=$(( $(date +%s) - started ))
[ "$RC" -eq 124 ] || fail "timeout-rc:$RC:$OUT"
[ "$elapsed" -lt 3 ] || fail "timeout-not-bounded:$elapsed"
[ -s "$TMP/grandchild.pid" ] || fail no-grandchild-pid
wait_gone "$(cat "$TMP/grandchild.pid")" || fail grandchild-survived
pass process-group-timeout

# If the wrapper itself is interrupted, its signal handler must clean the
# helper group before returning 143.
PID_FILE="$TMP/interrupted-child.pid" "$PYTHON" "$HELPER" 30 -- bash -c \
  'sleep 30 & echo $! >"$PID_FILE"; wait' >"$TMP/out" 2>"$TMP/err" &
WRAPPER_PID=$!
tries=0
while [ ! -s "$TMP/interrupted-child.pid" ] && [ "$tries" -lt 30 ]; do
  sleep 0.05
  tries=$((tries + 1))
done
[ -s "$TMP/interrupted-child.pid" ] || fail interrupt-no-child
kill -TERM "$WRAPPER_PID"
set +e
wait "$WRAPPER_PID"
RC=$?
set -e
[ "$RC" -eq 143 ] || fail "interrupt-rc:$RC"
wait_gone "$(cat "$TMP/interrupted-child.pid")" || fail interrupt-child-survived
pass parent-signal-cleanup

pass all-process-timeout
