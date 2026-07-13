#!/usr/bin/env bash
# esp-idf-cy · ESP-IDF 自动安装(幂等,可中断重跑)。
#
# 用法: bash install.sh [--version stable|v5.5|v5.5.4] [--targets esp32s3|esp32c3|all] [--path <安装目录>]
#       bash install.sh --repair --version v5.5.4 --path <EIM登记的精确IDF目录>
#   --version  默认 stable;给 minor 系列(如 v5.5)时自动解析到该系列最新 patch
#   --targets  芯片目标,默认 all;已知板子时应显式传 esp32s3/esp32c6 等以减少下载
#   --path     IDF 仓库位置,默认 <用户主目录>/esp/esp-idf(官方惯例);Windows 走 EIM 时由 EIM 管理
#   --repair   只修复指定的 EIM 安装;必须同时给精确 patch 版本和登记中的精确路径,不会升级
#   --route-only 只输出当前实机将选择的安装路线,不安装 Python/IDF(仍会检查 CLT、网络和版本)
#
# 路线:macOS = 已有可用 EIM/Homebrew 时优先官方 EIM CLI,否则 bootstrap 后走官方 install.sh;
#       Linux = 官方 install.sh;Windows = 官方 EIM CLI,前置依赖 -a true 全自动。
# 注意:全程下载量以 GB 计,agent 调用时应放宽超时或后台运行。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
. "$SCRIPT_DIR/eim-registry.sh"

REQUESTED_VERSION=stable
VERSION_EXPLICIT=no
VERSION=""
TARGETS=all
TARGETS_EXPLICIT=no
IDF_DIR=""
IDF_DIR_EXPLICIT=no
RESOLVE_ONLY=no
ROUTE_ONLY=no
REPAIR=no
while [ $# -gt 0 ]; do
  case "$1" in
    --version|--targets|--path)
      [ $# -ge 2 ] || { echo "ERROR=$1 缺少参数值" >&2; exit 64; }
      case "$1" in
        --version) REQUESTED_VERSION="$2"; VERSION_EXPLICIT=yes ;;
        --targets) TARGETS="$2"; TARGETS_EXPLICIT=yes ;;
        --path) IDF_DIR="$2"; IDF_DIR_EXPLICIT=yes ;;
      esac
      shift 2
      ;;
    --resolve-only) RESOLVE_ONLY=yes; shift ;;
    --route-only) ROUTE_ONLY=yes; shift ;;
    --repair) REPAIR=yes; shift ;;
    *) echo "未知参数: $1" >&2; exit 64 ;;
  esac
done

HOME_DIR="$(user_home)"
[ -z "$IDF_DIR" ] && IDF_DIR="$HOME_DIR/esp/esp-idf"
if [ "$REPAIR" = yes ]; then
  [ "$VERSION_EXPLICIT" = yes ] && printf '%s\n' "$REQUESTED_VERSION" \
    | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || {
      echo "ERROR=--repair 必须显式提供精确 --version v<major>.<minor>.<patch>;不允许 stable/minor 暗中升级" >&2
      exit 64
    }
  [ "$IDF_DIR_EXPLICIT" = yes ] || {
    echo "ERROR=--repair 必须提供 EIM 登记中的精确 --path;不会猜默认目录" >&2
    exit 64
  }
fi

INSTALL_MODE="${ESP_IDF_CY_INSTALL_MODE:-auto}"
case "$INSTALL_MODE" in auto|eim|official-script) ;; *)
  echo "ERROR=ESP_IDF_CY_INSTALL_MODE 只能是 auto/eim/official-script" >&2; exit 64 ;;
esac

mac_brew_bin() {
  if [ "${ESP_IDF_CY_TEST_NO_BREW:-no}" = yes ]; then
    return 1
  elif [ -n "${ESP_IDF_CY_BREW_BIN:-}" ] && [ -x "$ESP_IDF_CY_BREW_BIN" ]; then
    printf '%s\n' "$ESP_IDF_CY_BREW_BIN"
  elif have brew; then
    command -v brew
  else
    return 1
  fi
}

choose_install_route() {
  if [ "$REPAIR" = yes ]; then
    case "$OS" in
      windows) printf '%s\n' windows-eim; return ;;
      mac) printf '%s\n' mac-eim; return ;;
      *) echo "ERROR=--repair 当前只支持本 Skill 使用 EIM 的 Windows/macOS 路线" >&2; return 64 ;;
    esac
  fi
  case "$OS" in
    windows) printf '%s\n' windows-eim ;;
    linux)   printf '%s\n' linux-official-script ;;
    mac)
      # --path 在本 Skill 中表示“精确 IDF 仓库路径”;EIM 的 -p 是 base path,
      # 语义不同。显式路径因此保持官方 install.sh 路线,绝不悄悄改位置。
      if [ "$IDF_DIR_EXPLICIT" = yes ]; then
        printf '%s\n' mac-official-script
      elif [ "$INSTALL_MODE" = official-script ]; then
        printf '%s\n' mac-official-script
      elif [ "$INSTALL_MODE" = eim ]; then
        if find_eim >/dev/null 2>&1 || mac_brew_bin >/dev/null; then printf '%s\n' mac-eim; else
          echo "ACTION_REQUIRED=choose_homebrew_or_official_script_route" >&2
          echo "ERROR=明确要求 EIM,但这台 Mac 没有可用 EIM 或 Homebrew;不会静默安装系统包管理器" >&2
          return 20
        fi
      elif find_eim >/dev/null 2>&1 || mac_brew_bin >/dev/null; then
        # v6.0+ 官方默认推荐 EIM;已有 EIM 或 Homebrew 时优先走官方 EIM 路线。
        printf '%s\n' mac-eim
      else
        # 没有 Homebrew 时不把安装包管理器变成前置,继续使用仍受官方支持的脚本路线。
        printf '%s\n' mac-official-script
      fi
      ;;
    *) echo "ERROR=不支持的平台 $OS" >&2; return 1 ;;
  esac
}

# macOS 的 stable 版本解析依赖 git,而空白机的 git 来自 Command Line Tools。
# 先主动触发系统安装器;rc=20 表示等用户完成系统 UI 后重跑即可续上。
if [ "$OS" = mac ]; then
  MAC_CLT_OUT="$(bash "$SCRIPT_DIR/bootstrap-macos.sh" --clt-only 2>&1)"
  MAC_CLT_RC=$?
  printf '%s\n' "$MAC_CLT_OUT"
  [ "$MAC_CLT_RC" -eq 0 ] || exit "$MAC_CLT_RC"
fi

NET="$(check_network)"
echo "NET=$NET"
if [ "$NET" = offline ]; then
  echo "ERROR=无网络,无法安装" >&2
  exit 4
fi

# stable 或 minor 系列名不能永久硬编码成某个旧 tag。安装本来就需要网络,
# 因此在当前可达的官方仓库查 tag,精确 patch 则尊重用户指定。
resolve_version() {
  local requested="$1" repo tags series escaped git_bin
  if printf '%s\n' "$requested" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$requested"
    return 0
  fi
  if [ "$requested" != stable ] && ! printf '%s\n' "$requested" | grep -Eq '^v[0-9]+\.[0-9]+$'; then
    echo "ERROR=版本只支持 stable、v<major>.<minor> 或精确 v<major>.<minor>.<patch>: $requested" >&2
    return 64
  fi

  if [ "$NET" = cn ]; then
    repo="https://jihulab.com/esp-mirror/espressif/esp-idf.git"
  else
    repo="https://github.com/espressif/esp-idf.git"
  fi
  git_bin="${ESP_IDF_CY_GIT_BIN:-git}"
  if command -v "$git_bin" >/dev/null 2>&1; then
    tags="$("$git_bin" ls-remote --refs --tags "$repo" 2>/dev/null | sed 's#.*refs/tags/##')"
  elif [ "$OS" = windows ]; then
    # EIM 能补 Git,但版本必须在 EIM 安装前决定。Windows 自带 PowerShell,
    # 因此在 Git 尚未就绪时从结构化 tag API 取候选，避免空白机自举死锁。
    if [ "$NET" = cn ]; then
      tags="$(ps_run "(Invoke-RestMethod -Headers @{'User-Agent'='esp-idf-cy'} -Uri 'https://jihulab.com/api/v4/projects/esp-mirror%2Fespressif%2Fesp-idf/repository/tags?per_page=100').name" 2>/dev/null || true)"
    else
      tags="$(ps_run "(Invoke-RestMethod -Headers @{'User-Agent'='esp-idf-cy'} -Uri 'https://api.github.com/repos/espressif/esp-idf/tags?per_page=100').name" 2>/dev/null || true)"
    fi
  else
    tags=""
  fi
  if [ "$requested" = stable ]; then
    printf '%s\n' "$tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
  else
    series="${requested#v}"
    escaped="${series//./\\.}"
    printf '%s\n' "$tags" | grep -E "^v${escaped}(\\.[0-9]+)?$" | sort -V | tail -1
  fi
}

if [ "$REPAIR" = yes ]; then
  VERSION="$REQUESTED_VERSION"
else
  VERSION="$(resolve_version "$REQUESTED_VERSION")"
fi
if [ -z "$VERSION" ]; then
  echo "ERROR=无法把 $REQUESTED_VERSION 解析为官方 ESP-IDF tag;检查网络/镜像,或显式传 --version vX.Y.Z" >&2
  exit 6
fi
echo "VERSION_REQUESTED=$REQUESTED_VERSION"
echo "VERSION_RESOLVED=$VERSION"
[ "$RESOLVE_ONLY" = yes ] && exit 0

INSTALL_ROUTE="$(choose_install_route)" || exit $?
echo "INSTALL_ROUTE=$INSTALL_ROUTE"
if [ "$INSTALL_ROUTE" = windows-eim ]; then
  # 架构门禁必须早于 winget/下载等任何写操作；不能先装 x64 包再发现 ARM64。
  PLATFORM_HELPER="$(cygpath -w "$SCRIPT_DIR/eim-windows.ps1" 2>/dev/null || echo "$SCRIPT_DIR/eim-windows.ps1")"
  ps_file "$PLATFORM_HELPER" CheckPlatform || {
    echo "ERROR=当前 Windows 架构不在官方 EIM x64 自动路线支持范围内" >&2
    exit 8
  }
fi
case "$INSTALL_ROUTE" in
  mac-eim)
    if path_has_whitespace "$HOME_DIR"; then
      echo "ERROR=EIM 默认 base path 位于用户目录,但真实用户目录含空白: $HOME_DIR" >&2
      echo "HINT=请让 Agent 选择无空格的安装 base path或改用受支持的无空格账户/磁盘位置" >&2
      exit 8
    fi
    if [ "$REPAIR" = yes ] && path_has_whitespace "$IDF_DIR"; then
      echo "ERROR=ESP-IDF 官方构建系统不支持待修复路径包含空白: $IDF_DIR" >&2
      exit 8
    fi
    ;;
  mac-official-script|linux-official-script)
    if path_has_whitespace "$IDF_DIR"; then
      echo "ERROR=ESP-IDF 官方构建系统不支持安装路径包含空白: $IDF_DIR" >&2
      exit 8
    fi
    ;;
esac
[ "$ROUTE_ONLY" = yes ] && exit 0

# ---------- python 版本闸门 / macOS 自动 bootstrap ----------
known_idf_min_python() {
  local major
  major="$(printf '%s\n' "$1" | sed -nE 's/^v([0-9]+)\..*/\1/p')"
  case "$major" in
    3|4|5|6) idf_min_python "$1" ;;
    *)
      echo "ERROR=尚未内置 ESP-IDF $1 的官方 Python 下限;拒绝把未知新 major 静默当成 Python 3.8" >&2
      return 6
      ;;
  esac
}
MIN_PY="$(known_idf_min_python "$VERSION")" || exit $?
if [ "$OS" = mac ] && [ "$INSTALL_ROUTE" = mac-official-script ]; then
  MAC_PY_OUT="$(bash "$SCRIPT_DIR/bootstrap-macos.sh" --min-python "$MIN_PY" 2>&1)"
  MAC_PY_RC=$?
  printf '%s\n' "$MAC_PY_OUT"
  [ "$MAC_PY_RC" -eq 0 ] || exit "$MAC_PY_RC"
  MAC_PY_BIN="$(printf '%s\n' "$MAC_PY_OUT" | sed -n 's/^PYTHON_BIN=//p' | tail -1)"
  [ -n "$MAC_PY_BIN" ] || { echo "ERROR=macOS bootstrap 未返回 PYTHON_BIN" >&2; exit 7; }
  export ESP_IDF_CY_PYTHON_BIN="$MAC_PY_BIN"
  export PATH="$(dirname "$MAC_PY_BIN"):$PATH"
elif [ "$OS" != mac ]; then
  PY_VER="$(python_version || true)"
  if [ -z "$PY_VER" ]; then
    echo "ERROR=没有可用的 Python3。Windows EIM 会自动安装;Linux 需要系统包管理器权限" >&2
    [ "$OS" != windows ] && exit 5
  elif ! version_ge "$PY_VER" "$MIN_PY"; then
    echo "PYTHON=$PY_VER MIN_REQUIRED=$MIN_PY"
    if [ "$OS" != windows ]; then
      echo "ERROR=Python $PY_VER 低于 ESP-IDF $VERSION 要求的 $MIN_PY。升级 python 或改装低版本 IDF(--version)" >&2
      exit 5
    fi
  fi
fi

# ================= Windows:EIM 路线 =================
EIM_INSTALLED_PATH=""

verify_exact_eim_path() {
  local path="$1" eim_bin="$2"
  env -u IDF_PATH -u ESP_IDF_CY_PROJECT_DIR \
    ESP_IDF_CY_IDF_PATH="$path" ESP_IDF_CY_EIM_BIN="$eim_bin" \
    bash "$SCRIPT_DIR/verify-install.sh" --version "$VERSION" --path "$path"
}

install_windows() {
  local eim_bin="" find_rc=0 helper helper_win eim_win winget_out winget_rc=0
  local exact_path="" resolve_rc=0 action="" exact_win="" registry_dir="" registry_dir_win=""
  helper="$SCRIPT_DIR/eim-windows.ps1"
  helper_win="$(cygpath -w "$helper" 2>/dev/null || echo "$helper")"
  eim_bin="$(find_eim 2>/dev/null)"; find_rc=$?
  if [ "$find_rc" -eq 64 ]; then
    find_eim >/dev/null
    exit 5
  elif [ "$find_rc" -ne 0 ]; then
    echo "STEP=安装 EIM CLI(winget)"
    if ps_run "winget --version" | grep -q .; then
      winget_out="$(ps_run "winget install --id Espressif.EIM-CLI --exact --source winget --scope user --silent --disable-interactivity --accept-source-agreements --accept-package-agreements" 2>&1)"
      winget_rc=$?
      printf '%s\n' "$winget_out" >&2
      echo "EIM_WINGET_RC=$winget_rc"
      if [ "$winget_rc" -eq 0 ]; then
        eim_bin="$(find_eim 2>/dev/null || true)"
        [ -n "$eim_bin" ] || echo "WARN=winget 返回成功,但当前会话仍未发现 EIM;转用可验证下载" >&2
      else
        echo "WARN=winget 安装失败(rc=$winget_rc);转用可验证下载" >&2
      fi
    fi
    if [ -z "$eim_bin" ]; then
      echo "STEP=winget 不可用或未产出可用 EIM,从官方 release 动态解析并双重验真"
      local ver="${ESP_IDF_CY_EIM_VERSION:-}"
      local dl_dir="$HOME_DIR/.esp-idf-cy/bin"
      mkdir -p "$dl_dir"
      eim_bin="$dl_dir/eim.exe"
      eim_win="$(cygpath -w "$eim_bin" 2>/dev/null || echo "$eim_bin")"
      local dl_args=(DownloadVerified -Destination "$eim_win")
      [ -n "$ver" ] && dl_args+=(-Version "$ver")
      ps_file "$helper_win" "${dl_args[@]}" || {
        echo "ERROR=EIM 官方 release 下载或 SHA256/Authenticode 验证失败" >&2
        exit 6
      }
    fi
  fi

  validate_eim_candidate "$eim_bin" || { echo "ERROR=EIM 文件不可执行: $eim_bin" >&2; exit 7; }
  export ESP_IDF_CY_EIM_BIN="$eim_bin"

  eim_win="$(cygpath -w "$eim_bin" 2>/dev/null || echo "$eim_bin")"
  registry_dir="$(eim_json_dir)" || exit $?
  registry_dir_win="$(cygpath -w "$registry_dir" 2>/dev/null || echo "$registry_dir")"
  exact_path="$(eim_exact_idf_path "$VERSION" "$([ "$REPAIR" = yes ] && printf '%s' "$IDF_DIR")")"
  resolve_rc=$?
  case "$resolve_rc" in
    0)
      if verify_exact_eim_path "$exact_path" "$eim_bin" >/dev/null 2>&1; then
        action=reuse
        echo "STEP=EIM 登记中的 $VERSION 已健康,复用精确路径"
      else
        action=repair
        echo "STEP=EIM 登记中的 $VERSION 已损坏,修复精确路径"
      fi
      ;;
    10)
      [ "$REPAIR" = no ] || {
        echo "ERROR=--repair 指定的 $VERSION 不在 EIM 登记中;拒绝改成新安装" >&2
        exit 8
      }
      action=install
      ;;
    *) exit 8 ;;
  esac

  local args=()
  case "$action" in
    install)
      echo "STEP=EIM 安装 ESP-IDF $VERSION(前置依赖自动补齐)"
      args=(InstallIdf -EimPath "$eim_win" -IdfVersion "$VERSION" -Targets "$TARGETS" \
        -EspIdfJsonPath "$registry_dir_win")
      ;;
    repair)
      exact_win="$(cygpath -w "$exact_path" 2>/dev/null || echo "$exact_path")"
      args=(FixIdf -EimPath "$eim_win" -IdfPath "$exact_win" \
        -EspIdfJsonPath "$registry_dir_win")
      [ "$TARGETS_EXPLICIT" = no ] || args+=(-Targets "$TARGETS")
      ;;
    reuse) ;;
  esac
  if [ "$action" != reuse ]; then
    if [ "$NET" = cn ]; then
      # EIM 内置的官方镜像候选值(idf-im-ui 源码 get_*_mirrors_list)
      args+=(-Mirror https://dl.espressif.cn/github_assets)
      args+=(-IdfMirror https://git.espressif.com.cn)
      args+=(-PypiMirror https://pypi.tuna.tsinghua.edu.cn/simple)
    fi
    ps_file "$helper_win" "${args[@]}" || {
      echo "ERROR=eim $action 失败,完整日志见上方输出" >&2
      exit 7
    }
  fi

  EIM_INSTALLED_PATH="$(eim_exact_idf_path "$VERSION" "$([ "$REPAIR" = yes ] && printf '%s' "$IDF_DIR")")" || {
    echo "ERROR=EIM $action 后未登记唯一的 $VERSION 精确路径" >&2
    exit 8
  }
  echo "EIM_ACTION=$action"
  echo "EIM_IDF_PATH=$EIM_INSTALLED_PATH"
}

# ================= macOS / Linux:官方 install.sh 路线 =================
install_posix() {
  # macOS 前置已由 bootstrap-macos.sh 处理;Linux 仍只做系统依赖检查。
  if ! have git; then
    echo "ERROR=缺 git。Linux 需要 apt/yum/pacman 等系统包管理器权限" >&2
    exit 5
  fi
  # Linux 的系统依赖尽力提示,不强装(需要 sudo)
  if [ "$OS" = linux ] && ! have cmake && ! [ -d "${IDF_TOOLS_PATH:-$HOME/.espressif}/tools/cmake" ]; then
    echo "INFO=cmake/ninja 将由 IDF install.sh 装到 ~/.espressif,无需系统安装" >&2
  fi

  # ---------- 克隆(幂等) ----------
  if is_idf_dir "$IDF_DIR"; then
    local cur; cur="$(idf_dir_version "$IDF_DIR" || echo unknown)"
    echo "IDF_DIR_EXISTS=yes VERSION=$cur"
    if [ "$cur" != "$VERSION" ]; then
      echo "ERROR=已存在 $cur,与请求的 $VERSION 不同;为避免在旧仓库上安装错版工具链,本次不继续。请用 --path 指到新目录(如 ~/esp/esp-idf-$VERSION)" >&2
      exit 8
    fi
  else
    if [ -e "$IDF_DIR" ]; then
      echo "ERROR=目标已存在但不是完整 ESP-IDF: $IDF_DIR。不自动删除用户文件;请检查是否为中断的 clone,或改用新 --path" >&2
      exit 8
    fi
    echo "STEP=克隆 esp-idf $VERSION 到 $IDF_DIR"
    mkdir -p "$(dirname "$IDF_DIR")"
    if [ "$NET" = cn ]; then
      # 乐鑫官方 jihulab 镜像:主仓直接从镜像克隆,子模块用仓库级 insteadOf 重写(不动全局 git 配置)
      bash "$SCRIPT_DIR/clone-idf.sh" --destination "$IDF_DIR" --version "$VERSION" \
        --primary https://jihulab.com/esp-mirror/espressif/esp-idf.git \
        --fallback https://gitee.com/EspressifSystems/esp-idf.git \
        --rewrite-from https://github.com/ --rewrite-to https://jihulab.com/esp-mirror/ \
        || exit $?
    else
      bash "$SCRIPT_DIR/clone-idf.sh" --destination "$IDF_DIR" --version "$VERSION" \
        --primary https://github.com/espressif/esp-idf.git || exit $?
    fi
  fi

  # ---------- 子模块(重试 3 次,幂等) ----------
  echo "STEP=更新子模块"
  local i ok=no
  for i in 1 2 3; do
    if git -C "$IDF_DIR" submodule update --init --recursive; then ok=yes; break; fi
    echo "INFO=子模块第 $i 次失败,重试" >&2
    sleep 3
  done
  [ "$ok" = yes ] || { echo "ERROR=子模块更新失败(弱网常见),可直接重跑本脚本续传" >&2; exit 6; }

  # ---------- 工具链 + python venv ----------
  echo "STEP=安装工具链(targets: $TARGETS)"
  if [ "$NET" = cn ]; then
    # 官方镜像机制:下载 URL 里的 github.com 整体替换;pip 走清华镜像
    export IDF_GITHUB_ASSETS="dl.espressif.cn/github_assets"
    export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
  fi
  ( cd "$IDF_DIR" && ./install.sh "$TARGETS" ) || {
    if [ "$NET" = cn ]; then
      echo "INFO=镜像下载失败(dl.espressif.cn 只镜像部分资产),去掉镜像回退 GitHub 重试一次" >&2
      unset IDF_GITHUB_ASSETS
      ( cd "$IDF_DIR" && ./install.sh "$TARGETS" ) || { echo "ERROR=install.sh 失败" >&2; exit 7; }
    else
      echo "ERROR=install.sh 失败,日志见上" >&2
      exit 7
    fi
  }
}

case "$INSTALL_ROUTE" in
  windows-eim) install_windows ;;
  mac-eim)
    MAC_EIM_ARGS=(--version "$VERSION" --net "$NET")
    [ "$TARGETS_EXPLICIT" = no ] || MAC_EIM_ARGS+=(--targets "$TARGETS")
    [ "$REPAIR" = yes ] && MAC_EIM_ARGS+=(--repair-path "$IDF_DIR")
    MAC_EIM_OUT="$(bash "$SCRIPT_DIR/install-eim-macos.sh" "${MAC_EIM_ARGS[@]}" 2>&1)"
    MAC_EIM_RC=$?
    printf '%s\n' "$MAC_EIM_OUT"
    [ "$MAC_EIM_RC" -eq 0 ] || exit "$MAC_EIM_RC"
    MAC_EIM_BIN="$(printf '%s\n' "$MAC_EIM_OUT" | sed -n 's/^EIM_BIN=//p' | tail -1)"
    [ -n "$MAC_EIM_BIN" ] || { echo "ERROR=macOS EIM 安装未返回 EIM_BIN" >&2; exit 7; }
    export ESP_IDF_CY_EIM_BIN="$MAC_EIM_BIN"
    EIM_INSTALLED_PATH="$(printf '%s\n' "$MAC_EIM_OUT" | sed -n 's/^EIM_IDF_PATH=//p' | tail -1)"
    [ -n "$EIM_INSTALLED_PATH" ] || { echo "ERROR=macOS EIM 未返回精确登记路径" >&2; exit 8; }
    ;;
  mac-official-script|linux-official-script) install_posix ;;
  *) echo "ERROR=未知安装路线 $INSTALL_ROUTE" >&2; exit 1 ;;
esac

echo "STEP=安装完成,复检环境"
if [ "$INSTALL_ROUTE" = windows-eim ] || [ "$INSTALL_ROUTE" = mac-eim ]; then
  env -u IDF_PATH -u ESP_IDF_CY_PROJECT_DIR \
    ESP_IDF_CY_IDF_PATH="$EIM_INSTALLED_PATH" \
    bash "$SCRIPT_DIR/verify-install.sh" --version "$VERSION" --path "$EIM_INSTALLED_PATH" || exit $?
else
  bash "$SCRIPT_DIR/verify-install.sh" --version "$VERSION" --path "$IDF_DIR" || exit $?
fi
echo "INSTALL_READY=yes"
