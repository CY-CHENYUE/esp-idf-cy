#!/usr/bin/env bash
# esp-idf-cy · 连接设备验身:输出 CHIP/MAC,用于烧录确认和 USB 重枚举后身份匹配。
# 用法: bash identify-device.sh -p <端口>
# 注意:esptool 连接过程会复位芯片,但不写 flash。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port)
      [ $# -ge 2 ] || { echo "ERROR=$1 需要一个端口" >&2; exit 64; }
      PORT="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 64 ;;
  esac
done
[ -n "$PORT" ] || { echo "用法: identify-device.sh -p <端口>" >&2; exit 64; }
[ "${PORT#-}" = "$PORT" ] || { echo "ERROR=-p 需要一个端口,不能是选项: $PORT" >&2; exit 64; }

VERSION_OUT="$(bash "$SCRIPT_DIR/idf-env.sh" python -m esptool version 2>&1)"
VERSION_RC=$?
if [ "$VERSION_RC" -ne 0 ]; then
  echo "ERROR=无法获取 esptool 版本" >&2
  printf '%s\n' "$VERSION_OUT" >&2
  exit 2
fi
MAJOR="$(printf '%s\n' "$VERSION_OUT" | sed -nE 's/.*v?([0-9]+)\.[0-9]+.*/\1/p' | head -1)"
[ -n "$MAJOR" ] || MAJOR=4

if [ "$MAJOR" -ge 5 ]; then
  CHIP_CMD=chip-id
  MAC_CMD=read-mac
else
  CHIP_CMD=chip_id
  MAC_CMD=read_mac
fi

CHIP_OUT="$(bash "$SCRIPT_DIR/idf-env.sh" python -m esptool -p "$PORT" "$CHIP_CMD" 2>&1)"
CHIP_RC=$?
if [ "$CHIP_RC" -ne 0 ]; then
  echo "ERROR=无法连接设备 $PORT" >&2
  printf '%s\n' "$CHIP_OUT" >&2
  exit 3
fi

MAC="$(printf '%s\n' "$CHIP_OUT" | sed -nE 's/.*MAC[^0-9A-Fa-f]*(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}).*/\1/p' | head -1)"
if [ -z "$MAC" ]; then
  MAC_OUT="$(bash "$SCRIPT_DIR/idf-env.sh" python -m esptool -p "$PORT" "$MAC_CMD" 2>&1)"
  MAC_RC=$?
  if [ "$MAC_RC" -ne 0 ]; then
    echo "ERROR=连接成功但无法读取 MAC" >&2
    printf '%s\n' "$MAC_OUT" >&2
    exit 4
  fi
  MAC="$(printf '%s\n' "$MAC_OUT" | sed -nE 's/.*(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}).*/\1/p' | head -1)"
fi
CHIP="$(printf '%s\n' "$CHIP_OUT" | sed -nE 's/.*Chip is ([^(]+).*/\1/p' | head -1 | sed 's/[[:space:]]*$//')"
[ -n "$MAC" ] || { echo "ERROR=未能从 esptool 输出解析 MAC" >&2; exit 4; }
[ -n "$CHIP" ] || {
  echo "CHIP=unknown"
  echo "ERROR=连接成功但未能从 esptool 输出解析芯片型号;拒绝把不完整身份当作成功" >&2
  printf '%s\n' "$CHIP_OUT" >&2
  exit 5
}

echo "PORT=$PORT"
echo "CHIP=$CHIP"
echo "MAC=$(printf '%s' "$MAC" | tr '[:lower:]' '[:upper:]')"
