# esp-idf-cy · 排错剧本

按「现象 → 原因 → 动作」组织。给用户的指引要转译成动作("按住 BOOT 键"),不要甩原始报错。
这些条目是已知模式，不代替实机证据；报错不完全吻合时先调查，不要机械套解法。最近复核：2026-07-13。

### ESP-IDF或项目路径含空格 / CMake 找不到组件
- 原因:ESP-IDF 官方明确不支持 IDF 和项目路径含空白。即使 shell 参数引用完全正确,构建仍可能失败。
- 动作:停止直接重试。Agent先检查相对路径依赖、Git submodule和符号链接;一次性构建可在无空格位置
  建立受管工作副本,长期开发则经用户确认迁移/重命名。不要直接移动或覆盖用户原项目。

### 用户要求 EIM GUI / 系统弹出权限窗口
- 普通 EIM 页面:当前宿主有 Computer Use且用户明确要求时,Agent可操作;否则改用功能等价的CLI。
- 密码、Touch ID、UAC、macOS安全确认、许可接受:让用户本人完成,然后重跑原命令续上。
- 不要把 Computer Use写成安装依赖,也不要因为没有GUI控制就把整套点击教程甩给新手。

## 一、安装类

### install.sh / idf_tools.py 下载工具链失败
- 原因:工具链是 GitHub Release Assets,GitHub 不可达或慢。
- 动作:确认 doctor 的 `NET`;`cn` 时脚本已自动加 `IDF_GITHUB_ASSETS=dl.espressif.cn/github_assets`。
  该镜像只覆盖部分资产,偶发 404 → install.sh 脚本会自动去镜像回退重试;再失败就直接重跑(断点续传)。

### git clone / submodule 反复失败
- 原因:esp-idf 子模块极多,弱网易断。
- 动作:直接重跑 install.sh;首次 clone 的半成品只存在受管暂存区,会安全清理后重试,
  不会把半仓库暴露为最终 IDF;子模块更新本身幂等。`NET=cn` 时已走 jihulab 官方镜像。
  手动排查:`git -C <IDF_DIR> submodule update --init --recursive` 单独重试。

### export.sh 报 "Python interpreter not found" / EXPORT_FAILED
- 原因:系统/brew 的 python 升级后,`~/.espressif/python_env/idfX.Y_pyA.B_env` 里的 venv
  指向失效解释器(venv 目录名编码了 python 版本,能看出它当时用的哪个)。
- 动作:重跑 `install.sh`,会重建 venv。这是 macOS 上最常见的"昨天还能编译今天不行"。

### macOS: xcrun: error: invalid active developer path
- 原因:缺 Xcode Command Line Tools(git 都依赖它)。
- 动作:重跑顶层 `install.sh`;它会主动触发 `xcode-select --install`。看到
  `ACTION_REQUIRED=complete_xcode_command_line_tools`/rc=20 时让用户只确认系统弹窗,
  完成后原命令重跑自动续上。

### macOS: install.sh 返回 rc=20 / ACTION_REQUIRED
- 原因:不是失败;Command Line Tools 或 Python.org 官方 pkg 进入了必须由本人确认的 macOS 系统 UI。
- 动作:按 `HINT` 完成当前系统安装器,然后**重跑同一条 install.sh**。克隆、工具下载和安装都幂等,
  不需要从头手动清理。不要把 rc=20 当成普通错误反复执行脚本,否则只会重复拉起窗口。

### macOS: 编译报 "Compatibility with CMake < 3.5 has been removed"
- 原因:PATH 里 brew 的 CMake 4.x 太新,老组件不兼容。
- 动作:走 idf-env.sh 就不会遇到——export.sh 会把 IDF 自管的 cmake 排在 PATH 前面。
  若用户自己的终端遇到,让他先 source export.sh 再编译,别用 brew 的 cmake。

### Apple Silicon: "bad CPU type in executable"
- 原因:IDF ≤4.x 的工具链是 x86_64。
- 动作:`softwareupdate --install-rosetta`;或建议升级到 v5.x(原生 arm64)。

### Windows: 乐鑫脚本报 "MSys/Mingw is not supported"
- 原因:Git Bash 的 `MSYSTEM=MINGW64` 遗传给了子进程,官方脚本硬拦截。
- 动作:一律走本 skill 的脚本(内部 `env -u MSYSTEM`);绝不在 Git Bash 里直接跑
  install.sh/export.bat。装机走 install.sh(EIM 路线),执行走 idf-env.sh(eim run)。

### Windows: winget 不可用
- 动作:install.sh 会动态解析 EIM 官方 GitHub 正式 release,同时核对 asset SHA256 与
  Espressif Authenticode 签名,双验通过后才原子落盘和执行。失败时不要绕过验签手动执行 exe;
  先查 GitHub API/证书链/系统时间/公司代理。EIM 安装与运行默认关闭 telemetry。

### Windows: 系统是 ARM64，但 release 只有 eim-cli-windows-x64
- 原因:当前官方 Windows EIM CLI 资产是 x64；“Windows 11”本身不能证明 CPU/OS 架构兼容。
- 动作:先调用固定 helper 的 `CheckPlatform`（人工诊断可读 `.NET RuntimeInformation.OSArchitecture`
  和 `PROCESSOR_ARCHITEW6432`）。非 x64 时停止自动下载，
  复核当期官方 release 是否已有对应资产；没有就明确说明支持边界并选择官方兼容路线，不能硬跑 x64 包。

### EIM 已登记目标版本，但 idf.py/export/Python 工具链损坏
- 原因:这是“已安装但损坏”，不是“未安装”；另一个同版本目录或 ambient `IDF_PATH` 还可能污染验证。
- 动作:从项目证据与 `eim list`/登记文件锁定精确路径，对该路径执行 `eim fix -p <path>`，清除外部
  `IDF_PATH` 后重跑真命令与严格门禁。多个同版本路径无法消歧时停下取证，不重新 install、不静默升级。
  若登记路径已不存在或不再是有效 IDF 仓库，`fix` 本身也不适用；不要把它误报为“未安装”后自动另装，
  由 Agent 说明损坏程度，再决定是否取得用户同意按原位置重建。

### install.sh 显示安装器成功但最终 VERIFY_INSTALL=no
- 原因:安装器退出 0 不代表环境真的可用;可能是 `idf.py --version` 失败、仓库元数据或
  真命令报告了错误版本,
  或 POSIX 最终发现路径不是本次请求路径。
- 动作:按 `VERIFY_REASON=ready|version|path|doctor_exit` 定位。修复后重跑;只有
  `VERIFY_REASON=command_version` 表示真命令版本不匹配。只有 `VERIFY_INSTALL=yes` 和
  `INSTALL_READY=yes` 才能向用户报告装好。

### Python 版本不够
- 闸门:先读取所选 IDF 自带版本检查/当前官方前置。已验证快照为 v5.5 需 ≥3.9、v6.0 需 ≥3.10、
  ≤v5.4 需 ≥3.8；未知的新 major 必须重新取证或 fail closed，不能自动套用 3.8。
- 动作:macOS 重跑顶层 `install.sh`,由 bootstrap 复用兼容 Python、用现有 Homebrew 自动安装,
  或下载验签后的 Python.org pkg;Windows EIM 会自动装。也可明确选择项目要求的较低 IDF 版本。

## 二、编译类

- **首次 build 特别慢**:正常,全量编译几百个文件 + 可能拉组件,后台跑。
- **改了 sdkconfig.defaults 不生效**:defaults 只在生成 sdkconfig 时套用 →
  `idf-env.sh idf.py -C <proj> set-target <芯片>` 重新生成(或删掉 sdkconfig 再 build)。
- **per-target 的 `sdkconfig.defaults.esp32s3` 不生效**:必须同时存在基础 `sdkconfig.defaults`
  文件(哪怕是空的)——官方行为,经典坑。
- **换芯片后一堆诡异错误**:`fullclean` 后重新 `set-target` + `build`。
- **组件找不到 / managed_components 报错**:`idf-env.sh idf.py -C <proj> reconfigure`;
  国内网络组件仓库慢属正常,重试。

## 三、烧录 / 串口类

### 找不到串口
- macOS:换数据线(很多线只供电);CH340 板要 WCH 驱动且 V1.7+ 才支持 Apple Silicon,
  装完在"隐私与安全性"里放行;优先看 `/dev/cu.*` 不是 `/dev/tty.*`。
- Linux:`sudo usermod -a -G dialout $USER` + **重新登录**(仅 source 不够);
  Arch 用 `uucp` 组;Ubuntu 的 `brltty` 会抢占 CH340,卸掉。
- Windows:S3 原生口 Win10+ 免驱;CH340 要装 WCH CH341SER 驱动(全新系统常缺);
  CP210x 一般自动装。

### flash 连不上 / "Failed to connect" / 板子没进下载模式
这不是终态失败,是板子没就绪。标准应对(见 SKILL.md 烧录节):
1. 告诉用户按键顺序:**按住 BOOT(GPIO0)不放 → 点按 RESET(EN)→ 松开 BOOT**;
   没有 RESET 键就按住 BOOT 重新插 USB。
2. 端口不见时跑 `wait-port.sh -t 90`;它只返候选口,多口会拒绝自动选择。
3. 对候选口重跑 `identify-device.sh -p <口>`,芯片型号和 MAC 与用户确认的设备一致才重试。
4. 重试仍连不上:换低波特率 `-b 115200`;换线(充电线没数据脚)、换 USB 口(别过 hub)。
5. 手动下载模式烧完进入 post-flash 两阶段门禁,不要把 flash 退出 0 当成应用已经运行。

### 手动下载模式:flash 成功但新程序不跑
- 原因:手动 BOOT 是本轮历史,不能从端口名可靠反推。部分原生 USB 下载路径的默认 reset 只做
  core reset,不会重新采样 strapping 引脚,板子可能继续留在 ROM 下载模式。
- 动作:在仍是烧录口时先运行
  `post-flash-check.sh prepare -p <口> -m <确认MAC> --download-entry manual` 完成最后验身;
  记下输出的 `POST_FLASH_SESSION`,然后让用户**松开 BOOT,按 RESET/EN 或重新上电**;完成后运行
  `post-flash-check.sh verify --session <token> -C <proj> -e <应用健康标志>`。
- 顺序红线:最终 RESET/上电后不能再跑 `identify-device.sh`。它内部调用 esptool,会主动进入/连接
  ROM 并再次改变启动状态;verify 只能校验 prepare session、重扫端口,再用串口控制线做一次受控
  reset 并采集应用日志。
- 恢复红线:不要默认用 `--after watchdog-reset`。它不适用于所有芯片,C6 原生 USB 上可能导致
  端口消失并需要断电恢复;跨芯片保守兜底是物理 RESET/EN 或重新上电。

### post-flash 结果怎么解释
- `POST_FLASH_READY=yes`/rc=0:只在已完成 prepare 身份重验、应用 `-e` 命中且未见 ROM 下载
  签名时出现。flash 退出 0、`ESP-ROM`、`rst:`、普通 boot 行都不等于应用健康。
- `DOWNLOAD_MODE_SUSPECTED=yes`/rc=20:本轮新鲜日志看到了 `DOWNLOAD_BOOT(...)`、
  `DOWNLOAD(USB/UART0...)` 或 `waiting for download`;让用户释放 BOOT 后物理恢复再 verify。
- `DOWNLOAD_MODE_SUSPECTED=unknown`:无日志、端口消失或 expect 未命中都只能算未知。应用禁用 USB、
  重配 USB 引脚、深睡或崩溃同样可能没日志,不能都误判成下载模式。
- `port_ambiguous`/rc=3:系统里有多个串口,必须选择或暂时拔掉无关设备。macOS `/dev/cu.*` 和
  Windows COM 号只是本轮定位符,不是永久设备身份。
- `port_selection_required`/rc=3:原烧录口消失，只出现了新的候选路径。即使只有一个候选也不能
  自动认作原板；Agent 应结合刷新前后清单、USB topology/serial 或用户明确选择，再以 `-p` 指定恢复口。
  最终恢复后 verify 不再运行 esptool，所以 `CURRENT_PORT_IDENTITY=unverified` 是诚实边界，
  `PRE_RESET_IDENTITY=matched` 只说明 RESET/重新上电前的 MAC 已匹配。

### S3 特有:烧完串口从系统消失
- 原因:固件行为——重配了 USB 引脚(S3 是 GPIO19/20)、禁用了 USB-Serial/JTAG、或进了深睡。
  **不是驱动坏了。**
- 动作:按住 BOOT + 点按 RESET 进下载模式(此时端口会回来)→ 重烧正确的固件。

### 端口被占用 / flash 报 busy
- 原因:上一个 monitor 进程没退干净(它独占串口)。
- 动作:`pkill -f esp_idf_monitor`(Windows: 任务管理器杀 python/monitor 进程)后重试。
  本 skill 的 monitor.sh 自带超时,正常不会残留。

### 烧录中途断开
- S3 原生口在烧录/复位时会断开重枚举属正常;失败就重扫端口再来一次。
  连续失败换 USB 口(别用 hub)、换线。

## 四、monitor 类

- **脚本报 monitor 需要 TTY**:说明误跑了官方 `idf.py monitor` 或旧版脚本;
  agent 用 `scripts/monitor.sh` 的 pyserial 有界采集,它不依赖 TTY。
- **等不到 expect 的关键字**:烧录后先走 post-flash 两阶段门禁;单独 monitor 超时不能证明仍在
  下载模式。再检查正则是否写太死、波特率是否匹配项目配置。
- **expect 报 unsafe regex / rc=64**:模式包含 `(a+)+` 这类量词嵌套,或长度超过 4096 字符;
  这类表达式可让回溯引擎无界占用 CPU,因此被安全门禁拒绝。改成简单关键字、顶层交替或非嵌套量词;
  其他正则也会在可终止子进程中受 `-t` 总 deadline 约束。
- **纯采集 rc=0 但没有日志**:看 `DATA_SEEN=no`/`CAPTURE_BYTES=0`;这只表示采集窗口正常结束,
  不表示固件有输出。需要健康判定时必须传 `-e <正则>`。
- **输出乱码**:波特率不匹配;或板子在疯狂重启(看是否反复打印 boot 日志 → 固件崩溃,
  把采集到的 backtrace 给用户分析)。
- **反复重启 + "rst:0x10 (RTCWDT_RTC_RESET)"** 之类:固件崩溃回环,读 backtrace 定位,
  与烧录流程无关。
