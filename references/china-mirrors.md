# esp-idf-cy · 国内镜像机制(脚本已自动处理,这里是人工排查用的底账)

> 判定:doctor.sh / install.sh 里 `NET=cn`(GitHub 探测失败但国内可达)时自动启用。
> 下列 IDF仓库/工具/依赖镜像均为乐鑫官方机制，通常不需要 VPN；EIM 本体自举是单独边界。
> 镜像可用性会变化；使用前由 Agent 真实探测，404/证书/哈希异常就回退，不绕过验真。最近复核：2026-07-13。

## macOS 有可用 EIM/Homebrew(EIM路线,Skill 自动传参)

```bash
eim --do-not-track true install -i <IDF_TAG> -t <芯片目标> --cleanup true \
  --mirror      https://dl.espressif.cn/github_assets \
  --idf-mirror  https://git.espressif.com.cn \
  --pypi-mirror https://pypi.tuna.tsinghua.edu.cn/simple
```

macOS 不传 Windows 专属 `-a true`;有 Homebrew 时由 `install-eim-macos.sh` 补齐前置;只有现成
EIM 时由 EIM 真实检查,失败后 Agent 根据缺项换路,不假定依赖已经存在。

## macOS 无 EIM/Homebrew / Linux(官方 install.sh 路线)

### 1. Git 仓库 → jihulab 官方镜像

```bash
# install.sh 的做法:主仓直接从镜像克隆 + 仓库级 insteadOf 让子模块也走镜像(不污染全局 git 配置)
git clone -b <IDF_TAG> https://jihulab.com/esp-mirror/espressif/esp-idf.git <IDF_DIR>
git -C <IDF_DIR> config url."https://jihulab.com/esp-mirror/".insteadOf "https://github.com/"
git -C <IDF_DIR> submodule update --init --recursive
```

备胎:`https://gitee.com/EspressifSystems/esp-idf`(乐鑫官方 Gitee 镜像,每日同步,
但子模块仍要靠上面的 insteadOf 重写)。
官方工具仓:`https://gitee.com/EspressifSystems/esp-gitee-tools`(其 `jihu-mirror.sh set`
是全局版 insteadOf,我们用仓库级替代,侵入更小)。

### 2. 工具链二进制 → dl.espressif.cn

```bash
export IDF_GITHUB_ASSETS="dl.espressif.cn/github_assets"   # 官方文档正式机制
./install.sh esp32,esp32s3
```

机制:idf_tools.py 把下载 URL 里的 `https://github.com` 整体替换。
**限制:只镜像部分 release 资产,偶发 404** → install.sh 已内置"去镜像回退 GitHub 重试"。

### 3. pip → 清华镜像

```bash
export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"   # 环境变量方式,不动用户 pip 配置
```

## Windows(EIM 路线,install.sh 自动传参)

EIM 原生支持镜像参数(候选值来自 idf-im-ui 源码,均为官方内置):

```bash
eim --do-not-track true install -i <IDF_TAG> -t <芯片目标或all> -a true --cleanup true \
  --mirror      https://dl.espressif.cn/github_assets \
  --idf-mirror  https://git.espressif.com.cn \
  --pypi-mirror https://pypi.tuna.tsinghua.edu.cn/simple
```

这段只适用于已确认兼容的 Windows EIM（当前官方 Windows CLI 资产为 x64）。Agent 必须先调用
`CheckPlatform`探测原生架构，不能因为使用国内镜像就跳过架构、release SHA256 或 Espressif Authenticode 校验。

eim 本体下载:winget 不可用时由 `eim-windows.ps1` 动态解析官方正式 release,
核对 GitHub asset SHA256 与 Espressif Authenticode 双重信任后才原子落盘;不能为绕过网络问题
而执行未验签的手工下载 exe。

限制:EIM 当前 fallback 元数据与 CLI asset 仍来自 GitHub release；“IDF 镜像可达”不等于“EIM 本体
一定可自举”。GitHub完全阻断且winget不可用时，Agent应复核当期乐鑫官方下载页/企业允许源，仍做
哈希与发布者签名验证；没有可验证来源就暂停并诚实说明，不能声称国内镜像覆盖了 EIM 本体。

## 组件管理器(idf_component.yml 拉组件慢)

组件仓库 components.espressif.com 本身在国内可达,一般无需处理;慢就重试。

## 来源

- IDF_GITHUB_ASSETS:https://docs.espressif.com/projects/esp-idf/zh_CN/stable/esp32/api-guides/tools/idf-tools.html
- jihulab 镜像:https://gitee.com/EspressifSystems/esp-gitee-tools
- EIM 镜像参数:https://docs.espressif.com/projects/idf-im-ui/en/latest/cli_commands.html
