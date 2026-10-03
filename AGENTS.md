# AGENTS.md — AI 交接文档

> **接手本项目请先完整读一遍本文件，再读 `README.md`。**
>
> 本文件回答「现在什么状态、接下来干什么、哪些坑不能再踩」。
> `README.md` 回答「这是什么、硬件细节、网络设计、刷机步骤」。
>
> 最后更新：2026-10-03 · 内容对应 `main` 分支当前状态
> （固件校验值见 §8，**只对标注了 Run 号的那一次有效**，换一次构建哈希就变）

---

## 0. 一页速览

| 项 | 值 |
|----|----|
| **项目** | 为 Tenda BE12 Pro（泰山 BE7200 Ultra）定制 OpenWrt 主路由固件 |
| **仓库** | <https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt> |
| **基线** | 官方 OpenWrt **mainline SNAPSHOT**，commit `3f26ab3d4d973fdbd3a1593a68e8186f5cc58dbd` |
| **目标** | `mediatek/filogic` / `tenda_be12-pro`（MT7987A，512MB DDR4，128MB SPI-NAND） |
| **当前状态** | ✅ 固件已构建并通过 24 项内容校验；✅ **Run #15 已于 2026-10-03 刷入设备**，上机验证进行中 |
| **最新成功 CI** | [Run #15](https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt/actions/runs/37094280125) · [Run #14](https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt/actions/runs/37038515704) |
| **编译耗时** | 82 分钟（GitHub Actions） |
| **CI 触发** | 手动 `workflow_dispatch` / 推 tag / 每周定时。**⛔ 推 main 不再触发构建**（2026-10-03 起，见下） |

**一句话任务**：固件已经做好了，**接下来该做的是让用户刷上去并验证运行时**，
而不是继续改构建体系。构建体系已经稳定（连续 2 次全绿）。

> ### ⛔ 推 main 不再自动编译（2026-10-03 起）
>
> `on.push` 里的 `branches: [main]` **已删除**。现在只有
> **手动 `workflow_dispatch`** / 打 `v*` tag / 每周一 cron 会构建。
>
> 原因：全量构建要 82~96 分钟，实测出现过纯文档提交
> （`2dc401d` 只加了 AGENTS.md）白烧掉 96 分钟的情况。
>
> **改完代码先推 main，攒够一批再手动触发一次**。推 main 是安全的，不会自动开跑。

---

## 1. 用户需求（不可变更的设计基线）

用户在初次沟通中确认的需求，**改动前必须先跟用户确认**：

### 硬件与网络

- 设备：Tenda BE12 Pro（MT7987A / 512MB DDR4 / 128MB SPI-NAND / MT7992E）
- **双线路**：
  - WAN1 = `eth2`（2.5G），电信 1000M，光猫**路由模式**，路由器 **DHCP** → **双重 NAT**
  - WAN2 = `lan3`（1G），移动 300M，光猫**桥接**，路由器 **PPPoE** → 单层 NAT
- mwan3 初始权重 **3:1**（电信 : 移动）
- **NAT 敏感业务（游戏、远程、端口转发等）优先走移动线** —— 因为移动是单层 NAT
- LAN = `eth1`（2.5G）+ `lan4` + `lan5`（1G），地址 `192.168.100.254/24`
- DHCP 池 `.100–.199`
- 预置简体中文 LuCI

### 无线预置（2026-10-03 用户要求，已实现）

刷完直接能连，不用进 LuCI 先配一遍：

| 项 | 值 |
|----|----|
| SSID（2.4G + 5G **同名**） | `ASUS` |
| 密码 | `abcd1234.` |
| 加密 | `psk2` = **WPA2-PSK (CCMP)**。⚠️ 不是 `sae`，sae 会变成 WPA3 |
| 默认状态 | **启用**（`disabled='0'`）—— 用户明确要「配完就能连」 |
| country | `CN`（2.4G 信道 1 / EHT20，5G 信道 36 / EHT80） |

- **同名 SSID 是有意的**：客户端按信号强度自行选频段，等效于漫游，
  与用户原先 ImmortalWrt 上的用法一致。
- **country='CN' 是正确性修复，不是偏好**：国内用 CN 监管域，
  不设或设成别的域，5G 功率上限和 DFS 行为会按错误法规走
  （旧 ImmortalWrt 上出现过 country='AU' 导致 5G 跑到 23 dBm）。
- **⛔ 配置必须预置在 `files/etc/config/wireless`，不能只靠首启脚本**。
  该文件默认不在固件里（由 `/sbin/wifi config` 运行时生成），
  只靠 `uci set` 会造出错误类型的伪段并被生成器洗掉 ——
  旧版 `disable_wifi()` 就这么静默失效，设备以**无密码开放网络 `OpenWrt`** 上线。
  完整机制见 **§5 坑 10**。
- 实现分两层：
  - `files/etc/config/wireless` —— 预置完整配置（带正确段类型和 `option path`，
    生成器见此跳过），**这是真正起决定作用的一层**
  - `files/etc/uci-defaults/99-tenda-custom` 的 `setup_wifi()` —— 幂等兜底 +
    自愈（配置缺失时先调 `/sbin/wifi config`）+ 段类型复核 + 6 项回读
- 改完必须同步到 `package/tenda-preset/files/`（见 §11 双份同步铁律）。

### 插件取舍（已定，不要擅自改回）

| 组件 | 决定 | 理由 |
|------|------|------|
| **PassWall** | ❌ **已移除** | 完整依赖超出 90MB UBI 预算。恢复方案见 `README.md` §4.6 |
| **luci-theme-edge** | ❌ **已移除** | 唯一可用源 `zhucemax/openwrt-packages` 是含数百包的大杂烩（含 openclash/ssr-plus/xray-core），全量安装会撑爆 rootfs，且其自带的 2019 版 luci-theme-argon 与本仓库的 2.4.7 冲突 |
| **mwan3** | ⚠️ **不打包进固件** | 官方 mwan3 是 iptables 实现，在 fw4/nftables 上负载均衡已失效；且含 mwan3 的 sysupgrade 会静默装回失效版本。改用 `dl12345/mwan3` 原生 nft 移植版，**刷机后手动安装** |
| **frp** | ✅ 用官方包 | `frpc` 来自 openwrt/packages，`luci-app-frpc` 来自 openwrt/luci。第三方 `kuoruan/luci-app-frpc` 已移除 |
| **argon / aurora** | ✅ 保留 | 由 `fetch-extra-packages.sh` 挂载。**aurora（eamonxg/luci-theme-aurora）是内置默认主题**，argon 是备选。主题注册机制见 **§5 坑 11**（写错会让主题下拉框完全空白） |

### 凭据处理

**PPPoE 账号密码从不写入仓库。** 仓库是公开的。

`files/etc/config/network` 里是空占位：

```
config interface 'wan2'
	option device 'lan3'
	option proto 'pppoe'
	option username ''
	option password ''
	option metric '20'
	option ipv6 '0'
```

刷机后由用户在 LuCI 中手工填写。其余内容（仓库地址、commit SHA、IP、接口名等）
**均无需脱敏**。

> ### ⚠️ 例外：WiFi 密码是**故意**公开的，不要「修」回去
>
> `99-tenda-custom` 里的 `WIFI_KEY='abcd1234.'` **明文写在公开仓库里**。
> 这是**用户知情后明确决定**的（2026-10-03：「直接写进仓库，我就知道会公开」），
> 并被反复重申。理由是他要的是「刷完直接能连」。
>
> - 这和上面「PPPoE 凭据不进仓库」**不矛盾**：PPPoE 不写是因为没必要，
>   WiFi 写是因为用户要。
> - 已在源码里加了显著警告注释，首启时也会 `warn` 提醒用户尽快改密码。
> - **后续 agent 看到明文密码不要当成泄露漏洞擅自改掉**，
>   要改先问用户。想彻底清除需要 rewrite history，另做打算。

---

## 2. 仓库结构逐文件说明

```
Tenda-BE12-Pro-OpenWrt/
├── README.md                        1080+ 行，12 章 + §13 开发历程
├── AGENTS.md                        ⭐ 本文件
├── LICENSE                          MIT（构建脚本与配置）
├── versions.lock                    ⭐ 所有上游组件的 commit 锁定（96 行）
├── .gitattributes                   强制 LF
├── .gitignore
│
├── configs/base.config              .config 片段（120 行）
├── package/tenda-preset/            ⭐ 预置配置包（90 行 Makefile + files/）
├── files/                           预置文件「源」，需手动同步到 package/tenda-preset/files/
├── docs/                            调试留档（dts.txt / fl.mk / nw.txt / prof.json）
│
├── scripts/
│   ├── gen-feeds.sh                 227 行 — 生成 feeds.conf
│   ├── gen-config.sh                71 行  — 生成 .config
│   ├── build.sh                     212 行 — 本地一键构建
│   ├── fetch-extra-packages.sh      165 行 — ⭐ 挂载「根 Makefile」仓库
│   ├── size-guard.sh                163 行 — ⭐ 体积守卫
│   ├── verify-firmware.sh           215 行 — ⭐⭐ 固件内容抽查
│   └── lib/ensure-unsquashfs.sh      89 行 — 三级兜底获取 unsquashfs
│
└── .github/workflows/build.yml      316 行 — CI（22 步）
```

### 各文件职责与注意事项

| 文件 | 职责 | ⚠️ 改它时注意 |
|------|------|-------------|
| `versions.lock` | 上游 commit 锁定 | 唯一真源。`gen-feeds.sh` 和 `fetch-extra-packages.sh` 都从这读 |
| `configs/base.config` | kconfig 片段 | **不要手工改 `.config`**，改这里后跑 `gen-config.sh` || `files/` | 预置文件源 | 改完**必须**同步到 `package/tenda-preset/files/`，否则不生效 |
| `package/tenda-preset/Makefile` | 预置配置包 | 只直接装 `/etc/config/network`；其余走 `uci batch`（见 §5 坑 3） |
| `files/etc/config/network` | 双 WAN 接口划分 | **唯一**随包安装的配置文件 |
| `files/etc/uci-defaults/99-tenda-custom` | 首启脚本 | 见 §6 heredoc 陷阱；防火墙 zone 用动态索引；`switch_mirror` 默认源必须 USTC（见 §5 坑 12） |
| `scripts/gen-feeds.sh` | feeds.conf 生成 | ⚠️ 无引号 heredoc 内**禁用反引号和裸 `#`** |
| `scripts/verify-firmware.sh` | 内容抽查 | 用 `grep -qF`（固定串），**别用 `grep -q`** |
| `.github/workflows/build.yml` | CI | ⚠️ 步骤 9 和 11 各有一行不能删（见 §5 坑 7、8） |

---

## 3. 怎么构建

### 3.1 CI（推荐）

```sh
# 用 GitHub API 触发（需 token）
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/r3zound/Tenda-BE12-Pro-OpenWrt/actions/workflows/build.yml/dispatches \
  -d '{"ref":"main","inputs":{}}'

# 查状态
curl -H "Authorization: Bearer $TOKEN" \
  https://api.github.com/repos/r3zound/Tenda-BE12-Pro-OpenWrt/actions/runs?per_page=1
```

产物在 Artifact `tenda_be12-pro-main-<run_number>`，含：
`.bin` × 2、`sha256sums`、`config.buildinfo`、`packages/`。

### 3.2 本地

```sh
sudo apt-get install -y git build-essential flex bison g++ \
     python3 python3-setuptools libssl-dev libelf-dev \
     ecj fastjar java-propose-classpath maven ant \
     qemu-kvm uml-utilities bzip2 zstd libzstd-dev

git clone https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt.git
cd Tenda-BE12-Pro-OpenWrt
./scripts/build.sh            # 一键（内部调用 gen-feeds → fetch-extra → gen-config → make）
```

或分步：

```sh
./scripts/gen-feeds.sh                 # ① 生成 feeds.conf
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a -p luci     # ⚠️ 不能省
./scripts/feeds install frp/frpc
cd ..
./scripts/fetch-extra-packages.sh openwrt                    # ② 挂载主题包
cp -r package/tenda-preset openwrt/package/tenda-preset      # ③ 挂载预置配置包
./scripts/gen-config.sh openwrt                             # ④ 生成 .config
cd openwrt && make -j$(nproc) V=s && cd ..
./scripts/size-guard.sh openwrt                            # ⑤ 体积守卫
./scripts/verify-firmware.sh openwrt                       # ⑥ 内容抽查
```

### 3.3 ⭐ 推之前先在本地跑

**CI 每次 80 分钟，别拿它当调试器。** 最后三个坑（§5 的 4、6、7）
都是在提交前本地实跑才发现的。

最低限度：

```sh
bash -n scripts/*.sh scripts/lib/*.sh        # shell 语法
sh  -n files/etc/uci-defaults/99-tenda-custom # 首启脚本语法
bash scripts/verify-firmware.sh <有 bin 的目录>  # 用旧固件反测
```

---

## 4. 怎么判断一个构建真的成功

**核心原则：编译成功 ≠ 内容正确。CI 绿不绿、守卫过不过，都发现不了下面那八个坑。**

### 三道闸门

| 闸门 | 时机 | 抓什么 |
|------|------|--------|
| ① 关键包校验 | `.config` 后、`make` 前 | 包没被发现（坑 1、8） |
| ② 体积守卫 | 编译后 | rootfs 占用 / 插件空间（坑 3） |
| ③ 固件内容抽查 | 编译后 | ⭐ 解开 squashfs 逐项核对（坑 2、3、4、6、7） |

### 拿到任何 sysupgrade 镜像后的自查三条

```sh
# 1. 完整性
sha256sum -c sha256sums

# 2. 元数据 —— 断流就丢这里
fwtool -q -i /tmp/m.json openwrt-...-sysupgrade.bin && cat /tmp/m.json
#   期望输出含 "supported_devices":["tenda,be12-pro"]

# 3. 内容
./scripts/verify-firmware.sh <含 bin/targets/mediatek/filogic/ 的目录>
```

### 没装 unsquashfs 时

`scripts/lib/ensure-unsquashfs.sh` 有三级兜底：PATH → 包管理器 → 源码编译。
源码编译**必须带 make 变量 `XZ_SUPPORT=1`**（不是 CFLAGS 里的宏 ——
写成宏会编出「认得出 superblock 却解不开 xz」的半残版本）。

---

## 5. ⚠️ 完整坑位清单（13 个，全部静默失败）

**这十三个坑的共同点：链路上没有任何一个环节会报错。**
形态都是「编译成功 → CI 绿 → 守卫过 → 固件里东西是错的」。

完整成因与解法见 `README.md` §13.2，这里只列速查：

| # | 坑 | 症状 | 解法 |
|---|-----|------|------|
| 1 | feeds 索引不到「根 Makefile」仓库 | 三个 LuCI 主题全不在固件里，CI 全绿 | `fetch-extra-packages.sh` 挂到 `package/` |
| 2 | 预置配置根本没进固件 | 管理地址 192.168.1.1，双 WAN 不存在 | 做成包 `tenda-preset` |
| 3 | apk 文件归属冲突 | 编译「成功」但 `bin/` 里没有固件 | dhcp/firewall 改走 `uci batch` |
| 4 | `unsquashfs` 解包成功却返回非 0 | 抽查误报失败 | 用产物判据，不看退出码 |
| 5 | heredoc 里的反引号触发命令替换 | `feeds.conf` 灌进上万文件路径 | 说明移出块外 + 加断言 |
| 6 | `<<UCI` vs `<<-UCI` | 首启脚本静默不执行 | 用 `<<-UCI` |
| 7 | `rm -rf files` 删了构建素材 | make 到 install 才炸 | 删掉那行 |
| 8 | 误删 `feeds install -a -p luci` | 整个 LuCI 消失 | 恢复该行 |
| 9 | **uci batch 把段类型写坏** | **刷完 LAN 客户端拿不到 IP** | **`set <包>.<段>=<值>` 是赋类型，必须写 `'dhcp'`** |

### 🔴 坑 9：uci batch 的段类型（2026-10-03 实机取证发现）

**这是唯一一个「CI 全绿 + 24 项抽查全过 + `sysupgrade -T` 返回 0」却依然
让设备不可用的坑。** 其余八个至少还有编译期或体积上的异常信号。

```sh
# ❌ Run #13~#15 用的写法
set dhcp.lan=dnsmasq      # ← 这是「把 lan 段的类型改成 dnsmasq」
set dhcp.lan='interface'  # ← 这是「把 lan 段的类型改成 interface」
```

**UCI 语义**：`set <包>.<段>=<值>` 是给**段赋类型**，不是赋选项值。
真正的选项赋值是三段式 `set <包>.<段>.<选项>=<值>`。

**为什么没被拦住**：

| 检查 | 结果 |
|---|---|
| `uci batch` 退出码 | 0，无报错 |
| 选项 `start` / `limit` 是否写进去 | ✅ 写进去了（所以回读校验报 4/4 通过） |
| `verify-firmware.sh` 的 6 条 grep | ✅ 全过（它只找 `set dhcp.lan.start='100'` 这类选项语句） |
| CI / 体积守卫 / 24 项抽查 | ✅ 全绿 |
| `sysupgrade -T` | ✅ 返回 0（它只校验镜像结构与设备匹配，不看运行结果） |
| `uci export dhcp`（唯一能看出来的） | ❌ `config interface 'lan'` ← 应该是 `config dhcp 'lan'` |

**机理**：`/etc/init.d/dnsmasq` 第 1231 行是
`config_foreach filter_dnsmasq dhcp dhcp_add` —— **只遍历类型为 `dhcp` 的段**。
类型一旦变成 `interface`，LAN 段被整个跳过，`dhcp-range` 不生成，
IPv4 DHCP 直接死掉（IPv6 SLAAC 可能还活着，所以更隐蔽：能看到路由器，
但就是拿不到 v4 地址）。

**修法**（已落地，两份 `99-tenda-custom` 都改了）：

```sh
set dhcp.lan='dhcp'          # 一行，幂等
set dhcp.lan.interface='lan' # 以下都是正常的选项赋值
```

**验证过的三种方法**（任选其一，设备上就能做）：

```sh
uci export dhcp | grep '^config'          # 必须看到 config dhcp 'lan'
grep dhcp-range /var/etc/dnsmasq.conf.*  # 必须有 set:lan,... 的行
grep -c "^config dhcp " <(uci export dhcp)   # 必须是 2
```

> 已加入 `scripts/verify-firmware.sh` 作为回归守卫：
> 检测 `set dhcp.lan=` 被写成 `dnsmasq`/`interface` 直接判失败。
> 另加一道守卫：预置文件里出现 `/etc/init.d/network restart` 也判失败
> （本机用它会 LAN 失联，见 §8）。

### 坑 10：无线配置不在固件里 → `uci set` 造伪段 → 静默零效果

**这个坑已经造成过真实事故**，而且是**安全方向的事故**。

`/etc/config/wireless` **默认不在固件 rootfs 里**。它是运行时生成的：

```sh
/sbin/wifi config     # → ucode /usr/share/hostap/wifi-detect.uc
                     # → ucode /lib/wifi/mac80211.uc | uci -q batch
```

源数据是 `/etc/board.json`。生成器里有个 `radio_exists(path, macaddr, phy, radio)`
—— 只有当某个频段**还没有**对应的 `config wifi-device` 段时，它才会生成。

于是有两条独立的失效路径：

**① 段类型错（最隐蔽）**
在 wireless 配置还不存在时执行

```sh
uci set wireless.default_radio0.disabled='1'   # ← 看起来毫无问题
```

`uci set` 在段不存在时会**新建一个类型叫 `default_radio0` 的段**，
而不是 `wifi-iface`。commit 成功、`uci get` 回读也「有值」，
但 `netifd` 完全不认 —— **执行成功、实际零效果**。
这和坑 9 是同一个病根（`set <包>.<段>=<值>` 是赋类型，不是赋选项值）。

**② 被生成器洗掉**
即使段类型对了，生成器如果认为该频段「不存在」，会整个重写文件，
首启脚本的修改全部消失。

**实际发生的事**：`disable_wifi()` 两条语句全部无效，Run #15 刷完后
设备以 **`ssid 'OpenWrt'` + `encryption 'none'` 的无密码开放网络**上线。
`uci get wireless.default_radio0.disabled` 返回空 —— 伪段连 option 都没留下。

**修法**（已实施）：

1. `files/etc/config/wireless` 里**预置完整配置**，带正确类型的
   `config wifi-device 'radio0'/'radio1'` + `option path`
   → `radio_exists()` 匹配得上，生成器跳过，不再覆盖。
   实机已验证：带着该文件跑 `/sbin/wifi config`，ASUS/psk2/CN 不被改动。
2. `setup_wifi()` 开头自愈：文件缺失**或段类型不对**时，
   **先把坏文件移走**再调 `/sbin/wifi config`，走「从零生成」这条可靠路径。
   - ⚠️ 不能只让生成器往已有文件里补：`radio_exists()` 按 `option radio` 索引
     和 `option path` 匹配，而**本机两个频段共用同一条 PCIe path**
     （`soc/11280000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0`），
     它可能认为「已经有 wifi-device 占了」而跳过该补的那段，留下半残配置。
     实测踩过：直接补 → 配置被清成空；先移走再生成 → 一次就恢复正确。
   - 移走后**再验一次**段类型，不对就 loud warn（备份留在 `/tmp/wireless.broken.*`）。
3. `setup_wifi()` 加**段类型复核**：`uci export wireless | grep '^config'`
   出现非 `wifi-device`/`wifi-iface` 的段就告警。
4. 回读从 4 项加到 6 项（两频段 SSID + 两频段加密 + country + disabled）。
   - 写这 6 项时踩过一次自己的坑：`country` 在 **`radio`** 上
     （`wireless.radio0.country`），不在 `wifi-iface` 上。
     取成 `wireless.default_radio0.country` 会**永远差 1 分**（5/6），
     看起来像配置有问题，其实是回读项自己写错了。

> 已加入 `scripts/verify-firmware.sh`：6 组正反用例全部验证过
> —— 缺文件 / 伪段 / `encryption 'none'` / 缺 `option path` / SSID 写错 /
> 加密写成 `sae`（WPA3），每种都能被抓出来。
>
> `setup_wifi()` 本身也在实机上跑过 T1/T2/T3 三个场景：
> 配置完好（守卫不误触发）/ 伪段（自愈）/ 文件缺失（自愈），全部通过。

**通用教训**：`uci get` 回读到值**不等于**配置生效。
判断段类型只有一个可靠办法：`uci export <包> | grep '^config'`。
另外 `uci get <包>.<段>`（不带选项名）返回的**就是段类型**，
可以直接拿来当类型判据 —— 伪段会返回 `default_radio0` 而不是 `wifi-device`。

### 坑 11：`uci set` 建不出段 → LuCI 主题下拉框完全空白

**已造成真实故障**：用户在设备上打开 LuCI「系统 → 系统 → 设计」，
主题下拉框里**一个主题都没有**，而 CI 全绿、系统一切正常。

下拉框的数据源在 `/www/luci-static/resources/view/system/system.js`：

```js
const th = Object.keys(uci.get('luci','themes') || {}).sort();
```

**只认 `luci.themes` 段的选项**。段没了或空了，下拉框就是空的
（注意 LuCI 其余部分完全正常 —— 主题渲染走 `luci.main.mediaurlbase`，
和这个下拉框是两条独立路径，所以「界面正常但选不了主题」）。

完整因果链：

1. 三个主题包自带的 `/etc/uci-defaults/30_luci-theme-{argon,aurora,bootstrap}`
   用 **`uci batch`** 把 `luci.themes` 注册好了。
2. 我们的 `register_themes()` 运行在 `99-`（排在后面），
   第一行 `uci -q delete luci.themes` **把上一步注册好的整个段删掉了**。
3. 接着它想重建，用的是**命令行** `uci set luci.themes.$t=...`。
   而 `uci set` 的 3 段式在**段不存在时不会自动建段**，
   直接报 `uci: Invalid argument` 并返回 1。
4. 每一条都失败，`uci commit` 提交了个空结果，
   而 `register_themes()` **没有任何错误检查**，日志照样打「已注册」。

同一条 `set` 语句的实测对照（uci 沙箱，同一份 `/etc/config/luci`）：

| 写法 | 结果 |
|------|------|
| `uci set luci.themes.X=...` | ❌ rc=1 `uci: Invalid argument` |
| `uci add luci themes` + `uci set` | ❌ 段建出来了，选项写不进去 |
| `uci batch` 里 `set luci.themes=themes` + `set luci.themes.X=...` | ✅ rc=0 |
| `uci batch` 里直接 3 段式 | ✅ rc=0 |

**结论：只有 `uci batch`（以及 `uci add`）会顺带建段，命令行 `set` 不会。**

修法里又踩了两个更细的坑（都已修）：

- **不能把变量拼进 `<<-EOF`**。`<<-` 只剥 here-doc **文本里行首的 TAB**，
  而 `$var` 后面紧跟的 TAB 是**展开后**才出现的，剥不掉，
  结果第一行变成缩进行 → `uci: Parse error`。
  改成**整段拼好再用管道送进 `uci batch`**。
- **选项名不能带连字符**。`uci batch` 的 `set` 解析器不接受 `bootstrap-dark`
  这种名字，会**静默丢弃该条**（实测 5 个主题只进去 3 个，丢的正好是两个
  bootstrap-*）。所以用驼峰 `BootstrapDark` / `BootstrapLight` ——
  这也正是官方 `30_luci-theme-bootstrap` 的写法。
  显示名由 LuCI 直接取选项名（`Object.keys` 当 label），等价。

> 已加入 `scripts/verify-firmware.sh`：不得出现 `uci set luci.themes.`、
> 必须走 `uci batch`、默认主题必须是 aurora、选项名不得带连字符、
> 必须有 `uci show` 回读校验、固件内必须有 aurora 的 `header.ut`。
>
> `register_themes()` 本身在实机跑了三个场景，全部通过：
> **A** 从零开始（段不存在）→ 5 个主题 + aurora 为默认；
> **B** 幂等重跑 → md5 完全一致；
> **C** aurora 目录缺失 → 自动回退 argon（4 个），恢复后回到 5 个 + aurora。


### 坑 12：软件源指向没有 snapshots 的镜像站 → 一个包装不上

**已造成真实故障**：Run #15 ~ #18 连续四个固件出厂就带
`https://mirrors.aliyun.com/openwrt`，用户在设备上 `apk add` 任何东西都失败。

关键在于：**这个坑跟「源慢」完全不是一回事，它是 404 —— 索引根本不存在。**

```
apk update
  WARNING: ... /targets/mediatek/filogic/packages/packages.adb: unexpected end of file
  ERROR: wget: exited with error 8
  4 unavailable, 0 stale; 221 distinct packages available
```

`221` 是残索引（只有固件自带的那部分），不是可用仓库。

#### 为什么阿里云会 404

绝大多数「OpenWrt 镜像站」**只同步 `releases/`，不同步 `snapshots/`**。
CERNET 镜像帮助页（`help.mirrors.cernet.edu.cn/openwrt/`）写得很清楚：

> 部分镜像站(例如 TUNA/BFSU)并不包含 snapshots 镜像，**USTC 提供了对 snapshots 的反代**。

2026-10-03 实测 `snapshots/packages/aarch64_cortex-a53/base/packages.adb`：

| 镜像站 | HTTP | 说明 |
|--------|------|------|
| `downloads.openwrt.org` | ✅ 200 / 115511 B | 官方，国内直连慢且不稳 |
| **`mirrors.ustc.edu.cn/openwrt`** | ✅ **200 / 115511 B** | **中科大，唯一提供 snapshots 反代的国内站** |
| `mirrors.aliyun.com/openwrt` | ❌ 404 | **无 snapshots**（旧默认，坑 12 元凶） |
| `mirrors.tuna.tsinghua.edu.cn/openwrt` | ❌ 404 | 无 snapshots（网上教程最爱推它） |
| `mirror.nju.edu.cn` / `mirrors.bfsu.edu.cn` / `mirrors.sjtug.sjtu.edu.cn` / `mirror.iscas.ac.cn` | ❌ 404 | 无 snapshots |
| `mirrors.huaweicloud.com/openwrt` | ⚠️ 200 但体积异常小（12109 B，四条路径体积相同） | 是跳转页/占位，不是真索引 |

> ⚠️ **网上（包括 AI 生成的）绝大多数「OpenWrt 国内换源」教程推荐的清华源，
> 对 SNAPSHOT 固件一律无效。** 清华只镜像 releases。

#### 关于用户列出的那 5 个第三方源

**没有一个能用**。X-Wrt / Lienol / coolsnowwolf-lede / iStoreOS / kiddin9-Kwrt
都是 **opkg 时代（OpenWrt 23.05 / 24.10 系）的 `Packages.gz` 格式**，
而本机是 **apk v3.0.5 + `packages.adb` + 内核 6.18.54**。
混用会直接把 apk 索引搞坏。要国内 LuCI 插件的话，正确做法是
**在 SNAPSHOT 源之外另加 customfeeds**，而不是换掉 distfeeds。

#### 修法

`switch_mirror()` 改了三处，每处都对应一个静默点：

1. **默认值换成 USTC**：`${TENDA_MIRROR:-https://mirrors.ustc.edu.cn/openwrt}`
2. **不只替换 `downloads.openwrt.org`**。旧版只 `sed` 这一个域名，
   于是**已经写成 aliyun 的文件永远换不掉** —— sed 匹配不到、返回 0、
   日志照样打「已切换」。现在维护一个 `bad` 清单，遍历替换：
   ```sh
   local bad="downloads.openwrt.org mirrors.aliyun.com/openwrt \
              mirrors.tuna.tsinghua.edu.cn/openwrt mirrors.bfsu.edu.cn/openwrt \
              mirror.nju.edu.cn/openwrt mirror.sjtug.sjtu.edu.cn/openwrt \
              mirror.iscas.ac.cn/openwrt"
   for b in $bad; do sed -i "s|https://${b}|${mirror}|g" "$repos"; done
   ```
3. **换完回读校验 + 统计包数**。`apk update` 返回 0 **不代表索引里有东西**，
   所以额外用 `apk list | wc -l > 1000` 兜底。

> 已加入 `scripts/verify-firmware.sh` 4 条守卫。写守卫时踩了一个小陷阱：
> 检查「有没有引用坏镜像」时**必须排除注释行和 `local bad=` 那一行** ——
> 注释里写了「阿里云 404」当反面教材，`bad` 清单里更是必须出现阿里云
> （否则救不回已写坏的源）。不排除的话就成了「修好也过不了」的死锁。

#### 实测验证（2026-10-03，设备 192.168.100.254）

- 四条 feed 从路由器实测**全部 200、亚秒级**（filogic 15509 B / base 115511 B /
  luci 400260 B / packages 760832 B）
- `apk update` → **rc=0，9185 distinct packages available**
- 端到端：`apk add htop` → 装上并跑起来（`htop 3.5.1`）→ `apk del htop` → 回到 221 包
- 沙箱跑 `switch_mirror` 逻辑，5 个输入场景全过：官方源 / 阿里云源 /
  清华源 / 已是 USTC（幂等无副作用）/ 混合源
- **附带收获**：USTC 索引里的 LuCI 版本是 `26.274.67354~aa3d488`，
  和本机固件的 LuCI **同一个 commit**，说明 snapshot 尚未从我们的构建点漂走


### 坑 13：流量卸载让 mwan3 负载均衡静默失效

**已造成真实故障**：两条 WAN 都 online、mwan3 规则全加载、
`mwan3 status` 里 `balanced` 策略也正常显示，但**第二条 WAN 的
rx/tx 长期只有几百字节**，等于没均衡。

**根因**：防火墙的软卸载/硬件卸载会在 **ingress 钩子**把连接
**直接钉死在链路上**，完全绕过 mwan3 的 mangle 打标链。
于是 `balanced` 策略虽然匹配上了，打的标却到不了 ip rule。
**负载均衡与流量卸载互斥。**

代价：失去 NAT 卸载，转发走 CPU。本机四核 A53 @2.0GHz 扛得住 1G 家用负载。
若更看重转发性能，把策略改成「故障转移」再把卸载改回 1。

修法：`99-tenda-custom` 里**显式**设

```sh
set firewall.@defaults[0].flow_offloading='0'
set firewall.@defaults[0].flow_offloading_hw='0'
set firewall.@defaults[0].fullcone='1'
```

> ⚠️ 必须**显式**设 0，不能靠 fw4 默认 —— 默认会随版本变，
> 而且用户在 LuCI 里勾一下「软件流量分载」就翻车。
> Run #18 实机确认：设备当时 `flow_offloading=1 / hw=1`（虽然运行时没有
> flowtable），已按新脚本改为 0 并 commit。

#### 顺带解决的第二个问题：配置得靠人记

`install-mwan3.sh` 原来只负责装包，装完让用户「自己去 LuCI 点一遍」，
权重 3:1 / 策略 / 规则全靠记忆。现已补上 `write_config()`，
装完自动生成 `/etc/config/mwan3`（实机验证：12 个段、段类型全对、
`mwan3 status` 四条策略和四条规则全部 Active）。

生成时踩到的三个约束（都写进守卫了）：

1. **段名 ≤ 15 字符** —— 超长 mwan3 静默跳过，没有任何报错。
   所以段名用 `wan_m1_w3` / `balanced` / `r_gaming` 这种短名。
2. **规则必须带 `option src_zone 'lan'`** —— 路由器自身发起的流量
   走 main 表，不该被策略路由抢走。
3. **HTTPS(443) 要 `sticky`** —— 否则一条大流量会被拆到两条 WAN，
   服务器侧看到的源 IP 时断时续。

#### check_balance 的一个误报（值得记）

第一版 `check_balance()` 只要发现第二条 WAN 没流量就报故障，
结果**误报**：规则是 `src_zone 'lan'`，只有 LAN 客户端的流量才进
打标链，而采样窗口（20 秒）里根本没有 LAN 流量 —— 那点流量是
SSH 和 apk update 本身产生的，走 main 表。

正确判据是**先看 mwan3 链的包计数器**：

```sh
nft list chain inet mwan3 mwan3_policy_balanced | sed -n 's/.*packets \([0-9]\+\).*/\1/p'
```

- 计数为 0 → 「采样窗口没有 LAN 流量」，**不是故障**
- 计数 > 0 但第二条 WAN 仍无流量 → 打标或策略没生效，**真故障**

> 这就是坑 9/10/11/12 那个老教训的又一次翻版：
> **「某个观察值是 0」不等于「功能坏了」，得先确认观察条件本身成立。**

#### 实测验证（2026-10-03，设备 192.168.100.254）

- 路由器下不动 GitHub Releases（`api.github.com` 通、`github.com` 下载 404/超时），
  改由 PC 下载后 `scp -O` 上去 `apk add --allow-untrusted`
- mwan3 `3.6.12-r1`（nft 移植版，带 `mwan3ct` / `mwan3-diag`）
- `mwan3 status`：wan / wan2 均 online 且 tracking active
- nft 表 `inet mwan3` 已建；`mwan3_policy_balanced` 链在打 fwmark
- `ip rule`：1001/1002 按 iif、2001/2002 按 fwmark、2061 blackhole、
  2062 unreachable、3002 按源地址 —— 策略路由齐全
- 路由表 1 = eth2 (192.168.1.1, metric 10)，表 2 = pppoe-wan2 (100.64.0.1, metric 20)
- 4 条规则全部 Active：游戏/远程 → mobile，443 sticky → balanced，默认 → balanced


### 坑 14：本机构建的固件刷完装不了任何内核模块

**已造成真实故障**：用户在 LuCI 里点安装 mwan3，详情页底部出现

```
依赖的软件包 kmod-ip6tables 在所有仓库都未提供。
依赖的软件包 kmod-nft-compat 在所有仓库都未提供。
依赖的软件包 kmod-ipt-conntrack-extra 在所有仓库都未提供。
依赖的软件包 kmod-ipt-ipopt 在所有仓库都未提供。
```

#### 根因（OpenWrt 源码，不是猜的）

`include/feeds.mk` 的 `FeedSourcesAppendAPK` 里，kmods 那一行被包在
**`$(if $(CONFIG_BUILDBOT), …)`** 里面 —— 也就是说

> **只有官方构建机产出的固件才会往 `distfeeds.list` 写 kmods 源。**

理由是「自己编的固件，该有的模块本来就已经在镜像里了」。代价就是
本机构建的固件永远缺这一行。

#### 实测证据（设备 192.168.100.254，Run #18 固件，内核 6.18.54）

| 检查 | 结果 |
|---|---|
| `distfeeds.list` 行数 | 4 行，**kmods 行 0 条** |
| `apk search kmod-*` | 3 个条目，全是 `kmod` / `libkmod` / `open-plc-utils-int6kmod` 这类工具包，**没有一个是内核模块** |
| 固件内已装 kmod 包数 | 64 个（编译期打进去的） |
| `apk policy kmod-nf-ipt` | 只有 `lib/apk/db/installed`，**没有任何仓库提供它** |

不是「少数几个模块缺」，是**一个内核模块都装不了**。

#### 官方 kmods 源确实可用（实测）

官方把 kmods 放在 `targets/<target>/kmods/<版本>-<release>-<配置哈希>/`。
实测当前内核 6.18.54 对应的目录存在，索引 1225 个包，USTC 与官方站
字节数完全一致（168536 字节）。

vermagic 逐字节相同，所以模块**能加载**：

```
本机:   vermagic:  6.18.54 SMP mod_unload aarch64
官方包: vermagic=6.18.54 SMP mod_unload aarch64
```

加上这个源之后：可用包 **9187 → 10412**，mwan3 缺的 4 个依赖全部解析成功，
`kmod-nft-tproxy` / `kmod-nft-socket` 也都在里面。

#### 固件侧的处理：`add_kmods_feed()`

首启脚本里新增，位置在 `switch_mirror` **之后**（要从已切好的 distfeeds 反推目录）：

- 从 `distfeeds.list` 里那条 `/targets/` 源地址**掐掉后缀反推 kmods 父目录**，
  而不是写死 `targets/mediatek/filogic` —— 换 target 或 arch 不会失效
- 列镜像站 `kmods/` 目录，取版本号等于 `uname -r` 的最新一条
- **追加**写入 `/etc/apk/repositories.d/customfeeds.list`（不覆盖，
  用户自己加的源要留着）
- 回读校验 → `apk update` → **拿 `kmod-nft-tproxy` 能不能搜到当判据**
  （不是拿「apk update 没报错」当判据）
- 探测不到就只告警不阻断，绝不拦住整个首启

#### ⚠️ 必须带 `curl -L`

**USTC 对 snapshots 是 301 重定向到 `downloads.openwrt.org`，不是真镜像。**

- 不带 `-L`：拿到 209 字节的 nginx 跳转页，一个 `href` 都没有
  → 探测永远「找不到条目」，而日志看起来像正常告警
- 带 `-L`：正常列出 23 个版本目录

顺带纠正一个一直存在的误解：
**「USTC 是唯一可用的国内源」成立的原因不是它更快，而是它不返回 404。**
它对 snapshots 没有任何加速作用，文件是原样从 `downloads.openwrt.org` 来的。

#### 残留风险

那个目录名里的**配置哈希对应的是 buildbot 的内核配置，和我们的 `base.config` 不同**。
版本号相同、vermagic 相同，所以模块能加载；但如果某个模块依赖了我们
没开的内核选项，会在加载时以 `Unknown symbol` **干净地失败**（不会静默崩溃，
因为本机 vermagic 里没有 `modversions`，没有 CRC 校验，但符号解析仍然要做）。

这种偶发失败才是自建源（`scripts/build-repo.sh`）不可替代的地方：
源和固件在同一个 build root 产出，配置哈希天然一致。


### 两条最容易重犯的

**坑 8 的机制**（务必理解）：

```sh
./scripts/feeds install -a -p luci
```

这行的作用是**把 luci feed 的包放进 `package/feeds/luci/` 让 kconfig 能看见**
（173 个），**不是把它们都装进固件**。真正进固件的只有 `base.config` 里
写成 `=y` 的那几个。删掉它 → `luci` / `luci-base` / `csstidy` / `luasrcdiet`
全部不存在 → 连带三个主题和 `tenda-preset` 的依赖也废掉。

**坑 4 的机制**（务必理解）：

```sh
"$USQ" -f -d "$dst" "$ROOTFS" >/dev/null 2>&1 || true
```

`unsquashfs` **解包成功后仍可能返回非 0**（末尾告警被计进退出码）。
判据必须是产物：

```sh
[ -d "$dst" ] && [ "$(find "$dst" -type f | wc -l)" -ge 50 ]
```

---

## 6. 几个具体的实现陷阱

### 6.1 heredoc

```sh
uci batch <<-'UCI'      # ✅ 带横杠：剥 TAB + 允许变量展开
	set foo='bar'
	UCI                   # ✅ 结束符缩进没问题
```

```sh
uci batch <<UCI         # ❌ 不带横杠：结束符必须顶格
	set foo='bar'
	UCI                   # ← 缩进了，结束符不匹配 → 读到 EOF → 整个脚本不执行
```

```sh
cat > file <<EOF
# 这里写 `command` 会被当命令替换执行！  # ❌
EOF
```

**无引号 heredoc（`<<EOF`）内禁用反引号。**

### 6.2 防火墙匿名 section 索引

**不要写死 `firewall.@zone[1]`** —— 下标取决于官方默认配置里 zone 的排列顺序，
写死轻则改错段、**重则把 lan 配成 wan 直接断网**。按 name 反查：

```sh
zlan="$(uci -q show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]\+\]\)\.name='lan'$/\1/p")"
[ -z "$zlan" ] && zlan="@zone[0]"
```

`99-tenda-custom` 里已这么实现。回读校验那行也要用动态索引。

### 6.3 `files/` 的双份同步

顶层 `files/` 是「源」，但**构建时实际被 Makefile 读取的是
`package/tenda-preset/files/`**。改完顶层那份必须同步：

```sh
rm -rf package/tenda-preset/files && cp -r files package/tenda-preset/files
```

### 6.4 feeds.conf 三条铁律

1. feed 名只允许 `[A-Za-z0-9_]` —— **禁止连字符**（官方解析器用 `(\w+)`）
2. **禁止引号** —— 官方 `split /\s+/` 不剥引号
3. **禁止裸 `#` 空注释行** —— 官方 `s/#.+$/` 要求 `#` 后至少一个字符

ref 语法：分支用 `;`，commit 用 `^`。

---

## 7. 当前待办

### 7.1 优先级最高：上机验证

**固件已经构建并校验完毕，接下来该做的是让用户刷上去。** 构建体系本身已稳定。

给用户的刷机要点（详见 `README.md` §7、§4.9）：

1. **先备份移动宽带 PPPoE 账号密码** —— 跨发行版升级**不保留任何设置**
2. 传输后先自检：`sha256sum -c` → `fwtool -q -i` → `sysupgrade -T`
3. `sysupgrade -n <固件>`（`-n` = 不保留设置）
4. 刷完管理地址是 **`192.168.100.254`**（不是 192.168.1.1）
5. `lan3` **不要**插网线 —— 它现在是移动 WAN2
6. 装 mwan3：`sh /usr/lib/tenda/install-mwan3.sh`
7. WAN2 填移动 PPPoE；WAN1（`eth2`）走 DHCP 接电信

**接口对照**（已由用户实测确认）：

| 逻辑名 | 物理 | 用途 |
|--------|------|------|
| `eth0` | — | AN8855 交换芯片 CPU trunk，**无物理插孔** |
| `eth1` | 2.5G | LAN |
| `eth2` | 2.5G | **WAN1**（电信 1000M，DHCP，双重 NAT） |
| `lan3` | 1G | **WAN2**（移动 300M，PPPoE，单层 NAT） |
| `lan4` `lan5` | 1G | LAN |

刷完后请用户提供：`sysupgrade` 输出 + `logread | grep tenda-custom`，
以便确认 mwan3 与双 WAN 的实际状态。

### 7.2 上机后待验证项

见 `README.md` §10「部署时需实测记录」：

- [ ] mwan3 两条线路是否真的都在用（`ifstatus wan wan2`）
- [ ] NAT 敏感业务是否确实走移动（单层 NAT）
- [ ] WED / HNAT 硬件加速是否生效
- [ ] 无线：9 天线通路（4T4R + 5T5R）是否全出
- [ ] 1000M 软 NAT 吞吐（`iperf3`）
- [ ] **LuCI 主题下拉框里能选到全部 5 个主题**（Aurora / Argon / Bootstrap / BootstrapDark / BootstrapLight）
      判据：`uci show luci | grep '^luci\.themes\.'` 行数 >= 1，且
      `uci get luci.main.mediaurlbase` = `/luci-static/aurora`
      —— 见 **§5 坑 11**，这条曾经长期为空

### 7.3 可选优化（不是当前重点）

- 精简包体积（当前 rootfs 13MB，`rootfs_data` 剩 73MB，很宽裕，暂无必要）
- 恢复 PassWall（需重新评估体积，方案见 `README.md` §4.6）
- 把 `files/` 的双份同步改成脚本自动完成（当前需手动）

---

## 8. 已交付的固件

| 项 | 值 |
|----|----|
| CI Run | [#15](https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt/actions/runs/37094280125) · [#14](https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt/actions/runs/37038515704) |
| 提交 | `2dc401d` / `c6caa27` |
| 编译耗时 | 82 分钟（#15 为 96 分钟，含等缓存） |
| sysupgrade | 19,149,065 字节 |
| sysupgrade SHA256（**Run #15**） | `80e9b9e3cc50447eba47beb5e0bf2c62b6a24df59b7948d4f0055ed52a61de9b` |
| initramfs SHA256（**Run #15**） | `75d2c51dbb314c4df10d447093a8da094e149c13bc201714c993142750dae037` |
| sysupgrade SHA256（Run #14） | `c74cae8719dee983657cce0ef074d03469b581e34234de0e03425b2a100c6120` |
| initramfs SHA256（Run #14） | `e3de2ee5ba2dcb12b57654a26e565d1f9de24a5a602797041142d63a24e81b83` |
| OpenWrt 基线 | `3f26ab3d4d973fdbd3a1593a68e8186f5cc58dbd` |
| 内核 | 6.18.54（用户当前 ImmortalWrt 是 6.18.52） |
| rootfs（squashfs） | 13 MB |
| 展开体积 | 40 MB / 1411 个文件 |
| rootfs_data | **73 MB** ← 插件空间 |
| 包数量 | 1411 |
| 内容校验 | **24 项全过**（本地独立复核） |
| fwtool 元数据 | ✅ `supported_devices: ["tenda,be12-pro"]` |

固件二进制**不随仓库分发**，需自行编译或从 Actions Artifacts 获取。

---

## 9. GitHub 与凭据

| 项 | 值 |
|----|----|
| 仓库 | `r3zound/Tenda-BE12-Pro-OpenWrt`（**公开**） |
| 默认分支 | `main` |
| CI workflow | `.github/workflows/build.yml` |
| Artifact 保留 | 90 天 |

**凭据策略**：

- PPPoE 账号密码**从不写入仓库**（仓库公开）
- GitHub token 存在加密 secret `GITHUB_TOKEN`，推送用一次性 `GIT_ASKPASS`
- ⚠️ 用户提供的 token 权限极高，**项目完成后建议撤销并换最小权限 token**
- 除 PPPoE 凭据外，仓库地址、commit SHA、IP、接口名等**均无需脱敏**
- WiFi 默认密码是**例外，明文公开**（用户知情决定，见 §1，不要擅自改回）

---

## 10. 沟通风格提示

用户是中文使用者，技术水平高，能读脚本、懂 OpenWrt 内部机制。
反馈信息时**直接给结论和依据**，不要铺垫。

本项目历史上的沟通失误（值得避免）：

- 连续三次在 CI 上试错，而其中三个问题在本地跑一遍就能发现
- 声称「镜像里没有元数据」时**用错了 magic 常量且方向搞反**（`README.md` §4.9 已记录）
- 用户报告刷机失败时，我先猜「A/B 双槽」被数据否掉，**浪费了一轮**；
  正确做法是先要 `logread` / `sysupgrade -T` 的原始输出

**教训：先取证再下结论。** 本项目的坑几乎全是「我以为是这样，实际是那样」。

---

## 11. 快速自检清单

改动本项目后，提交前逐条过一遍：

```sh
# 1. shell 语法
bash -n scripts/*.sh scripts/lib/*.sh
sh  -n files/etc/uci-defaults/99-tenda-custom

# 2. feeds.conf 能生成且通过校验
#    ⚠️ 必须是**真 git 仓库**且有 origin remote —— 脚本会 `git fetch` 去检出
#    OpenWrt HEAD。只 mkdir 一个空的 .git 目录会在「检出 OpenWrt HEAD」这步失败。
git init /tmp/fakeowrt && cd /tmp/fakeowrt && git remote add origin \
    https://github.com/openwrt/openwrt.git && git commit -q --allow-empty -m init
cd - >/dev/null && ./scripts/gen-feeds.sh /tmp/fakeowrt

# 3. 预置文件双份同步
diff -r files package/tenda-preset/files && echo "✅ 已同步"

# 4. 没有裸凭据
grep -rInE "password[[:space:]]*=[[:space:]]*['\"][^'\"]+" \
     --include='*' . | grep -v '^\./\.git/' | grep -v "password ''"

# 5. 预置文件里没有危险命令（network restart 会让本机 LAN 失联）
grep -rn "/etc/init.d/network restart" files/ package/ && echo "❌ 见上面"

# 6. uci batch 的段类型没有被写坏（坑 9）
grep -nE "^\s*set\s+dhcp\.lan=" files/etc/uci-defaults/99-tenda-custom
#    期望只有一行，且是  set dhcp.lan='dhcp'

# 7. 无线预置没被改坏（§1 无线预置表、§5 坑 10）
[ -f files/etc/config/wireless ] || { echo "❌ 缺 files/etc/config/wireless（坑 10）"; }
grep -cE "^config wifi-device '?radio[01]'?" files/etc/config/wireless      # 期望 2
grep -cE "^[[:space:]]*option path " files/etc/config/wireless               # 期望 >=1（radio_exists 要靠它）
grep -cE "^[[:space:]]*config (wifi-device|wifi-iface) " files/etc/config/wireless  # 期望 = 段总数（不能有伪段）
grep -cE "^[[:space:]]*option ssid 'ASUS'" files/etc/config/wireless         # 期望 2
grep -cE "^[[:space:]]*option encryption 'psk2'" files/etc/config/wireless  # 期望 2
grep -cE "^[[:space:]]*option encryption 'none'" files/etc/config/wireless  # 期望 0（开放网络）
grep -cE "^[[:space:]]*option country 'CN'" files/etc/config/wireless        # 期望 >=2
grep -nE "^(WIFI_SSID|WIFI_KEY|WIFI_ENC)=" files/etc/uci-defaults/99-tenda-custom  # 期望 ASUS / abcd1234. / psk2
grep -c "disabled='1'" files/etc/uci-defaults/99-tenda-custom                # 期望 0
grep -cE "^[[:space:]]*disable_wifi[[:space:]]*$" files/etc/uci-defaults/99-tenda-custom  # 期望 0（只看调用行，注释提及不算）

# 8. LuCI 主题注册没被改坏（§5 坑 11）
F=files/etc/uci-defaults/99-tenda-custom
grep -nE "^LUCI_DEFAULT_THEME=" $F                               # 期望 LUCI_DEFAULT_THEME='aurora'
grep -qE "^[[:space:]]*uci[[:space:]]+set[[:space:]]+luci\.themes\." $F \
  && echo "❌ 用 uci set 写 luci.themes —— 建不出段，下拉框会是空的（坑 11）"
grep -q "uci batch" $F || echo "❌ 主题注册没走 uci batch"
grep -qE "set luci\.themes\.[A-Za-z0-9_]*-" $F \
  && echo "❌ luci.themes 选项名带连字符，uci batch 会静默丢弃"
grep -q 'template/themes/\$t' $F || echo "❌ 主题探测没查 LuCI 模板目录"

# 9. apk 软件源没被改坏（§5 坑 12）—— 本机是 SNAPSHOT，只能用有 snapshots 的源
F=files/etc/uci-defaults/99-tenda-custom
grep -nE "^[[:space:]]*local mirror=" $F \
  | grep -q 'mirrors\.ustc\.edu\.cn/openwrt' \
  || echo "❌ 默认源不是 USTC —— 换回阿里云/清华的话 SNAPSHOT 全 404，一个包装不上"
# 检查「有没有把坏源当源用」时，必须排除注释行和 bad 清单自身
grep -vE "^[[:space:]]*(#|local bad=)" $F \
  | grep -qE "mirrors\.(aliyun|tuna\.tsinghua|bfsu)\.|mirror\.(nju|sjtug\.sjtu|iscas\.ac)\." \
  && echo "❌ 把没有 snapshots 的镜像站当源用了（坑 12）"
# bad 清单必须含阿里云，否则已写坏的源永远救不回来
grep -qE 'local bad="[^"]*mirrors\.aliyun\.com/openwrt' $F \
  || echo "❌ bad 清单缺阿里云 —— 已被写坏的 distfeeds.list 换不掉"
# 换完必须有回读校验（sed 没匹配上也会返回 0）
grep -qE 'if grep -qE "\$\{bad\}" "\$repos"; then' $F \
  || echo "❌ 换源缺回读校验（坑 12 的第二个静默点）"
# 包数兜底：apk update 返回 0 不代表索引有内容
grep -q 'apk list 2>/dev/null | wc -l' $F \
  || echo "❌ 没有包数兜底 —— 残索引也会让 apk update 返回 0"

# 10. 双 WAN 负载均衡没被改坏（§5 坑 13）
F=files/etc/uci-defaults/99-tenda-custom
M=files/usr/lib/tenda/install-mwan3.sh
# 流量卸载必须显式为 0 —— 不能靠 fw4 默认，用户在 LuCI 勾一下就翻车
grep -qE "set firewall\.@defaults\[0\]\.flow_offloading='0'" $F \
  || echo "❌ 没显式关 flow_offloading —— mwan3 负载均衡会静默失效（坑 13）"
grep -qE "set firewall\.@defaults\[0\]\.flow_offloading_hw='0'" $F \
  || echo "❌ 没显式关 flow_offloading_hw（同上）"
grep -qE "set firewall\.@defaults\[0\]\.flow_offloading(_hw)?='1'" $F \
  && echo "❌ 又把流量卸载打开了 —— 和负载均衡直接冲突"
# 配置生成器
grep -qE '^[[:space:]]*write_config\(\)' $M || echo "❌ 缺 write_config()"
grep -qE 'WAN_A_WEIGHT:-3' $M && grep -qE 'WAN_B_WEIGHT:-1' $M \
  || echo "❌ 默认权重不是 3:1"
grep -qE "config policy 'balanced'" $M || echo "❌ 没有 balanced 策略"
# 段名 ≤15 字符：超长被 mwan3 静默跳过，check_balance 第 3 项查这个
grep -qE 'check_balance\(\)' $M || echo "❌ 缺 check_balance() 体检"
# PPPoE 出口设备名必须从 ubus 拿（netifd 会改名成 pppoe-wanX）
grep -qE 'dev_of\(\)' $M || echo "❌ 缺 dev_of()，体检读不到 wan2 流量"
# 规则必须有 src_zone，否则路由器自身流量也被打标
grep -qE "option src_zone 'lan'" $M || echo "❌ 规则缺 src_zone lan"

# 11. 内核模块源没被改坏（§5 坑 14）—— 本机构建的固件装不了任何内核模块
F=files/etc/uci-defaults/99-tenda-custom
grep -q '^add_kmods_feed()' $F \
  || echo "❌ 缺 add_kmods_feed —— 刷完机装不了任何内核模块（坑 14）"
# ⚠️ 必须 -L：USTC 对 snapshots 是 301 重定向到 downloads.openwrt.org，
#    不跟重定向拿到的是 209 字节 nginx 跳转页，一个 href 都没有，
#    探测永远失败而日志看着像正常告警。
grep -qE 'curl -sL --max-time [0-9]+ "\$dir"' $F \
  || echo "❌ 列 kmods 目录没跟重定向 —— USTC 是 301（坑 14）"
# 必须从 distfeeds.list 反推目录，写死 targets/mediatek/filogic 换个 target 就废
grep -qE 'base="\$\(grep -v .\^#. "\$dist" \| grep ./targets/. \| head -1\)"' $F \
  || echo "❌ kmods 目录没从 distfeeds.list 反推（坑 14）"
# 必须追加而不是覆盖，用户自己加的源要留着
grep -q '>> "\$cf"' $F \
  || echo "❌ customfeeds.list 是覆盖写的，会抹掉用户自己加的源"
# 判据必须是「包能不能搜到」，不是「apk update 有没有报错」
grep -q "apk search -q '\^kmod-nft-tproxy\\\$'" $F \
  || echo "❌ 没拿 kmod-nft-tproxy 能不能搜到当判据（坑 9/10/11 的同款教训）"
# 定义了就得调用，否则等于没写
grep -q '^add_kmods_feed$' $F || echo "❌ 定义了却没在首启流程里调用"

# 12. 用旧固件反测抽查脚本（应当精确报出该固件缺什么）
./scripts/verify-firmware.sh <含 bin/targets/mediatek/filogic/ 的目录>
```

> 第 4 条的裸凭据 grep **只查 `password=`**，查不到 `WIFI_KEY=`。
> 这是有意的：WiFi 密码按用户决定公开（§1 凭据处理），
> **不要**把 `WIFI_KEY` 加进这条 grep 的黑名单。

**提交前最容易犯的错**（都栽过）：

- 改了 `configs/base.config` 但忘了对应的包**确实存在于 `.config`**
  → 依赖 CI 第 13 步才拦住，浪费 80 分钟
- 改了 `files/` 但忘了同步 `package/tenda-preset/files/`
  → 改动完全不生效，且**没有任何报错**
- 在 `build.yml` 里「顺手清理」某行命令
  → 参见坑 7、8
- 在 `uci batch` 里写 `set <包>.<段>=<值>` 却以为是在赋选项值
  → 参见坑 9；`verify-firmware.sh` 现在会拦，但**别等它拦**
- 换软件源时**只考虑 releases**（照抄网上的「OpenWrt 换源教程」）
  → 参见坑 12；本机是 SNAPSHOT，清华/阿里云/南大/上交全是 404，
  **只有中科大 USTC 提供 snapshots 反代**
- 以为「从国内源装东西」就等于「装得到」
  → 参见坑 14；本机构建的固件**一个内核模块都装不了**，
  因为 kmods 那一行被 `CONFIG_BUILDBOT` 门控。
  另外 **USTC 对 snapshots 只是 301 重定向到官方站，没有任何加速作用**，
  选它的唯一理由是它不返回 404 —— 凡是要 `curl` 镜像站的地方都得带 `-L`

