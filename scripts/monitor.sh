#!/usr/bin/env bash
# esp-idf-cy · 非交互串口采集。不调 `idf.py monitor`:官方 monitor 必须绑定 TTY。
#
# 原理:在 IDF 环境内用 pyserial 直接读口,超时会自动退出;正则在可终止子进程中有界匹配。
#
# 用法: bash monitor.sh -p <端口> [-C <项目目录>] [-b <波特率>] [-t <秒,默认30>] [-e <expect正则>] [-R]
#   -e  等到串口输出匹配该正则就成功退出(退出码 0);不给则只采集 -t 秒日志
#   -R  监视前先复位板子(重新跑固件,从头看启动日志)
#   -t  最长等待秒数;expect 未匹配到超时 → rc=1
# 退出码:1=expect 超时 2=打开串口失败 3=读取失败 4=缺 pyserial 64=参数错误
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PORT="" ; PROJ="" ; BAUD="" ; SECS=30 ; EXPECT="" ; DO_RESET=no
while [ $# -gt 0 ]; do
  case "$1" in
    -p|-C|-b|-t|-e)
      OPT="$1"
      [ $# -ge 2 ] || { echo "ERROR=$OPT 需要一个值" >&2; exit 64; }
      VALUE="$2"
      [ -n "$VALUE" ] || { echo "ERROR=$OPT 需要一个非空值" >&2; exit 64; }
      case "$VALUE" in
        -p|-C|-b|-t|-e|-R) echo "ERROR=$OPT 缺少值,不能把选项 $VALUE 当作值" >&2; exit 64 ;;
      esac
      case "$OPT" in
        -p) PORT="$VALUE" ;;
        -C) PROJ="$VALUE" ;;
        -b) BAUD="$VALUE" ;;
        -t) SECS="$VALUE" ;;
        -e) EXPECT="$VALUE" ;;
      esac
      shift 2 ;;
    -R) DO_RESET=yes; shift ;;
    *) echo "未知参数: $1" >&2; exit 64 ;;
  esac
done
if [ -z "$PORT" ]; then
  echo "用法: monitor.sh -p <端口> [-C <项目目录>] [-b 波特率] [-t 秒] [-e expect正则] [-R]" >&2
  exit 64
fi
[ "${PORT#-}" = "$PORT" ] || { echo "ERROR=-p 需要一个端口,不能是选项: $PORT" >&2; exit 64; }
if ! printf '%s\n' "$SECS" | awk '
  BEGIN { ok = 0 }
  /^[0-9]+([.][0-9]+)?$/ { if ($0 + 0 > 0) ok = 1 }
  END { exit(ok ? 0 : 1) }
'; then
  echo "ERROR=-t 必须是大于 0 的有限秒数: $SECS" >&2
  exit 64
fi
if [ -n "$BAUD" ]; then
  case "$BAUD" in
    ''|*[!0-9]*) echo "ERROR=-b 必须是正整数: $BAUD" >&2; exit 64 ;;
  esac
  BAUD=$((10#$BAUD))
  [ "$BAUD" -gt 0 ] || { echo "ERROR=-b 必须大于 0" >&2; exit 64; }
fi

PY_SCRIPT="$SCRIPT_DIR/serial_monitor.py"
if [ "$OS" = windows ]; then
  PY_SCRIPT="$(cygpath -w "$PY_SCRIPT")"
  [ -n "$PROJ" ] && PROJ="$(cygpath -w "$PROJ")"
fi

ARGS=(python "$PY_SCRIPT" --port "$PORT" --timeout "$SECS")
[ -n "$PROJ" ] && ARGS+=(--project "$PROJ")
[ -n "$BAUD" ] && ARGS+=(--baud "$BAUD")
[ -n "$EXPECT" ] && ARGS+=(--expect "$EXPECT")
[ "$DO_RESET" = yes ] && ARGS+=(--reset)

bash "$SCRIPT_DIR/idf-env.sh" "${ARGS[@]}"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "MONITOR_RC=$rc" >&2
  case "$rc" in
    1) echo "HINT=没等到 '$EXPECT'。①手动下载后按 RESET ②重跑 find-port.sh 并重验设备 MAC ③检查波特率和正则" >&2 ;;
    2) echo "HINT=串口无法打开;检查端口是否仍存在、是否被其他 monitor 占用以及当前用户权限" >&2 ;;
    3) echo "HINT=串口已打开但读取失败;设备可能断开或 USB 正在重枚举,请重扫并重验 MAC" >&2 ;;
    4) echo "HINT=当前 ESP-IDF Python 环境缺 pyserial;先修复该 IDF 环境,这不是 expect 超时" >&2 ;;
    64) echo "HINT=参数或 expect 正则不安全/无效;简化模式,避免量词嵌套和过长表达式" >&2 ;;
  esac
fi
exit "$rc"
