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
2. 复用健康环境；仅在确认不可用时安装或修复。
3. 为每条 `idf.py` 命令装配正确环境，完成目标芯片的构建。
4. 烧录前读取芯片型号和 MAC，并等待用户确认；烧录口发生变化时拒绝按端口名猜设备。
5. 烧录后先在最终恢复前重验 MAC；手动下载模式会引导用户释放 BOOT 后按 RESET/重新上电，
   最终恢复后不再用 esptool 扰动板子，只靠应用专用健康日志完成验证。

macOS 主要使用 ESP-IDF 官方脚本和系统工具，不需要 EIM。Windows 优先把 EIM 作为内部安装和免激活执行通道；缺少 Python、Git 或工具链时，技能会在安全校验和系统权限允许的范围内自动补齐。macOS 的 Command Line Tools 或 Python 官方安装包可能需要用户确认系统窗口。

## 文件结构

```text
esp-idf-cy/
├── SKILL.md                    # Agent 入口、流程与安全规约
├── README.md                   # 用户安装和使用说明
├── LICENSE                     # Apache-2.0
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

不需要。macOS 走 ESP-IDF 官方脚本和本机 Python 环境；EIM 主要用于 Windows。

### 空白电脑上的依赖会自动安装吗？

会尽量自动处理 ESP-IDF 所需的 Python、Git、工具链和 EIM。系统权限、UAC、macOS Command Line Tools 或官方安装包窗口仍需要用户本人确认。技能无法在自身宿主 Agent 尚不能执行 Shell 或 PowerShell 时先安装宿主环境。

### 会自动升级已有 ESP-IDF 吗？

不会。只要现有环境真实验证为健康，就复用当前精确版本和位置；已有项目优先遵循项目锁定版本。

### 会直接烧录连接的板子吗？

不会。技能必须先识别芯片和 MAC、核对目标芯片并取得用户确认。若重枚举后还要继续写入，
必须在续烧前重新验明设备；最终 RESET/重新上电后的只读应用验证不会再调用 esptool。

### 为什么不用 `idf.py monitor`？

Agent 会话通常没有交互式 TTY。技能附带有界的 pyserial 采集器，可按超时和健康正则退出；正则匹配在可终止子进程中运行，高风险量词嵌套会被直接拒绝，其余匹配受采集总超时和 64 KiB 窗口约束。人类需要交互调试时仍可在真实终端运行官方 monitor。

### 烧录成功后为什么还要按 RESET？

用 BOOT 键手动进入 ROM 下载模式时，部分芯片/USB 路径在烧录结束后仍不会重新采样启动引脚，
所以板子可能继续等待下载。技能会把这一步当作可恢复的人机动作，而不是等串口超时后才猜测；
用户只需松开 BOOT，按一下 RESET/EN 或重新上电，后续验证会自动继续。

## 验证边界

仓库中的自动测试覆盖脚本参数、安装门禁、环境边界、Windows EIM 静态约束、串口控制线极性和
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

本项目使用 [Apache License 2.0](LICENSE)。

## 交流

![wechat qr](assets/wechat-qr.jpg)
