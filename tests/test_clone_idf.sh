#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL=clone-idf:$1" >&2; exit 1; }

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >>"$ESP_IDF_CY_TEST_GIT_LOG"' \
  'if [ "$1" = clone ]; then' \
  '  dest="${@: -1}"' \
  '  if printf "%s" "$*" | grep -q primary; then mkdir -p "$dest"; : >"$dest/partial"; exit 9; fi' \
  '  mkdir -p "$dest/tools"; : >"$dest/tools/idf.py"; exit 0' \
  'fi' \
  'exit 0' >"$TMP/git"
chmod +x "$TMP/git"

DEST="$TMP/esp-idf"
OUT="$(ESP_IDF_CY_GIT_BIN="$TMP/git" ESP_IDF_CY_TEST_GIT_LOG="$TMP/git.log" \
  bash "$ROOT/scripts/clone-idf.sh" --destination "$DEST" --version v5.5.4 \
  --primary https://primary.invalid/esp-idf.git --fallback https://fallback.invalid/esp-idf.git \
  --rewrite-from https://github.com/ --rewrite-to https://mirror.invalid/)" || fail fallback
[ -f "$DEST/tools/idf.py" ] || fail final-tree
[ ! -e "$DEST.esp-idf-cy-partial" ] || fail stage-cleanup
printf '%s\n' "$OUT" | grep -q '^CLONE_READY=yes$' || fail ready
grep -q 'primary.invalid' "$TMP/git.log" || fail primary-called
grep -q 'fallback.invalid' "$TMP/git.log" || fail fallback-called
grep -q 'url.https://mirror.invalid/.insteadOf https://github.com/' "$TMP/git.log" || fail rewrite

# 只清理 marker 与本次目标/版本完全匹配的受管残留。
DEST2="$TMP/retry-idf"
STAGE2="$DEST2.esp-idf-cy-partial"
mkdir -p "$STAGE2/repo"
printf 'managed_by=esp-idf-cy\ndestination=%s\nversion=v5.5.4\n' "$DEST2" >"$STAGE2/.managed-by-esp-idf-cy"
ESP_IDF_CY_GIT_BIN="$TMP/git" ESP_IDF_CY_TEST_GIT_LOG="$TMP/git.log" \
  bash "$ROOT/scripts/clone-idf.sh" --destination "$DEST2" --version v5.5.4 \
  --primary https://fallback.invalid/esp-idf.git >/dev/null || fail managed-retry
[ -f "$DEST2/tools/idf.py" ] || fail managed-retry-tree

# 同名未知目录绝不删除。
DEST3="$TMP/foreign-idf"
mkdir -p "$DEST3.esp-idf-cy-partial"
: >"$DEST3.esp-idf-cy-partial/user-file"
set +e
OUT="$(ESP_IDF_CY_GIT_BIN="$TMP/git" ESP_IDF_CY_TEST_GIT_LOG="$TMP/git.log" \
  bash "$ROOT/scripts/clone-idf.sh" --destination "$DEST3" --version v5.5.4 \
  --primary https://fallback.invalid/esp-idf.git 2>&1)"
RC=$?
set -e
[ "$RC" -eq 8 ] || fail "foreign-rc:$RC"
[ -f "$DEST3.esp-idf-cy-partial/user-file" ] || fail foreign-deleted

echo 'PASS=clone-idf'
