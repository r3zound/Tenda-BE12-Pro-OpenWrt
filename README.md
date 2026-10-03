# Tenda BE12 Pro — ImmortalWrt 25.12 固件

给 Tenda BE12 Pro（MT7987A / 512MB / 128MB SPI-NAND / MT7992E）编的
**ImmortalWrt 25.12** 固件。

> ## 这是什么分支
>
> 仓库有两个分支，**别搞混**：
>
> | 分支 | 基线 | 内核 | LuCI | 特点 |
> |------|------|------|------|------|
> | **`immortalwrt-25.12`**（当前） | ImmortalWrt 25.12 | 6.12 | 稳定版 | 固定可复现、国内软件源和插件全 |
> | `main` | OpenWrt SNAPSHOT | 6.18 | master（滚动） | 跟着主线走，修复最新 |
>
> 日常用哪个都行。**固件不要混刷** —— 两个分支的 rootfs 结构不同。

---

## 快速开始

```sh
git clone https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt.git
cd Tenda-BE12-Pro-OpenWrt
git checkout immortalwrt-25.12
./scripts/build.sh
```

CI 构建（推荐，约 80 分钟）：

```sh
# 在仓库页面 Actions 页面手动触发 build workflow
# 或用 API：
curl -X POST -H "Authorization: token <你的PAT>" \
  https://api.github.com/repos/r3zound/Tenda-BE12-Pro-OpenWrt/actions/workflows/build.yml/dispatches \
  -d '{"ref":"immortalwrt-25.12"}'
```

产物在 `bin/targets/mediatek/filogic/`：

```
openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.bin
sha256sums
config.buildinfo
```

---

## 这个分支做了什么（和 main 的差别）

ImmortalWrt 25.12 **官方没有这块板子**。本分支把它移植进来了，共三件：

| 文件 | 行数 | 作用 |
|------|------|------|
| `patches/immortalwrt-25.12/mt7987a-tenda-be12-pro.dts` | 390 | 设备树：GPIO、SPI-NAND 分区、AN8855 交换芯片、MT7992 无线、MAC 地址从 Factory 区读 |
| `patches/immortalwrt-25.12/board-port.mk` → `Build/tenda-mkdualimageheader` | 6 | 原厂私有镜像头（`"God1"` 魔数 + gzip CRC） |
| 同上 → `Device/tenda_be12-pro` | 14 | 板子定义：内存布局、打包方式 |

由 `scripts/apply-board-port.sh` 在克隆源码后自动追加，**幂等**。

> ⚠️ **`tenda-mkdualimageheader` 不能改也不能删** —— 原厂 bootloader
> 靠这个头识别镜像，缺了 sysupgrade 会直接失败。

MT7987 这颗 SoC 在 25.12 里是支持的（bpi-r4-lite、routerich_be7200 等），
缺的只是「这台机器的描述」，所以移植量很小。

### 已知的两个风险

1. **内核 6.12 vs 6.18** —— DTS 里用到的较新 binding
   （`airoha,an8855-ext-surge`、MT76 的 `band@0`/`band@1` 节点写法）
   6.12 未必认。构建失败先看 dtc 报的是哪个属性。
2. **aurora 主题** —— 锁的 commit 是给 LuCI master 编译的，
   25.12 是稳定版、API 可能有出入。症状是主题装上了但渲染不出来
   （下拉框空 / 界面花掉）。不行就回退到 argon。

---

## 刷机前必读

1. **校验 SHA256**
   ```sh
   cd bin/targets/mediatek/filogic && sha256sum -c sha256sums
   ```
2. 确认型号是 **Tenda BE12 Pro**
3. 从原厂固件进入需要**过渡固件**，步骤见 `main` 分支的 README §7
4. 升级时**不要勾选「保留设置」** —— 会带着旧配置，坑很多
5. **刷完不要用 `/etc/init.d/network restart`**！
   AN8855 交换芯片在 SNAPSHOT 系固件下对整栈软重置支持不良，
   整栈重启会导致 LAN 口失联、必须断电。一律用 `reload_config`（增量生效）

> 详细文档（坑位清单、救援流程、设计取舍）在 **`AGENTS.md`** 和 `main` 分支的 README。

---

## 刷机后

- 管理地址：`http://192.168.100.254`（root，密码为空）
- 无线预置：`ASUS` / `abcd1234.`（**这是公开仓库里的默认密码，请尽快改掉**）
- 双 WAN：电信走 `eth2`（光猫 DHCP），移动走 `lan3`（PPPoE）
  → **PPPoE 账号密码刷机后要在 LuCI 里手工填**，仓库不含任何宽带凭据
- 装多 WAN 负载均衡：
  ```sh
  sh /usr/lib/tenda/install-mwan3.sh     # 装完自动写配置（权重 3:1）
  sh /usr/lib/tenda/install-mwan3.sh --check   # 体检
  ```
  > 路由器下不动 GitHub Releases 时，用 PC 下载 `.apk` 再 `scp -O` 上去
  > `apk add --allow-untrusted`。软件源用中科大（`mirrors.ustc.edu.cn/openwrt`），
  > 清华/阿里云**都没有 snapshots**，填了装不上包。

---

## 不包含的东西

| 组件 | 状态 | 原因 |
|------|------|------|
| mwan3 | ❌ 不打进固件 | 官方版是 iptables 实现，在 fw4 上负载均衡已失效。改用 [dl12345/mwan3](https://github.com/dl12345/mwan3) 原生 nft 版，刷机后手动装 |
| passwall | ❌ 已排除 | 依赖解压 >150MB，超出 60MB overlay |
| 宽带凭据 | ❌ 永不进仓库 | 仓库公开 |

---

## 许可

源码遵循上游各自的许可。本仓库的预置配置与脚本部分见各文件头部声明。
