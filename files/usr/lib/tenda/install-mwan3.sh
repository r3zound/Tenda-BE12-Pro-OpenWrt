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
#    sh /usr/lib/tenda/install-mwan3.sh              # 安装
#    sh /usr/lib/tenda/install-mwan3.sh --status     # 只看状态
#    sh /usr/lib/tenda/install-mwan3.sh --uninstall  # 卸载
#    sh /usr/lib/tenda/install-mwan3.sh --diag       # 生成诊断报告
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
	cat <<'EOF'

下一步：在 LuCI 中「网络 → MultiWAN Manager」按 README §5.5 配置
      接口 / 成员 / 策略 / 规则（权重 3:1）

⚠️ 重要：每次 sysupgrade 升级固件后，需重新运行本脚本。
        原因见本文件头部说明。
EOF
}

case "${1:-install}" in
	--status)   show_status ;;
	--uninstall) uninstall ;;
	--diag)     diag ;;
	--help|-h)
		sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
		;;
	*)          install ;;
esac
