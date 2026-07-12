#!/usr/bin/env bash
# esp-idf-cy · 等板子就绪(插线/进下载模式)后自动继续。
#
# 场景:烧录报 "Failed to connect" 或扫不到端口 → agent 先用人话告诉用户怎么操作
# (按住 BOOT → 点按 RESET → 松开 BOOT),然后跑本脚本挂起等待;用户完成操作、
# 端口一出现脚本立即返回候选口。USB 重枚举后端口名可能变,
# agent 必须重验芯片+MAC 与用户确认的设备一致,才能续烧。
#
# 用法: bash wait-port.sh [-t 总超时秒=90] [-i 轮询间隔秒=2] [-p <端口>]
#   -p  等某个特定端口回来(不给则等任意串口出现)
# 退出码: 0=唯一/指定候选口出现  1=超时  3=多端口,需要明确选择  64=参数错误
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

TIMEOUT=90; INTERVAL=2; WANT_PORT=""; WANT_PORT_GIVEN=no
while [ $# -gt 0 ]; do
  case "$1" in
    -t)
      [ $# -ge 2 ] || { echo "ERROR=-t 需要一个非负整数秒数" >&2; exit 64; }
      TIMEOUT="$2"; shift 2 ;;
    -i)
      [ $# -ge 2 ] || { echo "ERROR=-i 需要一个正整数秒数" >&2; exit 64; }
      INTERVAL="$2"; shift 2 ;;
    -p)
      [ $# -ge 2 ] || { echo "ERROR=-p 需要一个端口" >&2; exit 64; }
      WANT_PORT="$2"; WANT_PORT_GIVEN=yes; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 64 ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) echo "ERROR=-t 必须是非负整数: $TIMEOUT" >&2; exit 64 ;;
esac
case "$INTERVAL" in
  ''|*[!0-9]*) echo "ERROR=-i 必须是正整数: $INTERVAL" >&2; exit 64 ;;
esac
[ "${#TIMEOUT}" -le 9 ] || { echo "ERROR=-t 数值过大: $TIMEOUT" >&2; exit 64; }
[ "${#INTERVAL}" -le 9 ] || { echo "ERROR=-i 数值过大: $INTERVAL" >&2; exit 64; }
# 强制十进制,避免 08/09 被 Bash 算术当成非法八进制。
TIMEOUT=$((10#$TIMEOUT))
INTERVAL=$((10#$INTERVAL))
[ "$INTERVAL" -gt 0 ] || { echo "ERROR=-i 必须大于 0" >&2; exit 64; }
[ "$WANT_PORT_GIVEN" = no ] || [ -n "$WANT_PORT" ] \
  || { echo "ERROR=-p 需要一个非空端口" >&2; exit 64; }
[ -z "$WANT_PORT" ] || [ "${WANT_PORT#-}" = "$WANT_PORT" ] \
  || { echo "ERROR=-p 需要一个端口,不能是选项: $WANT_PORT" >&2; exit 64; }

echo "WAITING=board(最多 ${TIMEOUT}s;用户操作完成、端口出现即自动继续)" >&2
elapsed=0
while [ "$elapsed" -le "$TIMEOUT" ]; do
  PORTS="$(list_ports)"
  if [ -n "$PORTS" ]; then
    if [ -z "$WANT_PORT" ] || printf '%s\n' "$PORTS" | awk '{print $2}' | grep -qxF "$WANT_PORT"; then
      printf '%s\n' "$PORTS"
      COUNT="$(printf '%s\n' "$PORTS" | grep -c '^PORT ')"
      echo "PORT_COUNT=$COUNT"
      if [ -n "$WANT_PORT" ]; then
        echo "CANDIDATE_PORT=$WANT_PORT"
      elif [ "$COUNT" -eq 1 ]; then
        echo "CANDIDATE_PORT=$(printf '%s\n' "$PORTS" | awk 'NR==1 {print $2}')"
      else
        echo "AMBIGUOUS=yes"
        echo "REVERIFY_REQUIRED=yes"
        echo "HINT=多个串口存在,不能自动选 BEST_PORT;对候选口重跑 identify-device.sh,匹配已确认 MAC" >&2
        exit 3
      fi
      echo "REVERIFY_REQUIRED=yes"
      echo "WAITED=${elapsed}s"
      exit 0
    fi
  fi
  [ "$elapsed" -ge "$TIMEOUT" ] && break
  remaining=$((TIMEOUT - elapsed))
  sleep_for="$INTERVAL"
  [ "$sleep_for" -le "$remaining" ] || sleep_for="$remaining"
  sleep "$sleep_for"
  elapsed=$((elapsed + sleep_for))
done

echo "TIMEOUT=yes(等了 ${TIMEOUT}s 没有端口出现)"
echo "HINT=让用户确认:①数据线是数据线不是充电线 ②按键顺序:按住 BOOT 不放→点按一下 RESET→松开 BOOT(没有 RESET 键就按住 BOOT 重新插 USB) ③Windows 的 CH340 板子需要驱动" >&2
exit 1
