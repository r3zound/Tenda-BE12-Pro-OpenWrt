# mwan3 配置参考 — Tenda BE12 Pro

> ⚠️ 这是**参考模板**，不是自动应用的配置。
> mwan3 刻意不打进固件镜像（原因见 README §4.3），需先执行安装脚本：
>
> ```sh
> sh /usr/lib/tenda/install-mwan3.sh
> ```

## 一键配置

```sh
sh /usr/lib/tenda/install-mwan3.sh --status      # 查看当前状态
sh /usr/lib/tenda/install-mwan3.sh --diag        # 生成诊断报告（贴论坛用）
sh /usr/lib/tenda/install-mwan3.sh --uninstall   # 卸载
```

## 手动配置步骤（对应 README §5.5）

### 1. 前置：填写移动宽带 PPPoE 凭据

```sh
uci set network.wan2.username='你的移动宽带账号'
uci set network.wan2.password='你的移动宽带密码'
uci commit network
/etc/init.d/network restart
```

确认两条 WAN 都能独立上网：

```sh
ping -I eth2   223.5.5.5    # 电信
ping -I lan3   223.5.5.5    # 移动
```

### 2. LuCI 配置（网络 → MultiWAN Manager）

**Interfaces（接口）**

| 名称 | 接口 | 初始状态 | 跟踪 IP | 可靠性 | 间隔/超时 | 失败/恢复 |
|------|------|----------|---------|--------|-----------|-----------|
| `wan` | wan | Online | 223.5.5.5, 114.114.114.114 | 1 | 5 / 2 | 3 / 8 |
| `wan2` | wan2 | Online | 223.5.5.5, 114.114.114.114 | 1 | 5 / 2 | 3 / 8 |

> `wan2` 高级选项中开启 **Use gateway metric** 或保持默认 20（见 `/etc/config/network`）。

**Members（成员）**

| 名称 | 接口 | 跃点 metric | **权重 weight** |
|------|------|-------------|-----------------|
| `wan_m1_w3` | wan | 1 | **3** |
| `wan2_m2_w1` | wan2 | 2 | **1** |

> 权重 3:1 依据：电信 1000M : 移动 300M ≈ 3.3:1
> **部署后按 iperf3 实测复核**。若电信软 NAT 实测仅 600M，改为 2:1。

**Policies（策略）**

| 名称 | 策略类型 | 使用成员 | 用途 |
|------|----------|----------|------|
| `balanced` | 均衡 | `wan_m1_w3` + `wan2_m2_w1` | **默认**，3:1 分流 |
| `mobile` | 均衡 | `wan2_m2_w1` | **NAT 敏感业务**（单层 NAT） |
| `telecom` | 均衡 | `wan_m1_w3` | 强制电信出口 |
| `failover` | 故障转移 | `wan_m1_w3` + `wan2_m2_w1` | 严格优先级 |

> ⚠️ **名称 ≤ 15 字符**，超长会被 mwan3 静默跳过。

**Rules（规则）** — 按优先级从上到下

| 名称 | 源区域 | 协议 | 目标 IP | 目标端口 | 策略 |
|------|--------|------|--------|----------|------|
| `r_gaming` | lan | UDP | — | `27015:27030,5000:5010,25565:25575` | `mobile` |
| `r_remote` | lan | TCP | — | `22,3389,5900,32400` | `mobile` |
| `r_default` | lan | 任意 | — | — | `balanced` |

> **为什么游戏/远程走 mobile 而不是电信？**
> 电信线是光猫路由 + 路由器 DHCP = **双重 NAT**，NAT 类型会降级成 Restricted/Symmetric，
> 联机匹配困难、端口转发需在光猫上再配一次。
> 移动线是光猫桥接 + 路由器 PPPoE = **单层 NAT**，出口干净。
> 300M 带宽对游戏绰绰有余。

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
