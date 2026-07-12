#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "PASS=$1"; }
fail() { echo "FAIL=$1" >&2; exit 1; }

for script in "$ROOT"/scripts/*.sh; do
  bash -n "$script" || fail "bash-n:$script"
done
pass bash-syntax

# 发布协议的三个真相源必须一致,避免镜像仓库再次显示旧协议。
grep -Fqx 'license: GPL-3.0-only' "$ROOT/SKILL.md" || fail license-frontmatter
grep -Fq 'GNU GENERAL PUBLIC LICENSE' "$ROOT/LICENSE" || fail license-file-name
grep -Fq 'Version 3, 29 June 2007' "$ROOT/LICENSE" || fail license-file-version
grep -Fq 'GNU General Public License v3.0 only' "$ROOT/README.md" || fail license-readme
pass license-consistency

bash "$ROOT/tests/test_eim_windows_static.sh" || fail eim-windows-static
bash "$ROOT/tests/test_agent_first_contract.sh" || fail agent-first-contract
bash "$ROOT/tests/test_macos_eim_install.sh" || fail macos-eim-install
bash "$ROOT/tests/test_project_discovery.sh" || fail project-discovery
bash "$ROOT/tests/test_network_probe.sh" || fail network-probe
bash "$ROOT/tests/test_install_readiness.sh" || fail install-readiness
bash "$ROOT/tests/test_runtime_boundaries.sh" || fail runtime-boundaries
bash "$ROOT/tests/test_clone_idf.sh" || fail clone-idf
bash "$ROOT/tests/test_process_timeout.sh" || fail process-timeout
bash "$ROOT/tests/test_post_flash_check.sh" || fail post-flash-check

# 所有入口的缺值/显式覆盖都必须 fail closed，并返回稳定的 usage 退出码。
for cmd in \
  "bash $ROOT/scripts/install.sh --version" \
  "bash $ROOT/scripts/install.sh --targets" \
  "bash $ROOT/scripts/install.sh --path" \
  "bash $ROOT/scripts/bootstrap-macos.sh --min-python"; do
  set +e
  OUT="$(sh -c "$cmd" 2>&1)"
  RC=$?
  set -e
  [ "$RC" -eq 64 ] || fail "missing-value:$cmd:$RC:$OUT"
done
set +e
OUT="$(ESP_IDF_CY_IDF_PATH="$TMP/not-an-idf" ESP_IDF_CY_EIM_JSON="$TMP/no-eim.json" \
  bash "$ROOT/scripts/doctor.sh" --no-net 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail explicit-idf-doctor-rc
printf '%s\n' "$OUT" | grep -q '^IDF_FOUND=no$' || fail explicit-idf-fallback
printf '%s\n' "$OUT" | grep -q '^DISCOVERY_ERROR=ESP_IDF_CY_IDF_PATH ' || fail explicit-idf-error
set +e
OUT="$(ESP_IDF_CY_EIM_BIN="$TMP/not-eim" bash -c '. "$1"; find_eim' _ "$ROOT/scripts/lib.sh" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 64 ] || fail "explicit-eim-rc:$RC:$OUT"
pass fail-closed-entrypoints

# Windows 空白机即使 ESP-IDF 前置 Git 尚未装好，也要能先解析 stable，交给 EIM 自举。
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  *api.github.com/repos/espressif/esp-idf/tags*) printf "v5.5.4\nv6.0.2\nv5.4.3\n"; exit 0 ;;' \
  'esac' \
  'exit 9' >"$TMP/mock-version-powershell"
chmod +x "$TMP/mock-version-powershell"
OUT="$(ESP_IDF_CY_OS=windows ESP_IDF_CY_GIT_BIN="$TMP/no-git" \
  ESP_IDF_CY_NET=global \
  ESP_IDF_CY_POWERSHELL_BIN="$TMP/mock-version-powershell" \
  bash "$ROOT/scripts/install.sh" --version stable --resolve-only)" || fail windows-no-git-resolve
printf '%s\n' "$OUT" | grep -q '^VERSION_RESOLVED=v6.0.2$' || fail windows-no-git-version
pass windows-no-git-bootstrap

# macOS 空白机:缺 CLT 时应主动触发系统安装器并返回可恢复状态,且发生在联网/版本解析前。
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$ESP_IDF_CY_TEST_XCODE_LOG"\nexit 0\n' >"$TMP/mock-xcode-select"
chmod +x "$TMP/mock-xcode-select"
set +e
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_TEST_CLT_READY=no \
  ESP_IDF_CY_XCODE_SELECT_BIN="$TMP/mock-xcode-select" ESP_IDF_CY_TEST_XCODE_LOG="$TMP/xcode.log" \
  bash "$ROOT/scripts/install.sh" --version stable --targets esp32s3 --resolve-only 2>&1)"
RC=$?
set -e
[ "$RC" -eq 20 ] || fail "mac-clt-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '^ACTION_REQUIRED=complete_xcode_command_line_tools$' || fail mac-clt-action
grep -q '^--install$' "$TMP/xcode.log" || fail mac-clt-trigger
pass mac-clt-bootstrap

# 已有兼容 Python 时直接复用,不碰 Homebrew/安装包。
printf '#!/usr/bin/env bash\nif [ "$1" = --version ]; then echo "Python 3.13.14"; else echo 3.13; fi\n' >"$TMP/python-compatible"
chmod +x "$TMP/python-compatible"
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_TEST_CLT_READY=yes ESP_IDF_CY_TEST_SKIP_SYSTEM_PYTHON=yes \
  ESP_IDF_CY_PYTHON_BIN="$TMP/python-compatible" \
  bash "$ROOT/scripts/bootstrap-macos.sh" --min-python 3.10)" || fail mac-python-reuse
printf '%s\n' "$OUT" | grep -Fqx "PYTHON_BIN=$TMP/python-compatible" || fail mac-python-reuse-bin
printf '%s\n' "$OUT" | grep -q '^READY=yes$' || fail mac-python-reuse-ready
pass mac-python-reuse

# 有 Homebrew 但无兼容 Python:自动 brew install,然后发现并返回新解释器。
mkdir -p "$TMP/brew-prefix/bin"
cp "$TMP/python-compatible" "$TMP/brew-prefix/bin/python3"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "$1" = install ]; then echo "$*" >>"$ESP_IDF_CY_TEST_BREW_LOG"; exit 0; fi' \
  'if [ "$1" = --prefix ]; then echo "$ESP_IDF_CY_TEST_BREW_PREFIX"; exit 0; fi' \
  'exit 9' >"$TMP/mock-brew"
chmod +x "$TMP/mock-brew"
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_TEST_CLT_READY=yes ESP_IDF_CY_TEST_SKIP_SYSTEM_PYTHON=yes \
  ESP_IDF_CY_BREW_BIN="$TMP/mock-brew" ESP_IDF_CY_TEST_BREW_LOG="$TMP/brew.log" \
  ESP_IDF_CY_TEST_BREW_PREFIX="$TMP/brew-prefix" \
  bash "$ROOT/scripts/bootstrap-macos.sh" --min-python 3.10)" || fail mac-python-brew
grep -q '^install python$' "$TMP/brew.log" || fail mac-python-brew-install
printf '%s\n' "$OUT" | grep -q '^PYTHON_SOURCE=homebrew$' || fail mac-python-brew-source
printf '%s\n' "$OUT" | grep -Fqx "PYTHON_BIN=$TMP/brew-prefix/bin/python3" || fail mac-python-brew-bin
pass mac-python-brew

# 无 Homebrew:只接受校验和与 Python Software Foundation 签名都通过的官方 pkg,再打开系统安装器。
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'while [ $# -gt 0 ]; do if [ "$1" = -o ]; then shift; out="$1"; fi; shift; done' \
  'printf fixture >"$out"' >"$TMP/mock-curl"
printf '#!/usr/bin/env bash\necho "8e58affb218c155a1dfdc27b291f817129669f8760e7a297adb2e4439ba5d2e8  $3"\n' >"$TMP/mock-shasum"
printf '#!/usr/bin/env bash\necho "Developer ID Installer: Python Software Foundation (BMM5U3QVKW)"\n' >"$TMP/mock-pkgutil"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >"$ESP_IDF_CY_TEST_OPEN_LOG"\n' >"$TMP/mock-open"
chmod +x "$TMP/mock-curl" "$TMP/mock-shasum" "$TMP/mock-pkgutil" "$TMP/mock-open"
set +e
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_TEST_CLT_READY=yes ESP_IDF_CY_TEST_SKIP_SYSTEM_PYTHON=yes \
  ESP_IDF_CY_TEST_NO_BREW=yes ESP_IDF_CY_DOWNLOAD_DIR="$TMP/downloads" \
  ESP_IDF_CY_CURL_BIN="$TMP/mock-curl" ESP_IDF_CY_SHASUM_BIN="$TMP/mock-shasum" \
  ESP_IDF_CY_PKGUTIL_BIN="$TMP/mock-pkgutil" ESP_IDF_CY_OPEN_BIN="$TMP/mock-open" \
  ESP_IDF_CY_TEST_OPEN_LOG="$TMP/open.log" \
  bash "$ROOT/scripts/bootstrap-macos.sh" --min-python 3.10 2>&1)"
RC=$?
set -e
[ "$RC" -eq 20 ] || fail "mac-python-pkg-rc:$RC:$OUT"
printf '%s\n' "$OUT" | grep -q '^PYTHON_PKG_VERIFIED=yes$' || fail mac-python-pkg-verified
printf '%s\n' "$OUT" | grep -q '^ACTION_REQUIRED=complete_python_org_installer$' || fail mac-python-pkg-action
grep -q 'python-3.13.14-macos11.pkg$' "$TMP/open.log" || fail mac-python-pkg-open
pass mac-python-pkg

# 校验和不匹配时必须拒绝打开,不能只依赖 HTTPS 或签名文本。
printf '#!/usr/bin/env bash\necho "badsha  $3"\n' >"$TMP/mock-bad-shasum"
chmod +x "$TMP/mock-bad-shasum"
rm -f "$TMP/open-bad.log"
set +e
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_TEST_CLT_READY=yes ESP_IDF_CY_TEST_SKIP_SYSTEM_PYTHON=yes \
  ESP_IDF_CY_TEST_NO_BREW=yes ESP_IDF_CY_DOWNLOAD_DIR="$TMP/downloads-bad" \
  ESP_IDF_CY_CURL_BIN="$TMP/mock-curl" ESP_IDF_CY_SHASUM_BIN="$TMP/mock-bad-shasum" \
  ESP_IDF_CY_PKGUTIL_BIN="$TMP/mock-pkgutil" ESP_IDF_CY_OPEN_BIN="$TMP/mock-open" \
  ESP_IDF_CY_TEST_OPEN_LOG="$TMP/open-bad.log" \
  bash "$ROOT/scripts/bootstrap-macos.sh" --min-python 3.10 2>&1)"
RC=$?
set -e
[ "$RC" -eq 9 ] || fail "mac-python-bad-sha-rc:$RC:$OUT"
[ ! -e "$TMP/open-bad.log" ] || fail mac-python-bad-sha-opened
printf '%s\n' "$OUT" | grep -q 'SHA256 不匹配' || fail mac-python-bad-sha-message
pass mac-python-pkg-reject

# SHA 正确但发布者签名不对时同样拒绝打开。
printf '#!/usr/bin/env bash\necho "Developer ID Installer: Unexpected Publisher"\n' >"$TMP/mock-bad-pkgutil"
chmod +x "$TMP/mock-bad-pkgutil"
rm -f "$TMP/open-bad-signature.log"
set +e
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_TEST_CLT_READY=yes ESP_IDF_CY_TEST_SKIP_SYSTEM_PYTHON=yes \
  ESP_IDF_CY_TEST_NO_BREW=yes ESP_IDF_CY_DOWNLOAD_DIR="$TMP/downloads-bad-signature" \
  ESP_IDF_CY_CURL_BIN="$TMP/mock-curl" ESP_IDF_CY_SHASUM_BIN="$TMP/mock-shasum" \
  ESP_IDF_CY_PKGUTIL_BIN="$TMP/mock-bad-pkgutil" ESP_IDF_CY_OPEN_BIN="$TMP/mock-open" \
  ESP_IDF_CY_TEST_OPEN_LOG="$TMP/open-bad-signature.log" \
  bash "$ROOT/scripts/bootstrap-macos.sh" --min-python 3.10 2>&1)"
RC=$?
set -e
[ "$RC" -eq 9 ] || fail "mac-python-bad-signature-rc:$RC:$OUT"
[ ! -e "$TMP/open-bad-signature.log" ] || fail mac-python-bad-signature-opened
printf '%s\n' "$OUT" | grep -q '签名不是 Python Software Foundation' || fail mac-python-bad-signature-message
pass mac-python-signature-reject

# 只打印正确 signer 文字但 pkgutil 本身失败，也必须拒绝，不能误信 stdout。
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "Developer ID Installer: Python Software Foundation (BMM5U3QVKW)"' \
  'exit 7' >"$TMP/mock-failing-pkgutil"
chmod +x "$TMP/mock-failing-pkgutil"
set +e
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_TEST_CLT_READY=yes ESP_IDF_CY_TEST_SKIP_SYSTEM_PYTHON=yes \
  ESP_IDF_CY_TEST_NO_BREW=yes ESP_IDF_CY_DOWNLOAD_DIR="$TMP/downloads-failing-signature" \
  ESP_IDF_CY_CURL_BIN="$TMP/mock-curl" ESP_IDF_CY_SHASUM_BIN="$TMP/mock-shasum" \
  ESP_IDF_CY_PKGUTIL_BIN="$TMP/mock-failing-pkgutil" ESP_IDF_CY_OPEN_BIN="$TMP/mock-open" \
  ESP_IDF_CY_TEST_OPEN_LOG="$TMP/open-failing-signature.log" \
  bash "$ROOT/scripts/bootstrap-macos.sh" --min-python 3.10 2>&1)"
RC=$?
set -e
[ "$RC" -eq 9 ] || fail "mac-python-pkgutil-rc:$RC:$OUT"
[ ! -e "$TMP/open-failing-signature.log" ] || fail mac-python-pkgutil-opened
pass mac-python-pkgutil-rc

# EIM quoting helper仍要保留通用 argv 边界;实际IDF/项目路径含空白会由wrapper另行拒绝。
ACTUAL="$(bash -c '. "$1"; shift; eim_command_string "$@"' _ \
  "$ROOT/scripts/lib.sh" idf.py -C 'C:\Users\A B\project' build)"
EXPECTED='"idf.py" "-C" "C:\Users\A B\project" "build"'
[ "$ACTUAL" = "$EXPECTED" ] || fail "eim-quoting:$ACTUAL"
pass eim-quoting

# skill 自己下载的 EIM 不在 PATH 里也必须能被下一次会话找到。
printf '#!/usr/bin/env bash\necho eim-test\n' >"$TMP/eim.exe"
chmod +x "$TMP/eim.exe"
FOUND="$(ESP_IDF_CY_EIM_BIN="$TMP/eim.exe" bash -c '. "$1"; find_eim' _ "$ROOT/scripts/lib.sh")"
[ "$FOUND" = "$TMP/eim.exe" ] || fail eim-discovery
pass eim-discovery

# 模拟 Windows+EIM 完整 wrapper:命令字符串是一个 argv,IDF 路径作为第二个参数锁定。
mkdir -p "$TMP/eim-idf/tools"
: >"$TMP/eim-idf/tools/idf.py"
printf '{"idfSelectedId":"fixture","idfInstalled":[{"id":"fixture","name":"v5.5.4","path":"%s"}]}\n' \
  "$TMP/eim-idf" >"$TMP/eim_idf.json"
printf '#!/usr/bin/env bash\nfor arg in "$@"; do printf "ARG=<%%s>\\n" "$arg"; done\n' >"$TMP/mock-eim"
chmod +x "$TMP/mock-eim"
printf '#!/usr/bin/env bash\nfor arg in "$@"; do printf "ARG=<%%s>\\n" "$arg"; done\n' >"$TMP/mock-powershell"
chmod +x "$TMP/mock-powershell"
OUT="$(ESP_IDF_CY_OS=windows ESP_IDF_CY_EIM_BIN="$TMP/mock-eim" \
  ESP_IDF_CY_POWERSHELL_BIN="$TMP/mock-powershell" \
  ESP_IDF_CY_EIM_JSON="$TMP/eim_idf.json" \
  bash "$ROOT/scripts/idf-env.sh" idf.py --version)" || fail eim-wrapper
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<RunIdf>' || fail eim-wrapper-run
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<"idf.py" "--version">' || fail eim-wrapper-command
printf '%s\n' "$OUT" | grep -Fqx "ARG=<$TMP/eim-idf>" || fail eim-wrapper-idf
pass eim-wrapper

# 模拟 macOS+EIM wrapper:POSIX 必须直接调用原生 EIM,不能落入 Windows PowerShell helper。
mkdir -p "$TMP/project-safe"
OUT="$(ESP_IDF_CY_OS=mac ESP_IDF_CY_EIM_BIN="$TMP/mock-eim" \
  ESP_IDF_CY_EIM_JSON="$TMP/eim_idf.json" \
  bash "$ROOT/scripts/idf-env.sh" idf.py -C "$TMP/project-safe" build)" || fail mac-eim-wrapper
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<--do-not-track>' || fail mac-eim-wrapper-privacy-flag
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<true>' || fail mac-eim-wrapper-privacy-value
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<run>' || fail mac-eim-wrapper-run
printf '%s\n' "$OUT" | grep -Fqx "ARG=<\"idf.py\" \"-C\" \"$TMP/project-safe\" \"build\">" || fail mac-eim-wrapper-command
printf '%s\n' "$OUT" | grep -Fqx "ARG=<$TMP/eim-idf>" || fail mac-eim-wrapper-idf
pass mac-eim-wrapper

# 多版本 EIM:显式选非 selected 路径后仍必须走 RunIdf，并把所选路径传给 helper。
mkdir -p "$TMP/eim-idf-alt/tools"
: >"$TMP/eim-idf-alt/tools/idf.py"
printf '{"idfSelectedId":"selected","idfInstalled":[{"id":"selected","name":"v5.5.4","path":"%s"},{"id":"alt","name":"v6.0.2","path":"%s"}]}\n' \
  "$TMP/eim-idf" "$TMP/eim-idf-alt" >"$TMP/eim_idf_multi.json"
OUT="$(ESP_IDF_CY_OS=windows ESP_IDF_CY_EIM_BIN="$TMP/mock-eim" \
  ESP_IDF_CY_POWERSHELL_BIN="$TMP/mock-powershell" \
  ESP_IDF_CY_EIM_JSON="$TMP/eim_idf_multi.json" ESP_IDF_CY_IDF_PATH="$TMP/eim-idf-alt" \
  bash "$ROOT/scripts/idf-env.sh" idf.py --version)" || fail eim-explicit-wrapper
printf '%s\n' "$OUT" | grep -Fqx 'ARG=<RunIdf>' || fail eim-explicit-run
printf '%s\n' "$OUT" | grep -Fqx "ARG=<$TMP/eim-idf-alt>" || fail eim-explicit-path
pass eim-explicit-selection

# 单口只返候选口+重验标记;多口必须拒绝 BEST_PORT。
printf 'PORT /dev/ttyTEST0 fixture\n' >"$TMP/ports"
OUT="$(ESP_IDF_CY_PORTS_FILE="$TMP/ports" bash "$ROOT/scripts/wait-port.sh" -t 0 -i 1)" || fail wait-single
printf '%s\n' "$OUT" | grep -q '^CANDIDATE_PORT=/dev/ttyTEST0$' || fail wait-single-candidate
printf '%s\n' "$OUT" | grep -q '^REVERIFY_REQUIRED=yes$' || fail wait-single-reverify
pass wait-single

printf 'PORT /dev/ttyTEST0 fixture\nPORT /dev/ttyTEST1 fixture\n' >"$TMP/ports"
set +e
OUT="$(ESP_IDF_CY_PORTS_FILE="$TMP/ports" bash "$ROOT/scripts/wait-port.sh" -t 0 -i 1 2>&1)"
RC=$?
set -e
[ "$RC" -eq 3 ] || fail "wait-multiple-rc:$RC"
printf '%s\n' "$OUT" | grep -q '^AMBIGUOUS=yes$' || fail wait-multiple-ambiguous
printf '%s\n' "$OUT" | grep -q 'BEST_PORT=' && fail wait-multiple-best-port
pass wait-multiple

# 设备验身要兼容 esptool v4 的下划线命令,并稳定输出标准化 MAC。
mkdir -p "$TMP/identify-idf/tools" "$TMP/identify-bin"
: >"$TMP/identify-idf/tools/idf.py"
printf '#!/usr/bin/env bash\nexport PATH="$ESP_IDF_CY_TEST_BIN:$PATH"\n' >"$TMP/identify-idf/export.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  *"esptool version"*) echo "esptool.py v4.12" ;;' \
  '  *"chip_id"*) echo "Chip is ESP32-S3 (revision v0.2)"; echo "MAC: 7c:df:a1:12:34:56" ;;' \
  '  *) echo "unexpected args: $*" >&2; exit 9 ;;' \
  'esac' >"$TMP/identify-bin/python"
chmod +x "$TMP/identify-bin/python"
OUT="$(ESP_IDF_CY_IDF_PATH="$TMP/identify-idf" ESP_IDF_CY_TEST_BIN="$TMP/identify-bin" \
  bash "$ROOT/scripts/identify-device.sh" -p /dev/ttyFIXTURE)" || fail identify-device
printf '%s\n' "$OUT" | grep -q '^CHIP=ESP32-S3$' || fail identify-chip
printf '%s\n' "$OUT" | grep -q '^MAC=7C:DF:A1:12:34:56$' || fail identify-mac
pass identify-device

# 仅存在 tools/idf.py 的假目录不能再被 doctor 报 READY=yes。
mkdir -p "$TMP/fake-idf/tools"
: >"$TMP/fake-idf/tools/idf.py"
set +e
OUT="$(ESP_IDF_CY_IDF_PATH="$TMP/fake-idf" bash "$ROOT/scripts/doctor.sh" --no-net 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "doctor-fake-rc:$RC"
printf '%s\n' "$OUT" | grep -q '^IDF_COMMAND_OK=no$' || fail doctor-fake-command
printf '%s\n' "$OUT" | grep -q '^READY=no$' || fail doctor-fake-ready
pass doctor-fake-idf

# 通过真 IDF python/pyserial 在 PTY 上验证 expect、timeout 和项目波特率。
bash "$ROOT/scripts/idf-env.sh" python "$ROOT/tests/test_serial_monitor.py" || fail serial-monitor
pass all
