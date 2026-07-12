#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL=project-discovery:$1" >&2; exit 1; }
pass() { echo "PASS=$1"; }

IDF="$TMP/vendor-sdk/custom-idf"
PROJECT="$TMP/project"
mkdir -p "$IDF/tools/cmake" "$IDF/bin" "$PROJECT/build"
printf '%s\n' \
  'set(IDF_VERSION_MAJOR 6)' \
  'set(IDF_VERSION_MINOR 0)' \
  'set(IDF_VERSION_PATCH 1)' >"$IDF/tools/cmake/version.cmake"
: >"$IDF/tools/idf.py"
printf '%s\n' '#!/usr/bin/env bash' 'export PATH="$IDF_PATH/bin:$PATH"' >"$IDF/export.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "ESP-IDF v6.0.1"' >"$IDF/bin/idf.py"
chmod +x "$IDF/bin/idf.py"
printf 'cmake_minimum_required(VERSION 3.16)\ninclude($ENV{IDF_PATH}/tools/cmake/project.cmake)\nproject(fixture)\n' \
  >"$PROJECT/CMakeLists.txt"
printf '{"idf_path":"%s"}\n' "$IDF" >"$PROJECT/build/project_description.json"

OTHER_IDF="$TMP/other-idf"
mkdir -p "$OTHER_IDF/tools"
: >"$OTHER_IDF/tools/idf.py"
printf '{"idfSelectedId":"other","idfInstalled":[{"id":"other","name":"v5.5.4","path":"%s"}]}\n' \
  "$OTHER_IDF" >"$TMP/eim.json"

OUT="$(HOME="$TMP/home" IDF_PATH="$OTHER_IDF" ESP_IDF_CY_EIM_JSON="$TMP/eim.json" \
  ESP_IDF_CY_OS=mac bash "$ROOT/scripts/doctor.sh" --no-net --project "$PROJECT")" \
  || fail doctor
printf '%s\n' "$OUT" | grep -Fqx "IDF_PATH=$IDF" || fail recorded-idf-path
printf '%s\n' "$OUT" | grep -Fqx 'PROJECT_READY=yes' || fail project-ready
printf '%s\n' "$OUT" | grep -Fqx 'READY=yes' || fail ready
pass project-recorded-idf-over-ambient

SPACE_PROJECT="$TMP/project with spaces"
mkdir -p "$SPACE_PROJECT"
printf 'project(fixture)\n' >"$SPACE_PROJECT/CMakeLists.txt"
set +e
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_IDF_PATH="$IDF" \
  bash "$ROOT/scripts/idf-env.sh" idf.py -C "$SPACE_PROJECT" build 2>&1)"
RC=$?
set -e
[ "$RC" -eq 8 ] || fail "space-project-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '不支持项目路径包含空白' || fail space-project-message
pass project-space-block

mkdir -p "$SPACE_PROJECT/nested"
set +e
OUT="$(cd "$SPACE_PROJECT" && ESP_IDF_CY_OS=mac ESP_IDF_CY_IDF_PATH="$IDF" \
  bash "$ROOT/scripts/idf-env.sh" idf.py -C . build 2>&1)"
RC=$?
set -e
[ "$RC" -eq 8 ] || fail "space-project-dot-rc:$RC:$OUT"
pass project-space-dot-block

SPACE_IDF="$TMP/idf with spaces"
mkdir -p "$SPACE_IDF/tools"
: >"$SPACE_IDF/tools/idf.py"
set +e
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_IDF_PATH="$SPACE_IDF" \
  bash "$ROOT/scripts/idf-env.sh" idf.py --version 2>&1)"
RC=$?
set -e
[ "$RC" -eq 8 ] || fail "space-idf-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '不支持 IDF 安装路径包含空白' || fail space-idf-message
pass idf-space-block

OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_IDF_PATH="$IDF" \
  bash "$ROOT/scripts/doctor.sh" --no-net --project "$SPACE_PROJECT" 2>&1)" || fail doctor-space
printf '%s\n' "$OUT" | grep -Fqx 'PROJECT_READY=no' || fail doctor-project-no
printf '%s\n' "$OUT" | grep -Fqx 'READY=no' || fail doctor-ready-no
pass doctor-project-gate

echo PASS=all-project-discovery
