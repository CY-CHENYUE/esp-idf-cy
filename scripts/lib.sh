#!/usr/bin/env bash
# esp-idf-cy · 公共函数库 —— 被其余脚本 source,不单独执行。
# 输出约定:给 agent 解析的都是 KEY=VALUE 行(stdout);人类可读提示走 stderr。
# 铁律:零硬编码 —— 平台运行时判定,所有路径来自探测或环境变量,项目位置由调用方决定。

set -u
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------- 平台 ----------------
detect_os() {
  if [ -n "${ESP_IDF_CY_OS:-}" ]; then
    case "$ESP_IDF_CY_OS" in
      mac|linux|windows|unknown) echo "$ESP_IDF_CY_OS"; return ;;
      *) echo "ERROR=ESP_IDF_CY_OS 只能是 mac/linux/windows/unknown" >&2; return 64 ;;
    esac
  fi
  case "$(uname -s)" in
    Darwin)                echo mac ;;
    Linux)                 echo linux ;;
    MINGW*|MSYS*|CYGWIN*)  echo windows ;;
    *)                     echo unknown ;;
  esac
}
OS="$(detect_os)"

# Windows 上 Git Bash 视角的用户主目录(HOME 可能被改写,以 USERPROFILE 为准)
user_home() {
  if [ "$OS" = windows ] && [ -n "${USERPROFILE:-}" ]; then
    cygpath -u "$USERPROFILE" 2>/dev/null || echo "$HOME"
  else
    echo "$HOME"
  fi
}

# Windows: 调 PowerShell。必须清 MSYSTEM —— 乐鑫官方脚本(idf_tools.py/install.bat/export.bat)
# 检测到 MSYSTEM 环境变量会直接拒跑,而 Git Bash 会把 MSYSTEM=MINGW64 遗传给子进程。
ps_run() {
  local ps_bin="${ESP_IDF_CY_POWERSHELL_BIN:-powershell.exe}" out rc
  out="$(env -u MSYSTEM "$ps_bin" -NoLogo -NoProfile -NonInteractive -Command "$*" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | tr -d '\r'
  return "$rc"
}

# Windows:以 argv 而非动态命令字符串调用固定 PowerShell 脚本。
# 调用方负责把需要交给 Windows 原生程序的路径先转成 Windows 形式。
ps_file() {
  local ps_bin="${ESP_IDF_CY_POWERSHELL_BIN:-powershell.exe}" script="$1"
  shift
  env -u MSYSTEM MSYS2_ARG_CONV_EXCL='*' "$ps_bin" -NoLogo -NoProfile -NonInteractive \
    -ExecutionPolicy Bypass -File "$script" "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# EIM 可能由 winget 装到 PATH,也可能是 install.sh 直下的独立二进制。
# 统一从这里发现,避免“安装时能用,下一次会话找不到”。
validate_eim_candidate() {
  [ -n "${1:-}" ] && [ -x "$1" ] || return 1
  # Windows 上绝不能在验签前执行候选 exe。真正使用前由
  # eim-windows.ps1 以 Authenticode 复验；其他平台才用 --version 验活。
  [ "$OS" = windows ] || "$1" --version >/dev/null 2>&1
}

find_eim() {
  local home candidate explicit local_app="" program_files="" path_eim=""
  home="$(user_home)"
  explicit="${ESP_IDF_CY_EIM_BIN:-}"
  if [ -n "$explicit" ]; then
    if [ "$OS" = windows ]; then explicit="$(cygpath -u "$explicit" 2>/dev/null || echo "$explicit")"; fi
    if validate_eim_candidate "$explicit"; then echo "$explicit"; return 0; fi
    echo "ERROR=ESP_IDF_CY_EIM_BIN 已显式设置但不可执行或验活失败: $explicit" >&2
    return 64
  fi
  if [ "$OS" = windows ]; then
    local_app="${LOCALAPPDATA:-}"
    program_files="${PROGRAMFILES:-${ProgramFiles:-}}"
    [ -n "$local_app" ] && local_app="$(cygpath -u "$local_app" 2>/dev/null || echo "$local_app")"
    [ -n "$program_files" ] && program_files="$(cygpath -u "$program_files" 2>/dev/null || echo "$program_files")"
  fi
  for candidate in \
    "$home/.esp-idf-cy/bin/eim.exe" \
    "$home/.esp-idf-cy/bin/eim" \
    "${local_app:+$local_app/Microsoft/WinGet/Links/eim.exe}" \
    "${program_files:+$program_files/WinGet/Links/eim.exe}"; do
    [ -n "$candidate" ] && validate_eim_candidate "$candidate" && { echo "$candidate"; return 0; }
  done
  if have eim; then
    path_eim="$(command -v eim)"
    validate_eim_candidate "$path_eim" && { echo "$path_eim"; return 0; }
  fi
  return 1
}

# eim run 接受一整条命令字符串。在 Windows 上给每个 argv 单独加引号,
# 保留 `-C "C:\\Users\\A B\\proj"` 这类空格路径的参数边界。
eim_command_string() {
  local arg out=""
  [ "$#" -gt 0 ] || return 64
  for arg in "$@"; do
    case "$arg" in
      *'"'*|*$'\r'*|*$'\n'*)
        echo "ERROR=EIM 命令参数不支持引号或换行: $arg" >&2
        return 64
        ;;
    esac
    out="${out}${out:+ }\"$arg\""
  done
  printf '%s\n' "$out"
}

# ---------------- 通用 ----------------
# 便携 timeout(macOS 默认没有 timeout;brew coreutils 里叫 gtimeout)
run_with_timeout() {
  local secs="$1" py; shift
  py="$(find_python)" || { echo "ERROR=缺少 Python,无法提供安全的进程组超时" >&2; return 127; }
  "$py" "$LIB_DIR/process_timeout.py" "$secs" -- "$@"
}

# python3 解释器(Windows 上可能只叫 python)
find_python() {
  if [ -n "${ESP_IDF_CY_PYTHON_BIN:-}" ] && [ -x "$ESP_IDF_CY_PYTHON_BIN" ] \
    && "$ESP_IDF_CY_PYTHON_BIN" --version 2>&1 | grep -q 'Python 3'; then
    echo "$ESP_IDF_CY_PYTHON_BIN"
    return 0
  fi
  if have python3; then echo python3; return 0; fi
  if have python && python --version 2>&1 | grep -q 'Python 3'; then echo python; return 0; fi
  return 1
}

python_version_of() {  # python_version_of /path/to/python → 3.13
  "$1" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null
}

python_version() {  # 输出如 3.9;找不到 python 输出空
  local py; py="$(find_python)" || return 1
  python_version_of "$py"
}

# version_ge 3.10 3.9 → true(第一个 >= 第二个)
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# IDF 版本 → 最低 python 版本(官方:v5.5 需 ≥3.9,v6.0 需 ≥3.10,更老的 ≥3.8)
idf_min_python() {
  case "$1" in
    v6*|6*)          echo 3.10 ;;
    v5.5*|5.5*)      echo 3.9  ;;
    *)               echo 3.8  ;;
  esac
}

# ---------------- 网络 ----------------
# NET=global(GitHub 通畅) / cn(GitHub 不畅但国内可达 → 启用乐鑫国内镜像) / offline
check_network() {
  if [ -n "${ESP_IDF_CY_NET:-}" ]; then
    case "$ESP_IDF_CY_NET" in
      global|cn|offline) echo "$ESP_IDF_CY_NET"; return ;;
      *) echo "ERROR=ESP_IDF_CY_NET 只能是 global/cn/offline" >&2; return 64 ;;
    esac
  fi
  local curl_bin="${ESP_IDF_CY_CURL_BIN:-curl}"
  # 只探测安装流程真正会访问的源，避免为了判断网络额外访问第三方站点。
  if "$curl_bin" -m 5 -fsI https://github.com/espressif/esp-idf.git >/dev/null 2>&1; then
    echo global
    return
  fi
  if "$curl_bin" -m 5 -fsI https://jihulab.com/esp-mirror/espressif/esp-idf.git >/dev/null 2>&1 \
     || "$curl_bin" -m 5 -fsI https://dl.espressif.cn/ >/dev/null 2>&1; then
    echo cn
    return
  fi
  echo offline
}

# ---------------- IDF 探测 ----------------
is_idf_dir() { [ -n "${1:-}" ] && [ -f "$1/tools/idf.py" ]; }

# EIM 的安装登记文件(官方:POSIX 默认 ~/.espressif/tools,Windows 默认 C:\Espressif\tools)
eim_json_path() {
  if [ -n "${ESP_IDF_CY_EIM_JSON:-}" ]; then
    echo "$ESP_IDF_CY_EIM_JSON"
    return
  fi
  if [ "$OS" = windows ]; then
    local d; d="$(cygpath -u 'C:\Espressif\tools' 2>/dev/null || echo /c/Espressif/tools)"
    echo "$d/eim_idf.json"
  else
    echo "${IDF_TOOLS_PATH:-$HOME/.espressif}/tools/eim_idf.json"
  fi
}

# 解析 eim_idf.json,输出行: <path>|<name>,selected 的排第一
parse_eim_json() {
  local f="$1" py
  [ -f "$f" ] || return 1
  py="$(find_python)" || { grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" | sed 's/.*: *"//; s/"$//; s/$/|unknown/'; return 0; }
  "$py" - "$f" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
sel = d.get("idfSelectedId", "")
items = d.get("idfInstalled", []) or []
items.sort(key=lambda x: x.get("id") != sel)
for it in items:
    print("%s|%s" % (it.get("path", ""), it.get("name") or it.get("id", "")))
PYEOF
}

# 取某个 IDF 目录的版本号
idf_dir_version() {
  local d="$1" v
  v="$(git -C "$d" describe --tags 2>/dev/null)" && { echo "$v"; return 0; }
  local f="$d/tools/cmake/version.cmake"
  if [ -f "$f" ]; then
    awk '/set\(IDF_VERSION_(MAJOR|MINOR|PATCH)/ {gsub(/[^0-9]/,"",$2); v = v sep $2; sep="."} END {if (v) print "v" v}' "$f"
    return 0
  fi
  return 1
}

# 探测已装 ESP-IDF。结果写入全局变量:
#   IDF_FOUND=yes|no  IDF_KIND=eim|legacy  FOUND_IDF_PATH=  IDF_VER=  IDF_CANDIDATES=path1;path2;...
# 优先级:ESP_IDF_CY_IDF_PATH 显式指定 > 当前 shell 的 IDF_PATH > EIM 登记(selected 优先) > 惯例路径
find_idf() {
  IDF_FOUND=no; IDF_KIND=""; FOUND_IDF_PATH=""; IDF_VER=""; IDF_CANDIDATES=""
  DISCOVERY_ERROR=""
  local home; home="$(user_home)"
  local cand=""

  # 0) 用户/agent 显式指定
  if [ -n "${ESP_IDF_CY_IDF_PATH:-}" ]; then
    local explicit_idf="$ESP_IDF_CY_IDF_PATH"
    [ "$OS" = windows ] && explicit_idf="$(cygpath -u "$explicit_idf" 2>/dev/null || echo "$explicit_idf")"
    if is_idf_dir "$explicit_idf"; then
      FOUND_IDF_PATH="$explicit_idf"; IDF_KIND=legacy
    else
      DISCOVERY_ERROR="ESP_IDF_CY_IDF_PATH 已显式设置但不是完整 ESP-IDF: $explicit_idf"
      return 0
    fi
  fi
  if [ -n "${ESP_IDF_CY_EIM_BIN:-}" ] && ! find_eim >/dev/null 2>&1; then
    DISCOVERY_ERROR="ESP_IDF_CY_EIM_BIN 已显式设置但不可执行或验活失败"
    IDF_FOUND=no; IDF_KIND=""; FOUND_IDF_PATH=""; IDF_VER=""; IDF_CANDIDATES=""
    return 0
  fi

  # 1) 当前环境已有 IDF_PATH
  if [ -z "$FOUND_IDF_PATH" ] && [ -n "${IDF_PATH:-}" ] && is_idf_dir "$IDF_PATH"; then
    FOUND_IDF_PATH="$IDF_PATH"; IDF_KIND=legacy
  fi

  # 2) EIM 登记文件(跨平台;VS Code 扩展也读它)
  local ej; ej="$(eim_json_path)"
  if [ -f "$ej" ]; then
    local line p n first_eim="" registered_path=""
    while IFS='|' read -r p n; do
      [ -n "$p" ] || continue
      [ "$OS" = windows ] && p="$(cygpath -u "$p" 2>/dev/null || echo "$p")"
      if is_idf_dir "$p"; then
        registered_path="$p"
      elif is_idf_dir "$p/esp-idf"; then
        registered_path="$p/esp-idf"
      else
        registered_path=""
      fi
      if [ -n "$registered_path" ]; then
        cand="$cand;$registered_path"
        [ -z "$first_eim" ] && first_eim="$registered_path"
        # 显式选中的路径若正是 EIM 登记项，仍应走受验签的 eim run，
        # 不能因为“显式”二字退化到实验性 export.bat/cmd 路线。
        [ "$FOUND_IDF_PATH" = "$registered_path" ] && IDF_KIND=eim
      fi
    done <<EOF
$(parse_eim_json "$ej")
EOF
    if [ -z "$FOUND_IDF_PATH" ] && [ -n "$first_eim" ]; then
      FOUND_IDF_PATH="$first_eim"; IDF_KIND=eim
    fi
  fi

  # 3) 惯例路径:~/esp/esp-idf 及多版本目录 ~/esp/esp-idf-*;Windows 另加 EIM 默认 C:\esp\<ver>
  local d
  for d in "$home/esp/esp-idf" "$home/esp/esp-idf-"*; do
    is_idf_dir "$d" || continue
    cand="$cand;$d"
    if [ -z "$FOUND_IDF_PATH" ]; then FOUND_IDF_PATH="$d"; IDF_KIND=legacy; fi
  done
  if [ "$OS" = windows ]; then
    # EIM 默认把 IDF 装在 C:\esp 下,目录层级可能是 C:\esp\<ver> 或 C:\esp\<ver>\esp-idf
    for d in /c/esp/* /c/esp/*/esp-idf /c/esp/esp-idf; do
      is_idf_dir "$d" || continue
      cand="$cand;$d"
      if [ -z "$FOUND_IDF_PATH" ]; then FOUND_IDF_PATH="$d"; IDF_KIND=eim; fi
    done
  fi

  IDF_CANDIDATES="${cand#;}"
  if [ -n "$FOUND_IDF_PATH" ]; then
    IDF_FOUND=yes
    IDF_VER="$(idf_dir_version "$FOUND_IDF_PATH" 2>/dev/null || echo unknown)"
    # eim 二进制不存在时,eim 安装才按 legacy 方式激活。
    if [ "$IDF_KIND" = eim ] && ! find_eim >/dev/null 2>&1; then IDF_KIND=legacy; fi
  fi
}

# ---------------- 串口探测 ----------------
# 输出行: PORT <设备> <描述>。乐鑫原生 USB-Serial/JTAG(VID_303A:PID_1001)会标 [espressif-usb-jtag]。
list_ports() {
  local p
  if [ -n "${ESP_IDF_CY_PORTS_FILE:-}" ]; then
    [ -f "$ESP_IDF_CY_PORTS_FILE" ] && cat "$ESP_IDF_CY_PORTS_FILE"
    return
  fi
  case "$OS" in
    mac)
      for p in /dev/cu.usbmodem* /dev/cu.usbserial* /dev/cu.SLAB* /dev/cu.wchusbserial*; do
        [ -e "$p" ] || continue
        case "$p" in
          /dev/cu.usbmodem*) echo "PORT $p usb-modem(大概率乐鑫原生USB-Serial/JTAG) [espressif-usb-jtag?]" ;;
          *)                 echo "PORT $p usb-uart桥(CP210x/CH340类)" ;;
        esac
      done
      ;;
    linux)
      for p in /dev/ttyACM* /dev/ttyUSB*; do
        [ -e "$p" ] || continue
        case "$p" in
          /dev/ttyACM*) echo "PORT $p usb-modem(大概率乐鑫原生USB-Serial/JTAG) [espressif-usb-jtag?]" ;;
          *)            echo "PORT $p usb-uart桥(CP210x/CH340类)" ;;
        esac
      done
      ;;
    windows)
      ps_run "Get-CimInstance -ClassName Win32_PnPEntity -Filter \"PNPClass='Ports'\" | ForEach-Object { \$_.Name + '|' + \$_.DeviceID }" \
      | while IFS='|' read -r name devid; do
          [ -n "$name" ] || continue
          local com; com="$(printf '%s' "$name" | grep -o 'COM[0-9][0-9]*' | head -1)"
          [ -n "$com" ] || continue
          local tag=""
          case "$devid" in *VID_303A*PID_1001*) tag=" [espressif-usb-jtag]" ;; esac
          echo "PORT $com $name$tag"
        done
      ;;
  esac
}
