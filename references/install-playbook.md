# esp-idf-cy · 手动安装配方(install.sh 不适用时,agent 按此分步执行)

> 每一步独立可重试。失败不要从头来,定位哪步卡住,单独解决那一步。
> 下面用 `<IDF_TAG>` 表示已确定的精确 tag(如 v5.5.4 或 v6.0.2)。
> 项目有指定就跟项目;新项目查官方 stable;注意 v5.5≥3.9,v6.0≥3.10。

## macOS / Linux(空白机默认的官方脚本流程)

### 1. 前置

```bash
bash <skill>/scripts/bootstrap-macos.sh --clt-only
bash <skill>/scripts/bootstrap-macos.sh --min-python <最低版本>  # v5.5=3.9,v6.0=3.10
```

- 缺 Command Line Tools:脚本主动执行 `xcode-select --install`,输出
  `ACTION_REQUIRED=complete_xcode_command_line_tools`/rc=20;用户只处理苹果系统弹窗,完成后重跑。
- Python 不达标且已有 Homebrew:脚本自动 `brew install python`,不要求用户复制命令。
- 没有 Homebrew:下载 Python.org 官方 universal2 pkg,同时校验固定 SHA256 和
  `Python Software Foundation` 安装签名后才 `open`;用户完成系统安装器后重跑。
- 不自动安装 Homebrew。它会写系统目录并引入新的长期包管理器,超出“补齐 IDF 必需依赖”的最小范围。
- macOS 能用 EIM,官方推荐 Homebrew 安装;但 POSIX 只做前置检查,缺依赖时不会像 Windows
  的 `-a true` 那样代装。空白 Mac 因此默认走本节,已有健康 EIM 则由 `idf-env.sh` 原生复用。

Linux 系统依赖(cmake/ninja 不用装,IDF 会装自己管理的版本到 ~/.espressif):

```bash
sudo apt-get install git wget flex bison gperf python3 python3-pip python3-venv \
  libffi-dev libssl-dev dfu-util libusb-1.0-0        # Ubuntu/Debian
```

### 2. 克隆(约 1-2 GB 含子模块)

```bash
mkdir -p ~/esp && cd ~/esp
# 直连:
git clone -b <IDF_TAG> --recursive https://github.com/espressif/esp-idf.git
# 国内(乐鑫官方 jihulab 镜像,子模块用仓库级 insteadOf 重写,不污染全局配置):
git clone -b <IDF_TAG> https://jihulab.com/esp-mirror/espressif/esp-idf.git esp-idf
git -C esp-idf config url."https://jihulab.com/esp-mirror/".insteadOf "https://github.com/"
git -C esp-idf submodule update --init --recursive
```

- 失败处理:子模块极多,弱网易断——`git submodule update --init --recursive` 幂等,重跑即续传。
- 多版本共存:装到 `~/esp/esp-idf-<IDF_TAG>` 这类带版本目录,互不干扰;用哪个 source 哪个的 export.sh。

### 3. 工具链 + python venv

```bash
cd ~/esp/esp-idf
# 国内加两个环境变量(官方机制;dl.espressif.cn 只镜像部分资产,404 就去掉重试):
export IDF_GITHUB_ASSETS="dl.espressif.cn/github_assets"
export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
./install.sh esp32,esp32s3        # 或 all(下载量大);装到 $IDF_TOOLS_PATH(默认 ~/.espressif)
```

- 失败处理:DownloadError → 看是哪个工具的 URL,镜像 404 就 `unset IDF_GITHUB_ASSETS` 重跑;
  install.sh 幂等,已下载的会跳过。
- "Python interpreter not found" → python 升级过导致旧 venv 失效,重跑顶层 install.sh;
  它会先复用/补齐兼容 Python,再重建 venv。

### 4. 验证

```bash
source ~/esp/esp-idf/export.sh && idf.py --version    # 应输出选定的精确 tag
```

### 已有 EIM 的 macOS

```bash
brew tap espressif/eim
brew install eim                  # 或 brew install --cask eim-gui
eim --do-not-track true list
eim --do-not-track true run "idf.py --version" <IDF路径>
```

EIM 本体支持 macOS x64/arm64,但开始安装 IDF 前仍需满足官方列出的 POSIX 前置依赖。
Agent 实际执行统一走 `idf-env.sh`,避免依赖用户手工激活 shell。

## Windows(官方 EIM CLI 流程;在 Git Bash 里编排,原生命令清 MSYSTEM)

### 1. 拿到 eim

```bash
# 首选 winget:
env -u MSYSTEM powershell.exe -NoLogo -NoProfile -Command \
  "winget install --id Espressif.EIM-CLI --exact --source winget --scope user --silent --disable-interactivity --accept-source-agreements --accept-package-agreements"
# winget 不可用/装完仍不可发现:不要手写 curl 直下 exe,让顶层 install.sh 调
# scripts/eim-windows.ps1 动态取官方正式 release，并校验 asset SHA256 +
# Espressif Authenticode 签名后原子落盘。
```

手动拿到的 EIM 也必须先验证 `Get-AuthenticodeSignature` 为 `Valid` 且 signer 是 Espressif;
不满足就拒绝执行。顶层 `install.sh` 已自动吸收这层边界。

### 2. 安装(默认非交互;-a true 自动补齐 Python/Git 等前置,裸机可用)

```bash
env -u MSYSTEM eim --do-not-track true install -i <IDF_TAG> -t <芯片目标或all> -a true --cleanup true
# 国内追加(EIM 内置官方镜像候选):
#   --mirror https://dl.espressif.cn/github_assets \
#   --idf-mirror https://git.espressif.com.cn \
#   --pypi-mirror https://pypi.tuna.tsinghua.edu.cn/simple
```

- 默认位置:IDF 在 `C:\esp\<版本>`,工具和登记文件在 `C:\Espressif\tools\`(`eim_idf.json`)。
- 失败处理:镜像资产 404 → 去掉对应 mirror 参数重跑;前置检查误报 → `--skip-prerequisites-check`。

### 3. 验证

```bash
env -u MSYSTEM eim --do-not-track true list
env -u MSYSTEM eim --do-not-track true run "idf.py --version" <IDF路径>
```

实际 Agent 操作优先用 `idf-env.sh`,由固定 PowerShell helper 以 argv 调用、复验签名并保留退出码。

## 通用注意

- 安装全程下载量以 GB 计:后台跑,或把超时放到 10 分钟以上。首次 clone 用受管暂存区,
  中断后重跑会安全清理并重试;子模块和工具下载会复用已完成内容。
- 不往用户 shell 配置里写 export/alias(官方也不建议自动 source);要写先问用户。
- 装完检查不能只看目录:必须 `READY=yes`、`idf.py --version` 真命令成功、版本与请求精确一致;
  POSIX 还要路径一致。顶层 `install.sh` 用 `verify-install.sh` 自动门控。
