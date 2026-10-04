# 换机迁移交接说明

> 读者：把这台机器换掉之后、拿到这份文档的人或 agent。
>
> 写作时间：2026-10-04（北京时间）
> 代码状态：分支 `immortalwrt-25.12`，HEAD `4f67b45`，工作树干净，已推送
> 设备状态：Tenda BE12 Pro 刷的是 Run #18 产物 `cb5c51a`，内核 6.18.54

---

## 0. 三十秒结论

**可行。** 代码 100% 躺在 GitHub 上，新机器 `git clone` 就回来了，一行不用重写。

真正必须手工搬的东西只有 5 项，其中**只有 1 项丢了就不可逆**——自建 apk 源的私钥。
其余丢了都能重建或从 GitHub 拿回来。

按「可重建 / 必须搬 / 可以丢」三类分清楚了，照着 §4 一步步做即可。

---

## 1. 可行性判断

| 类别 | 判断 | 依据 |
|---|---|---|
| 代码能不能重建 | ✅ 能，零损耗 | 50 个跟踪文件全部已推送，`.gitignore` 排除了所有构建产物 |
| 能不能换机 | ✅ 能 | 项目不依赖本机任何绝对路径（CI 在 GitHub runner 上跑） |
| 会不会丢东西 | ⚠️ 会丢 1 样不可逆的 | `.repo-keys/private-key.pem` |
| 新 agent 能不能接手 | ✅ 能 | `AGENTS.md` 1251 行，坑 1–15 全部记录，含自检清单 |

**唯一真正的风险点**：`private-key.pem` 是本机生成的 RSA 3072 私钥，
GitHub 上没有、CI secret 里也还没配（用户一直没操作）。丢了就永久失去自建源的签名能力，
只能重新生成一把并把所有已发布固件用户的 `/etc/apk/keys/public-key.pem` 换掉。

---

## 2. 必须手工迁移的清单

### 2.1 🔴 最高优先级：自建源私钥（丢了不可逆）

| 项 | 值 |
|---|---|
| 本机路径 | `D:\OneDrive\User\Network\Router\tenda_be12-pro\.repo-keys\private-key.pem` |
| 大小 | 2524 字节 |
| 类型 | RSA 3072 |
| 已验证 | `openssl rsa -check` → `RSA key ok` |
| 公钥副本 | 同目录 `public-key.pem`（636 字节） |

**同目录的公钥已经进 git 了**（`keys/public-key.pem`），所以**公钥不用搬**。
但 **GitHub 上那把公钥只对没有 stable private key 的情况有意义**——
本机这把私钥配进 secret 后，CI 会用本机私钥重新签名。

**搬完之后还要做**（用户待办，本机也没做）：

```
GitHub → Settings → Secrets and variables → Actions → New repository secret
  name: TENDO_REPO_PRIVATE_KEY
  value: private-key.pem 的**完整内容**（含 BEGIN/END 行）
```

没配这个 secret 的话，CI 会**整段跳过自建源**（`build.yml` 里的硬逻辑，不会拿一次性 EC 密钥凑数），
所以不会出事，但也一直没有自建源可用。

### 2.2 🟠 设备运维脚本：`.sshhelper/`

| 项 | 值 |
|---|---|
| 路径 | `D:\OneDrive\User\Network\Router\tenda_be12-pro\.sshhelper\` |
| 体积 / 数量 | 2.2 MB / 376 个文件 |
| 为什么必须搬 | 全是**跟设备对话的工具**，git 里没有，也没有别的来源 |

核心是两个入口：

```sh
# 在路由器上跑一个本地脚本
bash /d/OneDrive/User/Network/Router/tenda_be12-pro/.sshhelper/rssh.sh <脚本POSIX路径>

# 传一个本地文件到路由器
bash /d/OneDrive/User/Network/Router/tenda_be12-pro/.sshhelper/rscp.sh <本地POSIX路径> <远端路径>
```

设备连接参数（`192.168.100.254`，root，空密码）也只存在这些脚本里。

⚠️ `rssh.sh` 带了 `UserKnownHostsFile=NUL`，副作用是会在**项目根目录**生成假的 known_hosts 文件。
本机已经留下了 `_UL`、`_UL-MSI-Z390`、`_UL-MSI-Z390-2`、`_UL-MSI-Z390-3` 这几个 97 字节的垃圾文件，
以及一个名字被转义破坏的 `D:OneDriveUserNetworkRoutertenda_be12-pro.sshhelperprobe-r18-out.txt`。
换机后别误以为是什么重要资料，可以直接删（走 mavis-trash，别永久删除）。

### 2.3 🟠 含明文凭据的目录（搬的时候注意安全）

| 路径 | 体积 | 敏感点 |
|---|---|---|
| `SNAPSHOT固件配置教程\` | 320 KB | **`1-setup-wan.sh` 里有明文 PPPoE 密码** |

同目录还有 `final-healthcheck.sh` / `wan-setup.sh` / `SSH粘贴执行命令.md` /
`复制粘贴执行手册.md` / 几个 `ImmortalWrt.mtd*.bin`。

🚫 **这些内容一律不要提交进 git**（`.gitignore` 里的 `*.pem` 规则也覆盖不到它，
因为它根本不是 pem）。PPPoE 凭据是用户明确要求不入仓库的。

### 2.4 🟡 固件与分析产物（丢了能重造，但重造要等 4–6 小时 CI）

| 路径 | 体积 | 内容 |
|---|---|---|
| `固件\` | 210 MB | 多个固件 bin（sysupgrade、过渡固件、原厂包、SNAPSHOT/gt/iStore 变体） |
| `_firmware_artifact\` | 266 MB | run 14/15/18 的 zip 与分析脚本 |
| `备份\` | 112 MB | 含 `ImmortalWrt.mtd*.bin` |
| `教程\` | 72 KB | — |
| `dts\` | 8 KB | — |
| `info\` | 136 KB | — |
| `.tendarepo-work\` | 76 KB | tenda-repo 工作区 |

合计约 **660 MB**。其中 `备份\` 和 `固件\` 里的 `.bin` 是**已经刷进设备**的，
新机器如果只是继续开发，可以先不搬；如果要回砖，就必须搬。

### 2.5 🟡 根目录散落文件（不在 git 里，容易漏）

| 文件 | 大小 | 说明 |
|---|---|---|
| `README.md` | 36,507 B | 项目说明（**注意：仓库里另有一个 5,544 B 的 `README.md`**，两个不是一回事） |
| `tenda-repo-README.md` | 3,197 B | 自建源仓库的说明 |
| `~$nda泰山BE12 Pro不拆机刷OpenWrt+刷回官方固件教程 [复制链接].docx` | 162 B | Word 临时锁文件，可丢 |
| `_UL*` 四个 | 各 97 B | SSH 副作用垃圾，可丢 |

### 2.6 🟡 Minimax Code 数据目录

| 项 | 值 |
|---|---|
| 路径 | `C:\Users\tb852\.minimax\` |
| 总体积 | 约 224 MB |

**同款软件 + 同款模型的关键文件**：

| 文件 | 大小 | 为什么重要 |
|---|---|---|
| `auth/prod/cn/mcode-public/auth.json` | — | **登录凭据**，丢了要重新登录 |
| `config.yaml` | 3,642 B | 里面钉了 `defaultModel: minimax/MiniMax-M3.1-Flash-Preview`、`defaultModelVariant: thinking`、`permissionMode: bypassPermissions` |
| `permission.json` | 756 B | 权限配置 |
| `v2/` | 190 MB | 会话、快照、llm-call 记录 |
| `sessions/` | 2.3 MB | 聊天历史 |
| `agents/.builtin/` | 48 KB | 内置 agent 定义 |

**可以丢弃**：

| 路径 | 体积 | 理由 |
|---|---|---|
| `cache/` | 5.1 MB | `models-dev-catalog.json`，会自动重建 |
| `background-tasks/` | 3.8 MB | 临时产物，1316 个文件 |
| `run/` | 44 B | 租约文件 |
| `integrations/` `plugins/` | 0 | 空目录 |

**不用搬**：`.builtin-skills/`（20 个内置 skill）、`bin/`（4 个内置工具）——
这些是**安装时自带的**，新机器装好 Minimax Code 就有。

🔒 **`auth/` 整个目录都是凭据**。如果新机器不方便整套搬 `.minimax`，
**最简做法是：新机器装好 Minimax Code 后直接重新登录一次**，比搬文件干净。

---

## 3. 可完全重建的（不要搬）

| 内容 | 重建方式 |
|---|---|
| `Tenda-BE12-Pro-OpenWrt/.git` | `git clone`，`.git` 才 1.4 MB |
| `openwrt/` `dl/` `build_dir/` `staging_dir/` `tmp/` `bin/` | CI 自动拉取 + 编译 |
| `cache/` `background-tasks/` | 自动重建 |
| `.builtin-skills/` `bin/` | 装 Minimax Code 自带 |
| 公钥 `keys/public-key.pem` 及其 2 份副本 | 已在 git 里 |
| ssr-plus 面板仓库 | **已从 `versions.lock` 移除**，`coolsnowwolf/luci` 的 master 分支上没有任何 ssr 包 |

---

## 4. 新机器落地步骤

按顺序做，每步都有判据。

### Step 1 · 装 Git for Windows

要带 **Git Bash**（后面所有脚本都靠它）。
路径通常是 `C:\Program Files\Git\`，本项目脚本里**写死全路径调用** git 和 bash，
换机器如果装到别处，`.sshhelper/` 里的脚本要跟着改。

### Step 2 · clone 代码

```sh
git clone https://github.com/r3zound/Tenda-BE12-Pro-OpenWrt.git
cd Tenda-BE12-Pro-OpenWrt
git checkout immortalwrt-25.12
git log --oneline -1     # 期望: 4f67b45
```

分支情况（截至写作时）：

| 分支 | HEAD |
|---|---|
| `main` | `cf00b83` |
| `immortalwrt-25.12` | `4f67b45` ← 当前在做的 |

⚠️ **`main` 是旧的**（停在坑 12/13 修完那会儿），坑 14/15 的东西全在 `immortalwrt-25.12` 上。
别 checkout 错了。

### Step 3 · 装 Minimax Code，用同一个账号登录

模型选 **`MiniMax-M3.1-Flash-Preview`**（`config.yaml` 里钉的就是这个）。
装完先不用搬 `.minimax`，直接登录即可。

### Step 4 · 搬私钥（最关键的一步）

把旧机器的 `.repo-keys\` 整个目录复制到新机器的项目根目录下：

```
<新机器项目根>\.repo-keys\private-key.pem
<新机器项目根>\.repo-keys\public-key.pem
```

**复制完必须回读校验**（本项目铁律：拷贝成功 ≠ 文件对）：

```sh
openssl rsa -in .repo-keys/private-key.pem -noout -check   # 期望: RSA key ok
wc -c < .repo-keys/private-key.pem                        # 期望: 2524
```

### Step 5 · 把私钥加进 GitHub Actions secret

见 §2.1。**这一步本机还没做**，是当前的头号待办。

### Step 6 · 搬 `.sshhelper/`

复制 `D:\OneDrive\User\Network\Router\tenda_be12-pro\.sshhelper\` 到新机器同位置。
搬完改掉里面脚本的路径（如果新机器用户名不是 `tb852`）。

### Step 7 · 跑自检

见 §6。

---

## 5. 环境差异（新旧机器不一样的地方）

这几条是本项目**踩过的坑**，换机后如果行为诡异，先查这里。

### 5.1 网络：代理是硬需求，而且它会掉

| 现象 | 结论 |
|---|---|
| `github.com:443` 直连 | ❌ 频繁超时 / 连接重置，**必须走代理** |
| `api.github.com` 直连 | ✅ 可用（本次会话实测 curl 退出码 0） |
| 本地代理端口 | `127.0.0.1:7897`（**换机器后要重新确认端口**） |
| ⚠️ 本次会话后期 | 代理 7897 **掉线了**，所有走代理的请求 curl 退出码 7 |

所以脚本里**写「先试代理，失败再直连」的兜底**，不要只写一条路。

`raw.githubusercontent.com` 直连 HTTP=000，要走 `api.github.com` + `Accept: application/vnd.github.raw`。

### 5.2 取 GitHub token

新 shell 里 `$GH_TOKEN` 是不存在的。要现取：

```sh
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p')
```

前提是本机 `credential.helper=manager` 且已经登录过。新机器第一次要重新 `git credential` 授权。

### 5.3 PowerShell 的坑（本项目全程中文 Windows，最容易翻车的地方）

| 坑 | 后果 | 正确做法 |
|---|---|---|
| `&&` / `\|\|` | **PowerShell 里是语法错误** | 逐步 `if` 判定，或 `bash -c` |
| 管道给原生程序 | 插 CRLF，脚本被搞坏 | 用 `write` 工具写文件 + `bash` 调用 |
| 命令行里拼中文/引号 | 转义层层剥掉，输出只剩 `---` | **一律写脚本文件再执行** |
| `.ps1` 执行策略 | 默认禁止 | 不要用 `.ps1` |
| `C:\Windows\` 下 `Set-Content` | 拒绝 | 别在那儿写文件 |

> 实战记录：本次会话里连续 4 次用 `bash -lc '...'` 内联拼脚本，输出全部被吞成 `---`，
> 最后老老实实写 `.sh` 文件才通。**写脚本文件是唯一可靠路径。**

### 5.4 行尾

**整个仓库工作树是 LF**，和 `.gitattributes` 里的 `* text=auto eol=lf` 一致
（2026-10-04 用 `tr -d -c '\r' | wc -c` 逐个验过：`AGENTS.md` 1251 行、
`README.md` 142 行、`build.yml` 545 行、`stamp-firmware.sh` 90 行，**CR 字节数全为 0**）。

所以：

- 新机器 clone 出来就是 LF，**与 CI 完全一致，正常，不用做任何事**。
- 手工复制文件时也别把 CRLF 的 `.sh` 混进 `files/` —— 那会让设备上的
  `uci-defaults` 因 `\r` 执行失败、`/etc/config/*` 解析出诡异值。
- 仓库里**一律用 LF**，包括 `.md`。别听信「文档用 CRLF」的说法。

> ⚠️ 顺带记一个本次踩到的假结果：用 `grep -c $'\r' 文件` 统计 CR 行数是**不可靠**的。
> 在 Git Bash 的 `sh` 里，`$'\r'` 嵌在 `"$( ... )"` 中会被误解析，
> 导致 pattern 退化成「匹配任意行」，于是每个文件都报「全部行都含 CR」——
> 我据此差点把一个纯 LF 的仓库写进交接文档说成 CRLF。
> **正确写法：`tr -d -c '\r' < 文件 | wc -c`**，直接数 CR 字节。


### 5.5 GitHub API 限流

批量探查会 403/429。**不要循环轮询**，要看状态就跑一次。

---

## 6. 自检脚本

换完机跑一遍，全绿才算迁移成功。存成 `check.sh` 用 Git Bash 跑：

```sh
#!/bin/sh
# 换机自检：每项打印 OK / FAIL，最后给总判据
ok(){ echo "  ✅ $1"; }
no(){ echo "  ❌ $1"; FAILED=$((FAILED+1)); }
FAILED=0
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "▸ git 仓库"
cd "$ROOT" || exit 1
git rev-parse --abbrev-ref HEAD | grep -q immortalwrt-25.12 \
  && ok "在 immortalwrt-25.12 分支" || no "分支不对（当前 $(git rev-parse --abbrev-ref HEAD)）"
[ -z "$(git status --porcelain)" ] && ok "工作树干净" || no "工作树有未提交改动"
git log --oneline -1 | grep -q 4f67b45 && ok "HEAD = 4f67b45" || no "HEAD 不是 4f67b45"

echo "▸ 私钥（不可逆，优先查）"
if [ -f "$ROOT/.repo-keys/private-key.pem" ]; then
  openssl rsa -in "$ROOT/.repo-keys/private-key.pem" -noout -check 2>/dev/null \
    && ok "私钥有效" || no "私钥校验失败"
  [ "$(wc -c < "$ROOT/.repo-keys/private-key.pem")" = "2524" ] \
    && ok "私钥 2524 字节" || no "私钥字节数不对"
else
  no "私钥不存在 —— 自建源永久不可用"
fi

echo "▸ 运维脚本"
[ -f "$ROOT/.sshhelper/rssh.sh" ] && ok "rssh.sh 在" || no "缺 .sshhelper/rssh.sh"
[ -f "$ROOT/.sshhelper/rscp.sh" ] && ok "rscp.sh 在" || no "缺 .sshhelper/rscp.sh"

echo "▸ 网络"
curl -sS --max-time 10 -o /dev/null https://api.github.com && ok "api.github.com 直连通" || no "api.github.com 不通"
curl -sS --max-time 10 -x http://127.0.0.1:7897 -o /dev/null https://github.com \
  && ok "github.com 走 7897 通" || no "github.com 走代理不通（github.com 必须走代理）"

echo "▸ 关键脚本可执行位"
for f in scripts/*.sh scripts/lib/*.sh; do
  [ -x "$f" ] || no "$f 没有可执行位（chmod +x）"
done

echo
[ "$FAILED" -eq 0 ] && echo "🎉 全部通过" || echo "⚠️ $FAILED 项失败"
```

---

## 7. 当前进展与未完成的事

### 7.1 已完成

- **坑 1–13**：全部修复并推送（`eb56c79` / `cf00b83`）
- **ImmortalWrt 25.12 板级移植**：DTS + `Build/tenda-mkdualimageheader` + `Device/tenda_be12-pro`（`7864c6d`）
- **自建 apk 源基础设施**：`fetch-proxy-packages.sh` / `build-repo.sh` / `publish-repo.sh`（`37cba7b` / `a3896f0` / `53d3763`）
- **签名机制核实与 4 处致命缺陷修复**（`208119c`）
- **坑 14**（内核模块源）`b02e556`
- **坑 15**（版本号时间戳）`32506bc` / `b719707` / `12316b8` / `4f67b45`

### 7.2 CI 最新状态：Run #22（本次会话查实）

| 项 | 值 |
|---|---|
| run id | 37138579072 |
| job id | 111248097417 |
| head | `4f67b45` |
| 起止 | 16:54:40Z → 18:37:58Z（约 1 小时 43 分） |
| 结论 | **failure** |

| 步骤 | 结果 |
|---|---|
| 1–17（检出 / 依赖 / ccache / versions.lock / feeds / 板级移植 / **拉取 feeds** / 挂载包） | ✅ 全过 |
| 18 编译固件 | ⚠️ **显示 success，实际没产出镜像**（见下） |
| **19 固件文件名加时间戳 ⚠️** | ❌ 失败（**这一声报警是准的**） |
| 20–28（校验和 / 体积守卫 / 内容抽查 / 面板 / 自建源） | ⏭ skipped |
| 29–30（上传 ccache / 上传固件产物） | ✅ 成功，产物已下载分析 |

#### 已查实的根因（两层）

**第一层：CI 骗了我们。** 下载 artifact 拆开后，里面只有：

```
config.buildinfo
mt7987-ram-comb-bl2-20261004.0055.bin     ← 本板用的 BL2 preload
mt7988-ram-*-bl2-20261004.0055.bin       ← 另外 7 个
packages/*.apk                            ← 96 个包
```

**一个 `*squashfs-sysupgrade*.bin` 都没有，连 `sha256sums` 也没有。**
但第 18 步却顶着绿灯。原因在 `build.yml` 原来的写法：

```sh
make -j$(nproc) V=s 2>&1 | tee /tmp/build.log || { ...; exit 1; }
```

**管道的退出码是最后一个命令（`tee`）的，`tee` 几乎永远返回 0** ——
所以那个 `||` 分支永远不触发，`make` 崩了也照样报 success。
这就是 AGENTS.md 里记过的 `${PIPESTATUS[0]}` 教训，**在 workflow 里又犯了一次**
（同一个文件第 371 行的体积守卫早就用对了，属实现不一致）。
**已修**：改用 `${PIPESTATUS[0]}`，并额外加一条「退出码为 0 但没有 sysupgrade 镜像」的兜底判据。

**第二层：`make` 为什么失败，仍待查。** 需要第 18 步的完整日志
（约 46 MB，本次直连下载两次都超时，代理又恰好掉线）。

> 值得注意的是：**这次是 `stamp-firmware.sh` 的回读校验把假成功拦下来的**。
> 也就是当初坚持写 `find_sysupgrade_bin` 回读的那个决定救了场 ——
> 否则这一轮会以「✅ 编译成功」的形式静静溜过去，体积守卫和内容抽查全部静默跳过。


⚠️ 已知隐患：`.github/workflows/build.yml` 的 `timeout-minutes: 360` 可能不够——
Run #19 的冷构建跑了 2h15m 还在工具链阶段（ccache 几乎没命中，因为之前缓存是
openwrt SNAPSHOT 内核 6.18、这次是 ImmortalWrt 内核 6.12）。**考虑调高。**

### 7.3 用户待办（换机后依然要提醒）

1. 🔴 把 `private-key.pem` 加为 GitHub Actions secret `TENDO_REPO_PRIVATE_KEY`
2. 🟡 在 LuCI 里改掉公开的默认 WiFi 密码（`AGENTS.md` §1 §9 §11 已写明这是用户知情同意的，
   但长期公开不理想）
3. 🟡 装包验证 kmod 能真正加载（用户此前选择「先只加源，不装任何包」，已加 1 个官方 kmods 源，
   包数 9187 → 10412）
4. 🟡 考虑调高 `timeout-minutes`

### 7.4 已知的设备侧硬约束（别踩）

| 约束 | 说明 |
|---|---|
| 🚫 SNAPSHOT 固件**禁用** `/etc/init.d/network restart` | AN8855 交换芯片会被搞挂，一律用 `reload_config` |
| 🚫 SNAPSHOT 固件**禁止**在 LuCI 点「升级全部已安装的软件包」 | 会把内核模块一起升掉导致开不了机 |
| ⚠️ 本机构建固件**装不了任何内核模块** | `CONFIG_BUILDBOT` 门控导致，已用 `add_kmods_feed()` 自动补官方 kmods 源 |
| ⚠️ 设备 apk 是运行时版 | **没有** `mkndx` / `mkpkg` 子命令，本地无法预演索引签名 |

---

## 8. 交给下一个 agent 的开场白

新机器上第一个 agent 读完 `AGENTS.md` 之后，直接说这句即可接上：

> 接着 `immortalwrt-25.12` 分支干。HEAD 是 `4f67b45`。上一个会话的收尾状态：
> CI Run #22 **并没有编译成功** —— 第 18 步显示绿灯是假的（`make | tee` 吞了退出码，已修），
> artifact 里只有 8 个 BL2 preload，没有 sysupgrade 镜像。
> 第 19 步的失败是**正确报警**，别去「修」它。
> 真正待查的是 **`make` 为什么失败**：拉第 18 步的完整日志（约 46 MB）。
> 另外交接文档在 `docs/HANDOVER-MIGRATION.md`，换机自检脚本在 §6。

---

## 9. 硬性约束速查（改代码前必读）

完整版在 `AGENTS.md`（1251 行，坑 1–15 全记录）。最容易违反的几条：

1. **双份同步铁律**：`files/` 与 `package/tenda-preset/files/` 是同一份内容的两个副本。
   改完必须 `cp -r files/. package/tenda-preset/files/ && diff -r files package/tenda-preset/files`
2. **回读校验铁律**：拷贝 / 追加 / 赋值成功 ≠ 生效，**必须回读**。本项目栽过多次。
3. **单份真相源铁律**：清单只能有一份权威来源（`versions.lock`），复制副本必然漂移。
4. **校验必须查产物，不能查中间态**：`.config` 里的值会被 `make defconfig` 静默吃掉，
   只有固件里的 `/etc/openwrt_release` 算数。
5. **管道会吞掉退出码**：`cmd | tee log || exit 1` 里的退出码是 **`tee` 的**，`tee` 永远成功，
   所以 `||` 分支是死代码。必须写 `cmd | tee log` 之后单独取 `${PIPESTATUS[0]}`。
   **本项目已经因此被骗过一次**（Run #22 把编译失败报成成功），是重复犯的坑。
6. **不要擅自编译**：CI 只在 workflow_dispatch / 打 `v*` tag / 每周一 cron `17 3 * * 1` 触发。
7. **删除文件一律走 mavis-trash**，不用永久删除。
8. **PPPoE 凭据不入 git**；WiFi 密码在公开仓库是用户**知情且明确同意**的
   （`AGENTS.md` §1 §9 §11 有记录，后续 agent 不得擅自改回去）。

---

*本文档不含任何私钥、token 或 PPPoE 明文密码，只记录路径与搬运方式。*
