#!/usr/bin/env bash
# esp-idf-cy · 可选环境全景探针，输出机器可读的 KEY=VALUE；Agent也可按现场逐项取证。
# 用法: bash doctor.sh [--no-net] [--project <项目目录>]
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

SKIP_NET=no
PROJECT_DIR=""
PROJECT_CHECK_OK=yes
while [ $# -gt 0 ]; do
  case "$1" in
    --no-net) SKIP_NET=yes; shift ;;
    --project)
      [ $# -ge 2 ] || { echo "ERROR=--project 缺少路径" >&2; exit 64; }
      PROJECT_DIR="$(normalize_shell_path "$2")"; shift 2 ;;
    *) echo "ERROR=未知参数: $1" >&2; exit 64 ;;
  esac
done

if [ -n "$PROJECT_DIR" ]; then
  if [ -d "$PROJECT_DIR" ]; then PROJECT_DIR="$(canonical_existing_dir "$PROJECT_DIR")"; fi
  echo "PROJECT_DIR=$PROJECT_DIR"
  if [ ! -d "$PROJECT_DIR" ]; then
    echo "PROJECT_READY=no"
    echo "PROJECT_ERROR=项目目录不存在" >&2
    PROJECT_CHECK_OK=no
  elif path_has_whitespace "$PROJECT_DIR"; then
    echo "PROJECT_READY=no"
    echo "PROJECT_ERROR=ESP-IDF 不支持项目路径包含空白" >&2
    PROJECT_CHECK_OK=no
  elif [ ! -f "$PROJECT_DIR/CMakeLists.txt" ]; then
    echo "PROJECT_READY=no"
    echo "PROJECT_ERROR=缺少顶层 CMakeLists.txt" >&2
    PROJECT_CHECK_OK=no
  else
    echo "PROJECT_READY=yes"
  fi
  export ESP_IDF_CY_PROJECT_DIR="$PROJECT_DIR"
fi

echo "OS=$OS"

# 基础工具
if have git; then echo "GIT=yes $(git --version 2>/dev/null | awk '{print $3}')"; else echo "GIT=no"; fi
PY_BIN="$(find_python || true)"
PY_VER="$(python_version || true)"
if [ -n "$PY_BIN" ]; then echo "PYTHON=$PY_BIN $PY_VER"; else echo "PYTHON=no"; fi

# macOS 前置:Xcode Command Line Tools(git 都依赖它)
if [ "$OS" = mac ]; then
  if xcode-select -p >/dev/null 2>&1; then echo "XCODE_CLT=yes"; else echo "XCODE_CLT=no"; fi
fi

# EIM(官方新一代安装管理器)
EIM_BIN="$(find_eim || true)"
if [ -n "$EIM_BIN" ]; then
  if [ "$OS" = windows ]; then
    # 候选 exe 在真正执行前由 eim-windows.ps1 做 Authenticode 验证。
    echo "EIM=yes $EIM_BIN TRUST=verified-on-use"
  else
    echo "EIM=yes $EIM_BIN $("$EIM_BIN" --version 2>/dev/null | head -1)"
  fi
else
  echo "EIM=no"
fi

# IDF 探测
find_idf
if [ -n "${DISCOVERY_ERROR:-}" ]; then echo "DISCOVERY_ERROR=$DISCOVERY_ERROR"; fi
echo "IDF_FOUND=$IDF_FOUND"
if [ "$IDF_FOUND" = yes ]; then
  echo "IDF_KIND=$IDF_KIND"
  echo "IDF_PATH=$FOUND_IDF_PATH"
  echo "IDF_VER=$IDF_VER"
  [ -n "$IDF_CANDIDATES" ] && echo "IDF_CANDIDATES=$IDF_CANDIDATES"
  # 宿主 python 版本只是线索;EIM/已安装 IDF 可能使用自己的 python。
  case "$IDF_VER" in
    v3.*|v4.*|v5.*|v6.*|3.*|4.*|5.*|6.*)
      MIN_PY="$(idf_min_python "$IDF_VER")"
      echo "PYTHON_MIN_REQUIRED=$MIN_PY"
      if [ -n "$PY_VER" ] && version_ge "$PY_VER" "$MIN_PY"; then
        echo "HOST_PYTHON_OK=yes"
      else
        echo "HOST_PYTHON_OK=no(安装/修复 $IDF_VER 时需要>=$MIN_PY)"
      fi
      ;;
    *)
      # READY 仍由该安装自己的真 idf.py 命令决定,但未知 major 的安装/修复
      # 前置不能沿用 lib.sh 的旧版本兜底值并误报 Python 3.8 足够。
      echo "PYTHON_MIN_REQUIRED=unknown"
      echo "HOST_PYTHON_OK=unknown(需读取 $FOUND_IDF_PATH 的当前官方约束)"
      ;;
  esac

  # READY 必须由真命令证明,不能只看 tools/idf.py 文件存在。
  IDF_CHECK_OUT="$(bash "$SCRIPT_DIR/idf-env.sh" idf.py --version 2>&1)"
  IDF_CHECK_RC=$?
  if [ "$IDF_CHECK_RC" -eq 0 ]; then
    echo "IDF_COMMAND_OK=yes"
    echo "IDF_COMMAND_VERSION=$(printf '%s\n' "$IDF_CHECK_OUT" | tail -1)"
    IDF_COMMAND_TAG="$(printf '%s\n' "$IDF_CHECK_OUT" \
      | sed -n 's/.*ESP-IDF[[:space:]][[:space:]]*\(v[0-9][0-9.]*\).*/\1/p' | tail -1)"
    if [ -n "$IDF_COMMAND_TAG" ]; then
      echo "IDF_COMMAND_TAG=$IDF_COMMAND_TAG"
    else
      echo "IDF_COMMAND_TAG=unknown"
    fi
  else
    echo "IDF_COMMAND_OK=no"
    echo "IDF_COMMAND_RC=$IDF_CHECK_RC"
    echo "IDF_COMMAND_ERROR=$(printf '%s\n' "$IDF_CHECK_OUT" | tail -5 | tr '\n' '|' | sed 's/|$//')"
  fi
fi

# 串口
PORTS="$(list_ports)"
if [ -n "$PORTS" ]; then
  printf '%s\n' "$PORTS"
  PORT_COUNT="$(printf '%s\n' "$PORTS" | grep -c '^PORT ')"
  echo "PORT_COUNT=$PORT_COUNT"
  if [ "$PORT_COUNT" -eq 1 ]; then
    echo "CANDIDATE_PORT=$(printf '%s\n' "$PORTS" | awk 'NR==1 {print $2}')"
  else
    echo "PORT_SELECTION=required(多设备需读芯片+MAC)"
  fi
else
  echo "PORT_COUNT=0"
fi

# 网络(装机/更新前需要;已装好只跑编译可用 --no-net 跳过)
if [ "$SKIP_NET" = yes ]; then
  echo "NET=skipped"
else
  echo "NET=$(check_network)"
fi

# 结论
if [ "$IDF_FOUND" = yes ] && [ "${IDF_CHECK_RC:-1}" -eq 0 ] && [ "$PROJECT_CHECK_OK" = yes ]; then
  echo "READY=yes"
else
  echo "READY=no"
  if [ "$IDF_FOUND" = yes ]; then
    echo "HINT=找到 ESP-IDF 但真命令验证失败;先看 IDF_COMMAND_ERROR,常见原因是 venv/工具链失效,可用 install.sh 修复" >&2
  else
    if [ -n "${DISCOVERY_ERROR:-}" ]; then
      echo "HINT=$DISCOVERY_ERROR;显式覆盖不会回退到其他安装" >&2
    else
      echo "HINT=未找到 ESP-IDF;先结合项目 build/project_description.json、EIM 登记和 IDE 设置做有界发现,确认确实没有后再安装;非常规位置可设 ESP_IDF_CY_IDF_PATH" >&2
    fi
  fi
fi
