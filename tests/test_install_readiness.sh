#!/usr/bin/env bash
# verify-install.sh 的 hermetic 回归：不联网、不调用真实 IDF。
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "PASS=$1"; }
fail() { echo "FAIL=$1" >&2; exit 1; }

make_fake_idf() {
  local dir="$1" version="$2" export_mode="$3" command_version="${4:-$2}"
  local plain="${version#v}" major minor patch
  major="${plain%%.*}"
  plain="${plain#*.}"
  minor="${plain%%.*}"
  patch="${plain#*.}"

  mkdir -p "$dir/tools/cmake"
  printf '%s\n' \
    "set(IDF_VERSION_MAJOR $major)" \
    "set(IDF_VERSION_MINOR $minor)" \
    "set(IDF_VERSION_PATCH $patch)" >"$dir/tools/cmake/version.cmake"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "echo 'ESP-IDF $command_version'" >"$dir/tools/idf.py"
  chmod +x "$dir/tools/idf.py"

  if [ "$export_mode" = healthy ]; then
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'export PATH="$IDF_PATH/tools:$PATH"' >"$dir/export.sh"
  else
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'echo "fixture export failure" >&2' \
      'return 17' >"$dir/export.sh"
  fi
}

run_verify() {
  local home="$1"
  shift
  HOME="$home" IDF_PATH="" IDF_TOOLS_PATH="$home/.espressif" \
    ESP_IDF_CY_EIM_JSON="$home/no-eim.json" ESP_IDF_CY_OS=linux \
    bash "$ROOT/scripts/verify-install.sh" "$@" 2>&1
}

# 1) 真命令、版本、路径全部匹配才成功。
HOME_OK="$TMP/home-ok"
IDF_OK="$TMP/idf-ok"
mkdir -p "$HOME_OK"
make_fake_idf "$IDF_OK" v5.5.4 healthy
set +e
OUT="$(run_verify "$HOME_OK" --version v5.5.4 --path "$IDF_OK")"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "success-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '^READY=yes$' || fail success-ready
printf '%s\n' "$OUT" | grep -q '^VERIFY_INSTALL=yes$' || fail success-verdict
pass install-readiness-success

# 2) IDF 目录存在，但 export/真命令失败时必须稳定非零。
HOME_BAD="$TMP/home-bad"
IDF_BAD="$TMP/idf-bad"
mkdir -p "$HOME_BAD"
make_fake_idf "$IDF_BAD" v5.5.4 broken
set +e
OUT="$(run_verify "$HOME_BAD" --version v5.5.4 --path "$IDF_BAD")"
RC=$?
set -e
[ "$RC" -eq 9 ] || fail "ready-no-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '^READY=no$' || fail ready-no-doctor
printf '%s\n' "$OUT" | grep -q '^VERIFY_REASON=ready$' || fail ready-no-reason
pass install-readiness-ready-no

# 3) 环境健康但不是请求版本，也不能报安装成功。
HOME_VERSION="$TMP/home-version"
IDF_VERSION="$TMP/idf-version"
mkdir -p "$HOME_VERSION"
make_fake_idf "$IDF_VERSION" v5.4.3 healthy
set +e
OUT="$(run_verify "$HOME_VERSION" --version v5.5.4 --path "$IDF_VERSION")"
RC=$?
set -e
[ "$RC" -eq 9 ] || fail "wrong-version-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '^READY=yes$' || fail wrong-version-ready
printf '%s\n' "$OUT" | grep -q '^VERIFY_REASON=version$' || fail wrong-version-reason
pass install-readiness-wrong-version

# 4) 仓库元数据伪装成正确版本，但真命令报告另一版本，仍必须拒绝。
HOME_COMMAND_VERSION="$TMP/home-command-version"
IDF_COMMAND_VERSION="$TMP/idf-command-version"
mkdir -p "$HOME_COMMAND_VERSION"
make_fake_idf "$IDF_COMMAND_VERSION" v5.5.4 healthy v0.0.0
set +e
OUT="$(run_verify "$HOME_COMMAND_VERSION" --version v5.5.4 --path "$IDF_COMMAND_VERSION")"
RC=$?
set -e
[ "$RC" -eq 9 ] || fail "wrong-command-version-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '^IDF_VER=v5.5.4$' || fail wrong-command-metadata
printf '%s\n' "$OUT" | grep -q '^IDF_COMMAND_TAG=v0.0.0$' || fail wrong-command-tag
printf '%s\n' "$OUT" | grep -q '^VERIFY_REASON=command_version$' || fail wrong-command-reason
pass install-readiness-wrong-command-version

# 5) ESP-IDF 的 .0 正式版会把 v5.5.0 简写为 v5.5；只允许这一种等价规范化。
HOME_DOT_ZERO="$TMP/home-dot-zero"
IDF_DOT_ZERO="$TMP/idf-dot-zero"
mkdir -p "$HOME_DOT_ZERO"
make_fake_idf "$IDF_DOT_ZERO" v5.5.0 healthy v5.5
set +e
OUT="$(run_verify "$HOME_DOT_ZERO" --version v5.5.0 --path "$IDF_DOT_ZERO")"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "dot-zero-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '^VERIFY_INSTALL=yes$' || fail dot-zero-verdict
pass install-readiness-dot-zero

# v5.5 绝不能被当成 v5.5.1。
HOME_DOT_ONE="$TMP/home-dot-one"
IDF_DOT_ONE="$TMP/idf-dot-one"
mkdir -p "$HOME_DOT_ONE"
make_fake_idf "$IDF_DOT_ONE" v5.5.1 healthy v5.5
set +e
OUT="$(run_verify "$HOME_DOT_ONE" --version v5.5.1 --path "$IDF_DOT_ONE")"
RC=$?
set -e
[ "$RC" -eq 9 ] || fail "dot-one-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '^VERIFY_REASON=command_version$' || fail dot-one-reason
pass install-readiness-dot-one-reject

# 6) 显式期望路径不是实际 IDF 时必须失败；HOME 下即使另有健康 IDF，
# 也不能把它当成本次期望路径的安装结果。
HOME_PATH="$TMP/home-path"
FALLBACK_IDF="$HOME_PATH/esp/esp-idf"
WRONG_PATH="$TMP/not-the-installed-idf"
mkdir -p "$HOME_PATH"
make_fake_idf "$FALLBACK_IDF" v5.5.4 healthy
set +e
OUT="$(run_verify "$HOME_PATH" --version v5.5.4 --path "$WRONG_PATH")"
RC=$?
set -e
[ "$RC" -eq 9 ] || fail "wrong-path-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '^READY=no$' || fail wrong-path-ready
printf '%s\n' "$OUT" | grep -q '^VERIFY_INSTALL=no$' || fail wrong-path-verdict
pass install-readiness-wrong-path

pass all-install-readiness
