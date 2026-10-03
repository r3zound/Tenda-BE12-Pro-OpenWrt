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
- 这**推翻了**本文件早期「首次启动不广播 SSID」的安全策略。用户知情并选择可用性。
- 实现在 `files/etc/uci-defaults/99-tenda-custom` 的 `setup_wifi()`，
  提交前必须同步到 `package/tenda-preset/files/`（见 §11 双份同步铁律）。

### 插件取舍（已定，不要擅自改回）

| 组件 | 决定 | 理由 |
|------|------|------|
| **PassWall** | ❌ **已移除** | 完整依赖超出 90MB UBI 预算。恢复方案见 `README.md` §4.6 |
| **luci-theme-edge** | ❌ **已移除** | 唯一可用源 `zhucemax/openwrt-packages` 是含数百包的大杂烩（含 openclash/ssr-plus/xray-core），全量安装会撑爆 rootfs，且其自带的 2019 版 luci-theme-argon 与本仓库的 2.4.7 冲突 |
| **mwan3** | ⚠️ **不打包进固件** | 官方 mwan3 是 iptables 实现，在 fw4/nftables 上负载均衡已失效；且含 mwan3 的 sysupgrade 会静默装回失效版本。改用 `dl12345/mwan3` 原生 nft 移植版，**刷机后手动安装** |
| **frp** | ✅ 用官方包 | `frpc` 来自 openwrt/packages，`luci-app-frpc` 来自 openwrt/luci。第三方 `kuoruan/luci-app-frpc` 已移除 |
| **argon / aurora** | ✅ 保留 | 由 `fetch-extra-packages.sh` 挂载 |

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
| `files/etc/uci-defaults/99-tenda-custom` | 首启脚本 | 见 §6 heredoc 陷阱；防火墙 zone 用动态索引 |
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

## 5. ⚠️ 完整坑位清单（9 个，全部静默失败）

**这九个坑的共同点：链路上没有任何一个环节会报错。**
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
- [ ] 三个主题是否都能在 LuCI 里正常切换

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

# 7. 无线预置没被改坏（§1 无线预置表）
grep -nE "^(WIFI_SSID|WIFI_KEY|WIFI_ENC)=" files/etc/uci-defaults/99-tenda-custom
#    期望 ASUS / abcd1234. / psk2
grep -c "^	uci set wireless.radio[01].country='CN'" files/etc/uci-defaults/99-tenda-custom  # 期望 2
grep -c "uci set wireless" files/etc/uci-defaults/99-tenda-custom                            # disabled='0' 等，期望 >=8
grep -c "disabled='1'" files/etc/uci-defaults/99-tenda-custom                                # 期望 0
grep -rc "disable_wifi" files/etc/uci-defaults/99-tenda-custom                               # 期望 0（已被 setup_wifi 取代）

# 8. 用旧固件反测抽查脚本（应当精确报出该固件缺什么）
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

