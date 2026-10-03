#!/bin/sh
# =============================================================================
# /usr/lib/tenda/install-mwan3.sh
# -----------------------------------------------------------------------------
# 安装 mwan3 原生 nftables 移植版（刷机后执行）
#
# ⚠️ 为什么不用官方 mwan3？
#    1. 官方 mwan3 是 iptables 实现，OpenWrt 22.03+ 用 fw4/nftables，
#       社区实测 25.12+ 上 balanced 策略只走第一个节点，其余被忽略。
#    2. dl12345 的移植版使用独立的 `table inet mwan3`，与 fw4 完全解耦。
#    3. 官方文档明确警告：任何包含 mwan3 的 sysupgrade 都会静默装回
#       iptables 版本，覆盖你的多 WAN 行为。**所以刻意不打进固件镜像。**
#
# 用法：
#    sh /usr/lib/tenda/install-mwan3.sh              # 安装 + 自动生成配置
#    sh /usr/lib/tenda/install-mwan3.sh --config     # 只重写 /etc/config/mwan3（先备份）
#    sh /usr/lib/tenda/install-mwan3.sh --check      # 负载均衡体检（卸载/版本/段名/分流）
#    sh /usr/lib/tenda/install-mwan3.sh --status     # 只看状态
#    sh /usr/lib/tenda/install-mwan3.sh --uninstall  # 卸载
#    sh /usr/lib/tenda/install-mwan3.sh --diag       # 生成诊断报告
#
# 可用环境变量（改接口名/权重，不必改脚本）：
#    WAN_A=wan  WAN_B=wan2  WAN_A_WEIGHT=3  WAN_B_WEIGHT=1  TRACK_IPS="223.5.5.5 ..."
# =============================================================================

MWAN_REPO="${MWAN_REPO:-dl12345/mwan3}"
LUCI_REPO="${LUCI_REPO:-dl12345/luci-app-mwan3}"
OPENWRT_VER="${OPENWRT_VER:-25.12}"     # SNAPSHOT 资产标注为 openwrt-25.12

RED=''; GRN=''; YEL=''; RST=''
if [ -t 1 ]; then
	RED=$(printf '\033[31m'); GRN=$(printf '\033[32m')
	YEL=$(printf '\033[33m'); RST=$(printf '\033[0m')
fi

die()  { echo "${RED}❌ $*${RST}" >&2; exit 1; }
warn() { echo "${YEL}⚠️  $*${RST}"; }
ok()   { echo "${GRN}✅ $*${RST}"; }

ARCH="$(uname -m)"
case "$ARCH" in
	aarch64) FULL_ARCH="aarch64_cortex-a53" ;;
	armv7l)  FULL_ARCH="arm_cortex-a7_neon-vfpv4" ;;
	x86_64)  FULL_ARCH="x86_64" ;;
	*)       FULL_ARCH="$ARCH" ;;
esac

# -----------------------------------------------------------------------------
# 判断当前装的是哪个版本
# -----------------------------------------------------------------------------
detect_build() {
	if ! command -v mwan3 >/dev/null 2>&1; then
		echo "none"
		return
	fi
	# 原生 nft 移植版会额外带 mwan3ct 和 mwan3-diag
	if [ -x /usr/sbin/mwan3ct ] || [ -x /usr/sbin/mwan3-diag ]; then
		echo "nft"
	elif [ -x /usr/sbin/mwan3rtmon ] && [ -x /usr/sbin/mwan3track ]; then
		echo "iptables"
	else
		echo "unknown"
	fi
}

show_status() {
	local build
	build="$(detect_build)"
	echo "当前架构      : $FULL_ARCH"
	echo "当前 OpenWrt   : $(. /etc/openwrt_release 2>/dev/null && echo "${DISTRIB_RELEASE:-?}")"
	echo "防火墙         : $(command -v fw4 >/dev/null && echo 'fw4/nftables' || echo 'fw3/iptables')"
	echo "mwan3 构建版本 : $build"
	case "$build" in
		nft)        ok "当前为原生 nft 移植版（正确）" ;;
		iptables)   warn "当前为官方 iptables 版，在 fw4 上负载均衡会失效，建议重装" ;;
		none)       warn "未安装 mwan3" ;;
		*)          warn "无法识别构建版本" ;;
	esac
	echo
	echo "已安装的命令："
	ls -1 /usr/sbin/mwan3* 2>/dev/null | sed 's/^/  /' || echo "  (无)"
}

uninstall() {
	apk del mwan3 luci-app-mwan3 2>/dev/null || true
	rm -f /etc/config/mwan3
	ok "mwan3 已卸载"
}

diag() {
	if command -v mwan3-diag >/dev/null 2>&1; then
		mwan3-diag
	else
		warn "未安装 mwan3-diag（原生 nft 移植版才有此工具）"
		echo "可粘贴以下内容到 OpenWrt 论坛："
		show_status
		mwan3 status 2>&1 || true
	fi
}

# -----------------------------------------------------------------------------
# 生成 /etc/config/mwan3
# -----------------------------------------------------------------------------
# 为什么需要自动生成：以前这里只有一份手写模板（mwan3-README.md），
# 安装完还要自己去 LuCI 点一遍，权重 3:1、策略、规则全靠人记。
# 实机跑通的配置见 SNAPSHOT固件配置教程/1-setup-wan.sh，这里把它固化下来。
#
# ⚠️ 三条硬约束（都是踩过的）：
#   1. 段名/策略名 **≤ 15 字符**，超长 mwan3 会静默跳过，没有任何报错。
#   2. 必须配 `option src_zone 'lan'`，否则规则会匹配到路由器自身发起的流量。
#   3. HTTPS(443) 开 sticky —— 会话粘在一条线上，否则大流量会被拆到两条 WAN，
#      服务器侧看到的是同一个 IP 时断时续。
WAN_A="${WAN_A:-wan}"        # 电信 1000M，eth2，光猫 DHCP
WAN_B="${WAN_B:-wan2}"       # 移动 300M，lan3，PPPoE
WAN_A_WEIGHT="${WAN_A_WEIGHT:-3}"
WAN_B_WEIGHT="${WAN_B_WEIGHT:-1}"
TRACK_IPS="${TRACK_IPS:-223.5.5.5 119.29.29.29}"
MWAN_CFG="/etc/config/mwan3"

write_config() {
	local stamp tracks
	stamp="$(date +%Y%m%d-%H%M%S)"

	if [ -f "$MWAN_CFG" ]; then
		cp "$MWAN_CFG" "$MWAN_CFG.bak-$stamp"
		ok "原配置已备份到 $MWAN_CFG.bak-$stamp"
	fi

	tracks=""
	local ip
	for ip in $TRACK_IPS; do tracks="$tracks	list track_ip '$ip'
"; done

	# 无引号 heredoc：$WAN_A/$WAN_B/权重需要展开。
	# ⚠️ 此块内**禁用反引号**（会触发命令替换），且所有字面 $ 都要写 \$。
	cat > "$MWAN_CFG" <<MWAN3CFG
package mwan3

# 由 /usr/lib/tenda/install-mwan3.sh 自动生成，$stamp
# 接口名可通过环境变量覆盖：WAN_A= wan= WAN_B= wan2= WAN_A_WEIGHT= WAN_B_WEIGHT=
# ⚠️ mwan3 会静默跳过长度 > 15 字符的段名，改名后请用 --check 复查。

# ---- Interfaces ----
config interface '$WAN_A'
	option enabled '1'
$tracks	option family 'ipv4'
	option reliability '1'
	option count '1'
	option timeout '2'
	option interval '5'
	option down '3'
	option up '3'
	option size '56'
	option max_ttl '60'
	option check_quality '0'

config interface '$WAN_B'
	option enabled '1'
$tracks	option family 'ipv4'
	option reliability '1'
	option count '1'
	option timeout '2'
	option interval '5'
	option down '3'
	option up '3'
	option size '56'
	option max_ttl '60'
	option check_quality '0'

# ---- Members（权重按带宽比：电信 1000M : 移动 300M ≈ 3:1）----
config member 'wan_m1_w$WAN_A_WEIGHT'
	option interface '$WAN_A'
	option metric '1'
	option weight '$WAN_A_WEIGHT'

config member 'wan2_m2_w$WAN_B_WEIGHT'
	option interface '$WAN_B'
	option metric '2'
	option weight '$WAN_B_WEIGHT'

# ---- Policies ----
config policy 'balanced'
	list use_member 'wan_m1_w$WAN_A_WEIGHT'
	list use_member 'wan2_m2_w$WAN_B_WEIGHT'
	option last_resort 'default'

# mobile：移动线是 PPPoE 单层 NAT，NAT 类型干净，给游戏/远程/P2P 用
config policy 'mobile'
	list use_member 'wan2_m2_w$WAN_B_WEIGHT'
	option last_resort 'default'

config policy 'telecom'
	list use_member 'wan_m1_w$WAN_A_WEIGHT'
	option last_resort 'default'

config policy 'failover'
	list use_member 'wan_m1_w$WAN_A_WEIGHT'
	list use_member 'wan2_m2_w$WAN_B_WEIGHT'
	option last_resort 'unreachable'

# ---- Rules（顺序即优先级，从上到下）----
config rule 'r_gaming'
	option src_zone 'lan'
	option proto 'udp'
	option dest_port '27015:27030,5000:5010,25565:25575'
	option use_policy 'mobile'

config rule 'r_remote'
	option src_zone 'lan'
	option proto 'tcp'
	option dest_port '22,3389,5900,32400'
	option use_policy 'mobile'

# HTTPS 会话粘性：同一连接不跨线路
config rule 'r_https'
	option src_zone 'lan'
	option proto 'tcp'
	option dest_port '443'
	option sticky '1'
	option use_policy 'balanced'

config rule 'r_default'
	option src_zone 'lan'
	option dest_ip '0.0.0.0/0'
	option use_policy 'balanced'
MWAN3CFG

	[ -s "$MWAN_CFG" ] || die "生成 $MWAN_CFG 失败（文件为空）"
	ok "已生成 $MWAN_CFG（权重 $WAN_A_WEIGHT : $WAN_B_WEIGHT）"

	# 回读校验：写文件成功不等于 mwan3 认（坑 9/10/11/12 同一个教训）
	local np
	np="$(grep -c "^config " "$MWAN_CFG" 2>/dev/null || echo 0)"
	if [ "$np" -ge 10 ]; then
		ok "回读校验通过：$np 个 config 段"
	else
		warn "只解析出 $np 个段，期望 >= 10，请检查 $MWAN_CFG"
	fi

	if [ -x /etc/init.d/mwan3 ]; then
		/etc/init.d/mwan3 restart >/dev/null 2>&1 || warn "mwan3 重启失败，可手动 /etc/init.d/mwan3 restart"
		sleep 3
	fi
}

# -----------------------------------------------------------------------------
# 负载均衡体检
# -----------------------------------------------------------------------------
# 从 ubus 取接口的出口设备名。
# ⚠️ 不能靠字符串拼：wan2 是 PPPoE，netifd 会把真实出口命名成 pppoe-wan2，
#    直接拿 $WAN_B 去 /sys/class/net 找会找不到。
dev_of() {
	local iface="$1" dev
	dev="$(ubus call "network.interface.$iface" status 2>/dev/null \
		| jsonfilter -e '@.l3_device' 2>/dev/null)"
	[ -n "$dev" ] && [ "$dev" != "null" ] && { echo "$dev"; return 0; }
	# 兜底：dhcp/static 接口的 l3_device 有时为空，取 device
	dev="$(ubus call "network.interface.$iface" status 2>/dev/null \
		| jsonfilter -e '@.device' 2>/dev/null)"
	[ -n "$dev" ] && [ "$dev" != "null" ] && { echo "$dev"; return 0; }
	echo "$iface"
}

# 三个静默失效点，逐条查：
#   1. 防火墙流量卸载开着 → mwan3 打标被绕过 → 均衡策略形同虚设
#   2. mwan3 是官方 iptables 版 → balanced 只走第一个节点
#   3. 配置里段名超 15 字符 → 被静默跳过
check_balance() {
	local bad=0

	echo "1) 流量卸载（必须关闭）"
	local fo foh
	fo="$(uci -q get firewall.@defaults[0].flow_offloading || echo 1)"
	foh="$(uci -q get firewall.@defaults[0].flow_offloading_hw || echo 1)"
	if [ "$fo" = "0" ] && [ "$foh" = "0" ]; then
		ok "配置已关闭（flow_offloading=$fo / hw=$foh）"
	else
		warn "配置未关闭（flow_offloading=$fo / hw=$foh）—— 均衡会失效"
		bad=1
	fi
	if nft list table inet fw4 2>/dev/null | grep -qi flowtable; then
		warn "运行时仍存在 flowtable —— 卸载没真正关掉"
		bad=1
	else
		ok "运行时无 flowtable，确认卸载已关闭"
	fi

	echo
	echo "2) mwan3 构建版本（必须是 nft 移植版）"
	local build; build="$(detect_build)"
	case "$build" in
		nft) ok "nft 移植版" ;;
		iptables) warn "官方 iptables 版 —— balanced 只会走第一个节点，请重装"; bad=1 ;;
		none) warn "未安装"; bad=1 ;;
		*) warn "无法识别"; bad=1 ;;
	esac

	echo
	echo "3) 段名长度（> 15 字符会被静默跳过）"
	if [ -f "$MWAN_CFG" ]; then
		local long
		long="$(sed -n "s/^config [a-z]* '\(.*\)'$/\1/p" "$MWAN_CFG" | awk 'length($0)>15' | tr '\n' ' ')"
		if [ -n "$long" ]; then
			warn "以下段名超过 15 字符，会被静默跳过：$long"
			bad=1
		else
			ok "所有段名都在 15 字符以内"
		fi
	else
		warn "$MWAN_CFG 不存在，请先执行 --config"
		bad=1
	fi

	echo
	echo "4) 分流实测（20 秒样本，流量大时才有意义）"
	# 出口设备名不能靠字符串拼：wan2 是 PPPoE，netifd 把它命名成 pppoe-wan2。
	# 统一从 ubus 拿 l3_device，拿不到再退回 /sys/class/net/<接口名>。
	local da db
	da="$(dev_of "$WAN_A")"; db="$(dev_of "$WAN_B")"
	echo "  出口设备: $WAN_A=$da  $WAN_B=$db"
	if [ -z "$da" ] || [ -z "$db" ] || [ ! -d "/sys/class/net/$da" ] || [ ! -d "/sys/class/net/$db" ]; then
		warn "拿不到出口设备，跳过分流实测（两条 WAN 可能还没都拨通）"
		return $bad
	fi
	local a0 b0 a1 b1 dA dB tot
	a0="$(cat /sys/class/net/$da/statistics/tx_bytes 2>/dev/null || echo 0)"
	b0="$(cat /sys/class/net/$db/statistics/tx_bytes 2>/dev/null || echo 0)"
	sleep 20
	a1="$(cat /sys/class/net/$da/statistics/tx_bytes 2>/dev/null || echo 0)"
	b1="$(cat /sys/class/net/$db/statistics/tx_bytes 2>/dev/null || echo 0)"
	dA=$((a1-a0)); dB=$((b1-b0)); tot=$((dA+dB))
	echo "  $WAN_A +$((dA/1024)) KB / $WAN_B +$((dB/1024)) KB"

	# ⚠️ 关键判据：路由器**自身**发出的流量走 main 表，不经过 mwan3 打标链
	#    （规则是 src_zone 'lan'，只管 LAN 客户端）。所以「wan2 没流量」本身
	#    不能判为失败 —— 必须先确认**有没有 LAN 流量进过 mwan3 链**。
	#    早先版本不看这个计数器，把「采样窗口没人下载」一律报成故障，误报。
	local pkts
	pkts="$(nft list chain inet mwan3 mwan3_policy_balanced 2>/dev/null \
		| sed -n 's/.*packets \([0-9]\+\).*/\1/p' | head -1)"
	[ -n "$pkts" ] || pkts=0
	if [ "$pkts" -eq 0 ]; then
		warn "mwan3 打标链计数为 0 —— 采样窗口内没有任何 LAN 流量，分流比例测不出来（不是故障）"
		echo "     等 LAN 设备下载时再跑一次本命令"
		return $bad
	fi
	ok "mwan3 打标链已处理 $pkts 个包（LAN 流量确实进来了）"

	if [ "$dB" -lt 20000 ]; then
		warn "$WAN_B 上几乎没有流量，但 mwan3 链是有流量的 —— 打标或策略可能没生效"
		bad=1
	else
		echo "  比例 ≈ $((dA*100/tot))% : $((dB*100/tot))%（权重 $WAN_A_WEIGHT:$WAN_B_WEIGHT）"
		ok "两条线都在跑流量"
	fi

	echo
	[ "$bad" -eq 0 ] && ok "负载均衡体检通过" || warn "体检发现 $bad 处问题，见上方 ⚠️"
	return $bad
}

install() {
	local build
	build="$(detect_build)"
	if [ "$build" = "nft" ]; then
		ok "mwan3 原生 nft 版已安装，无需重复安装"
		return 0
	fi
	if [ "$build" = "iptables" ]; then
		warn "检测到官方 iptables 版，先卸载…"
		apk del mwan3 2>/dev/null || true
	fi

	command -v apk >/dev/null 2>&1 || die "未找到 apk（OpenWrt 25.12+ 包管理器）"

	ok "架构: $FULL_ARCH"

	# ---------------------------------------------------------------------------
	# 下载地址**不再用字符串拼**，改成读 release 的 assets 列表按名挑。
	#
	# ⚠️ 为什么（这个坑踩过）：原先按 "${ver}-1_openwrt-${VER}_${ARCH}.apk" 拼，
	#    实测返回 **HTTP 404** —— release tag 是 v3.6.12-1，末尾那个 `-1` 是
	#    发布序号，已经含在包版本里了，脚本又多拼了一个。
	#    而且两个仓库的命名规则还不一样：
	#      mwan3 → mwan3-3.6.12-1_openwrt-25.12_aarch64_cortex-a53.apk  （带 -1）
	#      luci  → luci-app-mwan3_26.999.3.6.12.apk                      （不带 -1）
	#    靠字符串推导，上游下次改名又会坏。直接读 assets 列表一劳永逸。
	# ---------------------------------------------------------------------------
	fetch_release() {
		# ⚠️ OpenWrt 的 wget 是 uclient-fetch 的软链，**只认 -O（大写）**，
		#    没有 -o（小写）选项，写了小写会直接报 "unrecognized option: o" 并
		#    什么都不下载 —— 看起来像"GitHub 不通"，其实是参数写错了。
		wget -q -O "$RELTMP" "https://api.github.com/repos/$1/releases/latest" 2>/dev/null || return 1
		[ -s "$RELTMP" ]
	}

	# $1=json 文件  $2=asset 名的 shell glob → 打印 browser_download_url
	pick_asset() {
		local f="$1" pat="$2" i=0 idx="" n
		for n in $(jsonfilter -e '@.assets[*].name' -i "$f" 2>/dev/null); do
			# shellcheck disable=SC2254
			case "$n" in $pat) idx=$i; break ;; esac
			i=$((i+1))
		done
		[ -n "$idx" ] || return 1
		jsonfilter -e "@.assets[$idx].browser_download_url" -i "$f" 2>/dev/null
	}

	RELTMP="/tmp/.mwan3-rel-$$.json"
	trap 'rm -f "$RELTMP"' EXIT

	command -v jsonfilter >/dev/null 2>&1 \
		|| die "未找到 jsonfilter（base-files 提供），无法解析 release 资源列表"

	echo "▸ 查询 $MWAN_REPO 最新版本…"
	fetch_release "$MWAN_REPO" || die "无法获取 $MWAN_REPO 的 release（GitHub 不通？）"
	local tag mwan_url
	tag="$(jsonfilter -e '@.tag_name' -i "$RELTMP" 2>/dev/null)"
	[ -n "$tag" ] || die "解析 $MWAN_REPO 的 tag_name 失败"
	ok "最新版本: $tag"

	mwan_url="$(pick_asset "$RELTMP" "mwan3-*_${FULL_ARCH}.apk")" \
		|| mwan_url=""
	if [ -z "$mwan_url" ]; then
		warn "在 $MWAN_REPO $tag 里没找到 ${FULL_ARCH} 的包。可用资源："
		jsonfilter -e '@.assets[*].name' -i "$RELTMP" 2>/dev/null | sed 's/^/    /'
		die "无法继续"
	fi

	cd /tmp || die "无法进入 /tmp"
	echo "▸ 下载 mwan3…"
	echo "  ${mwan_url##*/}"
	wget -q -O mwan3.apk "$mwan_url" \
		|| die "下载失败: $mwan_url"

	# LuCI 界面（架构无关）
	local luci_tag luci_url=""
	if fetch_release "$LUCI_REPO"; then
		luci_tag="$(jsonfilter -e '@.tag_name' -i "$RELTMP" 2>/dev/null)"
		luci_url="$(pick_asset "$RELTMP" 'luci-app-mwan3*.apk')" || luci_url=""
	fi
	if [ -n "$luci_url" ]; then
		echo "▸ 下载 LuCI 界面…"
		echo "  ${luci_url##*/}"
		if wget -q -O luci-app-mwan3.apk "$luci_url"; then
			:
		else
			rm -f luci-app-mwan3.apk; luci_url=""
			warn "LuCI 包下载失败，将只安装核心（可用 SSH 配置）"
		fi
	else
		luci_url=""
		warn "未在 $LUCI_REPO 找到 LuCI 包，将只安装核心（可用 SSH 配置）"
	fi

	# 安装（包未签名，需 --allow-untrusted）
	echo "▸ 安装…"
	# shellcheck disable=SC2086
	apk add --allow-untrusted /tmp/mwan3.apk ${luci_url:+/tmp/luci-app-mwan3.apk} \
		|| die "安装失败"

	rm -f /tmp/mwan3.apk /tmp/luci-app-mwan3.apk
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/uhttpd restart 2>/dev/null || true

	ok "安装完成"
	echo
	show_status

	# 装完立刻写配置：以前这里只让用户「自己去 LuCI 点一遍」，
	# 权重 3:1 / 策略 / 规则全靠人记，实机上极易漏配。
	echo
	echo "▸ 生成 mwan3 配置…"
	write_config
	echo
	cat <<'EOF'

────────────────────────────────────────────────
 安装完成。配置已自动写入 /etc/config/mwan3
   Interfaces  wan(电信 eth2) / wan2(移动 lan3 PPPoE)
   Members     权重 3:1   Members   wan:1  wan2:2
   Policies    balanced(默认) / mobile / telecom / failover
   Rules       游戏、远程 → mobile；HTTPS 443 sticky → balanced

 常用命令：
   sh /usr/lib/tenda/install-mwan3.sh --check     负载均衡体检
   sh /usr/lib/tenda/install-mwan3.sh --status    看状态
   sh /usr/lib/tenda/install-mwan3.sh --config    重写配置（会先备份）

 ⚠️ 每次 sysupgrade 后需重跑本脚本（原因见文件头）。
 ⚠️ PPPoE 凭据刷机后要在 LuCI 填：
      uci set network.wan2.username='账号'
      uci set network.wan2.password='密码'
      uci commit network && reload_config
    （必须 reload_config，不能用 network restart，见 README §8）
────────────────────────────────────────────────
EOF
}

case "${1:-install}" in
	--status)   show_status ;;
	--config)   write_config ;;
	--check)    check_balance ;;
	--uninstall) uninstall ;;
	--diag)     diag ;;
	--help|-h)
		sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
		;;
	*)          install ;;
esac
