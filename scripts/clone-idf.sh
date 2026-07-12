#!/usr/bin/env bash
# 在目标目录的同级受管暂存区克隆，完整成功后再原子落位。
# 这样首次 clone 被中断时可安全重跑，同时绝不删除目标路径里的未知用户文件。
set -u

DESTINATION=""
VERSION=""
PRIMARY=""
FALLBACK=""
REWRITE_FROM=""
REWRITE_TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --destination|--version|--primary|--fallback|--rewrite-from|--rewrite-to)
      [ $# -ge 2 ] || { echo "ERROR=$1 缺少参数值" >&2; exit 64; }
      case "$1" in
        --destination) DESTINATION="$2" ;;
        --version) VERSION="$2" ;;
        --primary) PRIMARY="$2" ;;
        --fallback) FALLBACK="$2" ;;
        --rewrite-from) REWRITE_FROM="$2" ;;
        --rewrite-to) REWRITE_TO="$2" ;;
      esac
      shift 2
      ;;
    *) echo "ERROR=未知参数: $1" >&2; exit 64 ;;
  esac
done

[ -n "$DESTINATION" ] && [ -n "$VERSION" ] && [ -n "$PRIMARY" ] || {
  echo "ERROR=必须提供 --destination、--version、--primary" >&2
  exit 64
}
if { [ -n "$REWRITE_FROM" ] && [ -z "$REWRITE_TO" ]; } \
  || { [ -z "$REWRITE_FROM" ] && [ -n "$REWRITE_TO" ]; }; then
  echo "ERROR=--rewrite-from 与 --rewrite-to 必须成对提供" >&2
  exit 64
fi
if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
  echo "ERROR=目标已存在,拒绝覆盖: $DESTINATION" >&2
  exit 8
fi

GIT_BIN="${ESP_IDF_CY_GIT_BIN:-git}"
STAGE="${DESTINATION}.esp-idf-cy-partial"
MARKER="$STAGE/.managed-by-esp-idf-cy"
REPO="$STAGE/repo"
EXPECTED_MARKER="managed_by=esp-idf-cy
destination=$DESTINATION
version=$VERSION"

if [ -e "$STAGE" ] || [ -L "$STAGE" ]; then
  if [ -d "$STAGE" ] && [ ! -L "$STAGE" ] \
    && [ -f "$MARKER" ] && [ ! -L "$MARKER" ] \
    && [ "$(sed -n '1,3p' "$MARKER")" = "$EXPECTED_MARKER" ]; then
    echo "INFO=清理上次中断的受管克隆暂存区: $STAGE" >&2
    rm -rf "$STAGE"
  else
    echo "ERROR=暂存路径已存在但不属于本次安装,拒绝删除: $STAGE" >&2
    exit 8
  fi
fi

mkdir -p "$STAGE" || exit 6
printf '%s\n' "$EXPECTED_MARKER" >"$MARKER"

clone_one() {
  local url="$1"
  "$GIT_BIN" clone -b "$VERSION" "$url" "$REPO"
}

if ! clone_one "$PRIMARY"; then
  if [ -z "$FALLBACK" ]; then
    echo "ERROR=克隆失败;受管暂存区已保留,重跑会自动清理后重试" >&2
    exit 6
  fi
  echo "INFO=主镜像失败,清理受管 repo 后尝试备用镜像" >&2
  rm -rf "$REPO"
  clone_one "$FALLBACK" || {
    echo "ERROR=主镜像与备用镜像均失败;重跑会安全重试" >&2
    exit 6
  }
fi

[ -f "$REPO/tools/idf.py" ] || {
  echo "ERROR=clone 返回成功但产物不是完整 ESP-IDF" >&2
  exit 6
}
if [ -n "$REWRITE_FROM" ]; then
  "$GIT_BIN" -C "$REPO" config "url.${REWRITE_TO}.insteadOf" "$REWRITE_FROM" || exit 6
fi

# STAGE 与 DESTINATION 同级，mv 在同一文件系统内完成；最终路径不会暴露半成品。
mv "$REPO" "$DESTINATION" || exit 6
rm -rf "$STAGE"
echo "CLONE_READY=yes"
echo "IDF_PATH=$DESTINATION"
