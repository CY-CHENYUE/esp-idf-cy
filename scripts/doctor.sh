#!/usr/bin/env bash
# esp-idf-cy · 环境体检。每次 skill 触发先跑这个(Step 0),输出机器可读的 KEY=VALUE。
# 用法: bash doctor.sh [--no-net](跳过联网探测,更快)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

SKIP_NET=no
while [ $# -gt 0 ]; do
  case "$1" in
    --no-net) SKIP_NET=yes; shift ;;
    *) echo "ERROR=未知参数: $1" >&2; exit 64 ;;
  esac
done

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
  MIN_PY="$(idf_min_python "$IDF_VER")"
  if [ -n "$PY_VER" ] && version_ge "$PY_VER" "$MIN_PY"; then
    echo "HOST_PYTHON_OK=yes"
  else
    echo "HOST_PYTHON_OK=no(安装/修复 $IDF_VER 时需要>=$MIN_PY)"
  fi

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
if [ "$IDF_FOUND" = yes ] && [ "${IDF_CHECK_RC:-1}" -eq 0 ]; then
  echo "READY=yes"
else
  echo "READY=no"
  if [ "$IDF_FOUND" = yes ]; then
    echo "HINT=找到 ESP-IDF 但真命令验证失败;先看 IDF_COMMAND_ERROR,常见原因是 venv/工具链失效,可用 install.sh 修复" >&2
  else
    if [ -n "${DISCOVERY_ERROR:-}" ]; then
      echo "HINT=$DISCOVERY_ERROR;显式覆盖不会回退到其他安装" >&2
    else
      echo "HINT=未找到 ESP-IDF,运行 install.sh 自动安装;若装在了非常规位置,设 ESP_IDF_CY_IDF_PATH 指过去" >&2
    fi
  fi
fi
