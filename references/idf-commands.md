# esp-idf-cy · 命令速查

> 所有命令一律经 wrapper:`bash <skill>/scripts/idf-env.sh <命令...>`。下表省略这个前缀。

## idf.py 常用

| 命令 | 说明 |
|---|---|
| `idf.py create-project <名字>` | 新建最小项目(生成 CMakeLists.txt + main/) |
| `idf.py -C <proj> set-target esp32s3` | 设芯片目标,**会重新生成 sdkconfig**(套用 sdkconfig.defaults) |
| `idf.py -C <proj> build` | 编译(完全非交互;首次慢) |
| `idf.py -C <proj> -p <口> flash` | 烧录(需要时自动先 build;默认波特率 460800) |
| `idf.py -C <proj> -p <口> -b 115200 flash` | 低波特率烧录(连接不稳时) |
| `idf.py -C <proj> fullclean` | 删整个 build 目录(换芯片/诡异错误时) |
| `idf.py -C <proj> -p <口> erase-flash` | 整片擦除 |
| `idf.py -C <proj> size` / `size-components` | 固件体积 / 按组件分解 |
| `idf.py -C <proj> reconfigure` | 强制重跑 CMake(组件变更后) |
| `idf.py -C <proj> save-defconfig` | 把当前 sdkconfig 压缩导出成最小 defaults(帮用户固化配置) |

命令可组合:`idf.py -C <proj> -p <口> build flash` 一条跑完。
环境变量 `ESPPORT`/`ESPBAUD` 可提供默认端口/波特率,命令行 `-p`/`-b` 覆盖之。

禁用(agent 环境):`menuconfig`(TUI)、裸 `monitor`(交互长驻,用 monitor.sh)。

## 芯片目标名

`esp32` `esp32s2` `esp32s3` `esp32c2` `esp32c3` `esp32c6` `esp32h2` `esp32p4`
(用户说 "S3" → esp32s3;"C3" → esp32c3;不确定就问,别猜)

## esptool(单独用的场景:烧现成 .bin、读芯片信息)

**命令名随版本变(实测):IDF v5.x 环境里是 `esptool.py` + 下划线命令(v4.x);
IDF v6 / pip 单装的 esptool v5 才是 `esptool` + 连字符命令。**
不确定就先跑 `esptool.py version`,或统一用 `python -m esptool`。

```bash
# IDF v5.x 环境内(经 idf-env.sh):
esptool.py -p <口> chip_id              # 读芯片型号/ID(只读,验证连接和识别芯片的首选)
esptool.py -p <口> read_mac             # 读 MAC
esptool.py -p <口> flash_id             # 读 flash 型号/容量
esptool.py -p <口> write_flash 0x0 merged.bin       # 烧合并固件
esptool.py -p <口> write_flash 0x1000 bootloader.bin 0x8000 partition-table.bin 0x10000 app.bin
esptool.py -p <口> erase_flash          # 整片擦除
esptool.py --chip esp32s3 merge_bin -o merged.bin --flash_size 8MB \
        0x0 bootloader.bin 0x8000 partition-table.bin 0x10000 app.bin   # 合并成单文件(交付他人烧录)
# esptool v5(IDF v6)对应:esptool -p <口> chip-id / write-flash / erase-flash ...
```

idf.py 项目的三段偏移看 `build/flash_args` 文件,别背数字(S3 bootloader 在 0x0,ESP32 在 0x1000)。

## eim(Windows 主路线;macOS 也可用)

```bash
eim --do-not-track true list                         # 已装 IDF 版本
eim --do-not-track true select <IDF_TAG>             # 切默认版本
eim --do-not-track true install -i <IDF_TAG> -t esp32s3 -a true
eim --do-not-track true run "idf.py build" <IDF路径> # 免激活,显式锁定安装
```

Agent 默认用 `idf-env.sh`，它会在 Windows 复验 EIM Authenticode、关闭 telemetry、以 argv
保留空格路径并透传退出码；不要直接拼接 PowerShell 命令字符串。

## 常用 sdkconfig 项(写进 <proj>/sdkconfig.defaults,再 set-target 重生成)

```
CONFIG_IDF_TARGET="esp32s3"
CONFIG_ESPTOOLPY_FLASHSIZE_8MB=y          # flash 容量
CONFIG_SPIRAM=y                            # 启用 PSRAM(S3 常用)
CONFIG_SPIRAM_MODE_OCT=y                   # 八线 PSRAM(看模组型号,WROOM-1 N16R8 是 OCT)
CONFIG_LOG_DEFAULT_LEVEL_DEBUG=y           # 日志级别
CONFIG_ESP_CONSOLE_UART_BAUDRATE=115200    # 控制台波特率
CONFIG_FREERTOS_HZ=1000                    # tick 频率
CONFIG_ESPTOOLPY_NO_STUB=y                 # 烧录不稳时试试
```

per-target 变体 `sdkconfig.defaults.esp32s3` 需要基础 `sdkconfig.defaults` 同时存在(可为空)。

## 典型 hello_world 全流程(参考)

```bash
bash <skill>/scripts/doctor.sh
cp -r <IDF_PATH>/examples/get-started/hello_world <用户指定位置>
bash <skill>/scripts/idf-env.sh idf.py -C <proj> set-target esp32s3
bash <skill>/scripts/idf-env.sh idf.py -C <proj> build
bash <skill>/scripts/find-port.sh
bash <skill>/scripts/identify-device.sh -p <候选口>   # 报告型号+MAC,用户确认后才续烧
bash <skill>/scripts/idf-env.sh idf.py -C <proj> -p <已确认口> flash
# 最终 RESET/上电前,仍在烧录口上做最后一次身份重验
bash <skill>/scripts/post-flash-check.sh prepare -p <烧录口> -m <确认MAC> \
  --download-entry <automatic|manual|unknown>
# 记下 prepare 的 POST_FLASH_SESSION。manual/unknown 返回 rc20:让用户松开 BOOT 后
# 按 RESET/EN 或重新上电;最终恢复后禁止再 identify/esptool,verify 校验 session、
# 重扫端口并通过串口控制线受控 reset 后匹配应用健康日志
bash <skill>/scripts/post-flash-check.sh verify --session <POST_FLASH_SESSION> \
  -C <proj> -e "Hello world"
```

`prepare` 的 rc=0 只表示身份准备完成,不是应用 READY;只有 `verify` 输出
`POST_FLASH_READY=yes`/rc=0 才算烧录后闭环。多口时 verify 会 rc=3,不按端口名猜设备。
