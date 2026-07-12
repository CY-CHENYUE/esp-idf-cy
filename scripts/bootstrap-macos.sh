#!/usr/bin/env bash
# esp-idf-cy · macOS 空白机前置依赖 bootstrap。
#
# 官方 EIM 在 macOS 不会自动安装前置依赖。这里负责把可自动化的部分吸收掉:
#   1) 缺 Xcode Command Line Tools 时主动触发系统安装器;
#   2) 找到满足最低版本的 Python 就复用;
#   3) 已有 Homebrew 时自动安装 Python;
#   4) 无 Homebrew 时下载、校验并打开 Python.org 官方签名 pkg。
#
# 系统安装 UI 必须由用户本人确认。脚本用 rc=20 + ACTION_REQUIRED 表示“不是失败,
# 等用户完成系统动作后原命令重跑即可续上”。不静默安装 Homebrew,不 curl|sh 第三方 Python。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

MIN_PYTHON=""
CLT_ONLY=no
while [ $# -gt 0 ]; do
  case "$1" in
    --clt-only) CLT_ONLY=yes; shift ;;
    --min-python)
      [ $# -ge 2 ] || { echo "ERROR=--min-python 缺少版本值" >&2; exit 64; }
      MIN_PYTHON="$2"; shift 2
      ;;
    *) echo "ERROR=未知参数: $1" >&2; exit 64 ;;
  esac
done

[ "$OS" = mac ] || { echo "ERROR=bootstrap-macos.sh 只支持 macOS" >&2; exit 64; }
[ "$CLT_ONLY" = yes ] || [ -n "$MIN_PYTHON" ] \
  || { echo "ERROR=需要 --clt-only 或 --min-python <版本>" >&2; exit 64; }
if [ -n "$MIN_PYTHON" ] && ! printf '%s\n' "$MIN_PYTHON" | grep -Eq '^[0-9]+\.[0-9]+$'; then
  echo "ERROR=--min-python 必须是 major.minor: $MIN_PYTHON" >&2
  exit 64
fi

XCODE_SELECT_BIN="${ESP_IDF_CY_XCODE_SELECT_BIN:-xcode-select}"
CURL_BIN="${ESP_IDF_CY_CURL_BIN:-curl}"
SHASUM_BIN="${ESP_IDF_CY_SHASUM_BIN:-shasum}"
PKGUTIL_BIN="${ESP_IDF_CY_PKGUTIL_BIN:-pkgutil}"
OPEN_BIN="${ESP_IDF_CY_OPEN_BIN:-open}"

clt_ready() {
  case "${ESP_IDF_CY_TEST_CLT_READY:-}" in
    yes) return 0 ;;
    no) return 1 ;;
  esac
  "$XCODE_SELECT_BIN" -p >/dev/null 2>&1
}

if ! clt_ready; then
  echo "STEP=触发 Xcode Command Line Tools 系统安装器"
  "$XCODE_SELECT_BIN" --install >/dev/null 2>&1 || true
  echo "ACTION_REQUIRED=complete_xcode_command_line_tools"
  echo "HINT=请在 macOS 系统窗口中确认安装;完成后重跑原命令,会自动续上"
  exit 20
fi

if ! have git || ! git --version >/dev/null 2>&1; then
  echo "ERROR=Command Line Tools 已存在但 git 仍不可用;运行 xcode-select -p 和 git --version 检查安装状态" >&2
  exit 5
fi

echo "CLT_READY=yes"
echo "GIT_READY=yes"
[ "$CLT_ONLY" = yes ] && exit 0

absolute_command() {
  case "$1" in
    */*) printf '%s\n' "$1" ;;
    *) command -v "$1" 2>/dev/null ;;
  esac
}

compatible_python() {
  local candidate absolute version candidates=""
  [ -n "${ESP_IDF_CY_PYTHON_BIN:-}" ] && candidates="$ESP_IDF_CY_PYTHON_BIN"
  if [ "${ESP_IDF_CY_TEST_SKIP_SYSTEM_PYTHON:-no}" != yes ]; then
    candidates="${candidates}${candidates:+$'\n'}python3
python
/opt/homebrew/bin/python3
/usr/local/bin/python3
/Library/Frameworks/Python.framework/Versions/Current/bin/python3
/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
/Library/Frameworks/Python.framework/Versions/3.13/bin/python3
/Library/Frameworks/Python.framework/Versions/3.12/bin/python3
/Library/Frameworks/Python.framework/Versions/3.11/bin/python3
/Library/Frameworks/Python.framework/Versions/3.10/bin/python3"
  fi
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    absolute="$(absolute_command "$candidate" || true)"
    [ -n "$absolute" ] && [ -x "$absolute" ] || continue
    version="$(python_version_of "$absolute" || true)"
    [ -n "$version" ] && version_ge "$version" "$MIN_PYTHON" || continue
    echo "$absolute|$version"
    return 0
  done <<EOF
$candidates
EOF
  return 1
}

FOUND="$(compatible_python || true)"
if [ -n "$FOUND" ]; then
  echo "PYTHON_BIN=${FOUND%%|*}"
  echo "PYTHON_VERSION=${FOUND#*|}"
  echo "READY=yes"
  exit 0
fi

BREW_BIN="${ESP_IDF_CY_BREW_BIN:-}"
if [ "${ESP_IDF_CY_TEST_NO_BREW:-no}" != yes ] && [ -z "$BREW_BIN" ] && have brew; then
  BREW_BIN="$(command -v brew)"
fi
if [ -n "$BREW_BIN" ] && [ -x "$BREW_BIN" ]; then
  echo "STEP=使用现有 Homebrew 安装兼容 Python"
  "$BREW_BIN" install python || {
    echo "ERROR=Homebrew 安装 Python 失败;保留上方日志,不要重复安装 Homebrew" >&2
    exit 7
  }
  BREW_PREFIX="$($BREW_BIN --prefix python 2>/dev/null || true)"
  if [ -n "$BREW_PREFIX" ] && [ -x "$BREW_PREFIX/bin/python3" ]; then
    export ESP_IDF_CY_PYTHON_BIN="$BREW_PREFIX/bin/python3"
  fi
  FOUND="$(compatible_python || true)"
  if [ -n "$FOUND" ]; then
    echo "PYTHON_SOURCE=homebrew"
    echo "PYTHON_BIN=${FOUND%%|*}"
    echo "PYTHON_VERSION=${FOUND#*|}"
    echo "READY=yes"
    exit 0
  fi
  echo "ERROR=Homebrew 返回成功,但仍未找到 Python >= $MIN_PYTHON" >&2
  exit 7
fi

# 无包管理器时使用 Python.org 官方 universal2 安装包。版本与 SHA256 都可在后续维护时覆盖,
# 默认值来自 Python.org 3.13.14 发布页;3.13 在当前 ESP-IDF 支持范围内。
PY_RELEASE="${ESP_IDF_CY_MAC_PYTHON_VERSION:-3.13.14}"
PY_SHA256="${ESP_IDF_CY_MAC_PYTHON_SHA256:-8e58affb218c155a1dfdc27b291f817129669f8760e7a297adb2e4439ba5d2e8}"
PY_URL="${ESP_IDF_CY_MAC_PYTHON_URL:-https://www.python.org/ftp/python/$PY_RELEASE/python-$PY_RELEASE-macos11.pkg}"
DL_DIR="${ESP_IDF_CY_DOWNLOAD_DIR:-$HOME/.esp-idf-cy/downloads}"
PY_PKG="$DL_DIR/python-$PY_RELEASE-macos11.pkg"
mkdir -p "$DL_DIR"

verify_python_pkg() {
  local pkg_path="${1:-$PY_PKG}" actual_sha signature_out signature_rc
  actual_sha="$($SHASUM_BIN -a 256 "$pkg_path" 2>/dev/null | awk '{print $1}')"
  [ "$actual_sha" = "$PY_SHA256" ] || {
    echo "ERROR=Python 安装包 SHA256 不匹配;拒绝打开。expected=$PY_SHA256 actual=$actual_sha" >&2
    return 9
  }
  signature_out="$("$PKGUTIL_BIN" --check-signature "$pkg_path" 2>&1)"
  signature_rc=$?
  [ "$signature_rc" -eq 0 ] \
    && printf '%s\n' "$signature_out" | grep -Fq 'Developer ID Installer: Python Software Foundation (BMM5U3QVKW)' || {
    echo "ERROR=Python 安装包签名不是 Python Software Foundation;拒绝打开" >&2
    return 9
  }
}

if [ -f "$PY_PKG" ] && verify_python_pkg; then
  echo "STEP=复用已验证的 Python.org Python $PY_RELEASE 安装包"
else
  echo "STEP=下载 Python.org 官方 Python $PY_RELEASE 安装包"
  PY_PART="$PY_PKG.part.$$"
  "$CURL_BIN" -fL --retry 3 -o "$PY_PART" "$PY_URL" || {
    rm -f "$PY_PART"
    echo "ERROR=Python.org 安装包下载失败: $PY_URL" >&2
    exit 6
  }
  verify_python_pkg "$PY_PART" || { rc=$?; rm -f "$PY_PART"; exit "$rc"; }
  mv -f "$PY_PART" "$PY_PKG"
fi

echo "PYTHON_PKG_VERIFIED=yes"
if "$OPEN_BIN" "$PY_PKG"; then
  echo "ACTION_REQUIRED=complete_python_org_installer"
  echo "HINT=请完成 macOS 安装器;结束后重跑原命令,Agent 会自动发现新 Python 并继续"
  exit 20
fi

echo "ACTION_REQUIRED=open_python_installer"
echo "PYTHON_PKG=$PY_PKG"
echo "HINT=当前会话无法打开图形安装器;请双击该官方已验签安装包,完成后重跑原命令"
exit 20
