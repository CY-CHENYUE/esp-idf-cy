---
name: esp-idf-cy
description: 面向第一次接触 ESP-IDF 的新手及已有工程用户的一站式 skill——用户只需说板子/芯片和想做什么,skill 自动检测或安装 macOS/Windows 开发环境(国内网络走乐鑫官方镜像),并完成编译、烧录、串口验证和排错;EIM、Python、工具链与环境激活默认由 skill 内部处理。支持 ESP32 全系芯片(ESP32/S2/S3/C3/C6 等)。当用户提到 "ESP-IDF"、"idf.py"、"ESP32 编译"、"烧录固件"、"flash 到板子"、"串口 monitor/日志"、"装 ESP-IDF"、"IDF 环境配置"、"menuconfig"、"sdkconfig"、"hello_world 跑不起来"、"找不到串口/COM口"、"esptool" 时必须触发;即使用户只说"我刚买了 ESP32-S3,电脑什么都没装,帮我开始"、"帮我把这个 ESP32 项目编译烧录一下"、"看看板子输出了什么",也应触发。不做:Arduino-ESP32 / PlatformIO 工作流,具体外设驱动业务代码的编写。
license: Apache-2.0
allowed-tools: Bash, Read, Edit, Write
---

# esp-idf-cy — ESP-IDF 编译/构建/烧录(agent 能力为主,脚本为辅)

## 你在处理什么

用户可能用 Mac 也可能用 Windows,项目在任何位置,ESP-IDF 装没装、怎么装的、装的哪个版本都不确定。
你的职责:用户一句"编译烧录",你负责搞清环境 → 缺什么补什么 → 编译 → 烧录 → 验证。
环境差异和故障靠**你自己的侦察和判断**吸收,不指望用户懂环境,也不指望脚本枚举了所有情况。

宿主边界:本 skill 运行在已经能执行 Agent 工具的会话里。macOS/Linux 需要可调用 Bash;
Windows 需要 Agent 宿主提供 Git Bash，或由 Agent 直接用系统 PowerShell 调用
`scripts/eim-windows.ps1`。它会自动补齐 ESP-IDF 所需的 EIM、Python、Git 和工具链，
但不能在自己尚无法执行时“先安装自己的 shell/Agent 宿主”。不要把这个边界甩给新手；
若当前 Windows 会话没有 Bash，就由你改走已有 PowerShell，而不是要求用户学习 EIM。

### 新手第一次使用的体验目标

默认把用户当作可能完全没装过、也不需要先理解 ESP-IDF 安装体系的新手:

- 用户只需要提供能知道的业务信息:板子/芯片型号、已有项目路径,以及想编译还是烧录。
  能从已连接板子、项目 `sdkconfig`/README 自动判断的就自己判断;只有判断不出且会改变 GB 级
  下载目标或烧录安全性时,才问一个简短问题。
- EIM、`export.sh`、Python 虚拟环境、工具链包和镜像都是**内部实现细节**。默认只报告结果,
  不把安装教程、官网链接或一串依赖清单甩给用户;只有失败定位或用户主动追问时才解释。
- `doctor.sh` 若证明现有环境 `READY=yes`,就复用探测到的精确版本和位置,继续用户的任务。
  **不要因为有更新的 stable 就静默升级、重装或切换版本。**
- 确认没有可用环境时才自动安装:已有项目优先服从项目锁定的精确版本;新项目用 `stable`;
  从板子推导并显式传 `--targets`,避免默认下载全部芯片工具链。安装完成必须真实执行
  `idf.py --version`;若用户要“从零开始/跑起来”,再用对应 target 构建官方最小示例完成端到端验证。
- 正常情况下不要让用户暂停去手工装 Python/Git/SDK 或访问网页。只在系统权限/系统弹窗
  (如 macOS Command Line Tools)、缺少无法探测的板型信息,或真实烧录确认时请用户介入。
- 完成后用新手听得懂的三件事收口: **装好了什么版本和位置、验证到了哪一步、下一句可以怎么说**。
  不要用 EIM 等实现名词作为成功摘要的主角。

四条物理事实,决定了下面所有做法:

1. **`export.sh` 只对当前 shell 生效**,而你每次 Bash 调用都是新 shell
   → 每条 idf 命令都要在**同一条命令里**先装配环境。
2. **你没有交互终端** → menuconfig(TUI)和官方 `idf.py monitor`(强制要求 TTY)
   对你不可用;配置改 defaults,日志验证用有界的 pyserial 采集器。
3. **烧录/复位会让 USB 重枚举** → 端口名不能跨步骤缓存,每次烧录/监视前重扫。
4. **烧录 = 覆盖用户硬件上的固件**,板上可能跑着用户其他项目
   → 未验明设备身份并经用户确认,不烧。这条不因任何理由松动。
5. **flash 退出 0 ≠ 新固件已经运行** → 手动下载模式可能仍停在 ROM;只有目标身份已重验、
   应用专用健康标志命中且没有 ROM 下载证据,才能报告烧录闭环完成。

## 工作方式:侦察 → 判断 → 行动 → 验证

以你自己的能力为主:自己跑命令探测、自己读报错、自己决定下一步。
脚本和文档是工具不是流程——脚本覆盖不了的情况,你直接上手。

### 侦察:环境线索在哪

省事的话跑 `bash <skill>/scripts/doctor.sh` 一次拿全景(KEY=VALUE 输出)。
自己侦察时的线索地图:

- **IDF 在哪**:`$IDF_PATH` 环境变量;EIM 登记文件 `eim_idf.json`(POSIX 在
  `~/.espressif/tools/`,Windows 在 `C:\Espressif\tools\`);惯例路径 `~/esp/esp-idf*`。
  版本用 `git -C <目录> describe --tags` 拿,别信目录名。
- **工具链健康度**:`~/.espressif/python_env/idf<IDF版本>_py<py版本>_env`——目录名本身
  编码了它绑定的 python 版本,系统 python 升级过它就失效(经典坑)。
- **python 闸门**:装/用 v5.5 要 ≥3.9,v6.0 要 ≥3.10。
- **串口**:mac 看 `/dev/cu.usbmodem*`(乐鑫原生口)和 `/dev/cu.usbserial*`/`SLAB*`/`wch*`(桥接);
  linux 看 `/dev/ttyACM*`/`/dev/ttyUSB*`;Windows 用 PowerShell
  `Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Ports'"`,乐鑫原生口 DeviceID 含
  `VID_303A&PID_1001`。
- **网络**:GitHub 不畅但国内可达 → 全程走乐鑫官方镜像(`references/china-mirrors.md`),
  绝不让用户开 VPN。
- 探到多个 IDF 版本或奇怪位置 → 把候选列给用户选,别猜。

### 环境装配:每条 idf 命令的写法

- **mac / linux**(同一条 Bash 里串起来):
  ```bash
  source <IDF_PATH>/export.sh >/dev/null 2>&1 && idf.py -C <项目目录> build
  ```
- **Windows(你跑在 Git Bash 里)**:
  ```bash
  bash <skill>/scripts/idf-env.sh idf.py -C <项目目录> build
  ```
  为什么清 `MSYSTEM`:乐鑫官方脚本检测到 MSYS 环境直接拒跑,而 Git Bash 会把
  `MSYSTEM=MINGW64` 遗传给一切子进程。wrapper 内部经固定 PowerShell 边界验 EIM 的
  Authenticode 签名,关闭 EIM telemetry 后再 `eim run`;免激活执行是 Windows 首选;
  没有 EIM 的 legacy 安装才考虑 `env -u MSYSTEM cmd.exe //c "call <IDF>\export.bat && ..."`(实验性)。
- 嫌拼写啰嗦可用 `bash <skill>/scripts/idf-env.sh idf.py ...` 等价替代——两种写法效果相同,选顺手的。
- 项目位置永远来自用户上下文(用户说的路径/当前目录),用 `idf.py -C` 传,不确定就问。

### 安装(侦察确认没装才做)

- 先以 `doctor.sh` 的真实命令结果分流:`READY=yes` 就原样复用现有版本,不安装、不升级;
  `READY=no` 且确认没有其他可用候选时才进入安装。多版本但都可用时按项目版本选择,
  不让新手先理解安装器差异。
- 省事路径:`bash <skill>/scripts/install.sh [--version stable|v5.5|v5.5.4] [--targets esp32s3]`
  ——幂等、可安全重跑、国内自动镜像。首次 clone 走同级受管暂存区,完整后才原子落位;
  子模块与工具下载可重复执行。下载量以 GB 计,后台跑或放宽超时。
- **macOS 空白机**:`install.sh` 会先调用 `bootstrap-macos.sh`。缺 Command Line Tools 时主动
  拉起苹果系统安装窗口;缺兼容 Python 时,已有 Homebrew 就自动安装,没有 Homebrew 就从
  Python.org 下载固定版本的 universal2 官方包,同时校验 SHA256 和 Python Software Foundation
  签名后才打开系统安装器。系统 UI 必须由用户本人确认;脚本返回 `ACTION_REQUIRED`/rc=20 时
  不是安装失败,等用户完成后重跑原命令即可续上。不要静默安装 Homebrew,也不要用 `curl|sh`
  引入第三方 Python。EIM 的自动前置参数只支持 Windows,不能拿它替代这层 bootstrap。
- **脚本失败或不适用**(特殊版本/公司代理/非常规位置):别无脑重跑。读它的输出定位卡点,
  按 `references/install-playbook.md` 的配方自己一步步来——每一步都能单独重试和替换。
- 版本选择:先看项目 README/CI/容器配置;已有项目跟它的精确版本。新项目默认
  `stable`;`--version v5.5` 表示“5.5 系列最新 patch”,要复现才传 `v5.5.4` 这类精确 tag。
- `--targets` 从板子/项目推导并显式传入(C6→`esp32c6`);真不知道才用 `all`。
- Windows 优先用 `winget` 精确包/官方源/用户 scope 安装 EIM;fallback 动态读官方 GitHub release,
  必须同时通过 release asset SHA256 与 Espressif Authenticode 签名才落盘和执行。EIM 的安装/运行
  都默认 `--do-not-track true`;不要直接执行未验签的下载 exe。
- 装完必须经过严格门禁:真实运行 `idf.py --version`,`READY=yes`,仓库元数据版本与
  `idf.py --version` 实际报告版本都必须和请求精确一致;
  macOS/Linux 还要与请求安装路径一致。任一不满足都算安装失败,不能因安装器退出 0 就报成功。
  用户的目标是开始开发时,继续做目标芯片的最小示例构建,
  不把“安装脚本退出 0”当作完成。最后用人话告诉用户版本、位置、验证结果和下一步即可。

### 编译

- 芯片型号从用户话里拿("S3 板子"→ esp32s3),或看项目 sdkconfig 的 `CONFIG_IDF_TARGET`,
  都没有就问。首次或换芯片先 `set-target`(会重新生成 sdkconfig)。
- 首次 build 编译几百个文件,几分钟正常,后台跑。
- 报错不要瞎试:先看第一个 `error:`,对照 `references/troubleshooting.md`,没匹配再自己分析。
- 编译完把关键信息报给用户:固件大小、分区余量(build 输出末尾就有)。

### 烧录(硬安全规约,agent-first 不改变这条)

1. 重扫端口(线索见"侦察";或 `bash <skill>/scripts/find-port.sh`)。
2. 只读验明设备:`bash <skill>/scripts/identify-device.sh -p <口>` 拿芯片型号+MAC
   (内部兼容 esptool v4/v5 命令名;连接会复位板子,但不写 flash)。
3. 向用户报告"将烧录到 <口> 的 <型号>(MAC xx:xx)",**用户确认才烧**;
   多设备把候选全列出来让用户挑;芯片型号和项目 target 不符,拦下来问。
4. 烧录显式 `-p`。只要经历复位/掉线/USB 重枚举,必须在新口上重跑
   `identify-device.sh`;**MAC 与用户刚确认的设备一致**才能续烧。同一 MAC 无需再问,
   不同/读不出则立即停。

**板子没进下载模式 / 连不上时的标准应对**(不要报错了事,把用户带过去):

烧录报 `Failed to connect` / `Timed out waiting for packet header`,或者根本扫不到端口——
这不是失败,是板子还没就绪。流程:

1. 用人话告诉用户怎么进下载模式:**按住 BOOT(GPIO0)键不放 → 点按一下 RESET(EN)→
   松开 BOOT**;板上没有 RESET 键就按住 BOOT 重新插 USB 线。
2. 端口不见时跑 `bash <skill>/scripts/wait-port.sh -t 90`;它只返回 `CANDIDATE_PORT`,
   多口时拒绝猜 `BEST_PORT`。拿到候选口后重跑 `identify-device.sh`,匹配原 MAC 才续烧。
   等特定口用 `-p <端口>`,但即使名字没变也要重验身份。
3. 手动下载模式烧完不能只“提醒一下”就算结束。记录本轮进入方式为 `manual`(无法确认则
   `unknown`),在仍是刚才烧录口时先用下面的 post-flash `prepare` 重验 MAC;随后立即让用户
   **松开 BOOT,按一下 RESET/EN 或重新上电**。这一步返回 rc=20 是可恢复的人机交接,不是失败。
4. wait-port 超时(90s 没动静):按它输出的 HINT 引导用户检查数据线/按键顺序/驱动,再等一轮;
   连接不稳的板子换 `-b 115200` 低速烧。

### 烧录后闭环(prepare → 物理恢复 → verify)

`identify-device.sh` 内部使用 esptool,会主动连接 ROM 并改变复位状态。因此 MAC 的最后一次重验
必须发生在**最终物理恢复之前**;用户按 RESET/重新上电后严禁再跑 identify/esptool 来判断
“是否还在下载模式”。使用两阶段门禁:

```bash
# flash 刚结束,仍在刚才确认过的烧录口上
bash <skill>/scripts/post-flash-check.sh prepare \
  -p <烧录口> -m <用户已确认的MAC> --download-entry manual

# 记下 prepare 输出的 POST_FLASH_SESSION。rc=20 时让用户松开 BOOT 后按 RESET/EN
# 或重新上电;完成后用该 session 继续
bash <skill>/scripts/post-flash-check.sh verify --session <POST_FLASH_SESSION> \
  -C <proj> -e '<能证明应用健康的正则>' [-p <已明确的恢复后端口>]
```

- `--download-entry` 由你根据本轮历史显式传 `automatic|manual|unknown`,不能从端口日志猜。
  `manual/unknown` 的 prepare 会立即输出 `ACTION_REQUIRED=release_boot_then_reset_or_power_cycle`
  和 rc=20;用户完成动作后拿同一个短期 session 续跑 verify,不要把模式改写成 automatic。
- prepare 会把已匹配的 MAC、进入方式和烧录口写入权限受限、限时的 session;verify 必须校验它,
  不能靠调用方自报“已经验过身份”。成功后 session 自动消费。
- verify 阶段只做 fresh rescan + 串口控制线受控 reset/采集,**零次调用 identify/esptool**。
  多口时 rc=3 并要求用户
  选择或暂时拔掉无关设备;macOS 的 `/dev/cu.*`、Windows 的 COM 号都不是永久身份。
- 只有应用 `-e` 命中时才输出 `POST_FLASH_READY=yes`/rc=0。`DOWNLOAD_BOOT(...)`、
  `DOWNLOAD(USB/UART0...)`、`waiting for download` 是仍在 ROM 下载模式的强证据,输出 rc=20;
  无日志、端口消失、普通 `ESP-ROM`/`rst:` 文本只是不确定,不能冒充 READY 或下载模式确诊。
- 原始串口内容不混入机器 KV,而是写到 `CAPTURE_LOG` 指向的权限受限系统临时文件;需要排错时读取,
  任务结束后删除。恢复后的 `-p` 只是本轮明确定位符,多口或无法唯一关联时必须停下来让用户选择。
- 不默认尝试 `--after watchdog-reset`:它不是全芯片通用恢复路径,C6 原生 USB 场景甚至可能需要
  断电恢复。跨 ESP32 系列的保守兜底始终是释放 BOOT 后物理 RESET/EN 或重新上电。

### 监视(只采集日志或作为上述 verify 的底层)

官方 esp-idf-monitor 在 stdin 非 TTY 时会拒绝启动;它没有 `expect/reset/exit` 文本 DSL。
agent 验证固件用有界的直接串口采集:

```bash
bash <skill>/scripts/monitor.sh -p <口> -C <proj> -t 50 -R -e '<能证明正常的正则>'
```

脚本会从 `build/project_description.json` 读波特率(也可 `-b` 覆盖),匹配则 0,
超时未匹配则 1,开口失败 2,读取失败 3,缺 pyserial 4,参数错误 64;输出
`DATA_SEEN`/`CAPTURE_BYTES` 区分“完成了纯采集”和“真的看到了数据”。它不做官方 monitor 的符号化地址解码;
用户给定的 expect 正则会在可终止的独立进程里匹配,并受采集总 deadline、64 KiB 窗口和
4096 字符模式上限约束;量词嵌套等高风险模式直接 rc=64,不能用复杂回溯绕过 `-t` 超时。
如需人类交互调试,告诉用户在真终端里跑 `idf.py monitor`。**agent 不裸跑它**。
单独 monitor 等不到输出时不要直接断言仍在下载模式;回到上面的 post-flash 两阶段门禁。

### 配置修改

改项目的 `sdkconfig.defaults`(没有就创建)→ `set-target` 重新生成。
不直接编辑生成的 sdkconfig(会被覆盖),不跑 menuconfig。常用 CONFIG 项见 `references/idf-commands.md`。

## 辅助工具箱(可选加速器,不是必经之路)

| 脚本 | 值得用的时候 | 别依赖它的时候 |
|---|---|---|
| `scripts/doctor.sh` | 开场一次拿全景,省多轮探测 | 输出和你实际观察冲突时,以实际为准 |
| `scripts/install.sh` | 标准安装(mac bootstrap+legacy / win EIM + 镜像) | 非标场景 → install-playbook 手动配方 |
| `scripts/bootstrap-macos.sh` | Mac 缺 CLT/Python 时自动补到系统 UI 边界 | 非 macOS;系统安装窗口仍需用户本人确认 |
| `scripts/idf-env.sh` | 不想手拼 source && ... | 需要特殊环境变量/调试 export 过程时手写 |
| `scripts/find-port.sh` | 快速扫口;单口给候选,多口报需选择 | 它不代替芯片+MAC 验身 |
| `scripts/identify-device.sh` | 烧前及重枚举后读芯片+MAC | 读不出就停,不用端口名替代身份 |
| `scripts/wait-port.sh` | 提示用户操作后等候选端口 | 多口不自动选;返回后必须重验 MAC |
| `scripts/monitor.sh` | 无 TTY 时定时采集日志/正则验证 | 需要地址符号化或人类交互时用真终端的官方 monitor |
| `scripts/post-flash-check.sh` | flash 后做 prepare/verify 闭环,处理手动下载模式 | verify 后不再跑 identify;无应用 expect 不能判 READY |

同一个脚本失败两次 → 停止重试脚本,读输出、换你自己的手来。

## references(知识库,按需读)

- `references/troubleshooting.md` — 排错剧本:安装/编译/烧录串口/S3 特有坑,报错先查这里
- `references/install-playbook.md` — 手动安装配方(双平台分步 + 每步的失败处理)
- `references/idf-commands.md` — idf.py/esptool/eim 速查、esptool 版本差异、常用 sdkconfig 项
- `references/china-mirrors.md` — 国内镜像机制底账(排查镜像问题时看)

## 反模式

- ❌ 不装配环境裸跑 `idf.py`(必失败)
- ❌ 裸跑 `idf.py monitor` / `menuconfig`(交互式,卡死会话)
- ❌ 缓存串口名跨步骤复用,或把新端口名当设备身份(重枚举后要对 MAC)
- ❌ 把 flash 退出 0、普通 boot log 或无 expect 的 monitor rc=0 当作应用已运行
- ❌ 用户最终 RESET/上电后再跑 identify/esptool“验身”(它会重新扰动启动状态)
- ❌ 跨芯片默认使用 watchdog reset;C6/原生 USB 兜底请用户物理 RESET 或重新上电
- ❌ 不验明设备、未经用户确认就烧录(多设备烧错板子;板上可能是用户其他项目)
- ❌ 被脚本框死:脚本失败无脑重跑、脚本没覆盖就说做不了(你的能力才是主体)
- ❌ 假设用户平台、假设项目在固定路径
- ❌ 国内装不动让用户开 VPN(官方镜像全覆盖)
- ❌ 直接编辑生成的 sdkconfig

## 环境变量

| 变量 | 用途 | 默认 |
|---|---|---|
| `ESP_IDF_CY_IDF_PATH` | 显式指定用哪个 IDF(多版本/非常规位置) | 自动探测 |
| `ESP_IDF_CY_EIM_BIN` | 显式指定 EIM 二进制(直下/非 PATH 安装) | PATH 或 `~/.esp-idf-cy/bin/eim(.exe)` |
| `ESP_IDF_CY_EIM_VERSION` | Windows fallback 要求的精确 EIM tag;不设则动态取最新正式版 | 最新正式版 |
| `ESP_IDF_CY_PYTHON_BIN` | 显式指定兼容 Python;Mac bootstrap 成功后也用它续传 | 自动探测 |
| `ESP_IDF_CY_MAC_PYTHON_VERSION` | 无 Homebrew 时下载的 Python.org 版本 | 3.13.14 |
| `ESP_IDF_CY_MAC_PYTHON_SHA256` | 对应 Python.org pkg 的 SHA256 | 内置官方发布值 |
| `ESP_IDF_CY_MAC_PYTHON_URL` | 公司镜像/后续维护时覆盖官方 pkg URL | python.org 官方 URL |
| `ESP_IDF_CY_CURL_BIN` | 覆盖网络探针和 macOS 下载所用 curl(测试/非标准环境) | `curl` |
| `IDF_TOOLS_PATH` | 工具链位置(透传给官方脚本) | `~/.espressif` |
