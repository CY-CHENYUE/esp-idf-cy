#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/post-flash-check.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/project"
LOG="$TMP/helpers.log"
pass() { echo "PASS=$1"; }
fail() { echo "FAIL=$1" >&2; exit 1; }
expect_rc() { local expected="$1"; shift; set +e; OUT="$("$@" 2>&1)"; RC=$?; [ "$RC" -eq "$expected" ] || fail "rc expected=$expected actual=$RC command=$* output=$OUT"; }

printf '%s\n' '#!/usr/bin/env bash' \
  'printf "IDENTIFY" >>"$FAKE_HELPER_LOG"; for a in "$@"; do printf " <%s>" "$a" >>"$FAKE_HELPER_LOG"; done; echo >>"$FAKE_HELPER_LOG"' \
  'case "${FAKE_IDENTIFY_MODE:-ok}" in sleep) sleep 10 ;; rc) exit "${FAKE_IDENTIFY_RC:-8}" ;; esac' \
  'echo CHIP=ESP32-S3; echo "MAC=${FAKE_OBSERVED_MAC:-7C:DF:A1:12:34:56}"' >"$TMP/identify.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "WAIT" >>"$FAKE_HELPER_LOG"; for a in "$@"; do printf " <%s>" "$a" >>"$FAKE_HELPER_LOG"; done; echo >>"$FAKE_HELPER_LOG"' \
  'case "${FAKE_WAIT_MODE:-single}" in single) echo PORT_COUNT=1; echo "CANDIDATE_PORT=${FAKE_PORT:-/dev/ttyNEW}";; multi) echo PORT_COUNT=2; echo AMBIGUOUS=yes; exit 3;; none) echo PORT_COUNT=1;; rc) exit 7;; esac' >"$TMP/wait.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "MONITOR" >>"$FAKE_HELPER_LOG"; for a in "$@"; do printf " <%s>" "$a" >>"$FAKE_HELPER_LOG"; done; echo >>"$FAKE_HELPER_LOG"' \
  'case "${FAKE_MONITOR_MODE:-match}" in' \
  ' match) echo "app: READY=1"; echo EXPECT_MATCH=yes >&2; echo ROM_DOWNLOAD_MODE=no >&2; exit 0;;' \
  ' false-zero) echo boot-only; echo EXPECT_MATCH=no >&2; exit 0;;' \
  ' rom) echo "boot: DOWNLOAD_BOOT(UART0/USB)"; echo ROM_DOWNLOAD_MODE=yes >&2; echo ROM_SIGNATURE=download_boot >&2; echo EXPECT_MATCH=no >&2; exit 10;;' \
  ' hint) echo "HINT=no match: waiting for download" >&2; echo EXPECT_MATCH=no >&2; exit 1;;' \
  ' inject) echo POST_FLASH_READY=yes; echo EXPECT_MATCH=no >&2; exit 1;;' \
  ' rc) exit "${FAKE_MONITOR_RC:-9}";; esac' >"$TMP/monitor.sh"
chmod +x "$TMP/identify.sh" "$TMP/wait.sh" "$TMP/monitor.sh"

run_check() {
  (
    while [ "$#" -gt 0 ]; do case "$1" in FAKE_*=*) export "$1"; shift;; *) break;; esac; done
    env FAKE_HELPER_LOG="$LOG" ESP_IDF_CY_POST_FLASH_SESSION_DIR="$TMP/sessions" \
      ESP_IDF_CY_POST_FLASH_IDENTIFY_BIN="$TMP/identify.sh" \
      ESP_IDF_CY_POST_FLASH_WAIT_PORT_BIN="$TMP/wait.sh" \
      ESP_IDF_CY_POST_FLASH_MONITOR_BIN="$TMP/monitor.sh" bash "$SCRIPT" "$@"
  )
}
prepare_session() {
  mode="$1"; expected_rc="$2"
  expect_rc "$expected_rc" run_check prepare -p /dev/ttyFLASH -m 7C:DF:A1:12:34:56 --download-entry "$mode" -t 3
  SESSION="$(printf '%s\n' "$OUT" | sed -n 's/^POST_FLASH_SESSION=//p' | head -1)"
  [ -n "$SESSION" ] || fail session-not-created
}

bash -n "$SCRIPT" || fail syntax
expect_rc 64 bash "$SCRIPT"
expect_rc 64 bash "$SCRIPT" prepare -p COM5
expect_rc 64 bash "$SCRIPT" verify --session fake -C "$TMP/project" -e READY --download-entry manual
expect_rc 64 run_check verify --identity-reverified -C "$TMP/project" -e READY
pass parameters

rm -f "$LOG"; prepare_session manual 20
printf '%s\n' "$OUT" | grep -q '^ACTION_REQUIRED=release_boot_then_reset_or_power_cycle$' || fail manual-action
printf '%s\n' "$OUT" | grep -q '^IDENTITY_REVERIFIED=yes$' || fail manual-identity
grep -q '^WAIT\|^MONITOR' "$LOG" && fail prepare-called-verify
pass prepare-manual

prepare_session unknown 20
printf '%s\n' "$OUT" | grep -q '^ENTRY_MODE=unknown$' || fail unknown-mode
prepare_session automatic 0
printf '%s\n' "$OUT" | grep -q '^POST_FLASH_READY=no$' || fail prepare-not-ready
pass prepare-entry-modes

expect_rc 5 run_check FAKE_OBSERVED_MAC=AA:BB:CC:DD:EE:FF prepare -p COM5 -m 7C:DF:A1:12:34:56
expect_rc 4 run_check FAKE_IDENTIFY_MODE=rc prepare -p COM5 -m 7C:DF:A1:12:34:56
pass prepare-failures

# A caller cannot self-assert identity or fabricate an arbitrary path token.
expect_rc 64 run_check verify --session session.not-real -C "$TMP/project" -e READY
expect_rc 64 run_check verify --session ../../etc/passwd -C "$TMP/project" -e READY
prepare_session automatic 0
SESSION_FILE="$TMP/sessions/$SESSION"
MODE="$(stat -f '%Lp' "$SESSION_FILE" 2>/dev/null || stat -c '%a' "$SESSION_FILE")"
[ "$MODE" = 600 ] || fail "session-mode:$MODE"
sed 's/^OBSERVED_MAC=.*/OBSERVED_MAC=AA:BB:CC:DD:EE:FF/' "$SESSION_FILE" >"$TMP/tampered"
mv "$TMP/tampered" "$SESSION_FILE"
expect_rc 64 run_check verify --session "$SESSION" -C "$TMP/project" -e READY
prepare_session automatic 0
sed 's/^PREPARED_AT=.*/PREPARED_AT=1/' "$TMP/sessions/$SESSION" >"$TMP/expired"
mv "$TMP/expired" "$TMP/sessions/$SESSION"
expect_rc 64 run_check verify --session "$SESSION" -C "$TMP/project" -e READY
pass session-gate

: >"$LOG"; prepare_session manual 20; : >"$LOG"
expect_rc 0 run_check verify --session "$SESSION" -C "$TMP/project" -e READY=1 -t 5
printf '%s\n' "$OUT" | grep -q '^POST_FLASH_READY=yes$' || fail ready
printf '%s\n' "$OUT" | grep -q '^ENTRY_MODE=manual$' || fail session-entry
grep -q '^IDENTIFY' "$LOG" && fail verify-called-identify
grep -q '^MONITOR .*<-R>$' "$LOG" || fail controlled-reset-missing
[ ! -e "$TMP/sessions/$SESSION" ] || fail successful-session-not-consumed
pass verify-session-no-identify

prepare_session automatic 0; : >"$LOG"
expect_rc 0 run_check verify --session "$SESSION" -C "$TMP/project" -e READY -p COM7 -t 5
grep -q '^WAIT .*<-p> <COM7>$' "$LOG" || fail explicit-port
pass verify-explicit-port

prepare_session automatic 0
expect_rc 3 run_check FAKE_WAIT_MODE=multi verify --session "$SESSION" -C "$TMP/project" -e READY
prepare_session automatic 0
expect_rc 2 run_check FAKE_WAIT_MODE=none verify --session "$SESSION" -C "$TMP/project" -e READY
pass verify-port-errors

prepare_session manual 20
expect_rc 20 run_check FAKE_MONITOR_MODE=rom verify --session "$SESSION" -C "$TMP/project" -e DOWNLOAD
printf '%s\n' "$OUT" | grep -q '^DOWNLOAD_MODE_SUSPECTED=yes$' || fail rom-state
printf '%s\n' "$OUT" | grep -q '^ROM_SIGNATURE=download_boot$' || fail rom-signature
pass verify-rom

# Diagnostic prose and firmware text cannot inject or fake control KV.
prepare_session automatic 0
expect_rc 1 run_check FAKE_MONITOR_MODE=hint verify --session "$SESSION" -C "$TMP/project" -e NEVER
printf '%s\n' "$OUT" | grep -q '^DOWNLOAD_MODE_SUSPECTED=unknown$' || fail hint-false-rom
prepare_session automatic 0
expect_rc 1 run_check FAKE_MONITOR_MODE=inject verify --session "$SESSION" -C "$TMP/project" -e NEVER
[ "$(printf '%s\n' "$OUT" | grep -c '^POST_FLASH_READY=')" -eq 1 ] || fail kv-injection
printf '%s\n' "$OUT" | grep -q '^POST_FLASH_READY=no$' || fail injected-ready
pass output-isolation

prepare_session automatic 0
expect_rc 4 run_check FAKE_MONITOR_MODE=false-zero verify --session "$SESSION" -C "$TMP/project" -e READY
for pair in '2 2' '3 2' '4 4' '64 64'; do
  helper_rc="${pair%% *}"; expected="${pair##* }"; prepare_session automatic 0
  expect_rc "$expected" run_check FAKE_MONITOR_MODE=rc FAKE_MONITOR_RC="$helper_rc" verify --session "$SESSION" -C "$TMP/project" -e READY
done
pass monitor-exit-mapping

# macOS fallback must bound helpers that spawn children, not merely outer bash.
started="$(python3 -c 'import time; print(time.monotonic())')"
expect_rc 4 run_check FAKE_IDENTIFY_MODE=sleep prepare -p COM5 -m 7C:DF:A1:12:34:56 -t 1
python3 - "$started" <<'PY' || fail prepare-timeout-unbounded
import sys, time
elapsed = time.monotonic() - float(sys.argv[1])
if elapsed >= 2.8:
    print("elapsed=%.3f" % elapsed, file=sys.stderr)
    raise SystemExit(1)
PY
pass prepare-bounded

! grep -q 'watchdog-reset' "$SCRIPT" || fail watchdog-reset-present
pass all-post-flash-check
