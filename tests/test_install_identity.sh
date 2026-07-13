#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REGISTRY_DIR="$TMP/eim-tools"
REGISTRY="$REGISTRY_DIR/eim_idf.json"
mkdir -p "$REGISTRY_DIR"

fail() { echo "FAIL=install-identity:$1" >&2; exit 1; }
pass() { echo "PASS=$1"; }

make_idf() {
  local dir="$1" version="$2" plain major minor patch
  plain="${version#v}"; major="${plain%%.*}"; plain="${plain#*.}"
  minor="${plain%%.*}"; patch="${plain#*.}"
  mkdir -p "$dir/tools/cmake"
  : >"$dir/tools/idf.py"
  printf '%s\n' \
    "set(IDF_VERSION_MAJOR $major)" \
    "set(IDF_VERSION_MINOR $minor)" \
    "set(IDF_VERSION_PATCH $patch)" >"$dir/tools/cmake/version.cmake"
}

resolve() {
  HOME="$TMP/home" IDF_PATH="${AMBIENT_IDF_PATH:-}" ESP_IDF_CY_OS=mac \
    ESP_IDF_CY_EIM_JSON="$REGISTRY" \
    bash -c '. "$1"; . "$2"; eim_exact_idf_path "$3" "${4:-}"' \
    _ "$ROOT/scripts/lib.sh" "$ROOT/scripts/eim-registry.sh" "$@"
}

IDF_A="$TMP/vendor/a"
IDF_OTHER="$TMP/vendor/ambient"
make_idf "$IDF_A" v6.0.2
make_idf "$IDF_OTHER" v5.5.4
printf '{"idfSelectedId":"old","idfInstalled":[{"id":"old","name":"v5.5.4","path":"%s"},{"id":"wanted","name":"v6.0.2","path":"%s"}]}\n' \
  "$IDF_OTHER" "$IDF_A" >"$REGISTRY"
AMBIENT_IDF_PATH="$IDF_OTHER" OUT="$(resolve v6.0.2)" || fail unique-rc
[ "$OUT" = "$IDF_A" ] || fail "unique-path:$OUT"
pass eim-exact-version-ignores-selected-and-ambient

OUT="$(resolve v6.0.2 "$IDF_A")" || fail required-path
[ "$OUT" = "$IDF_A" ] || fail required-path-output
set +e
OUT="$(resolve v6.0.2 "$IDF_OTHER" 2>&1)"; RC=$?
set -e
[ "$RC" -eq 12 ] || fail "path-mismatch-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -Eq 'EIM_INSTALL_STATE=(path_mismatch|conflict)' || fail path-mismatch-state
pass eim-repair-path-must-match-registry

IDF_B="$TMP/vendor/b"
make_idf "$IDF_B" v6.0.2
printf '{"idfInstalled":[{"id":"a","name":"v6.0.2","path":"%s"},{"id":"b","name":"v6.0.2","path":"%s"}]}\n' \
  "$IDF_A" "$IDF_B" >"$REGISTRY"
set +e
OUT="$(resolve v6.0.2 2>&1)"; RC=$?
set -e
[ "$RC" -eq 11 ] || fail "ambiguous-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q 'EIM_INSTALL_STATE=ambiguous' || fail ambiguous-state
pass eim-same-version-ambiguous-fail-closed

# 项目给出精确路径时允许在多个同版本登记中消歧，不能受 JSON 排序影响。
OUT="$(resolve v6.0.2 "$IDF_B")" || fail explicit-path-disambiguation
[ "$OUT" = "$IDF_B" ] || fail "explicit-path-output:$OUT"
pass eim-explicit-path-disambiguates-same-version

DAMAGED="$TMP/vendor/damaged"
mkdir -p "$DAMAGED/tools"
: >"$DAMAGED/tools/idf.py"
printf '{"idfInstalled":[{"id":"damaged","name":"v6.0.2","path":"%s"}]}\n' \
  "$DAMAGED" >"$REGISTRY"
OUT="$(resolve v6.0.2)" || fail damaged-registered-path
[ "$OUT" = "$DAMAGED" ] || fail damaged-path-output
pass eim-damaged-exact-registration-is-repairable

MISSING="$TMP/vendor/missing-idf"
printf '{"idfInstalled":[{"id":"missing","name":"v6.0.2","path":"%s"}]}\n' \
  "$MISSING" >"$REGISTRY"
set +e
OUT="$(resolve v6.0.2 "$MISSING" 2>&1)"; RC=$?
set -e
[ "$RC" -eq 12 ] || fail "missing-registered-path-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q 'EIM_INSTALL_STATE=registered_path_missing' || fail missing-path-state
pass eim-missing-registration-does-not-fall-through-to-install

RENAMED="$TMP/vendor/renamed-damaged"
mkdir -p "$RENAMED/tools"
: >"$RENAMED/tools/idf.py"
printf '{"idfInstalled":[{"id":"random-uuid","name":"My SDK","path":"%s"}]}\n' \
  "$RENAMED" >"$REGISTRY"
OUT="$(resolve v6.0.2 "$RENAMED")" || fail renamed-explicit-path
[ "$OUT" = "$RENAMED" ] || fail renamed-explicit-output
set +e
OUT="$(resolve v6.0.2 2>&1)"; RC=$?
set -e
[ "$RC" -eq 12 ] || fail "renamed-auto-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q 'EIM_INSTALL_STATE=unidentified_registration' || fail renamed-auto-state
pass eim-renamed-damaged-registration-needs-exact-path

# Windows 裸机在 EIM 自举前可能没有 Python；登记解析必须使用固定 PowerShell
# JSON 路径，而不是会留下双反斜杠的 grep 伪解析。
cat >"$TMP/registry-powershell" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ESP_IDF_CY_TEST_PS_LOG"
printf 'C:\\sdk\\idf-main\tv6.0.2\n'
SH
chmod +x "$TMP/registry-powershell"
OUT="$(ESP_IDF_CY_OS=windows ESP_IDF_CY_POWERSHELL_BIN="$TMP/registry-powershell" \
  ESP_IDF_CY_TEST_PS_LOG="$TMP/registry-ps.log" \
  bash -c '. "$1"; find_python(){ return 1; }; parse_eim_json "$2"' \
  _ "$ROOT/scripts/lib.sh" "$REGISTRY")" || fail windows-registry-powershell
[ "$OUT" = $'C:\\sdk\\idf-main\tv6.0.2' ] || fail "windows-registry-output:$OUT"
grep -q 'ConvertFrom-Json' "$TMP/registry-ps.log" || fail windows-registry-structured-json
pass windows-registry-parses-without-python

PIPE_IDF="$TMP/vendor/idf|pipe"
make_idf "$PIPE_IDF" v6.0.2
printf '{"idfInstalled":[{"id":"pipe","name":"v6.0.2","path":"%s"}]}\n' \
  "$PIPE_IDF" >"$REGISTRY"
OUT="$(resolve v6.0.2)" || fail pipe-path-rc
[ "$OUT" = "$PIPE_IDF" ] || fail "pipe-path-output:$OUT"
pass eim-registry-keeps-pipe-as-data

printf '{not-json\n' >"$REGISTRY"
set +e
OUT="$(resolve v6.0.2 2>&1)"; RC=$?
set -e
[ "$RC" -eq 13 ] || fail "malformed-registry-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q 'EIM_INSTALL_STATE=registry_unreadable' || fail malformed-registry-state
pass malformed-eim-registry-fails-closed

for BROKEN_JSON in '{}' '{"idfInstalled":[{"id":"x","name":"v6.0.2"}]}' \
  '{"idfInstalled":[{"id":"x","name":"","path":"/tmp/idf"}]}' \
  '{"idfInstalled":[{"id":"x","name":"v6.0.2","path":"/tmp/idf\tbad"}]}'; do
  printf '%s\n' "$BROKEN_JSON" >"$REGISTRY"
  set +e
  OUT="$(resolve v6.0.2 2>&1)"; RC=$?
  set -e
  [ "$RC" -eq 13 ] || fail "invalid-record-rc:$RC:$OUT"
done
pass structurally-invalid-eim-registry-fails-closed

# macOS 的显式 repair 必须调用 fix -p 原登记路径,不能退化成 install/升级。
REPAIR_EIM="$TMP/repair-eim"
cat >"$REPAIR_EIM" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'eim 0.test'; exit 0; fi
for arg in "$@"; do printf 'ARG=<%s>\n' "$arg" >>"$ESP_IDF_CY_TEST_EIM_LOG"; done
case " $* " in
  *" fix "*)
    mkdir -p "$ESP_IDF_CY_TEST_EIM_IDF/tools/cmake"
    : >"$ESP_IDF_CY_TEST_EIM_IDF/tools/idf.py"
    printf '%s\n' 'set(IDF_VERSION_MAJOR 6)' 'set(IDF_VERSION_MINOR 0)' \
      'set(IDF_VERSION_PATCH 2)' >"$ESP_IDF_CY_TEST_EIM_IDF/tools/cmake/version.cmake"
    ;;
esac
SH
chmod +x "$REPAIR_EIM"
printf '{"idfInstalled":[{"id":"damaged","name":"v6.0.2","path":"%s"}]}\n' \
  "$DAMAGED" >"$REGISTRY"
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_EIM_BIN="$REPAIR_EIM" \
  ESP_IDF_CY_EIM_JSON="$REGISTRY" ESP_IDF_CY_TEST_EIM_LOG="$TMP/eim.log" \
  ESP_IDF_CY_TEST_EIM_IDF="$DAMAGED" PATH=/usr/bin:/bin \
  bash "$ROOT/scripts/install-eim-macos.sh" --version v6.0.2 --targets esp32c6 \
    --net global --repair-path "$DAMAGED")" || fail "mac-repair-rc:$OUT"
grep -Fqx 'ARG=<fix>' "$TMP/eim.log" || fail mac-repair-fix
grep -Fqx "ARG=<$DAMAGED>" "$TMP/eim.log" || fail mac-repair-path
grep -Fqx 'ARG=<install>' "$TMP/eim.log" && fail mac-repair-must-not-install
printf '%s\n' "$OUT" | grep -Fqx 'EIM_ACTION=repair' || fail mac-repair-action
printf '%s\n' "$OUT" | grep -Fqx "EIM_IDF_PATH=$DAMAGED" || fail mac-repair-output-path
pass mac-eim-explicit-repair-no-upgrade

# 未显式要求 target 覆盖时，fix 必须保留 EIM 原登记配置而不是默认改成 all。
rm -f "$DAMAGED/tools/cmake/version.cmake"; : >"$TMP/eim.log"
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_EIM_BIN="$REPAIR_EIM" \
  ESP_IDF_CY_EIM_JSON="$REGISTRY" ESP_IDF_CY_TEST_EIM_LOG="$TMP/eim.log" \
  ESP_IDF_CY_TEST_EIM_IDF="$DAMAGED" PATH=/usr/bin:/bin \
  bash "$ROOT/scripts/install-eim-macos.sh" --version v6.0.2 \
    --net global --repair-path "$DAMAGED")" || fail "mac-repair-preserve-rc:$OUT"
grep -Fqx 'ARG=<-t>' "$TMP/eim.log" && fail mac-repair-overrode-targets
pass mac-eim-repair-preserves-recorded-targets

printf '{"idfInstalled":[]}\n' >"$REGISTRY"
set +e
OUT="$(resolve v6.0.2 2>&1)"; RC=$?
set -e
[ "$RC" -eq 10 ] || fail "absent-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q 'EIM_INSTALL_STATE=absent' || fail absent-state
pass eim-absent-is-not-default-path

set +e
OUT="$(ESP_IDF_CY_OS=linux ESP_IDF_CY_NET=global HOME="$TMP/future-home" \
  bash "$ROOT/scripts/install.sh" --version v7.0.0 --path "$TMP/future" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 6 ] || fail "future-major-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '拒绝把未知新 major 静默当成 Python 3.8' || fail future-major-message
pass unknown-future-idf-python-fails-closed

cat >"$TMP/arm64-powershell" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ESP_IDF_CY_TEST_PS_LOG"
case " $* " in *' CheckPlatform '*) exit 8 ;; esac
exit 90
SH
printf '#!/usr/bin/env bash\nprintf "v6.0.2\\n"\n' >"$TMP/windows-git"
chmod +x "$TMP/arm64-powershell" "$TMP/windows-git"
set +e
OUT="$(ESP_IDF_CY_OS=windows ESP_IDF_CY_NET=global \
  ESP_IDF_CY_GIT_BIN="$TMP/windows-git" ESP_IDF_CY_POWERSHELL_BIN="$TMP/arm64-powershell" \
  ESP_IDF_CY_TEST_PS_LOG="$TMP/arm64-ps.log" \
  bash "$ROOT/scripts/install.sh" --version stable --route-only 2>&1)"
RC=$?
set -e
[ "$RC" -eq 8 ] || fail "windows-arm64-route-rc:$RC:$OUT"
grep -q 'CheckPlatform' "$TMP/arm64-ps.log" || fail windows-arm64-platform-check
grep -q 'winget install' "$TMP/arm64-ps.log" && fail windows-arm64-mutated-before-check
pass windows-architecture-fails-before-install-mutation

FUTURE_IDF="$TMP/future-idf"
make_idf "$FUTURE_IDF" v7.0.0
mkdir -p "$FUTURE_IDF/bin"
cat >"$FUTURE_IDF/export.sh" <<'SH'
export PATH="$IDF_PATH/bin:$PATH"
SH
cat >"$FUTURE_IDF/bin/idf.py" <<'SH'
#!/usr/bin/env bash
echo 'ESP-IDF v7.0.0'
SH
chmod +x "$FUTURE_IDF/bin/idf.py"
OUT="$(HOME="$TMP/future-doctor-home" ESP_IDF_CY_OS=linux \
  ESP_IDF_CY_EIM_JSON="$TMP/no-eim.json" ESP_IDF_CY_IDF_PATH="$FUTURE_IDF" \
  bash "$ROOT/scripts/doctor.sh" --no-net)" || fail future-doctor-rc
printf '%s\n' "$OUT" | grep -Fqx 'PYTHON_MIN_REQUIRED=unknown' || fail future-doctor-python
printf '%s\n' "$OUT" | grep -Fqx 'READY=yes' || fail future-doctor-ready
printf '%s\n' "$OUT" | grep -Fq 'PYTHON_MIN_REQUIRED=3.8' && fail future-doctor-default
pass unknown-future-idf-doctor-does-not-guess

set +e
OUT="$(ESP_IDF_CY_OS=linux ESP_IDF_CY_NET=global \
  bash "$ROOT/scripts/install.sh" --repair --version stable --path "$TMP/future" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 64 ] || fail "repair-version-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '不允许 stable/minor 暗中升级' || fail repair-version-message
pass repair-requires-exact-version-and-path

echo PASS=all-install-identity
