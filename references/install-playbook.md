# esp-idf-cy · 手动安装配方(install.sh 不适用时,agent 按此分步执行)

> 每一步独立可重试。失败不要从头来,定位哪步卡住,单独解决那一步。
> 下面用 `<IDF_TAG>` 表示已确定的精确 tag(如 v5.5.4 或 v6.0.2)。
> 项目有指定就跟项目;新项目查官方 stable。Python 下限先读所选 IDF 自带检查或当前官方前置；
> v5.5≥3.9、v6.0≥3.10 只是已验证快照，未知新 major 不得回落猜旧下限。最近复核：2026-07-13。
> v3/v4等老项目还可能有 Python**上限**和Apple Silicon/Rosetta约束；必须读该精确IDF自带检查，
> 不要因“最新Python高于最低版本”就认定兼容，也不要盲用Mac fallback的当前Python包。

## 先分三态，再选动作

1. **健康可复用**：真实 `idf.py --version`、项目兼容性和必要工具都通过。保持精确版本与位置，不安装、
   不升级，也不因为默认目录不同而搬迁。
2. **已安装但损坏**：项目/EIM登记已经锁定精确路径，但环境导出、Python venv或工具链真命令失败。
   EIM 管理的安装优先 `eim fix -p <精确路径>`；官方脚本安装则在该仓库重跑 `install.sh <targets>`。
   修复后仍验证同一路径，不能拿另一个同版本目录顶替。EIM `fix` 要求该路径仍是有效 IDF 仓库；
   登记路径已经消失或仓库本体被删毁时保持 fail closed，由 Agent 解释并决定是否按原位置重新安装。
3. **确实未安装**：穷尽项目元数据、EIM登记、IDE设置和相关目录的有界发现后仍无兼容候选，才新装。

多版本或证据冲突时，Agent 先用项目锁定信息消歧；仍会改变结果时只问用户一个关键问题。

## macOS / Linux

### macOS 路线 A:已有 EIM 或 Homebrew → 官方 EIM CLI(ESP-IDF v6.0+ 默认推荐)

```bash
brew install libgcrypt glib pixman sdl2 libslirp dfu-util cmake python
brew tap espressif/eim
brew install eim
eim --do-not-track true install -i <IDF_TAG> -t <芯片目标> --cleanup true
```

Agent 正常调用 `install-eim-macos.sh`,不让用户复制这些命令。已有 Homebrew 时先完成上面的官方
前置清单;只有现成 EIM 时先让 EIM 做真实依赖检查,不能把“EIM 可执行”当成“ESP-IDF 前置已齐”。
检查失败后按具体缺项改走官方脚本路线或向用户说明选择。不要传 Windows 专属 `-a true`。

若 EIM 已登记目标版本但健康检查失败，不要再次 `install`：从登记中锁定精确路径，执行
`eim --do-not-track true fix -p <精确路径>`，再清除 ambient `IDF_PATH` 干扰做严格复检。

### macOS 路线 B:EIM/Homebrew 都没有或用户指定精确仓库路径 → 官方 install.sh

#### macOS 前置

```bash
bash <skill>/scripts/bootstrap-macos.sh --clt-only
bash <skill>/scripts/bootstrap-macos.sh --min-python <最低版本>  # v5.5=3.9,v6.0=3.10
```

- 缺 Command Line Tools:脚本主动执行 `xcode-select --install`,输出
  `ACTION_REQUIRED=complete_xcode_command_line_tools`/rc=20;用户只处理苹果系统弹窗,完成后重跑。
- Python 不达标且已有 Homebrew:脚本自动 `brew install python`,不要求用户复制命令。
- 没有 Homebrew:下载 Python.org 官方 universal2 pkg,同时校验固定 SHA256 和
  `Python Software Foundation` 安装签名后才 `open`;用户完成系统安装器后重跑。
- 不自动安装 Homebrew。它会写系统目录并引入新的长期包管理器;没有时走本路线并不妨碍完成
  安装/编译。用户明确要求 EIM、机器又没有 EIM/Homebrew 时,说明选择并取得用户决定,不要自行 `curl|sh`。

### Linux 前置(官方 install.sh 路线)

Linux 系统依赖(cmake/ninja 不用装,IDF 会装自己管理的版本到 ~/.espressif):

```bash
sudo apt-get install git wget flex bison gperf python3 python3-pip python3-venv \
  libffi-dev libssl-dev dfu-util libusb-1.0-0        # Ubuntu/Debian
```

### 官方 install.sh 共用步骤(macOS 路线 B / Linux)

#### 1. 克隆(约 1-2 GB 含子模块)

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

#### 2. 工具链 + python venv

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

#### 3. 验证

```bash
source ~/esp/esp-idf/export.sh && idf.py --version    # 应输出选定的精确 tag
```

### macOS EIM 验证

```bash
brew tap espressif/eim
brew install eim                  # 或 brew install --cask eim-gui
eim --do-not-track true list
# 真命令通过 idf-env.sh 的固定 argv relay，或 Agent 等价的固定 runner 执行；
# 不把路径/正则/用户参数拼成 eim run 的命令文本。
bash <skill>/scripts/idf-env.sh idf.py --version
```

EIM 本体支持 macOS x64/arm64,但开始安装 IDF 前仍需满足官方列出的 POSIX 前置依赖。
Agent 实际执行统一走 `idf-env.sh`,避免依赖用户手工激活 shell。

## 路径与发现边界

- `~/esp`、`C:\esp` 都只是示例/默认值,不是检测真相。先看 `IDF_PATH`、项目
  `build/project_description.json`、EIM登记和IDE设置,再对实际用户目录做有界搜索。
- ESP-IDF 官方不支持 IDF或项目路径含空格。检测到后停止直接构建;Agent检查相对依赖/符号链接,
  再在无空格路径建立受管副本或经用户确认迁移。引号只能防shell拆词,不能修复CMake限制。
- 顶层 `install.sh --path` 表示“精确 IDF 仓库路径”，不等于 EIM `install -p` 的新装 base path。
  用户明确要装到非默认磁盘时，Agent先验架构/来源/签名，再用当前 EIM 的原生 argv
  `install -p <实机选择的无空格base>`；安装后从同一 registry 读取实际 IDF 根并走精确门禁。
  不要为了追求一条固定 helper 命令而忽略用户磁盘、权限和项目证据。

## Windows(官方 EIM CLI 流程;先探测架构)

优先调用 Skill 固定 helper 的 `CheckPlatform`。人工诊断时可读取原生架构：

```powershell
[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$env:PROCESSOR_ARCHITEW6432  # 32位/仿真进程下的原生架构线索
$env:PROCESSOR_ARCHITECTURE
```

当前官方 EIM CLI 的 Windows release 资产为 x64。只有检测为 x64 才走下面的自动下载/执行路径；
ARM64/其他架构不得盲装 x64 exe，Agent 应复核当期官方资产，若仍无原生支持则说明边界并改走
官方支持的兼容环境，而不是假装安装成功。

PowerShell-only 时先调用固定 helper 的 `CheckPlatform`；Git Bash 的 `install.sh` 也会在 winget/下载前
执行同一门禁。架构不匹配时不会先写入一个 x64 安装再报错。

Git Bash 编排时对原生命令清 `MSYSTEM`；只有系统 PowerShell 时直接调用固定 helper，不要求新手先装 Bash。

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
- 失败处理:镜像资产 404 → 去掉对应 mirror 参数重跑。只有 Agent 已用独立真命令逐项证明前置满足、
  且能解释 EIM 检查为何误报时，才允许 `--skip-prerequisites-check`；不能把它当通用重试开关。

### 2.5 已登记安装损坏时精确修复

```bash
env -u MSYSTEM eim --do-not-track true fix -p <EIM登记中的精确IDF路径>
```

不得用 `install -i <同版本>` 代替修复，也不得只根据版本号从多个目录中随便挑一个。若同版本存在多个
登记且项目证据无法唯一锁定路径，保持 fail closed，由 Agent 继续取证或请用户选择。

### 3. 验证

```bash
env -u MSYSTEM eim --do-not-track true list
# Git Bash：
bash <skill>/scripts/idf-env.sh idf.py --version
```

验证必须以本次 install/fix 的 EIM 登记路径为目标，临时清除父进程的 `IDF_PATH`，再同时核对：
EIM 登记路径、仓库元数据版本、真实 `idf.py --version` 和目标示例 build。任何一个不一致都不能报成功。

有 Git Bash 时优先用 `idf-env.sh`。没有 Git Bash时,Agent直接用系统 PowerShell调用固定 helper:

```powershell
& <skill>\scripts\eim-windows.ps1 InstallIdf -EimPath <eim.exe> -IdfVersion <IDF_TAG> -Targets <target>
& <skill>\scripts\eim-windows.ps1 FixIdf -EimPath <eim.exe> -IdfPath <精确IDF路径>
& <skill>\scripts\eim-windows.ps1 RunIdf -EimPath <eim.exe> -IdfPath <IDF路径> `
  -RunnerPath <skill>\scripts\eim-argv-runner.py -CommandArgs @('idf.py','--version')
```

helper 以权限受限的 NUL argv 文件把参数交给固定 runner、复验签名并保留退出码；它不接受任意
`CommandString`，因此项目路径和正则不会变成 PowerShell/EIM 激活脚本代码。不要求新手为运行 Skill 先安装 Git Bash。
若登记不在默认目录，上述 `InstallIdf`/`FixIdf`/`RunIdf` 必须统一追加
`-EspIdfJsonPath <eim_idf.json所在目录>`；Git Bash wrapper 会从实机登记位置自动传递。不能只在探测时
读取自定义 JSON，执行时却让 EIM 回到默认 registry。

## 通用注意

- 安装全程下载量以 GB 计:后台跑,或把超时放到 10 分钟以上。首次 clone 用受管暂存区,
  中断后重跑会安全清理并重试;子模块和工具下载会复用已完成内容。
- 不往用户 shell 配置里写 export/alias(官方也不建议自动 source);要写先问用户。
- 装完或修复检查不能只看目录:必须 `READY=yes`、`idf.py --version` 真命令成功、版本与请求精确一致；
  还要和本次 EIM 登记/请求的精确路径一致。顶层 `install.sh` 用 `verify-install.sh` 自动门控。
