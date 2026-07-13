#!/usr/bin/env bash
# esp-idf-cy · 安装完成后的严格门控。
#
# 用法: verify-install.sh --version v5.5.4 [--path /path/to/esp-idf]
#
# doctor.sh 保持“信息探针”语义，即 READY=no 时也可以退出 0；本脚本把
# doctor 的机器输出转换为严格的安装判定。只有环境可真实执行、版本匹配，
# 且指定路径时路径也匹配，才返回 0。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_VERSION=""
EXPECTED_PATH=""
EXPECTED_PATH_SET=no

usage() {
  echo "用法: verify-install.sh --version vX.Y.Z [--path /path/to/esp-idf]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --path)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      EXPECTED_PATH="$2"
      EXPECTED_PATH_SET=yes
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 64
      ;;
  esac
done

[ -n "$EXPECTED_VERSION" ] || {
  echo "ERROR=缺少必填参数 --version" >&2
  usage
  exit 64
}
[ "$EXPECTED_PATH_SET" = no ] || [ -n "$EXPECTED_PATH" ] || {
  echo "ERROR=--path 不能为空" >&2
  exit 64
}

if [ "$EXPECTED_PATH_SET" = yes ]; then
  # 精确复检不能继承调用者的旧 IDF_PATH 或项目元数据。专用覆盖仍是唯一
  # 选择依据,这样 EIM 刚安装/修复的路径不会被同版本旧环境冒充。
  DOCTOR_OUT="$(env -u IDF_PATH -u ESP_IDF_CY_PROJECT_DIR \
    ESP_IDF_CY_IDF_PATH="$EXPECTED_PATH" \
    bash "$SCRIPT_DIR/doctor.sh" --no-net 2>&1)"
  DOCTOR_RC=$?
else
  DOCTOR_OUT="$(bash "$SCRIPT_DIR/doctor.sh" --no-net 2>&1)"
  DOCTOR_RC=$?
fi

# 不论验证成败，都保留完整 doctor 输出，便于 agent 继续定位。
printf '%s\n' "$DOCTOR_OUT"

field() {
  printf '%s\n' "$DOCTOR_OUT" | sed -n "s/^$1=//p" | tail -1
}

normalize_version() {
  if printf '%s\n' "$1" | grep -Eq '^v[0-9]+\.[0-9]+$'; then
    printf '%s.0\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

READY="$(field READY)"
FOUND_VERSION="$(field IDF_VER)"
FOUND_PATH="$(field IDF_PATH)"
COMMAND_VERSION="$(field IDF_COMMAND_TAG)"
NORMAL_EXPECTED="$(normalize_version "$EXPECTED_VERSION")"
NORMAL_FOUND="$(normalize_version "$FOUND_VERSION")"
NORMAL_COMMAND="$(normalize_version "$COMMAND_VERSION")"

if [ "$DOCTOR_RC" -ne 0 ]; then
  echo "VERIFY_INSTALL=no"
  echo "VERIFY_REASON=doctor_exit"
  echo "ERROR=doctor.sh 异常退出(rc=$DOCTOR_RC)" >&2
  exit 9
fi

if [ "$READY" != yes ]; then
  echo "VERIFY_INSTALL=no"
  echo "VERIFY_REASON=ready"
  echo "ERROR=安装结束但 ESP-IDF 真命令复检失败(READY=${READY:-missing})" >&2
  exit 9
fi

if [ "$NORMAL_FOUND" != "$NORMAL_EXPECTED" ]; then
  echo "VERIFY_INSTALL=no"
  echo "VERIFY_REASON=version"
  echo "ERROR=复检版本 ${FOUND_VERSION:-missing} 与期望版本 $EXPECTED_VERSION 不一致" >&2
  exit 9
fi

if [ "$NORMAL_COMMAND" != "$NORMAL_EXPECTED" ]; then
  echo "VERIFY_INSTALL=no"
  echo "VERIFY_REASON=command_version"
  echo "ERROR=idf.py --version 报告 ${COMMAND_VERSION:-missing},与期望版本 $EXPECTED_VERSION 不一致" >&2
  exit 9
fi

if [ "$EXPECTED_PATH_SET" = yes ] && [ "$FOUND_PATH" != "$EXPECTED_PATH" ]; then
  echo "VERIFY_INSTALL=no"
  echo "VERIFY_REASON=path"
  echo "ERROR=复检路径 ${FOUND_PATH:-missing} 与期望路径 $EXPECTED_PATH 不一致" >&2
  exit 9
fi

echo "VERIFY_INSTALL=yes"
exit 0
