#!/usr/bin/env bash
# esp-idf-cy · 串口探测。烧录/监视前必跑 —— 端口名不可缓存:
# ESP32-S3 原生 USB 在复位/烧录前后会断开重枚举,macOS 上 usbmodem 序号可能变化。
# 输出: 每个候选一行 "PORT <设备> <描述>"。单口给 CANDIDATE_PORT;多口只报 AMBIGUOUS。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PORTS="$(list_ports)"
if [ -z "$PORTS" ]; then
  echo "PORT_COUNT=0"
  case "$OS" in
    mac)     echo "HINT=没扫到串口。检查:①板子插了吗/换根数据线(有的线只供电) ②CH340 板子要装 WCH 驱动且需 V1.7+ 支持 Apple Silicon ③若刚烧完固件端口消失,可能是固件重配了 USB 引脚——按住 BOOT 再点按 RESET 进下载模式" >&2 ;;
    linux)   echo "HINT=没扫到串口。检查:①板子/数据线 ②权限: sudo usermod -a -G dialout \$USER 后重新登录 ③Ubuntu 的 brltty 会抢占 CH340,可卸载" >&2 ;;
    windows) echo "HINT=没扫到 COM 口。检查:①板子/数据线 ②CH340 板子装 WCH CH341SER 驱动(全新 Win10/11 常不自带) ③S3 原生 USB 口 Win10+ 免驱,插上就该有" >&2 ;;
  esac
  exit 1
fi

printf '%s\n' "$PORTS"
COUNT="$(printf '%s\n' "$PORTS" | grep -c '^PORT ')"
echo "PORT_COUNT=$COUNT"
if [ "$COUNT" -eq 1 ]; then
  echo "CANDIDATE_PORT=$(printf '%s\n' "$PORTS" | awk 'NR==1 {print $2}')"
else
  echo "AMBIGUOUS=yes"
  echo "HINT=多串口不自动选;逐个读芯片+MAC,由用户确认要写的设备" >&2
fi
