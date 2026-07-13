#!/usr/bin/env bash
# Dynamic regression for the EIM shell boundary.  Real argv must survive
# exactly, while shell metacharacters remain inert data.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL=eim-command-boundary:$1" >&2
  exit 1
}

assert_json_args() {
  local output="$1"
  shift
  python3 - "$output" "$@" <<'PYEOF'
import json
import sys

actual = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2:]
if actual != expected:
    raise SystemExit("argv mismatch: actual=%r expected=%r" % (actual, expected))
PYEOF
}

cat >"$TMP/capture.py" <<'PYEOF'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(sys.argv[2:], stream, ensure_ascii=False)
PYEOF

. "$ROOT/scripts/lib.sh"
export TMPDIR="$TMP"

# The binary format preserves empty arguments, Unicode, line breaks and every
# character that would have meaning to Bash if interpolated into source code.
DIRECT_MARKER="$TMP/direct-marker"
DIRECT_OUTPUT="$TMP/direct.json"
DIRECT_ATTACK="\$(printf injected > '$DIRECT_MARKER')"
DIRECT_ARGS=(
  python3 "$TMP/capture.py" "$DIRECT_OUTPUT"
  "" "中文 参数" "$DIRECT_ATTACK" '`printf injected`' '$HOME'
  'quote"single' $'line-one\nline-two' '&|;<>*?![]{}'
)
ARGV_FILE="$(write_secure_argv_file "${DIRECT_ARGS[@]}")" || fail write-direct
MODE="$(stat -f '%Lp' "$ARGV_FILE" 2>/dev/null || stat -c '%a' "$ARGV_FILE")"
[ "$MODE" = 600 ] || fail "argv-mode:$MODE"
python3 "$ROOT/scripts/eim-argv-runner.py" "$ARGV_FILE" || fail direct-runner
[ ! -e "$ARGV_FILE" ] || fail direct-payload-not-deleted
[ ! -e "$DIRECT_MARKER" ] || fail direct-command-injection
assert_json_args "$DIRECT_OUTPUT" "${DIRECT_ARGS[@]:3}" || fail direct-roundtrip

# Exercise the complete macOS EIM wrapper with a mock that behaves like EIM's
# POSIX activation script and evaluates the one command string it receives.
mkdir -p "$TMP/eim-idf/tools"
: >"$TMP/eim-idf/tools/idf.py"
printf '{"idfSelectedId":"fixture","idfInstalled":[{"id":"fixture","name":"v6.0.2","path":"%s"}]}\n' \
  "$TMP/eim-idf" >"$TMP/eim_idf.json"
cat >"$TMP/mock-eim" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  echo 'eim fixture'
  exit 0
fi
while [ "$#" -gt 0 ] && [ "$1" != run ]; do shift; done
[ "${1:-}" = run ] && [ "$#" -ge 2 ] || exit 64
command_text="$2"
printf '%s\n' "$command_text" >"$ESP_IDF_CY_TEST_EIM_COMMAND_LOG"
PATH="$ESP_IDF_CY_TEST_EIM_BIN_DIR:$PATH" bash -c "$command_text"
EOF
chmod +x "$TMP/mock-eim"
mkdir -p "$TMP/eim-bin"
cat >"$TMP/eim-bin/python" <<'EOF'
#!/usr/bin/env bash
exec python3 "$@"
EOF
chmod +x "$TMP/eim-bin/python"

WRAPPER_MARKER="$TMP/wrapper-marker"
WRAPPER_OUTPUT="$TMP/wrapper.json"
WRAPPER_ATTACK="\$(printf injected > '$WRAPPER_MARKER')"
WRAPPER_ARGS=(
  python3 "$TMP/capture.py" "$WRAPPER_OUTPUT"
  "" "烧录 参数" "$WRAPPER_ATTACK" '`touch should-not-run`' '$USER'
  'double"quote' $'alpha\nbeta' 'semi; amp& pipe| redirect>'
)
env -u IDF_PATH \
ESP_IDF_CY_OS=mac \
ESP_IDF_CY_EIM_BIN="$TMP/mock-eim" \
ESP_IDF_CY_EIM_JSON="$TMP/eim_idf.json" \
ESP_IDF_CY_IDF_PATH="$TMP/eim-idf" \
ESP_IDF_CY_TEST_EIM_COMMAND_LOG="$TMP/eim-command.log" \
ESP_IDF_CY_TEST_EIM_BIN_DIR="$TMP/eim-bin" \
TMPDIR="$TMP" \
  bash "$ROOT/scripts/idf-env.sh" "${WRAPPER_ARGS[@]}" || fail wrapper-run

[ ! -e "$WRAPPER_MARKER" ] || fail wrapper-command-injection
assert_json_args "$WRAPPER_OUTPUT" "${WRAPPER_ARGS[@]:3}" || fail wrapper-roundtrip
[ "$(cat "$TMP/eim-command.log")" = 'python "$ESP_IDF_CY_RUNNER" "$ESP_IDF_CY_ARGV_FILE"' ] \
  || fail eim-command-not-fixed
if find "$TMP" -maxdepth 1 -name 'esp-idf-cy-argv.*' -print -quit | grep -q .; then
  fail argv-payload-leaked
fi

# Invalid custom registry identity must fail before creating an argv payload.
INVALID_REGISTRY="$TMP/not-eim-idf.json"
cp "$TMP/eim_idf.json" "$INVALID_REGISTRY"
mkdir -p "$TMP/invalid-registry-payloads"
set +e
OUT="$(env -u IDF_PATH \
  ESP_IDF_CY_OS=mac \
  ESP_IDF_CY_EIM_BIN="$TMP/mock-eim" \
  ESP_IDF_CY_EIM_JSON="$INVALID_REGISTRY" \
  ESP_IDF_CY_IDF_PATH="$TMP/eim-idf" \
  TMPDIR="$TMP/invalid-registry-payloads" \
  bash "$ROOT/scripts/idf-env.sh" idf.py --version 2>&1)"
RC=$?
set -e
[ "$RC" -eq 64 ] || fail "invalid-registry-rc:$RC:$OUT"
if find "$TMP/invalid-registry-payloads" -name 'esp-idf-cy-argv.*' -print -quit | grep -q .; then
  fail invalid-registry-leaked-payload
fi

echo 'PASS=eim-command-boundary'
