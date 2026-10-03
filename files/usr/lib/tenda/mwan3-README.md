# mwan3 配置参考 — Tenda BE12 Pro

> 安装脚本现在会**自动生成** `/etc/config/mwan3`，不用再照着本文档手点。
> mwan3 刻意不打进固件镜像（原因见 README §4.3），需先执行安装脚本：
>
> ```sh
> sh /usr/lib/tenda/install-mwan3.sh     # 安装 + 自动写配置
> sh /usr/lib/tenda/install-mwan3.sh --check   # 负载均衡体检
> ```
>
> 本文档保留下来是为了说明**每个参数为什么是这个值**，以及要改成什么。

## 一键命令

```sh
sh /usr/lib/tenda/install-mwan3.sh              # 安装 + 生成配置（重写前自动备份）
sh /usr/lib/tenda/install-mwan3.sh --config     # 只重写配置
sh /usr/lib/tenda/install-mwan3.sh --check      # 负载均衡体检
sh /usr/lib/tenda/install-mwan3.sh --status     # 查看当前状态
sh /usr/lib/tenda/install-mwan3.sh --diag       # 生成诊断报告（贴论坛用）
sh /usr/lib/tenda/install-mwan3.sh --uninstall  # 卸载
```

改接口名/权重不必改脚本，用环境变量：

```sh
WAN_A=wan WAN_B=wan2 WAN_A_WEIGHT=3 WAN_B_WEIGHT=1 sh /usr/lib/tenda/install-mwan3.sh --config
```

## ⚠️ 负载均衡的前提：流量卸载必须关闭

**这一条不满足，下面所有配置都是白配。**

防火墙的软/硬件卸载会在 **ingress 钩子**把连接直接钉死在链路上，
**完全绕过 mwan3 的 mangle 打标链**。表现是：mwan3 一切正常、
`mwan3 status` 策略也正常，但**第二条 WAN 的 rx/tx 长期只有几百字节**。

```sh
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci set firewall.@defaults[0].fullcone='1'
uci commit firewall
/etc/init.d/firewall restart
```

代价是失去 NAT 卸载、转发走 CPU。本机四核 A53 扛得住 1G 家用负载。
**若更看重转发性能**，把策略改成「故障转移」，再把前两项改回 1。

`--check` 的第 1 项就是查这个，跑一次就知道。

## 手动配置步骤（对应 README §5.5）

### 1. 前置：填写移动宽带 PPPoE 凭据

```sh
uci set network.wan2.username='你的移动宽带账号'
uci set network.wan2.password='你的移动宽带密码'
uci commit network
reload_config
```

> ⚠️ 最后一行必须是 `reload_config`，**不要**换成 `network restart`
> （即 `/etc/init.d/network` 那条）。本机 AN8855AE 交换芯片在 SNAPSHOT
> 固件下对整栈软重置支持不良：整栈重启之后 LAN 口失联，必须断电才能恢复
> （见 `README.md` §8）。`reload_config` 是增量生效，安全。

确认两条 WAN 都能独立上网：

```sh
ping -I eth2   223.5.5.5    # 电信
ping -I lan3   223.5.5.5    # 移动
```

### 2. LuCI 配置（网络 → MultiWAN Manager）

**Interfaces（接口）** — 由 `write_config()` 生成

| 名称 | 接口 | 初始状态 | 跟踪 IP | 可靠性 | 间隔/超时 | 失败/恢复 |
|------|------|----------|---------|--------|-----------|-----------|
| `wan` | wan | Online | 223.5.5.5, 119.29.29.29 | 1 | 5 / 2 | 3 / 3 |
| `wan2` | wan2 | Online | 223.5.5.5, 119.29.29.29 | 1 | 5 / 2 | 3 / 3 |

> `wan2` 的 metric 在 `/etc/config/network` 里是 20（`wan` 是 10）。
> 注意 mwan3 **成员**里的 metric 是另一回事，见下表。

**Members（成员）** — 段名 `wan_m1_w3` / `wan2_m2_w1`

| 名称 | 接口 | 成员 metric | **权重 weight** |
|------|------|-------------|-----------------|
| `wan_m1_w3` | wan | 1 | **3** |
| `wan2_m2_w1` | wan2 | 2 | **1** |

> 权重 3:1 依据：电信 1000M : 移动 300M ≈ 3.3:1
> **部署后按 iperf3 实测复核**。若电信软 NAT 实测仅 600M，改 2:1
> （`WAN_A_WEIGHT=2 sh install-mwan3.sh --config`）。
>
> ⚠️ **段名 ≤ 15 字符**，超长 mwan3 静默跳过。`--check` 第 3 项查这个。

**Policies（策略）** — 段名 `balanced` / `mobile` / `telecom` / `failover`

| 名称 | 策略类型 | 使用成员 | 用途 |
|------|----------|----------|------|
| `balanced` | 均衡 | `wan_m1_w3` + `wan2_m2_w1` | **默认**，3:1 分流 |
| `mobile` | 均衡 | `wan2_m2_w1` | **NAT 敏感业务**（单层 NAT） |
| `telecom` | 均衡 | `wan_m1_w3` | 强制电信出口 |
| `failover` | 故障转移 | `wan_m1_w3` + `wan2_m2_w1` | 严格优先级，`last_resort unreachable` |

> ⚠️ **名称 ≤ 15 字符**，超长会被 mwan3 静默跳过。

**Rules（规则）** — 段名 `r_gaming` / `r_remote` / `r_https` / `r_default`

| 名称 | 源区域 | 协议 | 目标端口 | sticky | 策略 |
|------|--------|------|----------|--------|------|
| `r_gaming` | lan | UDP | `27015:27030,5000:5010,25565:25575` | — | `mobile` |
| `r_remote` | lan | TCP | `22,3389,5900,32400` | — | `mobile` |
| `r_https` | lan | TCP | `443` | ✅ | `balanced` |
| `r_default` | lan | 任意 | dest_ip `0.0.0.0/0` | — | `balanced` |

> **为什么游戏/远程走 mobile 而不是电信？**
> 电信线是光猫路由 + 路由器 DHCP = **双重 NAT**，NAT 类型会降级成
> Restricted/Symmetric，联机匹配困难、端口转发需在光猫上再配一次。
> 移动线是光猫桥接 + 路由器 PPPoE = **单层 NAT**，出口干净。
> 300M 带宽对游戏绰绰有余。

> **为什么 443 要 sticky？** 否则一条大流量会被拆到两条 WAN，
> 服务器侧看到的源 IP 时断时续。
>
> **为什么每条规则都写 `option src_zone 'lan'`？**
> 路由器自身发起的流量（apt/update/NTP）走 main 表，
> 不该被策略路由抢走；不写的话 mwan3 会连自己的流量一起打标。

### 3. 验证

```sh
mwan3 status                      # 两条 WAN 应均为 online
mwan3-track wan wan2 -t          # 持续 ping 跟踪目标
watch -n1 'cat /proc/net/nf_conntrack | grep -c ""'   # 连接数
```

多线程测速（**单线程测不出叠加效果**）：

```sh
iperf3 -c <对端IP> -P 10 -t 30
# 或
apt install axel && axel -n 10 <大文件URL>     # Debian/Ubuntu
```

观察分流：

```sh
nft list table inet mwan3         # 原生 nft 版的规则表
ip rule show                      # 策略路由规则
```

## 常见问题

**Q: balanced 策略只有一条线有流量**
A: 装成了官方 iptables 版。执行 `sh /usr/lib/tenda/install-mwan3.sh --status` 确认，
   若显示 `iptables` 请重装（脚本会自动卸载旧版）。

**Q: sysupgrade 后多 WAN 失效**
A: **预期行为**。mwan3 刻意不进镜像，每次升级后重新执行安装脚本。

**Q: wan2 一直 offline**
A: ① 确认移动光猫已桥接；② PPPoE 凭据是否填写；③ `logread | grep mwan3` 看跟踪日志。

**Q: 测速叠加不明显**
A: ① 确认用多线程测速；② 确认策略类型是「均衡」而非「故障转移」；③ 确认权重已配。
