# Tenda BE12 Pro — OpenWrt 定制固件

> 基于 **OpenWrt 官方主线** 为 Tenda BE12 Pro（泰山 BE7200 Ultra）定制的主路由固件。
> 仓库：<https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt>

---

## 0. 项目状态

| 阶段 | 状态 |
|------|------|
| **需求确认** | ✅ **全部完成**（见 §10） |
| README 编写 | ✅ 本文件（1080+ 行） |
| 构建体系搭建 | ✅ 完成并跑通 |
| **首个固件出包** | ✅ **成功**（CI Run #13 / #14，详见 §13） |
| **构建内容校验** | ✅ 24 项全过（本地独立复核） |
| **上机验证** | ⬜ **未开始** ← 当前唯一未完成项 |

### 已交付的固件

| 项 | 值 |
|----|----|
| CI Run | [#13](https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt/actions/runs/37023632916) · [#14](https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt/actions/runs/37010440652)（同内容） |
| 提交 | `9e3e19a` / `c6caa27` |
| 编译耗时 | 82 分钟（GitHub Actions ubuntu-latest） |
| sysupgrade 大小 | 19,149,065 字节（18 MB） |
| sysupgrade SHA256 | `0dde4645833534268343f4c6b700d1285a2c535fc6f1e80379237c7279049538` |
| initramfs SHA256 | `cca69926d841aff3689d354c03dae396f5f37572df93bc0d6938f80e32a24144` |
| OpenWrt 基线 | `3f26ab3d4d973fdbd3a1593a68e8186f5cc58dbd` |
| 内核 | 6.18.54（用户当前 ImmortalWrt 是 6.18.52） |
| rootfs（squashfs） | **13 MB**（刷进去实际占分区） |
| 展开体积 | 40 MB / 1411 个文件（仅参考） |
| **rootfs_data** | **73 MB** ← 装插件、存配置的空间 |
| 固件包数量 | 1411 个 |
| fwtool 元数据 | ✅ `supported_devices: ["tenda,be12-pro"]` |

### 内容校验结果（24 项全过）

```
【必须存在】                                                    【预置内容】
  ✅ 预置网段+双WAN /etc/config/network                           ✅ LAN 地址 = 192.168.100.254
  ✅ 首次启动脚本 99-tenda-custom                                  ✅ 含 lan3（移动 WAN2 接口）
  ✅ mwan3 安装助手                                               ✅ 含 eth2（电信 WAN1 接口）
  ✅ bootstrap 主题                                              ✅ 99-tenda-custom 有 shebang（会执行）
  ✅ argon 主题                                                  ✅ 99-tenda-custom 换行符正常（LF）
  ✅ aurora 主题                                                  ✅ 99-tenda-custom shell 语法正确
  ✅ frpc 守护进程                                                ✅ 预置 DHCP 池起点 .100
  ✅ frpc LuCI 配置                                               ✅ 预置 DHCP 池数量 100
                                                                ✅ 预置 防火墙 wan 区挂 wan2
【必须不存在】                                                    ✅ 预置 防火墙 lan 区放行
  ✅ mwan3 / passwall / sing-box / openclash / xray 全已排除      ✅ 预置 时区 CST-8
                                                                ✅ 预置 主机名 Tenda-BE12-Pro
```

### 设备现状（2026-10-02 用户实测）

| 项 | 值 |
|----|----|
| 当前系统 | **ImmortalWrt SNAPSHOT** `r41386-45474b1733` |
| 构建时间 | 2026-09-20 10:53 (UTC+8) |
| 内核 | 6.18.52 |
| 设备树 | `tenda,be12-pro` |
| UBI 分区 | 90 MB（`0xd80000`–`0x6780000`） |
| UBI 卷 | `rootfs` 9.4 MB + `rootfs_data` 74.7 MB |
| 硬件确认 | 9 天线通路（4T4R + 5T5R），eFEM 4-4 变体 ✅ |

> ⚠️ **固件已构建并校验，但未经上机验证。** 在你本机刷入并确认可用前，请勿将其用于生产网络。
> 始终保留可用的回原厂路径（见 §8）。
>
> 📌 用户此前尝试刷 Run #5 失败，根因是**文件传输截断**（见 §4.9），不是固件问题。

---

## 1. 目标设备

**Tenda BE12 Pro**（又名 Tenda BE7200 / 泰山 BE7200 Ultra）

> ⚠️ 认准型号标识 `tenda_be12-pro`。**不要**与 BE12、BE3600、BE5100、BE7200 Ultra 等型号混淆。
> 刷错型号 = 变砖，且不保证能救回来。

### 硬件规格

| 项目 | 参数 |
|------|------|
| SoC | MediaTek **MT7987A**（Filogic 830），四核 ARM Cortex-A53 @ 2.0GHz |
| 内存 | 512 MB DDR4 |
| 闪存 | 128 MB SPI-NAND |
| 无线 | MediaTek **MT7992E**，WiFi 7 (802.11be) |
| ├ 2.4 GHz | 4T4R，最高 1376 Mbps |
| └ 5 GHz | 5T5R，最高 5765 Mbps |
| 有线 | 2 × 2.5GbE + 3 × 1GbE |
| LED | 蓝色（系统/运行）、红色（告警） |
| 按键 | Reset、WPS |
| USB | ❌ **无 USB 接口** |
| 调试串口 | 115200 8N1（VCC / RX / TX / GND） |
| 电源 | DC 12V 2A |

### 无线硬件确认 ✅

用户实测 `board.json` 报告 `antenna_rx = antenna_tx = 511`（`0b111111111`），即 **9 条天线通路**。

对照 MediaTek 官方 MT76 WiFi 7 release note：

| 变体 | 天线数 | EEPROM 文件 |
|------|--------|-------------|
| **BE7200 (4-4) eFEM** | **4 + 5 = 9** | **`mt7992_eeprom.bin`** ← **本机** |
| BE7200 (4-4) iFEM | 4 + 5 = 9 | `mt7992_eeprom_2i5i.bin` |
| BE7200 (4-4) 混合 | 4 + 5 = 9 | `mt7992_eeprom_2i5e.bin` |
| BE5000 (2-3) | 2 + 3 = 5 | `mt7992_eeprom_23*.bin` |

**结论：本机为标准 4-4 满配，使用官方默认 EEPROM 即可，无需覆盖。**
（若后续需区分 eFEM / iFEM，可执行 `ls /lib/firmware/mediatek/mt7996/` 查看实际加载的文件。）

实测驱动加载日志：

```
[    5.304966] Airoha EN8811H mdio-bus:0b: MD32 firmware version: 25062302
[    5.359308] MediaTek MT7987 2.5GbE PHY mdio-bus:0f: Firmware date code: 2025/8/22, version: 7.10
[    5.379947] MediaTek MT7987 2.5GbE PHY mdio-bus:0f: Firmware loading/trigger ok.
[   12.566368] mt7996e 0000:01:00.0: WM Firmware Version: ____000000, Build Time: 20260310125641
[   12.597744] mt7996e 0000:01:00.0: DSP Firmware Version: ____000000, Build Time: 20260310125442
[   12.658122] mt7996e 0000:01:00.0: WA Firmware Version: ____000000, Build Time: 20260310125812
```

> 📌 无线由 **mt76 的 `mt7996e` 驱动**加载（标准上游驱动，非闭源 MTK 驱动）。
> 5GHz 支持 EHT160（160MHz），2.4GHz 最大 EHT40（40MHz）。
> **未见 WED 相关内核输出**——WED 状态需另行确认（见 §10 ❻）。

### Flash 分区布局

| 地址区间 | 大小 | 分区 |
|----------|------|------|
| `0x000000`–`0x300000` | 3 MB | Bootloader |
| `0x300000`–`0x380000` | 512 KB | u-boot-env |
| `0x380000`–`0x780000` | 4 MB | Factory（MAC / EEPROM） |
| `0x780000`–`0xd80000` | 6 MB | kernel |
| `0xd80000`–`0x6780000` | **90 MB** | ubi（rootfs） |
| `0x6780000`–`0x6b80000` | 4 MB | CFG |
| `0x6b80000`–`0x6f80000` | 4 MB | MISC2 |

**可用 rootfs 空间约 60 MB（刷完官方镜像后实测）**。编译时需控制包体积。

### MAC 地址分配（NVMEM，Factory 偏移 0x4）

| 接口 | 用途 | 取值 |
|------|------|------|
| `gmac0` (eth0) | 内部主干 | Base − 1 |
| `gmac1` (eth1) | 2.5G LAN | Base − 2 |
| `gmac2` (eth2) | 2.5G WAN | Base − 2 |
| 2.4 GHz WiFi | — | Base + 3 |
| 5 GHz WiFi | — | Base + 5 |

> 上游 `2026-03-18` 的提交对齐了这些偏移，使其与原厂固件一致。

---

## 2. 上游基线 ⚠️

### 2.1 基线决策 ✅ 已确定

**本项目基线 = 官方 OpenWrt mainline SNAPSHOT，锁定 commit。**

### 2.2 Tenda BE12 Pro 目前只有 SNAPSHOT

这是本项目**最重要的前提**。核实结果（2026-10-02）：

| 版本 | filogic 设备总数 | 含 Tenda |
|------|------------------|----------|
| 24.10.x | 80 | 0 |
| 25.12.0 | — | 0 |
| **25.12.5（最新稳定版）** | **170** | **0** |
| **SNAPSHOT** | 170+ | ✅ `tenda_be12-pro` |

设备支持于 **2026-01-19** 首次合入 staging（[PR #21461](https://github.com/openwrt/openwrt/pull/21461)），
**2026-03-18** 更新了 MAC 分配与端口命名（[PR #22276](https://github.com/openwrt/openwrt/pull/22276)）。
尚未进入任何正式发行版。

**因此无「稳定版可选」，只能跟踪 SNAPSHOT + 锁定 commit。**

### 2.3 为什么不能直接用现成的通用固件

原厂 U-Boot 要求内核前有一个 **16 字节魔数头（Magic: `God1`）**才能校验并启动。
上游为此专门新增了一条镜像命令：

```makefile
# target/linux/mediatek/image/filogic.mk
IMAGE/sysupgrade.bin := append-kernel | tenda-mkdualimageheader | sysupgrade-tar kernel=$$@ | append-metadata
```

**任何自定义固件都必须从官方源码编译，或使用官方 filogic SDK 二次编译。**
拿其它 MT7987 路由器的固件直接刷，必然无法引导。

### 2.4 版本锁定策略

SNAPSHOT 每天滚动，设备树与镜像配方都可能在数周内变化。为保证可复现构建：

| 组件 | 锁定方式 |
|------|----------|
| openwrt 源码 | 固定 commit SHA（记录在 `versions.lock`） |
| luci feed | 固定 commit SHA |
| packages / base feeds | 固定 commit SHA |
| 第三方包（argon / edge / aurora） | 固定 tag 或 commit |

每次构建产出的固件附带 `config.buildinfo`，可完整还原构建环境。

### 2.5 包管理器：apk

OpenWrt 25.12 起默认包管理器已从 `opkg` 切换为 **`apk`**（Alpine 包管理器）。
本项目所有安装命令、CI 脚本均使用 `apk` 语法。

---

## 3. 硬件接口映射 ⚠️ 必读

这是**最容易踩坑**的地方。请对照官方 DTS 理解。

### 3.1 接口构成

| 内核接口 | 物理构成 | 有插孔吗 | 速率 |
|----------|----------|----------|------|
| **`eth0`** (gmac0) | → AN8855AE 交换芯片 `port@5`（CPU trunk） | ❌ **无插孔** | 2.5G internal |
| **`eth1`** (gmac1) | MT7987A 内部 PHY (`phy15`) | ✅ 有 | 2.5G |
| **`eth2`** (gmac2) | 外置 Airoha EN8811H (`phy11`) | ✅ 有 | 2.5G |
| `lan3` | 交换芯片 `port@2` | ✅ 有 | 1G |
| `lan4` | 交换芯片 `port@1` | ✅ 有 | 1G |
| `lan5` | 交换芯片 `port@0` | ✅ 有 | 1G |

### 3.2 关键结论

> ### ❗ `eth0` 没有物理网口，不能用来插网线拨号。
>
> `eth0` 是 CPU 连接交换芯片的**内部主干链路**。你把线插在「eth0」上是不可能的——
> 机身面板上根本不存在这个口。
>
> **你要 PPPoE 拨号的那根线，插在 `eth2`（那个 2.5G 口）。**
>
> 同时 `eth2` 也正是**官方默认的 WAN 口**：
> ```
> # target/linux/mediatek/filogic/base-files/etc/board.d/02_network
> tenda,be12-pro)
>     ucidef_set_interfaces_lan_wan "lan3 lan4 lan5 eth1" eth2
> ```
> 官方配置是：`LAN = lan3 lan4 lan5 eth1`，`WAN = eth2`。

### 3.3 运行时接口映射 ✅ 已由用户实测确认

**a) `board.json`（由官方 `02_network` 生成）**

```json
"network": {
    "lan": { "ports": ["lan3", "lan4", "lan5", "eth1"], "protocol": "static" },
    "wan": { "device": "eth2", "protocol": "dhcp" }
}
```

> 💡 官方把 `eth2` 默认配成 **DHCP** 客户端。本项目改为 **PPPoE**（见 §5），
> 这只是 LuCI 层的 `proto` 字段，不涉及内核或设备树改动。

**b) `ip link show` 实际输出（2026-10-02）**

```
1: lo                          mtu 65536
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>  mtu 1504   ← 交换芯片 CPU 主干，注意 MTU 1504
3: eth1: <NO-CARRIER,...>      mtu 1500    mac cc:2d:21:43:12:58
4: eth2: <NO-CARRIER,...>      mtu 1500    mac cc:2d:21:43:12:59   ← MAC 不同
5: lan5@eth0: <NO-CARRIER,...> mtu 1500    master br-lan
6: lan4@eth0:  <UP,LOWER_UP>    mtu 1500    master br-lan
7: lan3@eth0: <NO-CARRIER,...> mtu 1500    master br-lan
8: br-lan:     <UP,LOWER_UP>    mtu 1500
9: phy0.0-ap0  (2.4 GHz)        master br-lan
10: phy0.1-ap0 (5 GHz)          master br-lan
```

**三个关键信息：**

1. **`lan3` / `lan4` / `lan5` 都标注 `@eth0`** —— 印证 §3.2 的结论：
   `eth0` 是交换芯片的 DSA master（CPU trunk），**没有物理插孔**。
   三个千兆 LAN 口是它的下挂端口。
2. **`eth0` 的 MTU 是 1504**，比其它口的 1500 多 4 字节。
   这是 DSA/CPU 端口的典型特征，进一步确认其内部链路属性。
3. **`eth2` 的 MAC 是 `...12:59`，其余全是 `...12:58`** ——
   独立的 gmac2 控制器，对应 Airoha EN8811H 2.5G WAN 口。

**结论：官方映射无误，可直接用于 §5 的网络规划。**

> 💡 用户设备上 `ethtool` 未安装，如需确认协商速率请先 `apk add ethtool`（或 `opkg install ethtool`）。

### 3.4 EEPROM 文件确认 ✅

```
/lib/firmware/mediatek/mt7996/
├── mt7992_dsp.bin
├── mt7992_eeprom.bin          ← eFEM 4-4（本机使用，见 §1 推断）
├── mt7992_eeprom_2i5i.bin     ← iFEM 4-4
├── mt7992_eeprom_2i5e.bin     ← 混合 FEM
├── mt7992_rom_patch.bin
├── mt7992_wa.bin
└── mt7992_wm.bin
```

三个 EEPROM 变体均随包分发，驱动按 DTS/天线配置自动选择。
结合 `antenna_rx/tx = 511`（9 通路 = 4T4R + 5T5R 满配），
判定使用标准 `mt7992_eeprom.bin`。**无需任何覆盖操作。**

---

## 4. 固件功能清单

### 4.1 基础

- [ ] OpenWrt mainline SNAPSHOT（锁定 commit）
- [ ] 目标 `mediatek/filogic`，设备 `tenda_be12-pro`
- [ ] 简体中文（`luci-i18n-base-zh-cn`）
- [ ] 保留 `tenda-mkdualimageheader` 镜像流程（**不可修改**）

### 4.2 LuCI 主题（均需从源码编译进固件）

| 主题 | 来源 | 官方主线 | 打包方式 |
|------|------|----------|----------|
| Bootstrap | `openwrt/luci` | ✅ 官方 | 内置 |
| Argon | `jerrykuku/luci-theme-argon` | ❌ 第三方 | feed 源码编译 |
| Edge | 第三方 | ❌ 第三方 | feed 源码编译 |
| Aurora | `eamonxg/luci-theme-aurora` | ❌ 第三方 | feed 源码编译 |

> 已核实 `openwrt/luci` 官方 `themes/` 目录仅含：
> `bootstrap`、`footstrap`、`material`、`openwrt`、`openwrt-2020`。
> **argon / edge / aurora 均需自行引入。**
> Aurora 仓库自带标准 OpenWrt `Makefile`（Apache-2.0，v1.4.0，2026-09-19），
> 可作为 package feed 正常参与编译。

> ⚠️ **切换主题需谨慎**：若 `/etc/config/luci` 中 `mediaurlbase` 指向未打包的主题，
> LuCI 会白屏。首次部署默认使用 Bootstrap，确认各主题可用后再切换。

> 📌 **`luci-theme-edge` 已移除**：唯一能找到的源是 `zhucemax/openwrt-packages`，
> 那是个含数百个包的大杂烩仓库（openclash / ssr-plus / vssr / xray-core /
> v2ray-geodata / wrtbwmon …）。`feeds install -a` 会全量引入，后果有三：
> ① 撑爆 90MB rootfs；② 其自带的 2019 版 `luci-theme-argon` 与本仓库的
> 2.4.7 **同名冲突**；③ `wrtbwmon` 触发 kconfig 递归依赖错误。
> 且该主题本身是 2021 年包，现代 LuCI 下大概率不渲染。
> **如需恢复，请提供独立干净源的仓库地址。**

### 4.3 多 WAN / 负载均衡 — ⚠️ 重要设计决策

#### 为什么不把 mwan3 编译进固件

核实结论（2026-10-02）：

- `mwan3` **不在 OpenWrt 官方包仓库**（`openwrt/packages` 与 `openwrt/luci` 均无）
- 官方 wiki 收录的 `mwan3 (iptables)` 是**基于 iptables 的旧实现**
- OpenWrt 22.03 起默认使用 **fw4 / nftables**，旧版 mwan3 只能通过
  `iptables-nft` 兼容层工作，**负载均衡行为在 25.12+ 上已确认失效**
  （社区实测：balanced 策略只走第一个节点，其余被忽略）

#### 本项目采用的方案

使用**原生 nftables 移植版**：

| 组件 | 仓库 |
|------|------|
| mwan3 (nft) | <https://github.com/dl12345/mwan3> |
| luci-app-mwan3 (nft) | <https://github.com/dl12345/luci-app-mwan3> |

该移植版与原版配置 100% 向兼容，但：

- 使用独立的 `table inet mwan3`，**不依赖 iptables 兼容层**
- fw4 重载不再冲掉 mwan3 规则
- 自带 conntrack 刷新辅助程序 `mwan3ct`
- 内置 `mwan3-diag` 诊断工具
- LuCI 内置流量路径模拟器
- v3.7 beta 起支持 IPv6 多 WAN

#### ⚠️ 部署方式：刷机后安装，**不打包进固件**

官方文档明确警告：

> *"any sysupgrade or image-builder run that includes mwan3 silently reinstalls
> the iptables version over it. Keep mwan3 out of your image entirely and
> reinstall the port after each upgrade."*

**决定：mwan3 不进固件镜像。** 刷机后通过 `apk add --allow-untrusted` 单独安装。
每次 sysupgrade 后需重新安装。这是刻意的取舍，不是遗漏。

安装命令（待 §10 确认拓扑后定稿）：

```sh
# 架构：aarch64_cortex-a53
cd /tmp
wget https://github.com/dl12345/mwan3/releases/download/v3.6.12-1/mwan3-3.6.12-1_openwrt-25.12_aarch64_cortex-a53.apk
wget https://github.com/dl12345/luci-app-mwan3/releases/download/v3.6.12-1/luci-app-mwan3_26.999.3.6.12.apk
apk add --allow-untrusted *.apk
```

> 💡 固件基于 SNAPSHOT，而 mwan3 资产名标注为 `openwrt-25.12`。
> 二者同属 mainline 25.12+ 血统，安装脚本通过 `-o 25.12` 强制指定版本串即可。

> ⚠️ **mwan3 硬限制：policy 与 rule 的名称长度上限 15 字符**，超长会被静默跳过。

#### 其它约束

- 官方 mwan3 wiki 另收录了 IPv6 多 WAN 配置要点：
  需为每个 WAN 显式配置 `wan6` 接口并挂载 `device '@wan'`，
  避免动态生成的 `wan_6` 端口竞争；防火墙 wan 区域需开 `masq6`。
  本项目默认 **IPv4-only**，IPv6 留待后续评估。

### 4.4 硬件加速

> ⚠️ **必须先分清两个完全不同的东西**，混为一谈会导致错误预期：
>
> | | WED | HNAT |
> |---|---|---|
> | 全称 | Wireless Ethernet Dispatch | Hardware NAT |
> | 工作层 | **MAC 层** | **IP 层** |
> | 作用 | 无线包绕过 CPU 直通网口 | NAT 卸载到硬件 |
> | 加速对象 | 无线 → 有线 | 所有转发流量 |
> | 官方主线 | ✅ **有** | ❌ **无** |

#### ✅ WED：官方主线支持，本项目启用

已核实官方 mainline 的完整 WED 配置链路：

| 位置 | 内容 |
|------|------|
| `target/linux/mediatek/filogic/config-6.18:333` | `CONFIG_NET_MEDIATEK_SOC_WED=y` |
| `mt7987.dtsi:257` | `reserved-memory` → `wmcpu_emi` @ `0x50000000`，1 MB，`no-map` |
| `mt7987.dtsi:926` | `wed0: wed@15010000`，`compatible = "mediatek,mt7987-wed", "syscon"` |
| `mt7987.dtsi:935` | `wdma: wdma@15104800`，`compatible = "mediatek,wed-wdma"` |
| `mt7987.dtsi:1116` | `mediatek,wed = <&wed0>`（ethsys 引用） |

`wed0` / `wdma` 节点**无 `status` 属性**，按 Device Tree 规范默认为 `okay`，会正常 probe。

**含义**：无线客户端与有线 LAN 之间的转发**不经过 CPU**，由 MT7992E 的 WED 引擎
配合 MT7987A 硬件处理。这对无线吞吐和 CPU 占用帮助显著。

> 📌 **WED 默认不打印任何 dmesg 日志**——这正是你 `dmesg | grep -i wed` 空输出的原因，
> **不代表没启用**。验证方法见 §10 ⓬（需挂载 debugfs）。

#### ❌ HNAT：官方主线不提供

IP 层 NAT 硬件卸载依赖 MediaTek 闭源驱动，**上游 Linux 与 OpenWrt mainline 均未提供**。
参考项目 `Jio0oiJ/m798x-tdbe` 正是通过 ImmortalWrt-798x 的 MTK 补丁引入的。

**实际影响**：走 `eth2` / `lan3` 两个 WAN 的**有线**转发流量仍由 CPU 软件处理。
MT7987A 四核 A53 @ 2.0GHz 跑无硬件卸载的软 NAT，预期：

| 场景 | 预期表现 |
|------|----------|
| 2.5G WAN 纯转发（iperf3） | 大概率跑不满 2.5G，瓶颈在 CPU |
| 1G WAN 纯转发 | 有机会跑满 |
| 无线客户端转发 | **WED 生效，受益明显** |
| NAT + 防火墙 + 多 WAN 规则叠加 | CPU 占用上升明显 |

> ⚠️ 这是「官方主线 vs ImmortalWrt」选型时**最实质的取舍**。
> 若你日常以无线上网为主，WED 已覆盖主要瓶颈；
> 若你依赖有线跑 2.5G 宽带，官方主线可能成为短板。见 §10 ❼。

#### 关于参考项目 `Jio0oiJ/m798x-tdbe`

已查阅该仓库：

| 维度 | 情况 |
|------|------|
| 基线 | **ImmortalWrt-798x**（非官方 OpenWrt mainline） |
| 硬件加速 | 开启 `MTK_HNAT`（MediaTek 闭源实现） |
| 无线驱动 | 闭源驱动 |
| 默认密码 | `admin` |

**结论：不可直接复用。** HNAT 建立在 ImmortalWrt 的 MTK 闭源补丁之上，
与「基于官方主线定制」的目标冲突，且带来长期可维护性问题。

**建议路线**：

1. **主线**（本项目）：官方 mainline + WED
2. **实验分支**（可选）：基于 ImmortalWrt-798x 引入 HNAT，与主线并行维护
3. **实测对比**：两条线刷同一台机器，用 `iperf3` + `top` 对比 CPU 占用与吞吐
   —— 数据说话再决定要不要走实验分支

#### 📌 待实测确认

刷机后按 §10 ⓬ 验证 WED 状态，并用 iperf3 建立基线：

```sh
# 有线基线（需另接一台 2.5G 网卡或用 1G 上限）
iperf3 -c <对端IP> -t 60 -P 4        # 同时 top 看 mt7996e / CPU 占用
```

### 4.5 预装插件 ✅ 已确认

| 组件 | 来源 | 版本 | 说明 |
|------|------|------|------|
| `frpc` | **openwrt/packages 官方包** | v0.71.0 | 内网穿透客户端，Go 源码编译 |
| `luci-app-frpc` | **openwrt/luci 官方包** | — | 完整 LuCI 应用（htdocs/po/root 齐全），已声明 `+frpc` 依赖 |
| `luci-i18n-base-zh-cn` | 官方 luci | — | 简体中文 |
| `luci-theme-argon` | `jerrykuku/luci-theme-argon` | v2.4.7 | 活跃维护，已适配 apk |
| `luci-theme-aurora` | `eamonxg/luci-theme-aurora` | v1.4.0 | Vite + Tailwind，Apache-2.0 |
| `luci-theme-edge` | ❌ **已移除** | — | 唯一可用的源是数百包的大杂烩仓库，见 §4.2 脚注 |
| `luci-app-argon-config` | `jerrykuku/luci-app-argon-config` | — | argon 配色配置界面 |
| `luci-theme-bootstrap` | 官方 luci | — | 默认主题，最稳 |

> 📌 **PassWall 已按需求移除**（体积超限，详见 §4.6）。如需恢复见该节。
> 📌 **luci-theme-edge 已移除**，见 §4.2 脚注。当前三个主题：bootstrap（默认）/ argon / aurora。
> 📌 `frp` 需要 Go 工具链，构建时间会明显拉长，CI 已按 360 分钟超时配置。
> 📌 **argon / aurora 两个主题不走 feeds**，由 `scripts/fetch-extra-packages.sh`
>    直接挂到 `package/` 目录。原因见 §4.7，这是一个非常隐蔽的坑。

### 4.7 ⚠️ 踩过的坑：feeds 静默装不进「根 Makefile」仓库

这是本项目最隐蔽的一个坑，值得单独写一节——**它不会让构建失败，只会让固件悄悄少东西。**

OpenWrt 扫描 feed 内包的方式在 `include/scan.mk`：

```make
find -L $(SCAN_DIR) -mindepth 1 -maxdepth $(SCAN_DEPTH) -name Makefile | ...
                      ^^^^^^^^^^^^^
```

`-mindepth 1` 意味着**从子目录开始找，feed 根目录本身被排除**。
而 `jerrykuku/luci-theme-argon`、`eamonxg/luci-theme-aurora` 这类
**单包仓库的 `Makefile` 恰好就在根目录**。于是发生了这样一条静默失败链：

| 步骤 | 现象 |
|------|------|
| `feeds update -a` | ✅ 成功，仓库正常 clone |
| `feeds install luci_theme_argon/luci-theme-argon` | ✅ **退出码 0，无任何输出** |
| 索引生成 | 0 个包（官方 luci 173 个、packages 1452 个，第三方全 0） |
| `make defconfig` | ✅ 成功，`CONFIG_PACKAGE_luci-theme-argon` **符号压根不存在** |
| `make` | ✅ 全绿，85 分钟编译一次成功 |
| 刷机后 | **主题列表里没有 argon，也没有 aurora** |

kconfig 对未知符号既不报错也不警告，`feeds install` 对找不到的包也返回 0。
所以链路上**没有任何一个环节会失败**。

> 📌 这件事真的发生过：CI Run #5 全绿、体积守卫也过，事后翻 `config.buildinfo`
> 里的 `.config` 才发现三个包一个都没进去。frpc 当时看起来正常，纯属巧合——
> 官方 luci feed 自带 `luci-app-frpc`，官方 packages feed 自带 `frpc`。

**解决办法**（本项目采用）：绕开 feeds，把这类仓库直接 clone 到 `package/`。
`package/` 的扫描规则是 `SCAN_DIR=package`，`package/<名字>/Makefile` 正好落在
depth 1，能被正确索引。

```sh
./scripts/fetch-extra-packages.sh "$OPENWRT_SRC"
```

该脚本除了 clone，还会在 clone 后**断言 `Makefile` 存在且含 `call BuildPackage`**，
不满足就直接失败——不会再有静默通过。

**并且 CI 增加了一道前置闸**（`校验关键包已进 .config` 步骤），在 `make` 之前
逐个检查关键包的符号是否真的存在，缺一个就直接中止，
**绝不会再白跑一次 80 分钟编译**：

```sh
for p in luci-theme-bootstrap luci-theme-argon luci-theme-aurora \
         luci-app-argon-config luci-app-frpc frpc; do
  grep -qE "^CONFIG_PACKAGE_${p}=y" .config || { echo "❌ $p 缺失"; exit 1; }
done
```

> 💡 经验教训：**判断「某个包有没有进固件」，不要看 CI 绿不绿，要看 `.config` 里
> 有没有那个符号。** 最省事的办法是把 `config.buildinfo` 存进 Artifact 一起交付。

### 4.6 预留：PassWall 恢复方案（当前未启用）

> 状态：**已移除**。以下内容保留供将来需要时参考。

#### 体积问题

PassWall 完整依赖包（`aarch64_cortex-a53`）压缩后 **64.3 MB**，解压后远超 150MB。
本机 rootfs 刷完基础系统后**可用约 60MB**。

```
xray-core  sing-box  chinadns-ng  dns2socks  geoview  hysteria
ipt2socks  microsocks  naiveproxy  shadowsocks-rust  shadowsocksr-libev
simple-obfs  tcping  trojan-plus  tuic-client  v2ray-plugin  xray-plugin
shadow-tls  v2ray-geoip  v2ray-geosite
```

参考：小米 AX3000T（同为 128MB flash / ~60MB overlay）社区同样必须用
「minimal xray-core only」模式才装得下。

#### 恢复时的两个变体

| 变体 | 内容 | 预估 | 适用协议 |
|------|------|------|----------|
| `slim` | `luci-app-passwall` + `xray-core` + `v2ray-geoip` + `v2ray-geosite` + `chinadns-ng` + `tcping` + `luci-compat` | ~35–42 MB | VMess / VLESS / Trojan / Shadowsocks |
| `singbox` | `luci-app-passwall` + `sing-box` + `geoview` + geo 数据 + `chinadns-ng` + `tcping` | ~30–38 MB | 增 Hysteria2 / TUIC |

#### 两个必须知道的坑

**坑 1：sing-box 1.12.0 移除了 Geo 支持**

> *"由于 Sing-box 在 1.12.0 版本中移除 Geo 只保留规则集，Passwall 为适应这一变更，
> 从 25.3.9 版起，Sing-box 分流将依赖 Geoview 从 Geofile 生成规则集。
> 未安装 Geoview 将无法使用 Sing-box 分流。"*

→ `singbox` 变体中 `geoview` 是**必选项**。

**坑 2：Xray 已弃用 `allowInsecure`**

> *"自 2026 年 6 月 1 日起，Xray Core 内部定时器已自动弃用 allowInsecure
> （跳过证书验证），并要求自签证书必须配置 pinnedPeerCertSha256（pcs 参数）。"*

→ 机场若用自签证书：`slim` 变体需向机场索取 `pcs` 参数，否则连不上；
或改用 `singbox` 变体。

#### 兜底：内核跑 RAM

社区成熟做法：把 xray/sing-box 二进制放 `/tmp`（tmpfs），开机脚本从 overlay 释放。
512MB RAM 够用，代价是每次重启需 5–10 秒释放、期间代理不可用。

### 4.8 默认安全与体验设置

- [x] 软件源切换至国内镜像（阿里云，可用 `TENDA_MIRROR` 覆盖）
- [x] 基础工具：`bash` `vim` `curl` `htop` `tree` `htop` 等
- [x] 首次启动**无线默认关闭**
- [x] LAN 地址预置 `192.168.100.254`，DHCP 池 `.100–.199`
- [x] 防火墙 wan 区域开 `mtu_fix`（两条线路 MTU 不一致必需）
- [x] 4 个主题注册到 LuCI，默认 bootstrap
- [x] 硬件信息自动落盘 `/etc/tenda-hardware.txt`
- [ ] 强制提示修改 root 密码（LuCI 首次登录时提示）

> 📌 DHCP / 防火墙 / SSH / 系统这四项**不是**以 `/etc/config/*` 文件形式装进固件的，
> 而是由 `99-tenda-custom` 在首次开机时用 `uci batch` 写入。原因见 `package/tenda-preset/Makefile`
> 里的注释 —— apk 严格维护文件归属，硬覆盖会报
> `trying to overwrite etc/config/dhcp owned by dnsmasq` 并让 `package/install` 整体失败。
> 只有 `/etc/config/network` 是随包直接安装的（无归属冲突）。

### 4.9 ⚠️ 刷机前必看：sysupgrade 镜像的 fwtool 元数据

从第三方发行版（如 ImmortalWrt）刷到本仓库固件时，**必须知道这件事**：

ImmortalWrt 的 `sysupgrade` 会先调 `fwtool_check_image`（`/lib/upgrade/fwtool.sh`）：

```sh
if ! fwtool -q -i /tmp/sysupgrade.meta "$1"; then
    v "Image metadata not present"
    [ "$REQUIRE_IMAGE_METADATA" = 1 -a "$FORCE" != 1 ] && {
        v "Use sysupgrade -F to override this check ..."
    }
    [ "$REQUIRE_IMAGE_METADATA" = 1 ] && return 1
fi
```

本仓库固件**是带元数据的**（来自官方 `filogic.mk` 里写死的 `| append-metadata`）：

```json
{ "metadata_version": "1.1", "compat_version": "1.0",
  "supported_devices": ["tenda,be12-pro"], ... }
```

但**元数据块在文件最后 16 字节**（`FWx0` 块头在数据之后，不是之前）。
文件一旦在传输中被截断，丢的恰好就是这块头，于是报
`Image metadata not present` —— 而固件内容其实完全正常。

**刷机前先自检，三步：**

```sh
sha256sum openwrt-...-sysupgrade.bin       # 1. 比对 sha256sums
fwtool -q -i /tmp/m.json openwrt-...bin    # 2. 元数据在不在
sysupgrade -T openwrt-...bin               # 3. 试刷（只校验，不写盘）
```

第 2 步能出 JSON 就说明文件完整。第 3 步用 `-T` 不会碰任何分区。

> 💡 固件正确 SHA256 见每次构建的 `sha256sums`，在 Artifact 里。

---

## 5. 网络设计

### 5.1 目标拓扑 ✅ 已最终确认

**两条独立宽带。基线 = 官方 OpenWrt mainline SNAPSHOT。**

```
        ┌──────────────┐                        ┌──────────────┐
        │ 电信 1000M    │                        │ 移动 300M     │
        │ 光猫路由模式   │                        │ 光猫桥接 ✅    │
        └──────┬───────┘                        └──────┬───────┘
               │ DHCP 客户端                             │ PPPoE 直拨
               │ （⚠️ 双重 NAT）                          │ （✅ 单层 NAT）
               ▼                                          ▼
        ┌──────────────┐                        ┌──────────────┐
        │ WAN1  eth2    │                        │ WAN2  lan3    │
        │ 2.5G  Airoha  │                        │ 1G  AN8855    │
        └──────┬───────┘                        └──────┬───────┘
               │                                          │
               └────────────────┬─────────────────────────┘
                                ▼
                     ┌─────────────────────┐
                     │  mwan3 (nft)         │
                     │  balanced : weight 3:1│
                     │  mobile  : 单层 NAT 敏感业务 │
                     └─────────────────────┘
                                │
                                ▼
                     ┌─────────────────────┐
                     │      OpenWrt         │
                     └─────────────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
      eth1 (2.5G LAN)   lan4 (1G LAN)    lan5 (1G LAN)
              └─────────────────┼─────────────────┘
                                ▼
                   LAN: 192.168.100.254/24
                   DHCP 池建议 192.168.100.100–199
```

### 5.2 接口规划 ✅ 已最终确认

| 用途 | 接口 | 协议 | 速率 | 运营商 | NAT 层数 |
|------|------|------|------|--------|----------|
| **WAN1** | `eth2` | **DHCP 客户端** | 2.5G | 电信 1000M | **2 层** ⚠️ |
| **WAN2** | `lan3` | **PPPoE** | 1G | 移动 300M | **1 层** ✅ |
| LAN | `eth1` | 静态 | 2.5G | — | — |
| LAN | `lan4` + `lan5` | 静态 | 1G + 1G | — | — |
| **LAN 管理地址** | `br-lan` | 静态 | — | **192.168.100.254/24** | — |

### 5.3 ⚠️ 关键设计决策：NAT 敏感业务走**移动**线

你的两条线路 NAT 层数**不对称**，这是个反直觉但重要的结论：

| 线路 | 光猫模式 | 路由器行为 | NAT 层数 | 出口 IP 类型 |
|------|----------|-----------|----------|--------------|
| 电信 1000M | **路由** | DHCP 取 IP | **2 层（双重 NAT）** | 运营商 CGNAT 或共享 |
| 移动 300M | **桥接** | PPPoE 直拨 | **1 层** ✅ | 独立公网 IP |

**因此策略应当是：**

| 业务类型 | 走哪条 | 原因 |
|----------|--------|------|
| **游戏联机 / 远程访问 / 端口转发 / VPN** | **移动（`mobile` 策略）** | 单层 NAT，NAT 类型最优，入站可达 |
| **大文件下载 / 常规上网** | `balanced` 策略 | 吃满双线带宽 |

> 💡 **不要**把游戏和远程访问固定到电信线。电信线双重 NAT 会让
> NAT 类型降级为 Restricted/Symmetric，联机匹配困难、端口转发需在光猫和路由器
> 各配一次。移动线虽只有 300M，但**游戏带宽 300M 绰绰有余**，且出口干净。

> ⚠️ **电信线 1000M 的性能预判**：官方主线无 HNAT（见 §4.4），
> 1000M 走软 NAT，四核 A53 能否跑满需实测。**若实测不达 800M，
> 这将是 P1 基线最大的短板**，届时可考虑增加 §4.4 提到的 HNAT 实验分支。
> 请在部署后用 `iperf3 -P 4` 实测并记录结果。

### 5.4 防火墙区域

| 区域 | 成员 | input | output | forward | masq |
|------|------|-------|--------|---------|------|
| `wan` | `wan`(eth2) + `wan2`(lan3) | REJECT | ACCEPT | REJECT | ✅ |
| `lan` | `br-lan` | ACCEPT | ACCEPT | ACCEPT | ❌ |

> ⚠️ 两条 WAN **必须**在同一个 `wan` 区域，mwan3 策略路由才能正常标记与转发。
> 走 mwan3 的流量会绕过 `br-lan`，区域间转发规则必须放行 `wan → wan`。
> ⚠️ **电信线的端口转发需在光猫上额外配置一次**（双重 NAT 固有开销）。

### 5.5 nwan3 配置要点

| 项 | `wan` (eth2 / 电信 / DHCP) | `wan2` (lan3 / 移动 / PPPoE) |
|----|--------------------------|----------------------------|
| metric | 1（优先） | 2 |
| **weight** | **3** | **1** |
| tracking | ping `223.5.5.5` + `114.114.114.114` | 同左 |
| reliability | 1 | 1 |
| count / timeout | 5 / 2 | 5 / 2 |
| interval / down / up | 5 / 3 / 8 | 5 / 3 / 8 |
| `track_gateway` | ❌ 不适用（以太网 DHCP 非点对点） | ✅ `1`（PPPoE 点对点） |
| 接口级 metric | 10 | 20 |

**权重依据**：电信 1000M : 移动 300M ≈ **3.3 : 1** → 取整为 `3 : 1`。
> 📌 电信线实际可用带宽受软 NAT 限制（见 §5.3），
> 若实测仅 600M，权重应调整为 `2 : 1`。**部署后按 iperf3 结果复核。**

**策略与规则设计：**

| 策略名 | 类型 | 成员 | 用途 |
|--------|------|------|------|
| `balanced` | 均衡 | `wan_m1_w3` + `wan2_m2_w1` | **默认**，全流量按 3:1 分流 |
| `mobile` | 均衡 | 仅 `wan2` | **NAT 敏感业务**（游戏/远程/端口转发），单层 NAT |
| `telecom` | 均衡 | 仅 `wan` | 强制走电信（大文件下载，可选） |
| `failover` | 故障转移 | `wan` 优先，`wan2` 备 | 严格优先级，不做分流 |

**规则（按优先级从上到下）：**

| 规则名 | 源 | 匹配 | 策略 | 理由 |
|--------|-----|------|------|------|
| `r_gaming` | `lan` | UDP 目标端口 `27015-27030,5000-5010,25565-25575` | `mobile` | 游戏联机，NAT 类型优先 |
| `r_remote` | `lan` | TCP 端口 `22,3389,5900,32400` | `mobile` | SSH / 远程桌面 / Synology |
| `r_default` | `lan` | 全部 | `balanced` | 兜底 |

> ⚠️ **mwan3 名称硬限制：policy 与 rule 名称 ≤ 15 字符**，超长会被静默跳过。
> 上表 `balanced`(8) / `mobile`(6) / `telecom`(7) / `failover`(8)
> / `r_gaming`(8) / `r_remote`(8) / `r_default`(9) 均安全。

### 5.6 关于「负载均衡」的预期管理

两条独立宽带 → **`balanced` 策略成立，总带宽理论叠加至 1300M**。但需了解：

1. **按连接分流，非按字节分流。** mwan3 在连接建立时按权重决定走哪条线，
   之后该连接固定不变。单线程下载只会走一条线。**测速务必用多线程**
   （`iperf3 -P 10`、`axel -n 10`、多连接下载器）。
2. **电信线是双重 NAT。** 出口 IP 可能与光猫共享，部分网站/服务的风控更严。
3. **`lan3` 只有 1G**，移动 300M 完全够用，无瓶颈。
4. **电信线软 NAT 可能跑不满 1000M**（见 §5.3 警告）。
5. **会话粘性问题。** 同一网站的多个连接可能分散到两条线，触发风控/验证码。
   对策：重要站点建规则锁定到 `mobile`（单层 NAT 更稳）。
6. **DNS 与 MTU。** 电信 DHCP 通常 MTU 1500，移动 PPPoE 为 1492。
   **两条线路 MTU 不一致**，需在防火墙区域开启 `mtu_fix`，
   或在接口高级设置中显式指定，否则大包可能被丢。

---

## 6. 编译方式

双轨并行，**哪条先出包就用哪条**。

### 6.0 仓库结构

```
Tenda-BE12-Pro-OpenWrt/
├── README.md                        本文件
├── AGENTS.md                        ⭐ AI 交接文档（接手先读这个）
├── LICENSE                          MIT（构建脚本与配置）
├── versions.lock                    ⭐ 所有上游组件的 commit 锁定
├── .gitattributes                   强制 LF（防 CRLF 污染 uci-defaults）
├── .gitignore
├── configs/
│   └── base.config                  .config 片段（120 行）
├── package/                         ⭐ 本地包（挂到 OpenWrt 的 package/ 下）
│   └── tenda-preset/                预置配置包
│       ├── Makefile                 (90 行) 为什么要做成包见文件头注释
│       └── files/                   与顶层 files/ 同内容（构建时实际读取这里）
│           ├── etc/config/          network（其余四项由 uci-defaults 写入）
│           ├── etc/uci-defaults/99-tenda-custom   (299 行) 首启脚本
│           └── usr/lib/tenda/       install-mwan3.sh + mwan3-README.md
├── files/                           预置文件源（由 package/tenda-preset/files 同步）
├── docs/                            调试过程留档
│   ├── dts.txt                      设备树片段
│   ├── fl.mk                        官方 filogic.mk 的相关片段
│   ├── nw.txt                       网络配置草稿
│   └── prof.json                    board.json
├── scripts/
│   ├── gen-feeds.sh                 (227 行) 从 versions.lock 生成 feeds.conf
│   ├── gen-config.sh                (71 行)  生成并校验 .config
│   ├── build.sh                     (212 行) 一键构建（本地）
│   ├── fetch-extra-packages.sh      (165 行) ⭐ 挂载「根 Makefile」仓库到 package/
│   ├── size-guard.sh                (163 行) ⭐ 体积守卫
│   ├── verify-firmware.sh           (215 行) ⭐⭐ 固件内容抽查（编译后必跑）
│   └── lib/
│       └── ensure-unsquashfs.sh     (89 行)  三级兜底获取 unsquashfs
└── .github/workflows/
    └── build.yml                    CI（22 步）
```

> ⚠️ **顶层 `files/` 与 `package/tenda-preset/files/` 是重复的两份。**
> 顶层那份是「源」，改完记得同步：
> ```sh
> rm -rf package/tenda-preset/files && cp -r files package/tenda-preset/files
> ```
> 构建时实际被 Makefile 读取的是 `package/tenda-preset/files/`，顶层那份不参与构建。
> 原因：预置配置必须做成 OpenWrt 的包才能进镜像（详见 `package/tenda-preset/Makefile` 头注释）。

### 6.1 GitHub Actions（推荐，优先级更高）

| 项 | 值 |
|----|----|
| 触发 | 手动 `workflow_dispatch` / 推 tag / 推 main / 每周定时 |
| Runner | `ubuntu-24.04` |
| 超时 | 360 分钟（`frp` 需 Go 工具链，耗时较长） |
| 缓存 | ccache 5GB + Actions cache |
| 产物 | Artifacts（保留 90 天）；推 tag 时自动发 Release |
| 体积守卫 | 第 13 步，超限直接判失败 |

```bash
# 本地触发（需 gh CLI）
gh workflow run build.yml -f variant=main
```

### 6.2 本地编译

环境要求：**Linux x86_64，≥16GB 内存，≥60GB 磁盘**

```bash
# 依赖（Debian/Ubuntu）
sudo apt install build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools \
  rsync swig unzip zlib1g-dev file wget bc ecj fastjar

# 构建
./scripts/build.sh -j$(nproc)
```

常用参数：

| 参数 | 说明 |
|------|------|
| `-j N` | 并行任务数 |
| `--variant V` | 变体标识，写入 `config.buildinfo` |
| `--clean` | 构建前清理 |
| `--dl` | 只下载源码，跳过编译 |
| `-h` | 帮助 |

### 6.3 构建一致性

两条轨道使用**同一份 `versions.lock`**，所有上游组件锁定到 commit SHA。
每次构建产出 `config.buildinfo`，可完整还原构建环境。

升级组件的流程：**改 `versions.lock` → 重新构建 → 验证 → 提交**。

### 6.4 产物

```
bin/targets/mediatek/filogic/
├── openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.bin   ← 刷这个
├── openwrt-mediatek-filogic-tenda_be12-pro-initramfs-kernel.bin       ← 串口救援用
├── openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.tar.gz
├── config.buildinfo                                                    ← 构建环境记录
├── packages/                                                           ← 全部依赖包
└── sha256sums                                                          ← 校验和
```

**刷机前务必校验：**

```sh
sha256sum -c sha256sums
```

### 6.5 体积守卫（自动）

`scripts/size-guard.sh` 在 CI 与本地构建后自动执行：

| 检查项 | 阈值 | 超限动作 |
|--------|------|----------|
| sysupgrade 镜像 | > 20 MB | ⚠️ 警告 |
| rootfs 展开体积 | > 88 MB | ❌ **构建失败** |
| 包体积排行 | — | 输出 Top 20，定位大头 |

> 💡 本机 ubi 分区总计 90 MB，扣除 UBI 冗余与元数据后安全上限约 88 MB。
> 这条守卫是防止「编译通过但刷完变砖」的最后一道闸。

---

## 7. 刷机流程

> ⚠️ 刷机有风险，操作前请确认已阅读 §8 救援流程。

### 阶段一：从原厂固件进入 OpenWrt

> 此阶段**不需要拆机、不需要串口**。需先下载「过渡固件」。

1. 电脑**网线**连接路由器 LAN 口（不要用无线）
2. 浏览器访问 `192.168.0.1` 或 `tendawifi.com`，登录原厂后台
3. 更多 → 系统设置 → 固件升级 → 本地升级
4. 上传 **BE12 Pro 专用过渡固件**（社区提供，非本项目产物）
5. 等待升级完成，设备自动重启

### 阶段二：刷入本项目定制固件

1. 重启后电脑通常获得 `192.168.1.x` 地址
2. 浏览器访问 `192.168.1.1`，`root` / 密码留空
3. 系统 → 备份与升级 → 备份与升级
4. 上传 `openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.bin`
5. **取消勾选**「保留设置并继续使用当前的配置」
6. 确认写入完成并重启

#### ⚠️ 7.2 跨分支刷机特别注意

若你当前运行 **ImmortalWrt**（实测确认），而刷入**官方 OpenWrt**：

- **必须取消「保留设置」**。两个分支的默认配置、软件源、已装包列表格式不同，
  保留配置会导致包数据库不一致、启动脚本报错。
- 两者共享 `target/linux/mediatek/image/filogic.mk`，
  镜像头（`tenda-mkdualimageheader`）格式一致，**sysupgrade 机制本身可用**。
- 若刷完无法启动，走 §8.1 的 U-Boot 救援模式恢复。

> 💡 首次部署前**务必先备份原 ImmortalWrt 的配置**（系统 → 备份与升级 → 下载备份），
> 以便需要时回退对照。

### 阶段三：首次配置

1. 访问 `192.168.1.1`，**立即设置 root 密码**
2. 核对实际网口映射：网络 → 设备
3. 调整 LAN 地址为 `192.168.100.254`（§5.2）
4. 配置 PPPoE 拨号（`eth2`）
5. 配置第二 WAN（`lan3`，DHCP）
6. 无线默认关闭，配置 SSID/密码后再启用
7. 依法设置 country code 与信道（本设备无 6GHz 频段）

---

## 8. 救援与回原厂

### 8.1 U-Boot 硬解套救援（无需拆机）

这是本设备最重要的安全网。

1. 拔掉电源
2. 插上电源的同时，**用牙签/笔尖按住机身 Reset 键持续 25 秒**
   （无需观察指示灯）后松开
3. 电脑**必须网线**连接 **千兆 LAN 口**（⚠️ 不要接 2.5G 口）
4. 电脑设为静态 IP `192.168.1.2` / 掩码 `255.255.255.0`
5. 浏览器访问 `192.168.1.1` → Tenda 官方救灾界面
6. 上传腾达**原厂固件** → Upload → Proceed
7. 全程**切勿断电**
8. 完成后将电脑网卡改回「自动获取」

> 💡 若浏览器自动补全成 `192.168.1.1/bin/cgi`，请清缓存或用无痕模式访问。

### 8.2 刷机前必做备份

在**过渡固件**或正式 OpenWrt 环境下备份关键分区：

```sh
dd if=/dev/mtd0 of=/tmp/bootloader.bin bs=64k count=48
dd if=/dev/mtd1 of=/tmp/u-boot-env.bin bs=64k count=8
```

> 这些文件请单独保存到电脑上。回原厂时可能需要还原 `u-boot-env`。

### 8.3 串口方式（进阶，官方推荐路径）

仅在上述方法均失败时使用，需拆机 + USB-TTL 适配器。

1. 接线：仅接 **TX / RX / GND**，⚠️ **不要接 5V**
2. 串口参数 `115200 8N1`
3. 上电时按 `Ctrl+C` 中断 U-Boot
4. 电脑设 `192.168.1.2`，启动 TFTP 服务
5. `tftpboot openwrt-initramfs.bin` → `bootm`
6. 进入 initramfs 后通过网页刷入 sysupgrade 镜像

---

## 9. 风险与已知问题

| 风险 | 说明 | 缓解 |
|------|------|------|
| 断电变砖 | 写入 Flash 期间断电 | 见 §8.1，有硬解套 |
| 刷错型号 | 固件型号不匹配 | 核对 `tenda_be12-pro` 标识 |
| 无硬件断电保护 | 刷写中断无自动恢复 | 刷机期间不要碰电源 |
| SNAPSHOT 不稳定 | 上游滚动更新可能引入回归 | 锁定 commit，不盲目跟随 |
| 空间不足 | rootfs 约 60MB | 控制包体积，避免堆插件 |
| mwan3 被覆盖 | sysupgrade 会装回 iptables 版 | **每次升级后重装**，见 §4.3 |
| Apple 设备掉线 | MT7992 已知问题（参考项目反馈） | 关闭 MLO / HNAT 逐项排查 |
| 无 USB 扩展 | 设备无 USB 口 | 无 USB 存储/4G 需求 |
| WED 状态未知 | dmesg 无 WED 输出 | 见 §10 ⓬ |
| WAN2 带宽封顶 | `lan3` 为千兆口 | 权重按 940M 上限计算 |
| 双重 NAT | 移动光猫若为路由模式 | 优先桥接，否则 NAT 敏感业务锁电信 |
| 跨分支刷机 | ImmortalWrt → 官方 OpenWrt | **务必不保留配置**，见 §7 阶段二 |

---

## 10. 需求确认总结

### ✅ 全部已确认

| # | 项目 | 结论 |
|---|------|------|
| ❶ | 拨号口 | **`eth2`（2.5G）= WAN1**；`eth0` 无插孔，确认不可用 |
| ❷ | 线路关系 | **两条独立宽带**，负载均衡成立 |
| ❼ | 基线 | **官方 OpenWrt mainline SNAPSHOT**（非 ImmortalWrt） |
| ❽ | 移动光猫 | **可桥接** → `lan3` PPPoE 直拨，单层 NAT |
| ❾ | 带宽 | 电信 **1000M**（DHCP）/ 移动 **300M**（PPPoE）→ 权重 **3:1** |
| ❿ | 插件 | `frpc`（官方包）+ `luci-app-frpc`；**PassWall 已移除** |
| ❺ | 接口映射 | `ip link show` + `board.json` 双重确认，见 §3.3 |
| ❻ | EEPROM 变体 | 9 天线通路 → **eFEM 4-4 标准版**，用默认 EEPROM |

### 关键设计决策（基于上述确认）

| 决策 | 内容 | 依据 |
|------|------|------|
| **NAT 敏感业务走移动** | 游戏/远程/端口转发 → `mobile` 策略 | 电信双重 NAT，移动单层 NAT（§5.3） |
| **mwan3 不打包进固件** | 刷机后 `apk add` 单独安装 | sysupgrade 会装回失效的 iptables 版（§4.3） |
| **PassWall 整体移除** | 不进固件；恢复方案见 §4.6 | 完整依赖 64MB 压缩，装不进 60MB |
| **frp 用官方包** | `openwrt/packages` v0.71.0 | 官方 `luci-app-frp` 仓库已 404 下线 |
| **放弃 MTK HNAT** | 走官方 WED 路线 | HNAT 依赖闭源驱动，主线无（§4.4） |

### ❗ 部署时需实测记录

以下项目不阻塞构建，但部署后必须实测并回填本 README：

| 项目 | 命令 | 关注点 |
|------|------|--------|
| **电信软 NAT 实际吞吐** | `iperf3 -c <对端> -P 4 -t 60` + `top` | 若 < 800M，考虑增加 HNAT 实验分支（§5.3） |
| **WED 是否启用** | `ls /sys/kernel/debug/mtk_wed/`、`cat /sys/kernel/debug/ieee80211/phy0/mt7996e/` | 官方 mainline 构建的实测结果（§4.4） |
| **机身丝印 ↔ 接口名** | 逐口插线 + `ethtool <口> \| grep -i speed` | 记录到 §3.3 |
| **nwan3 权重复核** | `mwan3 status` + 多线程测速 | 若电信实测仅 600M，权重改 2:1（§5.5） |
| **模块参数名** | `ls /sys/module/mt7996e/parameters/` | 确认 `N Y N` 三项分别是什么 |

> 📌 **固件体积守卫**会在 CI 中自动检查镜像大小，
> 超过 rootfs 预算直接判失败并给出包体积排行，见 §6.5。

---


## 11. 参考资料

### 官方

- [OpenWrt 设备页 — Tenda BE12 Pro](https://openwrt.org/toh/tenda/be12_pro)
- [SNAPSHOT 下载 — mediatek/filogic](https://downloads.openwrt.org/snapshots/targets/mediatek/filogic/)
- [固件选择器](https://firmware-selector.openwrt.org/)
- [设备支持首次合入 PR #21461](https://github.com/openwrt/openwrt/pull/21461)
- [MAC/端口修正 PR #22276](https://github.com/openwrt/openwrt/pull/22276)

### 刷机

- [OpenWrt 论坛 — Flash Tenda BE12 Pro to OpenWrt & Revert to Original](https://forum.openwrt.org/t/flash-tenda-be12-pro-to-openwrt-revert-to-original/249511)
- [恩山 — Tenda BE12 Pro 不拆机刷 OpenWrt + 刷回官方固件教程](https://www.right.com.cn/forum/thread-8463884-1-1.html)

### 组件

- [mwan3 (nftables) — dl12345/mwan3](https://github.com/dl12345/mwan3)
- [luci-app-mwan3 (nftables) — dl12345/luci-app-mwan3](https://github.com/dl12345/luci-app-mwan3)
- [OpenWrt Wiki — mwan3 (nftables unofficial)](https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3-nft)
- [luci-theme-aurora — eamonxg/luci-theme-aurora](https://github.com/eamonxg/luci-theme-aurora)
- [luci-theme-argon — jerrykuku/luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)
- [luci-app-argon-config — jerrykuku/luci-app-argon-config](https://github.com/jerrykuku/luci-app-argon-config)
- [luci-app-frpc（官方 luci feed）— openwrt/luci](https://github.com/openwrt/luci/tree/master/applications/luci-app-frpc)
- [frp 官方包（openwrt/packages）](https://github.com/openwrt/packages/tree/master/net/frp)
- [OpenWrt include/scan.mk（`find -mindepth 1` 包扫描逻辑）](https://github.com/openwrt/openwrt/blob/master/include/scan.mk)
- [OpenWrt Wiki — LuCI Themes](https://openwrt.org/docs/guide-user/luci/luci.themes)

### 参考项目

- [Jio0oiJ/m798x-tdbe](https://github.com/Jio0oiJ/m798x-tdbe) — ImmortalWrt-798x + MTK HNAT + 闭源无线驱动（**未直接复用，理由见 §4.4**）

---

## 12. 许可证

本仓库的构建脚本与配置代码以 **MIT** 许可发布。

固件内包含大量第三方开源组件，各自遵循其原始许可证：

| 组件 | 许可证 |
|------|--------|
| OpenWrt / LuCI | GPL-2.0 |
| frp (frpc) | Apache-2.0 |
| luci-app-frpc | MIT |
| luci-theme-aurora | Apache-2.0 |
| luci-theme-argon | Apache-2.0 |
| mwan3 (nft port，刷机后安装) | GPL-2.0 |

> 固件二进制产物**不随本仓库分发**，请自行编译或从 Actions Artifacts 获取。

---

## 13. 开发历程与工程方法论

> 本章是接手这个项目最该先读的部分。前 12 章讲「是什么、怎么做」，
> 这一章讲「**踩过哪些坑，以及怎么判断一个构建是不是真的成功**」。

### 13.1 提交历史

从第一次搭建到出包，一共 12 次提交，其中 **8 次是修 CI**：

| # | 提交 | 内容 |
|---|------|------|
| 1 | `c1bfdd5` | 搭建完整构建体系（脚本 + 配置 + CI） |
| 2 | `b535ecc` | feeds.conf 语法：feed 名不允许连字符 |
| 3 | `70cd7dc` | feeds.conf 语法：不允许裸 `#` 空注释行 |
| 4 | `c6e403a` | feeds.conf：去引号 + ref 用 `^` 分隔 commit |
| 5 | `5087a46` | 修正 `CONFIG_TARGET_MULTI_PROFILE` 设备选择冲突；移除污染源 edge 主题；第三方包精确安装 |
| 6 | `1bdb60d` | **修复三个 LuCI 主题静默丢失** + 体积守卫空壳 |
| 7 | `af98078` | **预置配置打进固件**（做成包）+ 校验工具改用真 unsquashfs |
| 8 | `d3cbbec` | 裸 `#` 行 + `tenda-preset/files` 被误删 |
| 9 | `f1b69ae` | 恢复 `feeds install -a -p luci`（误删导致整个 LuCI 消失） |
| 10 | `8e52688` | apk 文件归属冲突 → dhcp/firewall 改走 `uci batch` |
| 11 | `9e3e19a` | **解包成功却判失败** → 改用产物判据而非退出码 |
| 12 | `c6caa27` | 文档：修正小节编号 + 新增 §4.9 |

**Run #13 / #14 首次全绿。** 编译耗时 82 分钟。

### 13.2 ⚠️ 完整坑位清单（8 个，全部静默失败）

这八个坑有一个共同点：**链路上没有任何一个环节会报错**。
它们的共同形态是「编译成功 → CI 绿 → 守卫过 → 固件里东西是错的」。

---

#### 坑 1：feeds 索引不到「根 Makefile」仓库

**症状**：argon / aurora / argon-config 三个主题全都不在固件里，CI 全绿。

**根因**：OpenWrt 的 `include/scan.mk` 这样扫包：

```make
find -L $(SCAN_DIR) -mindepth 1 -maxdepth $(SCAN_DEPTH) -name Makefile
                      ^^^^^^^^^^^^^
```

`-mindepth 1` 把 feed 根目录本身排除了。而 jerrykuku/luci-theme-argon、
eamonxg/luci-theme-aurora 这类**单包仓库的 Makefile 就在根目录**，于是：

| 步骤 | 现象 |
|------|------|
| `feeds update -a` | ✅ 成功，仓库正常 clone |
| `feeds install <名字>/<包名>` | ✅ **退出码 0，无任何输出** |
| 索引生成 | 0 个包（官方 luci 173 个、packages 1452 个，第三方全 0） |
| `make defconfig` | ✅ 成功，`CONFIG_PACKAGE_luci-theme-argon` **符号压根不存在** |
| `make` | ✅ 全绿 |
| 刷机后 | 主题列表里没有 argon，也没有 aurora |

**解法**：`scripts/fetch-extra-packages.sh` 绕开 feeds，直接 clone 到 `package/`
（`package/` 的扫描深度下正好落在 depth 1）。脚本会在 clone 后**断言**
`Makefile` 存在且含 `call BuildPackage`，不满足直接失败。

---

#### 坑 2：预置配置根本没进固件

**症状**：固件是官方默认配置，管理地址 192.168.1.1，双 WAN 划分不存在。

**根因**：`build.sh` 里有句注释「OpenWrt 通过 `CONFIG_TARGET_ROOTFS_INCLUDE_KERNEL` +
`FILES_DIR` 注入」—— **这套机制根本不存在**。`include/target.mk` 里的
`GENERIC_FILES_DIR` 是 target 自己的 files 目录，与自定义 rootfs 注入无关。
那段代码只是打印了文件名，什么也没接上。

**实锤方式**：用 `unsquashfs` 解开固件 grep `/etc/config/network` —— 连
**官方默认的 `/etc/config/network` 和 `/etc/config/system` 都不在里面**。

**解法**：做成真正的 OpenWrt 包 `package/tenda-preset`。

---

#### 坑 3：apk 文件归属冲突导致零产出

**症状**：编译报成功，但 `bin/` 里只有 7 个 bl2 二进制，**固件本体一个都没有**。

```
ERROR: tenda-preset: trying to overwrite etc/config/dhcp owned by dnsmasq
ERROR: tenda-preset: trying to overwrite etc/config/dropbear owned by dropbear
ERROR: tenda-preset: trying to overwrite etc/config/firewall owned by firewall4
1 error; 39.3 MiB in 220 packages
make[2]: *** [package/Makefile:164: package/install] Error 1
```

apk 严格维护文件归属。`/etc/config/dhcp` 属于 dnsmasq、`dropbear` 属于
dropbear、`firewall` 属于 firewall4。`network` 和 `system` 无人声明归属，
所以它们没冲突。

**解法**：只有 `/etc/config/network` 随包直接安装；
dhcp / firewall / dropbear / system 改由 `99-tenda-custom` 在首启时用
`uci batch` 写入（OpenWrt 官方发默认配置的正统做法）。

---

#### 坑 4：`unsquashfs` 解包成功却返回非 0

**症状**：`verify-firmware.sh` 报「unsquashfs 解包失败」，但同一轮里
`size-guard.sh` 读出了 1411 个文件 / 40 MB。

**根因**：两个脚本的解包命令**逐字相同**，唯一差别是结尾：

```sh
size-guard.sh  :  "$USQ" -f -d ... || true              # 吞掉，照常报通过
verify-firmware:  "$USQ" -f -d ... || { exit 2; }       # 老实查退出码 → 炸
```

`unsquashfs` 解包**成功后仍返回非 0**（末尾告警被计进退出码）。

**这里有个更值得记的教训**：`size-guard.sh` 当时是**蒙混过关**的 ——
它压根没意识到自己"失败"了。一个会静默失效的守卫比没有更糟。

**解法**：用**产物**判断成败（目录建了没、文件数够不够、有没有标志性目录），
不看退出码。`size-guard.sh` 也不再 `|| true` 后继续报绿，解包失败就 exit 2。

---

#### 坑 5：heredoc 里的反引号触发命令替换

**症状**：`feeds.conf` 里灌进一万多个文件路径，语法校验直接失败。

**根因**：注释里写了

```
#    的 Makefile 在仓库根目录，而 include/scan.mk 的 `find -mindepth 1`
```

heredoc 是**无引号的**（`<<EOF`，为了展开 `$LUCI_REPO` 等变量），
所以这对反引号被 shell 当成命令替换，**真的在 OpenWrt 源码树里跑了一遍 find**。

**解法**：说明移到 heredoc 块外；块内禁用反引号。并在校验器里加了断言 ——
feed 定义数超过 20 条就报「疑似反引号触发了命令替换」。

---

#### 坑 6：`<<UCI` 与 `<<-UCI` 的区别（会静默不执行）

**症状**：`99-tenda-custom` 在设备上不执行，设备起来是半成品。

**根因**：为了让 `$zlan` 这类变量展开，把 heredoc 从 `<<-'UCI'` 改成了 `<<UCI`。
但**不带横杠的 heredoc 结束符必须顶格**，而脚本里是 TAB 缩进的：

```
Syntax error: end of file unexpected (expecting "}")
```

shell 一直读到 EOF，整个首次启动配置**静默不执行**。

**正确写法是 `<<-UCI`**：带横杠才剥 TAB，同时允许变量展开。
这个错误在设备上极难排查，`sh -n` 一秒抓到。

---

#### 坑 7：`rm -rf files` 把构建素材删了

**症状**：make 一路跑到 install 阶段才炸。

**根因**：`tenda-preset/Makefile` 的 install 规则靠 `$(CP) ./files/...` 读取素材，
而 `build.sh` 和 `build.yml` 里我写了个「优化」：

```sh
rm -rf .../package/tenda-preset/files    # "构建完就不需要了"
```

**解法**：删掉这两行。`package/` 下的 `files/` 里没有 Makefile，
`include/scan.mk` 扫不到它，本来也无需清理。

---

#### 坑 8：误删 `feeds install -a -p luci`

**症状**：整个 LuCI 界面消失。

```
WARNING: Makefile 'package/luci-theme-aurora/Makefile' has a dependency
         on 'luci-base', which does not exist
❌ CONFIG_PACKAGE_luci=y  (缺失或被依赖覆盖)
❌ CONFIG_LUCI_LANG_zh_Hans=y
```

**根因**：改 build.yml 时把这一行整行删了。当时的想法是"少装点，避免全量引入" ——
**完全想反了**。`-a -p luci` 的作用是**把 luci feed 的包放进
`package/feeds/luci/` 让 kconfig 能看见**（173 个），**不是把它们都装进固件**。
真正进固件的只有 `base.config` 里写成 `=y` 的那几个。

**解法**：恢复该行，加详细注释。关键包校验清单补上 `luci` / `luci-base`。
`build.sh` 里的同一行还在，所以本地和 CI 早就分叉了 —— 是新加的校验步骤抓到的。

---

### 13.3 ⭐ 验证方法论：怎么判断一个构建是不是真的成功

**核心原则：编译成功 ≠ 内容正确。看 CI 绿不绿、看守卫生不通过，都发现不了上面那八个坑。**

本项目现在有三道闸门，缺一不可：

| 闸门 | 位置 | 抓什么 |
|------|------|--------|
| **① 关键包校验** | `.config` 生成后，`make` 之前 | 包有没有被发现（坑 1、8） |
| **② 体积守卫** | 编译后 | rootfs 占多少、插件空间还剩多少（坑 3） |
| **③ 固件内容抽查** | 编译后 | ⭐ **解开 squashfs 逐项核对**（坑 2、3、4、6、7） |

**① 关键包校验**必须在 `make` 之前 —— kconfig 对未知符号既不报错也不警告，
晚一步就是 80 分钟白跑：

```sh
for p in luci luci-base luci-theme-bootstrap luci-theme-argon \
         luci-theme-aurora luci-app-argon-config luci-app-frpc \
         frpc tenda-preset; do
  grep -qE "^CONFIG_PACKAGE_${p}=y" .config || { echo "❌ $p 缺失"; exit 1; }
done
# 还要反向断言：不该在的包确实不在
for p in mwan3 passwall sing-box xray; do
  grep -qE "^CONFIG_PACKAGE_${p}=y" .config && { echo "❌ $p 不该在"; exit 1; }
done
```

**③ 固件内容抽查**是唯一能抓到「编译全绿但内容错」的闸门。它不依赖 `unsquashfs`
的退出码（坑 4），用产物判据：

```sh
"$USQ" -f -d "$dst" "$ROOTFS" >/dev/null 2>&1 || true   # 退出码不可靠
[ -d "$dst" ] || return 1
[ "$(find "$dst" -type f | wc -l)" -ge 50 ] || return 1
[ -e "$dst/etc/uci-defaults" ] || return 1              # 抽查标志目录
```

**本地自查固件的三条命令**（拿到任何 sysupgrade 镜像都该先跑）：

```sh
# 1. 完整性
sha256sum -c sha256sums

# 2. 元数据（断流就丢这里，见 §4.9）
fwtool -q -i /tmp/m.json openwrt-...-sysupgrade.bin && cat /tmp/m.json

# 3. 内容（需要 unsquashfs 支持 xz）
./scripts/verify-firmware.sh <含 bin/targets/mediatek/filogic/ 的目录>
```

**推之前先在本地跑，别拿 CI 当调试器。** 最后三个坑（4、6、7）都是在提交前
本地实跑才发现的 —— CI 每次 80 分钟，代价太高。

### 13.4 CI 流水线 22 步

| # | 步骤 | 作用 | 关键点 |
|---|------|------|--------|
| 1-2 | Set up / 检出 | | |
| 3 | 安装构建依赖 | | |
| 4-5 | 配置/恢复 ccache | | |
| 6 | 校验 versions.lock | | |
| 7 | 生成 feeds.conf | `gen-feeds.sh` | 复刻官方解析器校验 |
| 8 | 校验 feeds.conf 语法 | | |
| 9 | 拉取 feeds | `feeds install -a -p luci` + `frp/frpc` | ⚠️ 这行不能省（坑 8） |
| 10 | 挂载第三方包到 `package/` | `fetch-extra-packages.sh` | 绕开 feeds（坑 1） |
| 11 | 挂载预置配置包 | `cp -r package/tenda-preset` | ⚠️ 不能删 `files/`（坑 7） |
| 12 | 生成 `.config` | `gen-config.sh` | |
| 13 | **校验关键包已进 .config** | | ⭐ 闸门① |
| 14 | 下载源码 | `make download` | |
| 15 | **编译固件** | `make -j$(nproc)` | 82 分钟 |
| 16 | 记录构建信息 | | 产出 `config.buildinfo` |
| 17 | 生成校验和 | | `sha256sums` |
| 18 | **体积守卫** | `size-guard.sh` | ⭐ 闸门② |
| 19 | **固件内容抽查** | `verify-firmware.sh` | ⭐⭐ 闸门③ |
| 20 | 上传 ccache | | |
| 21 | **上传固件产物** | | ⚠️ `if: always()` |
| 22 | 发布 Release（仅 tag） | | |

> 📌 第 21 步的 `if: always()` 是被逼出来的：之前校验一失败就跳过上传，
> 「固件有问题但拿不到固件」，只能靠 69MB 日志反推，还总被下载截断。

### 13.5 改配置时的注意事项

| 想改什么 | 改哪里 | 注意 |
|---------|--------|------|
| 升级上游版本 | `versions.lock` | 取 SHA：<br>`curl -sL "https://github.com/<o>/<r>/commits/<branch>.atom" \| grep -oE '/commit/[0-9a-f]{40}' \| head -1 \| sed 's\|/commit/\|\|'` |
| 加/减固件内的包 | `configs/base.config` | 改完跑 `gen-config.sh`；⚠️ 别手工改 `.config` |
| 加第三方 feed | `versions.lock` + `gen-feeds.sh` | ⚠️ feed 名只允许 `[A-Za-z0-9_]`，**禁止连字符** |
| 加第三方包 | `versions.lock` + `fetch-extra-packages.sh` | 仅当 Makefile **不在**仓库根目录时才用 feeds |
| 改预置配置 | 顶层 `files/` → **同步到** `package/tenda-preset/files/` | 两份要手动同步 |
| 加校验项 | `verify-firmware.sh` 的清单 | 用 `grep -qF`（固定串），**别用 `grep -q`** —— `[0]` 会被当正则字符类 |

