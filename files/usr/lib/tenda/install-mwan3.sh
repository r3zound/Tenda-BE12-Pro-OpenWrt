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

	# 查询最新 release
	echo "▸ 查询 $MWAN_REPO 最新版本…"
	local tag
	tag="$(wget -qO- "https://api.github.com/repos/$MWAN_REPO/releases/latest" 2>/dev/null \
		| grep -oE '"tag_name": *"[^"]+"' | head -1 | sed 's/.*"\(v[^"]*\)"/\1/')"
	[ -n "$tag" ] || die "无法获取最新版本号（网络问题？）"
	ok "最新版本: $tag"

	# 下载
	local ver="${tag#v}"
	local ver_luci="$ver"
	local mwan_url="https://github.com/$MWAN_REPO/releases/download/${tag}/mwan3-${ver}-1_openwrt-${OPENWRT_VER}_${FULL_ARCH}.apk"

	cd /tmp || die "无法进入 /tmp"
	echo "▸ 下载 mwan3…"
	wget -q --show-progress -O mwan3.apk "$mwan_url" \
		|| die "下载失败: $mwan_url"

	# LuCI 界面（架构无关）
	local luci_tag luci_url
	luci_tag="$(wget -qO- "https://api.github.com/repos/$LUCI_REPO/releases/latest" 2>/dev/null \
		| grep -oE '"tag_name": *"[^"]+"' | head -1 | sed 's/.*"\(v[^"]*\)"/\1/')"
	if [ -n "$luci_tag" ]; then
		local luci_ver="${luci_tag#v}"
		luci_url="https://github.com/$LUCI_REPO/releases/download/${luci_tag}/luci-app-mwan3_26.999.${luci_ver}.apk"
		echo "▸ 下载 LuCI 界面…"
		wget -q --show-progress -O luci-app-mwan3.apk "$luci_url" \
			&& echo "  LuCI 包版本: ${luci_ver}" \
			|| warn "LuCI 包下载失败，将只安装核心（可用 SSH 配置）"
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
