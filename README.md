# esp-idf-cy

面向 ESP-IDF 新手和已有工程用户的一站式 Agent Skill：自动侦察或准备 macOS / Windows 开发环境，并协助完成编译、烧录、串口验证和排错。

它把 EIM、Python、工具链、环境激活和国内网络镜像等细节尽量留在内部处理。用户通常只需说明板子或芯片型号、项目位置，以及想做什么。

## 适用场景

- 第一次使用 ESP32，希望从空白电脑开始准备 ESP-IDF 环境
- 检查现有 ESP-IDF、Python、工具链和串口是否可用
- 编译 ESP32、ESP32-S2、ESP32-S3、ESP32-C3、ESP32-C6 等 ESP-IDF 工程
- 安全识别开发板，确认后烧录固件
- 在 Agent 没有交互式 TTY 时限时采集串口日志
- 排查 `idf.py`、工具链、下载模式、串口或国内网络问题

## 不适用场景

- Arduino-ESP32 或 PlatformIO 工作流
- 代替用户设计具体外设驱动或业务代码
- 在没有用户确认目标设备时自动写入开发板
- 代替宿主 Agent 自身所需的 Shell、终端或系统权限

## 安装

### Codex

直接克隆到 Codex 的技能目录：

```bash
git clone https://github.com/CY-CHENYUE/esp-idf-cy.git ~/.codex/skills/esp-idf-cy
```

如果已经有一份本地 checkout，建议使用软链接，避免维护两份源码：

```bash
ln -s /你的绝对路径/esp-idf-cy ~/.codex/skills/esp-idf-cy
```

### Claude Code

直接克隆到 Claude Code 的技能目录：

```bash
git clone https://github.com/CY-CHENYUE/esp-idf-cy.git ~/.claude/skills/esp-idf-cy
```

也可以把同一份 checkout 软链接过去：

```bash
ln -s /你的绝对路径/esp-idf-cy ~/.claude/skills/esp-idf-cy
```

安装或更新后新开一个会话，并确认技能列表中出现 `esp-idf-cy`。如果客户端使用自定义技能目录，请以客户端实际配置为准。

### 从 cc-skills 使用

本项目的日常开发源位于 `cc-skills/esp-idf-cy`。如果已经克隆完整的 `cc-skills`，可让客户端直接扫描该目录，或把其中的 `esp-idf-cy` 软链接到客户端技能目录。

## 触发方式

可以直接说：

```text
我刚买了 ESP32-S3，Mac 上什么都没装，帮我把环境准备到 hello_world 能编译。
```

```text
帮我检查这个 ESP-IDF 项目，目标是 ESP32-C6，只编译，不要烧录。
```

```text
帮我把固件烧到板子上，然后抓 30 秒串口日志验证 READY_FOR_TEST。
```

提到 ESP-IDF、`idf.py`、环境安装、编译、烧录、串口、`menuconfig`、`sdkconfig`、`esptool` 或 ESP32 项目排错时，也会触发该技能。

## 工作方式

1. 侦察当前平台、已有 IDF、Python、工具链、工程目标和串口。
2. 区分“健康可复用 / 已安装但损坏 / 确实未安装”：健康环境不动，损坏环境精确修复，只有缺失时才新装。
3. 为每条 `idf.py` 命令装配正确环境，完成目标芯片的构建。
4. 烧录前读取芯片型号和 MAC，并等待用户确认；烧录口发生变化时拒绝按端口名猜设备。
5. 烧录后先在最终恢复前重验 MAC；手动下载模式会引导用户释放 BOOT 后按 RESET/重新上电，
   最终恢复后不再用 esptool 扰动板子，只靠应用专用健康日志完成验证。

这是一个 Agent-first Skill，不是固定安装脚本。Agent 负责读取项目与机器证据、选择路线、解释异常、
取得烧录确认并把任务推进到真实验证；`SKILL.md` 规定决策顺序和安全红线；`references/` 是按需读取并
结合当前官方能力复核的知识；`scripts/` 提供可重入的默认动作，并承担验签、参数边界、身份解析、
精确校验和超时等机械工作，但不替 Agent 决策或代替用户授权。
因此安装位置、目标芯片、Python 下限、EIM 登记和串口都来自当前电脑，而不是文档里的示例值。

macOS 和 Windows 都支持 EIM。Skill 会根据实机动态分流：Windows 优先 EIM；Mac 已有健康 IDF
就复用，已有可用 EIM 或 Homebrew 时走 ESP-IDF v6.0+ 官方推荐的 EIM CLI；EIM 与 Homebrew 都
没有时不静默安装新的包管理器，改走仍受官方支持的 Command Line Tools/Python + ESP-IDF 官方脚本路线。
用户传入的项目、IDF位置和 EIM 登记都是探测结果，不用本机用户名或固定绝对路径硬编码。

Windows 还有一个重要差异：EIM 的 `-a true` 可自动补 Python、Git 等前置，而 macOS EIM 只检查
POSIX 前置，缺项由 Agent 按实机补齐或切换官方脚本路线。当前官方 Windows EIM CLI 资产是 x64；
Agent 会先检查系统架构，不会在 ARM64 Windows 上盲下 x64 可执行文件。macOS EIM 原生支持 Intel
和 Apple Silicon，但它仍不是 macOS 完成 ESP-IDF 开发所必需的底层依赖。

## 文件结构

```text
esp-idf-cy/
├── SKILL.md                    # Agent 入口、流程与安全规约
├── README.md                   # 用户安装和使用说明
├── LICENSE                     # GNU GPL v3.0 only
├── assets/
│   └── wechat-qr.jpg
├── scripts/                    # 侦察、安装、环境、端口、验身与串口工具
├── references/                 # 安装、命令、镜像和排错知识库
├── tests/                      # 软件回归测试
└── evals/
    └── evals.json              # 典型行为评测用例
```

## 使用示例

### 检查现有环境

```text
看看我电脑上的 ESP-IDF 能不能直接开发 ESP32-S3，健康的话不要升级。
```

技能会报告实际版本、位置和可用性，并避免覆盖健康安装。

### 编译已有工程

```text
项目在 ~/work/sensor-node，目标是 ESP32-C6，帮我 set-target 后编译。
```

技能会使用用户提供的项目路径，正确激活 IDF 环境，并报告构建产物和分区余量。

### 烧录与验证

```text
编译好了，帮我识别连接的板子。确认是我的那块后再烧录，并检查启动日志。
```

烧录属于硬件写操作。技能会先读取芯片型号和 MAC、核对项目 target，并在用户明确确认后才执行。
如果本轮通过 BOOT 键手动进入下载模式，flash 成功后并不等于固件已经运行。技能会自动进入
`prepare → 物理 RESET/重新上电 → verify` 闭环；只有应用健康标志命中且没有 ROM 下载模式证据时，
才会报告 `POST_FLASH_READY=yes`。多串口时不会猜，C6 等原生 USB 场景也不会默认尝试有风险的
watchdog reset。

## 常见问题

### Mac 需要安装 EIM 吗？

不是必须，但完全可以用。乐鑫官方支持 Intel 与 Apple Silicon，并推荐用 Homebrew 安装 EIM：

```bash
brew tap espressif/eim
brew install eim                  # CLI
# 或 brew install --cask eim-gui  # 图形界面
```

ESP-IDF v6.0 起，EIM 是乐鑫在 macOS 上的默认推荐安装方式。这个 Skill 采用自适应策略：

- 已有健康 IDF：发现并验证后直接复用，不重复安装。
- 已有 EIM 登记但该精确 IDF 损坏：对登记的精确路径执行修复并复检，不借机升级或另装一份。
- 已有 EIM、没有健康 IDF：复用 EIM，由它真实检查依赖并安装；失败时 Agent 按缺项换路或说明。
- 已有 Homebrew、没有 IDF：由 Agent 补官方前置并使用 EIM CLI。
- EIM 与 Homebrew 都没有：不静默安装长期包管理器，使用仍受官方支持的脚本路线。
- 用户明确指定精确 IDF 仓库路径：保留该语义，使用官方脚本路线，不把 EIM 的 base path 偷换成仓库路径。

参考：[乐鑫 EIM 平台与安装说明](https://docs.espressif.com/projects/idf-im-ui/en/latest/index.html)、
[macOS/POSIX 前置依赖说明](https://docs.espressif.com/projects/idf-im-ui/en/latest/prerequisites.html)、
[ESP-IDF v6.0+ macOS 安装说明](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/macos-setup.html)。

### 空白电脑上的依赖会自动安装吗？

会尽量自动处理。Windows EIM 可以自动补 Python/Git 等前置；macOS 上 Skill 可触发 Command Line
Tools 安装，并复用 Homebrew 安装兼容 Python，或下载并验签 Python.org 官方安装包。苹果系统窗口、
管理员授权等边界仍需用户本人确认。macOS EIM 本身只会检查 POSIX 前置依赖，缺失时不会全部代装；
因此 Skill 不会把“EIM 已安装”等同于“空白 Mac 已准备完成”。

### Agent 会操作 EIM GUI 吗？

CLI 是默认且可移植的路线。用户明确要求 GUI、当前宿主又提供 Computer Use 时，Agent 可以打开
EIM并操作普通按钮、版本选择和日志页面；密码、Touch ID、UAC、macOS 安全窗口与许可确认必须
由用户本人完成。没有 Computer Use 时自动回到 CLI，不要求新手照着长教程自己点击。

### 安装位置或项目位置不一样怎么办？

Skill 按证据发现：项目 `build/project_description.json`、环境变量、EIM 登记、IDE设置和受限范围
搜索，`~/esp`/`C:\esp` 只作为最后候选。发现候选后还会真实执行 `idf.py --version`，不会仅看目录。

ESP-IDF 官方不支持 IDF 或项目路径包含空格。Skill 会在编译前拦截这种路径；不会假装“加引号”
就能解决。Agent 会检查项目依赖后，在无空格位置建立受管工作副本或经用户确认迁移，不直接覆盖原项目。
参见[乐鑫命令行项目说明](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/linux-macos-start-project.html)。

### 会自动升级已有 ESP-IDF 吗？

不会。只要现有环境真实验证为健康，就复用当前精确版本和位置；已有项目优先遵循项目锁定版本。
若现有 EIM 安装损坏，Skill 修复的是 EIM 登记中的那一个精确路径，并在清除外部 `IDF_PATH` 干扰后
验证真实版本；不会把另一个同版本目录误当作修复成功。

### 会直接烧录连接的板子吗？

不会。技能必须先识别芯片和 MAC、核对目标芯片并取得用户确认。若重枚举后还要继续写入，
必须在续烧前重新验明设备；最终 RESET/重新上电后的只读应用验证不会再调用 esptool。
最终恢复后即使系统里只出现一个新串口，它也只是候选，不能证明还是原设备；Agent 会结合前后设备
清单、USB 拓扑/序列号或用户选择明确指定恢复口，同时把当前端口身份保持为“未重新验证”。

### 为什么不用 `idf.py monitor`？

Agent 会话通常没有交互式 TTY。技能附带有界的 pyserial 采集器，可按超时和健康正则退出；正则匹配在可终止子进程中运行，高风险量词嵌套会被直接拒绝，其余匹配受采集总超时和 64 KiB 窗口约束。人类需要交互调试时仍可在真实终端运行官方 monitor。

### 烧录成功后为什么还要按 RESET？

用 BOOT 键手动进入 ROM 下载模式时，部分芯片/USB 路径在烧录结束后仍不会重新采样启动引脚，
所以板子可能继续等待下载。技能会把这一步当作可恢复的人机动作，而不是等串口超时后才猜测；
用户只需松开 BOOT，按一下 RESET/EN 或重新上电，后续验证会自动继续。

## 验证边界

仓库中的自动测试覆盖脚本参数、动态路径发现、空格路径拒绝、macOS EIM路由、固定 argv relay、
Windows EIM 静态约束、精确安装/修复门禁、esptool v4/v5 身份解析、串口控制线极性和
烧录后状态机。macOS / Windows 空白机安装、不同网络环境、USB 驱动以及各型号实机烧录仍受
外部系统和硬件影响；软件回归通过不等于所有平台与开发板组合都已完成实机验收。烧录和硬件验证
应在目标设备上执行，重点覆盖 S3/C3/C6 原生 USB 与 CP210x/CH340 桥接串口。

## 隐私与安全提示

- `doctor.sh` 的网络诊断只探测安装实际使用的 ESP-IDF GitHub 仓库、JihuLab 镜像和乐鑫下载镜像，不访问无关第三方站点；它也会输出本机发现到的 IDF 路径。
- `identify-device.sh` 会读取并输出开发板 MAC 地址。
- `monitor.sh` 会输出设备串口日志；日志可能含 Wi-Fi、设备标识、业务数据或其他敏感内容。
- `post-flash-check.sh verify` 为防止设备日志伪造机器状态,会把原始串口内容单独保存到系统临时目录,
  并输出 `CAPTURE_LOG` 路径；诊断完成后可删除该目录。prepare 的限时 session 也只保存在权限受限
  的系统临时目录,不会进入 Skill 仓库。
- 把诊断结果、终端截图或日志公开粘贴到 Issue、聊天或论坛前，请先删除用户名、本机路径、MAC、凭据、网络信息和业务数据。
- 技能不会绕过烧录确认；下载并执行 Windows 安装器前应经过来源、校验和签名验证。

## 同步来源

本独立仓库是公开发布镜像。canonical source 位于 `cc-skills/esp-idf-cy`；长期修改先进入 `cc-skills`，再通过可审计的同步流程发布到这里，不在两个仓库分别维护。

## 许可

本项目使用 [GNU General Public License v3.0 only](LICENSE)。

## 交流

![wechat qr](assets/wechat-qr.jpg)
