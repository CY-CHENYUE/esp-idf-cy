#!/usr/bin/env bash
# esp-idf-cy · 环境 wrapper —— 让每条 idf.py/esptool 命令自带 ESP-IDF 环境。
#
# 为什么需要它:export.sh 只对当前 shell 生效,而 agent 的每次 Bash 调用都是新 shell。
# 所以永远不要直接跑 idf.py,一律:
#   bash idf-env.sh idf.py -C <项目目录> build
#   bash idf-env.sh idf.py -C <项目目录> -p <端口> flash
# 项目位置由调用方通过 idf.py -C 传入(或先 cd 到项目目录再调用),wrapper 不做任何假设。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

if [ $# -eq 0 ]; then
  echo "用法: idf-env.sh <命令...>   例: idf-env.sh idf.py -C /path/to/proj build" >&2
  exit 64
fi

find_idf
if [ "$IDF_FOUND" != yes ]; then
  echo "IDF_FOUND=no"
  if [ -n "${DISCOVERY_ERROR:-}" ]; then
    echo "ERROR=$DISCOVERY_ERROR" >&2
  else
    echo "HINT=未找到 ESP-IDF。先跑 bash $SCRIPT_DIR/install.sh 安装;或设 ESP_IDF_CY_IDF_PATH 指向已有安装" >&2
  fi
  exit 2
fi

if [ "$IDF_KIND" = legacy ] \
   && [ -z "${ESP_IDF_CY_IDF_PATH:-}" ] \
   && [ -z "${IDF_PATH:-}" ] \
   && [ -n "$IDF_CANDIDATES" ]; then
  CANDIDATE_COUNT="$(printf '%s\n' "$IDF_CANDIDATES" | tr ';' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  if [ "$CANDIDATE_COUNT" -gt 1 ]; then
    echo "ERROR=找到多个 ESP-IDF,不自动猜版本: $IDF_CANDIDATES" >&2
    echo "HINT=先按项目要求选择,然后设 ESP_IDF_CY_IDF_PATH=<路径> 重跑" >&2
    exit 5
  fi
fi

EIM_BIN="$(find_eim || true)"
if [ "$IDF_KIND" = eim ] && [ -n "$EIM_BIN" ]; then
  # EIM 管理的安装:eim run 自己负责装配环境,无需激活,天然绕开
  # export 脚本和当前 shell 生命周期。显式传 IDF 路径,不依赖 EIM 的
  # selected 项;每个 argv 单独引用,空格路径不丢边界。
  if [ "$OS" = windows ]; then
    # Git Bash 的 /c/... 路径不能直接交给 Windows Python。
    # 转换明确的项目路径参数和已存在的 MSYS 绝对路径。
    NORMALIZED=()
    EXPECT_PATH=no
    for ARG in "$@"; do
      if [ "$EXPECT_PATH" = yes ]; then
        ARG="$(cygpath -w "$ARG" 2>/dev/null || echo "$ARG")"
        EXPECT_PATH=no
      else
        case "$ARG" in
          /[a-zA-Z]/*) [ -e "$ARG" ] && ARG="$(cygpath -w "$ARG" 2>/dev/null || echo "$ARG")" ;;
        esac
      fi
      NORMALIZED+=("$ARG")
      case "$ARG" in -C|--project-dir) EXPECT_PATH=yes ;; esac
    done
    set -- "${NORMALIZED[@]}"
  fi
  CMD_STRING="$(eim_command_string "$@")" || exit $?
  if [ "$OS" = windows ]; then
    # Windows 额外经过固定 PowerShell helper 复验 Authenticode,并隔离 MSYS。
    EIM_HELPER="$SCRIPT_DIR/eim-windows.ps1"
    EIM_HELPER_WIN="$(cygpath -w "$EIM_HELPER" 2>/dev/null || echo "$EIM_HELPER")"
    EIM_BIN_WIN="$(cygpath -w "$EIM_BIN" 2>/dev/null || echo "$EIM_BIN")"
    FOUND_IDF_PATH_WIN="$(cygpath -w "$FOUND_IDF_PATH" 2>/dev/null || echo "$FOUND_IDF_PATH")"
    ps_file "$EIM_HELPER_WIN" RunIdf -EimPath "$EIM_BIN_WIN" \
      -CommandString "$CMD_STRING" -IdfPath "$FOUND_IDF_PATH_WIN"
    exit $?
  fi
  # macOS/Linux 的 EIM 是原生可执行文件,不需要也不能调用 Windows helper。
  exec "$EIM_BIN" --do-not-track true run "$CMD_STRING" "$FOUND_IDF_PATH"
fi

case "$OS" in
  mac|linux)
    export IDF_PATH="$FOUND_IDF_PATH"
    _out="$(mktemp)"
    set +u  # export.sh 内部会引用未定义变量,不能带 -u source
    if . "$IDF_PATH/export.sh" >"$_out" 2>&1; then
      set -u
      rm -f "$_out"
      exec "$@"
    else
      set -u
      echo "EXPORT_FAILED=yes"
      cat "$_out" >&2; rm -f "$_out"
      echo "HINT=export.sh 失败。最常见原因:python venv 失效(系统 python 升级过)→ 重跑 bash $SCRIPT_DIR/install.sh 会重建 venv" >&2
      exit 3
    fi
    ;;
  windows)
    # legacy 安装 + 没有 eim:实验性兜底。官方不支持 Git Bash,必须清 MSYSTEM 后交给 cmd.exe。
    _idf_win="$(cygpath -w "$FOUND_IDF_PATH")"
    _cmd="$(eim_command_string "$@")" || exit $?
    echo "WARN=Windows legacy 激活为实验性路径,推荐安装 EIM(bash $SCRIPT_DIR/install.sh 会自动装)" >&2
    exec env -u MSYSTEM cmd.exe //d //s //c "call \"${_idf_win}\\export.bat\" >NUL 2>&1 && $_cmd"
    ;;
  *)
    echo "ERROR=不支持的平台 $OS" >&2
    exit 1
    ;;
esac
