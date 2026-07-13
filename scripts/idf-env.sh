#!/usr/bin/env bash
# esp-idf-cy · 环境 wrapper —— 让每条 idf.py/esptool 命令自带 ESP-IDF 环境。
#
# 为什么需要它:export.sh 只对当前 shell 生效,而 agent 的每次 Bash 调用都是新 shell。
# 所以不能在未装配环境时裸跑 idf.py。需要统一免激活入口时可用:
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

PROJECT_DIR="$(project_dir_from_args "$@" || true)"
if [ -n "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(normalize_shell_path "$PROJECT_DIR")"
  [ -d "$PROJECT_DIR" ] || { echo "ERROR=项目目录不存在: $PROJECT_DIR" >&2; exit 2; }
  PROJECT_DIR="$(canonical_existing_dir "$PROJECT_DIR")"
  if path_has_whitespace "$PROJECT_DIR"; then
    echo "ERROR=ESP-IDF 官方构建系统不支持项目路径包含空白: $PROJECT_DIR" >&2
    echo "HINT=不要只加引号后重试;请让 Agent 在用户目录/磁盘上选择无空格路径,经确认迁移或建立受管工作副本" >&2
    exit 8
  fi
  export ESP_IDF_CY_PROJECT_DIR="$PROJECT_DIR"
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

CANONICAL_IDF_PATH="$(canonical_existing_dir "$FOUND_IDF_PATH" || printf '%s\n' "$FOUND_IDF_PATH")"
if path_has_whitespace "$CANONICAL_IDF_PATH"; then
  echo "ERROR=ESP-IDF 官方构建系统不支持 IDF 安装路径包含空白: $FOUND_IDF_PATH" >&2
  echo "HINT=选择无空格的 IDF 安装位置;不要用 shell 引号掩盖上游构建限制" >&2
  exit 8
fi

if [ "$IDF_KIND" = legacy ] \
   && [ "${IDF_SELECTED_BY_PROJECT:-no}" != yes ] \
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
  # selected 项。真实 argv 写入私有 NUL 文件,EIM 只解释固定 launcher。
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
          --project-dir=*|--build-dir=*)
            _path_value="${ARG#*=}"
            _path_value="$(cygpath -w "$_path_value" 2>/dev/null || echo "$_path_value")"
            ARG="${ARG%%=*}=$_path_value"
            ;;
          /[a-zA-Z]/*) [ -e "$ARG" ] && ARG="$(cygpath -w "$ARG" 2>/dev/null || echo "$ARG")" ;;
        esac
      fi
      NORMALIZED+=("$ARG")
      case "$ARG" in -C|-B|--project-dir|--build-dir) EXPECT_PATH=yes ;; esac
    done
    set -- "${NORMALIZED[@]}"
  fi

  EIM_JSON_DIR="$(eim_json_dir)" || exit $?
  ARGV_FILE="$(write_secure_argv_file "$@")" || exit $?
  cleanup_eim_argv() { rm -f "$ARGV_FILE"; }
  trap cleanup_eim_argv EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [ "$OS" = windows ]; then
    # Windows 额外经过固定 PowerShell helper 复验 Authenticode,并隔离 MSYS。
    EIM_HELPER="$SCRIPT_DIR/eim-windows.ps1"
    EIM_HELPER_WIN="$(cygpath -w "$EIM_HELPER" 2>/dev/null || echo "$EIM_HELPER")"
    EIM_BIN_WIN="$(cygpath -w "$EIM_BIN" 2>/dev/null || echo "$EIM_BIN")"
    FOUND_IDF_PATH_WIN="$(cygpath -w "$FOUND_IDF_PATH" 2>/dev/null || echo "$FOUND_IDF_PATH")"
    RUNNER_WIN="$(cygpath -w "$SCRIPT_DIR/eim-argv-runner.py" 2>/dev/null || echo "$SCRIPT_DIR/eim-argv-runner.py")"
    ARGV_FILE_WIN="$(cygpath -w "$ARGV_FILE" 2>/dev/null || echo "$ARGV_FILE")"
    EIM_JSON_DIR_WIN="$(cygpath -w "$EIM_JSON_DIR" 2>/dev/null || echo "$EIM_JSON_DIR")"
    ps_file "$EIM_HELPER_WIN" RunIdf -EimPath "$EIM_BIN_WIN" \
      -RunnerPath "$RUNNER_WIN" -ArgvFile "$ARGV_FILE_WIN" -IdfPath "$FOUND_IDF_PATH_WIN" \
      -EspIdfJsonPath "$EIM_JSON_DIR_WIN"
    exit $?
  fi
  # macOS/Linux 的 EIM 是原生可执行文件,不需要也不能调用 Windows helper。
  export ESP_IDF_CY_RUNNER="$SCRIPT_DIR/eim-argv-runner.py"
  export ESP_IDF_CY_ARGV_FILE="$ARGV_FILE"
  "$EIM_BIN" --do-not-track true --esp-idf-json-path "$EIM_JSON_DIR" \
    run "$(eim_posix_run_command)" "$FOUND_IDF_PATH"
  exit $?
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
    _argv_file="$(write_secure_argv_file "$@")" || exit $?
    cleanup_legacy_argv() { rm -f "$_argv_file"; }
    trap cleanup_legacy_argv EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    export ESP_IDF_CY_EXPORT_BAT="${_idf_win}\\export.bat"
    export ESP_IDF_CY_RUNNER="$(cygpath -w "$SCRIPT_DIR/eim-argv-runner.py" 2>/dev/null || echo "$SCRIPT_DIR/eim-argv-runner.py")"
    export ESP_IDF_CY_ARGV_FILE="$(cygpath -w "$_argv_file" 2>/dev/null || echo "$_argv_file")"
    _cmd='call "%ESP_IDF_CY_EXPORT_BAT%" >NUL 2>&1 && '
    _cmd="${_cmd}$(eim_cmd_run_command)"
    echo "WARN=Windows legacy 激活为实验性路径,推荐安装 EIM(bash $SCRIPT_DIR/install.sh 会自动装)" >&2
    env -u MSYSTEM cmd.exe //d //s //c "$_cmd"
    exit $?
    ;;
  *)
    echo "ERROR=不支持的平台 $OS" >&2
    exit 1
    ;;
esac
