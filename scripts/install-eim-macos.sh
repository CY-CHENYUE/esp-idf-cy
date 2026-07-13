#!/usr/bin/env bash
# esp-idf-cy · macOS EIM CLI 安装边界。
#
# 优先复用已有 EIM；已有 Homebrew 时按乐鑫当前官方清单补齐 POSIX 前置，
# 并按需安装 EIM CLI。两者都没有时不静默安装新的长期系统包管理器。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
. "$SCRIPT_DIR/eim-registry.sh"

VERSION=""
TARGETS="all"
TARGETS_EXPLICIT=no
NET="global"
REPAIR_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version|--targets|--net|--repair-path)
      [ $# -ge 2 ] || { echo "ERROR=$1 缺少参数值" >&2; exit 64; }
      case "$1" in
        --version) VERSION="$2" ;;
        --targets) TARGETS="$2"; TARGETS_EXPLICIT=yes ;;
        --net) NET="$2" ;;
        --repair-path) REPAIR_PATH="$2" ;;
      esac
      shift 2 ;;
    *) echo "ERROR=未知参数: $1" >&2; exit 64 ;;
  esac
done

[ "$OS" = mac ] || { echo "ERROR=install-eim-macos.sh 只支持 macOS" >&2; exit 64; }
[ -n "$VERSION" ] || { echo "ERROR=必须提供 --version" >&2; exit 64; }
printf '%s\n' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "ERROR=macOS EIM 安装边界只接受已解析的精确 tag: $VERSION" >&2
  exit 64
}
case "$NET" in global|cn) ;; *) echo "ERROR=--net 只能是 global/cn" >&2; exit 64 ;; esac

EIM_BIN=""
FIND_RC=0
EIM_BIN="$(find_eim 2>/dev/null)"; FIND_RC=$?
if [ "$FIND_RC" -eq 64 ]; then
  find_eim >/dev/null
  exit 7
fi

BREW_BIN="${ESP_IDF_CY_BREW_BIN:-}"
if [ -z "$BREW_BIN" ] && have brew; then BREW_BIN="$(command -v brew)"; fi
[ -n "$BREW_BIN" ] && [ -x "$BREW_BIN" ] || BREW_BIN=""
if [ -z "$EIM_BIN" ] && [ -z "$BREW_BIN" ]; then
  echo "ACTION_REQUIRED=choose_homebrew_or_official_script_route"
  echo "ERROR=未找到 EIM 或 Homebrew;Skill 不会静默安装新的系统包管理器" >&2
  exit 20
fi

EXACT_PATH=""
RESOLVE_RC=0
ACTION=""
resolve_eim_action() {
  EXACT_PATH="$(eim_exact_idf_path "$VERSION" "$REPAIR_PATH")"; RESOLVE_RC=$?
  case "$RESOLVE_RC" in
    0)
      if env -u IDF_PATH -u ESP_IDF_CY_PROJECT_DIR \
        ESP_IDF_CY_IDF_PATH="$EXACT_PATH" ESP_IDF_CY_EIM_BIN="$EIM_BIN" \
        bash "$SCRIPT_DIR/verify-install.sh" --version "$VERSION" --path "$EXACT_PATH" \
        >/dev/null 2>&1; then
        ACTION=reuse
        echo "STEP=EIM 登记中的 $VERSION 已健康,复用精确路径"
      else
        ACTION=repair
        echo "STEP=EIM 登记中的 $VERSION 已损坏,修复精确路径"
      fi
      ;;
    10)
      [ -z "$REPAIR_PATH" ] || {
        echo "ERROR=--repair-path 指定的 $VERSION 不在 EIM 登记中;拒绝改成新安装" >&2
        return 8
      }
      ACTION=install
      ;;
    *) return 8 ;;
  esac
}

# 健康安装在任何包管理动作之前直接复用；`brew install` 不是体检步骤。
if [ -n "$EIM_BIN" ]; then
  resolve_eim_action || exit $?
  if [ "$ACTION" = reuse ]; then
    echo "INSTALL_ROUTE=mac-eim"
    echo "EIM_BIN=$EIM_BIN"
    echo "EIM_ACTION=$ACTION"
    echo "EIM_IDF_PATH=$EXACT_PATH"
    exit 0
  fi
fi

if [ -n "$BREW_BIN" ]; then
  echo "STEP=用现有 Homebrew 补齐乐鑫官方 macOS EIM 前置"
  "$BREW_BIN" install libgcrypt glib pixman sdl2 libslirp dfu-util cmake python || {
    echo "ERROR=Homebrew 安装 macOS EIM/ESP-IDF 前置失败" >&2
    exit 7
  }
else
  echo "INFO=没有 Homebrew;复用现有 EIM 并由 EIM 校验 POSIX 前置"
fi

if [ -z "$EIM_BIN" ]; then
  echo "STEP=通过乐鑫 Homebrew tap 安装 EIM CLI"
  "$BREW_BIN" tap espressif/eim || { echo "ERROR=添加 espressif/eim tap 失败" >&2; exit 7; }
  "$BREW_BIN" install eim || { echo "ERROR=Homebrew 安装 EIM CLI 失败" >&2; exit 7; }
  BREW_PREFIX="$($BREW_BIN --prefix 2>/dev/null || true)"
  for CANDIDATE in "${BREW_PREFIX:+$BREW_PREFIX/bin/eim}" /opt/homebrew/bin/eim /usr/local/bin/eim; do
    [ -n "$CANDIDATE" ] && validate_eim_candidate "$CANDIDATE" \
      && { EIM_BIN="$CANDIDATE"; break; }
  done
fi

[ -n "$EIM_BIN" ] && validate_eim_candidate "$EIM_BIN" || {
  echo "ERROR=仍未找到可执行的 EIM CLI" >&2
  exit 7
}

[ -n "$ACTION" ] || { resolve_eim_action || exit $?; }
EIM_JSON_DIR="$(eim_json_dir)" || exit $?

case "$ACTION" in
  install) ARGS=(--do-not-track true --esp-idf-json-path "$EIM_JSON_DIR" install -i "$VERSION" -t "$TARGETS" --cleanup true) ;;
  repair)
    ARGS=(--do-not-track true --esp-idf-json-path "$EIM_JSON_DIR" fix -p "$EXACT_PATH")
    [ "$TARGETS_EXPLICIT" = no ] || ARGS+=(-t "$TARGETS")
    ;;
  reuse) ARGS=() ;;
esac
if [ "$ACTION" != reuse ] && [ "$NET" = cn ]; then
  ARGS+=(--mirror https://dl.espressif.cn/github_assets)
  ARGS+=(--idf-mirror https://git.espressif.com.cn)
  ARGS+=(--pypi-mirror https://pypi.tuna.tsinghua.edu.cn/simple)
fi

if [ "$ACTION" != reuse ]; then
  echo "STEP=EIM $ACTION ESP-IDF $VERSION(targets: $TARGETS)"
  "$EIM_BIN" "${ARGS[@]}" || { echo "ERROR=macOS eim $ACTION 失败" >&2; exit 7; }
fi
EXACT_PATH="$(eim_exact_idf_path "$VERSION" "$REPAIR_PATH")" || {
  echo "ERROR=macOS EIM $ACTION 后未登记唯一的 $VERSION 精确路径" >&2
  exit 8
}
echo "INSTALL_ROUTE=mac-eim"
echo "EIM_BIN=$EIM_BIN"
echo "EIM_ACTION=$ACTION"
echo "EIM_IDF_PATH=$EXACT_PATH"
