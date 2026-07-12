#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL=macos-eim:$1" >&2; exit 1; }
pass() { echo "PASS=$1"; }

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "BREW=<%s>\n" "$*" >>"$ESP_IDF_CY_TEST_BREW_LOG"' \
  'if [ "$1" = --prefix ]; then printf "%s\n" "$ESP_IDF_CY_TEST_BREW_PREFIX"; fi' \
  'exit 0' >"$TMP/brew"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${1:-}" = --version ]; then echo "eim 0.test"; exit 0; fi' \
  'for arg in "$@"; do printf "ARG=<%s>\n" "$arg"; done' >"$TMP/eim"
chmod +x "$TMP/brew" "$TMP/eim"

OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_BREW_BIN="$TMP/brew" \
  ESP_IDF_CY_EIM_BIN="$TMP/eim" ESP_IDF_CY_TEST_BREW_LOG="$TMP/brew.log" \
  ESP_IDF_CY_TEST_BREW_PREFIX="$TMP/prefix" \
  bash "$ROOT/scripts/install-eim-macos.sh" --version v6.0.1 --targets esp32s3 --net cn)" \
  || fail install
grep -Fq 'install libgcrypt glib pixman sdl2 libslirp dfu-util cmake python' "$TMP/brew.log" \
  || fail prerequisites
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<--do-not-track>' || fail privacy
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<install>' || fail install-command
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<-i>' || fail version-flag
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<v6.0.1>' || fail version
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<-t>' || fail target-flag
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<esp32s3>' || fail target
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<--idf-mirror>' || fail cn-idf-mirror
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<-a>' && fail windows-prerequisite-flag
printf '%s\n' "$OUT" | grep -Fqx 'INSTALL_ROUTE=mac-eim' || fail route-output
pass macos-eim-command

OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_EIM_BIN="$TMP/eim" PATH=/usr/bin:/bin \
  bash "$ROOT/scripts/install-eim-macos.sh" --version v6.0.1 --targets esp32 --net global)" \
  || fail existing-eim-no-brew
printf '%s\n' "$OUT" | grep -Fqx 'INFO=没有 Homebrew;复用现有 EIM 并由 EIM 校验 POSIX 前置' \
  || fail existing-eim-no-brew-info
printf '%s\n' "$OUT" | grep -Fqx 'INSTALL_ROUTE=mac-eim' || fail existing-eim-no-brew-route
pass macos-existing-eim-without-brew

printf '#!/usr/bin/env bash\nprintf "v6.0.1\n"\n' >"$TMP/git"
chmod +x "$TMP/git"
COMMON="ESP_IDF_CY_OS=mac ESP_IDF_CY_TEST_CLT_READY=yes ESP_IDF_CY_NET=global ESP_IDF_CY_GIT_BIN=$TMP/git"
OUT="$(env $COMMON ESP_IDF_CY_BREW_BIN="$TMP/brew" \
  bash "$ROOT/scripts/install.sh" --version stable --route-only)" || fail route-auto-brew
printf '%s\n' "$OUT" | grep -Fqx 'INSTALL_ROUTE=mac-eim' || fail route-auto-eim

OUT="$(env $COMMON ESP_IDF_CY_TEST_NO_BREW=yes \
  bash "$ROOT/scripts/install.sh" --version stable --route-only)" || fail route-auto-no-brew
printf '%s\n' "$OUT" | grep -Fqx 'INSTALL_ROUTE=mac-official-script' || fail route-auto-script

OUT="$(env $COMMON ESP_IDF_CY_TEST_NO_BREW=yes ESP_IDF_CY_EIM_BIN="$TMP/eim" \
  bash "$ROOT/scripts/install.sh" --version stable --route-only)" || fail route-auto-existing-eim
printf '%s\n' "$OUT" | grep -Fqx 'INSTALL_ROUTE=mac-eim' || fail route-auto-existing-eim-route

OUT="$(env $COMMON ESP_IDF_CY_BREW_BIN="$TMP/brew" \
  bash "$ROOT/scripts/install.sh" --version stable --path "$TMP/custom-idf" --route-only)" \
  || fail route-explicit-path
printf '%s\n' "$OUT" | grep -Fqx 'INSTALL_ROUTE=mac-official-script' || fail route-path-script

set +e
OUT="$(env $COMMON ESP_IDF_CY_BREW_BIN="$TMP/brew" \
  bash "$ROOT/scripts/install.sh" --version stable --path "$TMP/idf with spaces" --route-only 2>&1)"
RC=$?
set -e
[ "$RC" -eq 8 ] || fail "route-space-path-rc:$RC:$OUT"

set +e
OUT="$(env $COMMON ESP_IDF_CY_TEST_NO_BREW=yes ESP_IDF_CY_INSTALL_MODE=eim \
  bash "$ROOT/scripts/install.sh" --version stable --route-only 2>&1)"
RC=$?
set -e
[ "$RC" -eq 20 ] || fail "route-eim-no-brew-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q 'ACTION_REQUIRED=choose_homebrew_or_official_script_route' \
  || fail route-eim-no-brew-action
pass macos-install-routing

echo PASS=all-macos-eim
