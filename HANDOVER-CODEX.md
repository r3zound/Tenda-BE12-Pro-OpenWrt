# 交接文档 · 交给 Codex

> 面向对象：在本机用 Codex CLI 接手本项目的 agent / 人。
> 写作时间：2026-10-17 · 对应分支 `immortalwrt-25.12` · HEAD `7e136a6`
>
> **本文不重复 `AGENTS.md`**（那是项目的完整技术档案，坑位清单 1~22 都在里面）。
> 本文只讲三件 `AGENTS.md` 不会讲的事：
> ① **Codex 在这台机器上怎么跑** ② **本机环境的陷阱** ③ **当前真实状态**。

---

## 0. 一分钟速览

| 项 | 值 |
|---|---|
| 项目 | 为 Tenda BE12 Pro 定制 OpenWrt 主路由固件 |
| 仓库 | `r3zound/Tenda-BE12-Pro-OpenWrt`（**公开**） |
| 分支 | `immortalwrt-25.12`（= GitHub 默认分支），内核 6.12 |
| 项目根 | `/mnt/c/Users/LG/Documents/Codex/Tenda-BE12-Pro-OpenWrt/Tenda-BE12-Pro-OpenWrt` |
| 数据目录 | 在项目根的**上级**（`.sshhelper/`、`.repo-keys/`、`固件/`、`备份/` 等） |
| 构建 | GitHub Actions，约 90 分钟/轮，ccache 命中后 |
| 固件现状 | 构建链路全绿，**最新固件尚未上机验证** |

---

## 1. ⭐ Codex 在这台机器上怎么跑

**这是最容易搞错的一点：Codex CLI 跑在 WSL 里，不在 Windows 宿主上。**

| 项 | 值 |
|---|---|
| 版本 | `codex-cli 0.163.0-alpha.10.2` |
| 形态 | Linux ELF 64-bit 静态链接（`file` 确认为 ELF，不是 Windows PE） |
| 位置 | `/mnt/c/Users/LG/.codex/bin/wsl/<哈希>/codex` |
| 配置 | `/mnt/c/Users/LG/.codex/config.toml` |
| 模型 | `model_provider = "deepseek"` · `model = "deepseek-flash"` · `model_reasoning_effort = "high"` |

### ⛔ 路径里有哈希目录，别写死

`<哈希>` 是运行期生成的锁目录，**每次可能变**。硬编码路径必然失效。
用动态查找：

```sh
# 在 WSL 里
CB=$(find /mnt/c/Users/LG/.codex/bin/wsl -maxdepth 2 -type f -name 'codex' | head -1)
"$CB" --version
```

本机当前实测值是 `f19bbb73214bc62a`，但**别依赖它**。

### 从 PowerShell 调 Codex 的正确姿势

```powershell
wsl.exe -d Ubuntu -- bash -c 'CB=$(find /mnt/c/Users/LG/.codex/bin/wsl -maxdepth 2 -type f -name codex | head -1); exec "$CB" exec "你的任务"'
```

⚠️ **不要用 Git Bash 中转** —— Git Bash 会把 `/mnt/c/...` 翻译成
`C:/Program Files/Git/mnt/c/...`，直接报 `No such file or directory`。

### 常用命令

```sh
codex exec "<任务>"              # 非交互执行（脚本化首选）
codex exec -                     # 从 stdin 读任务
codex exec resume --last         # 续上一次会话
codex review                     # 非交互代码审查
codex doctor                     # 诊断本机安装/配置/鉴权
codex login status               # 鉴权状态
codex --help                     # 全部命令
```

### 沙箱与权限

Codex 的 sandbox / approval policy 由 `config.toml` 与命令行 `-c key=value` 决定。
**需要写文件时明确给写权限**，别指望它能自行动仓库。

---

## 2. 项目在哪、怎么进

```sh
# 项目根（git 仓库）
cd /mnt/c/Users/LG/Documents/Codex/Tenda-BE12-Pro-OpenWrt/Tenda-BE12-Pro-OpenWrt

# 数据目录在**上级**，不是仓库里
ls ../.sshhelper/        # 428 个运维脚本（本机独有，git 里没有）
ls ../.repo-keys/        # 🔴 自建源私钥，丢了不可再生
ls ../固件/              # 历史固件产物
ls ../备份/              # 原厂 mtd 分区，刷砖救砖唯一来源
```

⚠️ **`AGENTS.md` 是 Codex 的入口文件，先完整读一遍再动手。**
它有 1000+ 行，包含：坑位清单 1~22、项目结构、构建方式、43 条自检项。

### ⚠️ 仓库工作树必须保持干净

`../.sshhelper/check-migration.sh` 有一条判据是 `git status --porcelain` 必须为空。
**在仓库里新增未跟踪文件会让这项判红。** 本文档就是这样的文件 —— 提交它，或忽略它。

---

## 3. ⭐ 本机环境的五个陷阱（全部实测踩过）

这些是 `AGENTS.md` 里没有、但会直接浪费你时间的。

### ① PowerShell 里的裸 `bash` 是 WSL，不是 Git Bash

```powershell
bash xxx.sh   # ← 打到 C:\Windows\System32\bash.exe（WSL 启动器）
              #    而本机 WSL 有发行版能跑 → 不报错，静默跑错环境
```

**必须写全路径**：

```powershell
& 'C:\Program Files\Git\bin\bash.exe' '脚本.sh'
```

### ② PowerShell 管道会破坏二进制

```powershell
openssl pkey -in private-key.pem -pubout -outform DER 2>$null | sha256sum
```

PowerShell 5.1 会把二进制 DER 转成文本再编码，**算出的 sha256 必然不同**。
本机实测：PS 里得 `04e6d34f...`，Git Bash 里才是正确的 `74ea4b938d1c9496...`。
任何碰到二进制的管道都必须走 Git Bash。

### ③ `git push` 报 `cannot lock ref` —— **多半是假的**

本机已实测**四次**，现象完全一致：

```
第 1 次 push → [remote rejected] ... cannot lock ref: is at <新> but expected <旧>  + exit 1
第 2 次 push → Everything up-to-date                                              + exit 0
```

机理：ref 更新提交给 GitHub 并**已应用成功**，但**回包在抖动的链路被掐断**，
git 没收到确认就按乐观锁失败报错。**远端早就是新 commit 了。**

→ **看到这个报错不要回滚、不要 reset。** 重试一次即可。
`../.sshhelper/retry-git.sh` 已经内置了这个处理：重试耗尽后会独立核实远端状态，
而不是拿重试次数当结论。

### ④ 网络本身会间歇性失败

- `github.com` 直连超时/被重置，**必须走代理** `http://127.0.0.1:7897`
- Windows Git Bash 必须 `http.sslBackend = openssl`（schannel 会报 TLS EOF）；
  **WSL 自带 Git 不支持 openssl 后端**，那里要保持未设置，否则会报
  `Unsupported SSL backend 'openssl'`。两边都建议 `http.version = HTTP/1.1`
- 链路会**间歇 TLS EOF**，一次失败不代表结论 → 走 `retry-git.sh`
- 拉 Actions 日志**必须带 `Authorization` 头**（不带实测 403），
  且用 `C:\Program Files\Git\ucrt64\bin\curl.exe` 走代理；
  PowerShell 的 `Invoke-WebRequest` 会撞 schannel EOF

### ⑤ `unsquashfs` 的退出码不可信

解包 100% 成功也返回非 0（它把「不是 superuser 建不了 `/dev/console`」算进退出码）。
**按产物判断，不要看退出码。** —— 这是项目 `AGENTS.md` 坑 4 记的，我第一次也踩了。

另外：`sysupgrade.bin` 是 tar 包，squashfs 在里面的 `sysupgrade-tenda_be12-pro/root` 分片，
要 `tar -xf` 先解一层。

---

## 4. ⭐ WSL 是这个项目最被低估的工具

**CI 一轮 90 分钟，但本地解开固件看内容只要几分钟。**

Ubuntu 26.04.1 LTS 自带 `unsquashfs 4.7.5`，`/mnt/c` 已挂载，项目直接可达。

```sh
# 在 WSL 里对任意固件产物做完整内容抽查
wsl.exe -d Ubuntu -- bash /mnt/c/.../.sshhelper/verify-run32-in-wsl.sh
```

**坑 21（REVISION 导出顺序错了，导致固件版本串不带时间戳）就是这样发现的** ——
CI 全绿、`verify-firmware.sh` 的 60+ 项抽查全过，只有真正把 squashfs 解开
看 `/etc/openwrt_version` 才看得见。

> ⚠️ `verify-firmware.sh` 有一条 warning 写着
> 「REVISION 未设置（本地跑抽查脚本时正常，CI 里必须有）」——
> **别顺着这句话放过，它恰恰是线索。**

传脚本要**写文件再 `wsl.exe -d Ubuntu -- bash <路径>`**，PowerShell 内联传多行会被引号搞坏。

---

## 5. 当前真实状态

### ✅ 已经修好的（坑 1~22 均有解；坑 22 待下一轮 CI 验证）

最近三轮结果：

| Run | commit | 耗时 | ccache 命中 | 结论 |
|---|---|---|---|---|
| #29 | `ff45b84` | 3h13m | 10.01% | ccache 首次真正落盘；自建源静默退出 |
| #31 | `6ee6254` | 75 min | 28.06% | 滚动缓存 key 生效；坑 19 修复生效 |
| #32 | `88ae33d` | 93 min | **34.28%** | 包名发现修复生效（5→15 个包定义） |

- ✅ ccache 真正生效：数据落盘、恢复命中、持续更新
- ✅ 签名密钥 secret 已配，密钥对校验通过
- ✅ `verify-firmware.sh` 60+ 项抽查全过（exit 0）
- ✅ 坑 20 修复：包名发现认得出 `define Package/$(VAR)` 写法

### ⬜ 还开着的事

**1. 自建 apk 源发不出去（主要遗留项）**

链路全通（签名 ✅、收包 ✅、索引生成+签名 ✅），但**源里 0 个 kmod**，
硬校验按设计 fail-closed 拒绝发布。

**2026-10-17 更正**：Run #32 的 artifact 里明明有
`packages/kmod-nft-tproxy-6.12.108-r1.apk`，日志里也有 `apk mkpkg` 产出记录；
真正的问题是 `build-repo.sh` 只收 `bin/packages/<arch>/`，漏掉了
`bin/targets/mediatek/filogic/packages/`。kmod 一直编出来了，只是没被收进源。
完整证据见 `AGENTS.md` §5 坑 22。

修复已落地并用 `.sshhelper/test-collect-packages.sh` 验证：旧逻辑漏 kmod，
新逻辑同时收 arch 包和目标包。**下一轮 CI 的验收判据是 `kmods > 0` 且
`kmod-nft-tproxy` 在源中。**

**面板能不能在 25.12 上编过是另一个独立问题。** 坑 20 已修好包名发现，
Run #33 是第一次让这些面板真正进入编译；结果看第 25~27 步，不能再拿
「kmod 缺失」反推面板状态。

> 注意：用户的实际需求（双 WAN / 无线 / LuCI 主题 / kmod）**都不依赖自建源** ——
> kmod 走官方镜像站就能装（`AGENTS.md` 坑 14 的 `add_kmods_feed()` 已经解决）。
> 自建源唯一的价值是「kmod 与固件同 build root 产出」，
> 而这个价值的前提是透明代理面板能编出来。

**2. 固件尚未上机验证** —— 构建全绿不等于设备可用。
这是目前最高优先级的**业务**事项（技术侧已经收敛）。

**3. Run #33 待验证**（坑 21 的修复，2026-10-17 02:12 UTC 启动；
接手时仍处于第 19 步「编译固件」）

---

## 6. 怎么验证一次构建（推荐流程）

**别拿 CI 当调试器。** 标准动作：

```sh
# 1. 触发（需 token，scopes: gist, repo, workflow）
curl -X POST -H "Authorization: Bearer $TOKEN" \
  https://api.github.com/repos/r3zound/Tenda-BE12-Pro-OpenWrt/actions/workflows/build.yml/dispatches \
  -d '{"ref":"immortalwrt-25.12","inputs":{"variant":"immortalwrt-25.12"}}'

# 2. 改动小的话，先在本地跑自检（AGENTS.md §11 的清单）
bash -n scripts/*.sh scripts/lib/*.sh
diff -r files package/tenda-preset/files && echo "✅ 双份同步"
bash ../.sshhelper/check-migration.sh    # 换机自检

# 3. 拿到固件后，本地解开看内容（几分钟，不用等下一轮 CI）
wsl.exe -d Ubuntu -- bash ../.sshhelper/verify-run<NN>-in-wsl.sh
```

`.sshhelper/` 下还有这些现成脚本（**428 个，本机独有，git 里没有**），
排查时先翻一遍，能省大量时间：

| 脚本 | 用途 |
|---|---|
| `retry-git.sh` | git fetch/push 重试 + 远端状态独立核实 |
| `check-migration.sh` | 换机自检（8 项） |
| `rssh.sh` / `rscp.sh` | 与路由器对话（`root@192.168.100.254`） |
| `verify-*-in-wsl.sh` | WSL 里解开固件做内容抽查 |
| `check-new-guards.sh`、`test-guard*.sh` | 坑 18/19/20/21 的守卫正反向验证 |

---

## 7. 凭据现状

| 项 | 状态 |
|---|---|
| GitHub token | ✅ 已授权，存于 Windows 凭据管理器（Git Credential Manager），scopes `gist, repo, workflow` |
| Actions secret `TENDO_REPO_PRIVATE_KEY` | ✅ 已配（libsodium sealed box API 写入） |
| 代理 | `http://127.0.0.1:7897`（实测通） |

**取 token（给 API 用）**：

```powershell
cmd /c "git credential fill < <协议文件>"   # 从凭据管理器读
```

⚠️ **本机上有两处敏感数据，Codex 若要外发内容务必避开**：

- `../.repo-keys/private-key.pem` —— 自建源签名私钥，**丢了不可再生**
- `../SNAPSHOT固件配置教程/` —— **含明文 PPPoE 宽带密码**

仓库本身是公开的，**PPPoE 凭据从不入库**；WiFi 默认密码 `abcd1234.` 是
用户知情后明确决定公开的（见 `AGENTS.md` §1），**不要当泄露擅自改掉**。

---

## 8. 别重复踩的坑

**完整清单在 `AGENTS.md` §5（22 个），每条都有成因、证据和守卫脚本。** 不在这里重复。

最值得先记住的四条，因为它们有一个共同点 —— **全部静默失败**：

| 坑 | 一句话 |
|---|---|
| 坑 1 / 5 | 索引不到「根目录 Makefile」的仓库 → 主题全不在固件里，CI 全绿 |
| 坑 9 | `uci set <包>.<段>=<值>` 是**赋类型**不是赋选项值 → 刷完 LAN 拿不到 IP |
| 坑 15 / 21 | 版本时间戳：文件名和固件内版本串**必须**是同一个值，且 `GITHUB_ENV` 是单向的 |
| 坑 19 / 20 | 工具写窄了就等于「上游不兼容」；`set -e` 下守卫写在失败命令之后等于死代码 |

**一条通用原则**（本项目 22 个坑的共同教训）：

> **报错、绿灯、`ok` 退出码，全都证明不了「东西真的进去了」。**
> 判断的唯一方式是**去看产物本身**。

---

## 9. 交接 checklist

接手时按这个顺序过一遍：

- [ ] 读 `AGENTS.md`（至少 §0 §1 §5 §11）
- [ ] 跑 `bash ../.sshhelper/check-migration.sh`，确认 FAIL=0
- [ ] 确认 `git status --porcelain` 为空（工作树干净）
- [ ] 查 Run #33 结果，验证坑 21 的修复（版本串是否带回时间戳）
- [ ] 验收坑 22：新源里 `kmods > 0`、`kmod-nft-tproxy` 在位
- [ ] 单独看 Run #33 的面板预编译结果（不再和 kmod 收集混为一谈）
- [ ] 决定是否把固件刷到设备上做上机验证（目前最高优先级的业务事项）
