#!/usr/bin/env bash
# =============================================================================
# scripts/lib/stamp.sh — 构建时间戳与固件路径解析（被其它脚本 source）
# -----------------------------------------------------------------------------
# 这个文件**只放函数**，不放可执行逻辑（不要直接运行它）。
#
# ⚠️ 为什么单独抽出来：时间戳和「找 sysupgrade 镜像」这两件事
#    被 4 个地方需要（gen-config.sh / stamp-firmware.sh /
#    size-guard.sh / verify-firmware.sh），而它们必须**算出同一个值**。
#    各自复制一份 = 迟早漂移（本项目的老教训：清单一复制就会对不上）。
# =============================================================================

# -----------------------------------------------------------------------------
# bj_stamp — 北京时间戳，格式 20261004.0031
# -----------------------------------------------------------------------------
# ⚠️ GitHub runner 是 UTC，设备时区是 CST-8，但**两者都不能假设**：
#    这里的值是在**构建机上算一次然后烧进固件**的，不是开机时再算，
#    所以设备时区设成什么都无所谓，也不会出现「重启后版本变了」。
#
#    两条路都留着：优先 `date -u -d '+8 hours'`（不依赖 tzdata），
#    失败再退回 TZ=Asia/Shanghai。两条都失败返回空，由调用方决定怎么办。
bj_stamp() {
	local s=""
	# GNU date：纯算术偏移，不依赖时区数据库
	s="$(date -u -d '+8 hours' +%Y%m%d.%H%M 2>/dev/null)" || s=""
	if [ -z "$s" ]; then
		# BSD/其它 date
		s="$(TZ=Asia/Shanghai date +%Y%m%d.%H%M 2>/dev/null)" || s=""
	fi
	if [ -z "$s" ]; then
		# 最后兜底：手工从 UTC 数字算（date 有 %s 就够了）
		s="$(date -u +%Y%m%d.%H%M 2>/dev/null)" || s=""
	fi
	printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# bj_stamp_readable — 人读的北京时间，格式 "2026-10-04 00:31 CST"
# -----------------------------------------------------------------------------
# 只进 config.buildinfo 和日志，不进版本串（版本串不要空格，见 README 注释）。
bj_stamp_readable() {
	local s
	s="$(date -u -d '+8 hours' '+%Y-%m-%d %H:%M CST' 2>/dev/null)" || s=""
	if [ -z "$s" ]; then
		s="$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M CST' 2>/dev/null)" || s=""
	fi
	printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# build_revision — 取 OpenWrt 的 REVISION（形如 r1-9b95be917b）
# -----------------------------------------------------------------------------
# ⚠️ 必须**调用 OpenWrt 自己的 scripts/getver.sh**，不能自己写一套 git describe。
#    getver.sh 的逻辑很特殊：先数 ee53a240..HEAD 的提交数当 r<N>，
#    再拼上游分歧点的短 hash。手写十有八九对不上，
#    而版本串里 hash 对不上比没有 hash 更糟 —— 看起来像真的，其实是假的。
#    溯源：include/toplevel.mk:16 `REVISION:=$(shell $(TOPDIR)/scripts/getver.sh)`
#
# ⚠️⚠️ 调用前提：**OpenWrt 源码树必须已经 clone 出来**。
#    Run #20 就栽在这：生成时间戳的步骤排在「拉取 feeds」之前，
#    那时候 $OPENWRT_SRC 还不存在，getver.sh 跑不了，
#    版本串变成了毫无信息量的 "unknown-20261004.0041"。
#    所以这个步骤必须排在 gen-feeds.sh 之后。
build_revision() { # $1=openwrt 源码目录
	local src="${1:?缺少 openwrt 源码目录}"
	local rev=""
	if [ -f "$src/scripts/getver.sh" ]; then
		rev="$(cd "$src" && TOPDIR="$src" sh "$src/scripts/getver.sh" 2>/dev/null | head -1)" || rev=""
	fi
	# ⚠️ 不要直接回退成 "unknown"：那是个看起来合法的字符串，
	#    会安静地混进版本串（OpenWrt 自己就把它当合法 REVISION 用）。
	#    拿不到就用短 hash，好歹还能溯源，而且一眼看得出不是 getver.sh 的结果。
	if [ -z "$rev" ] || [ "$rev" = "unknown" ]; then
		if [ -d "$src/.git" ]; then
			rev="git-$(cd "$src" && git rev-parse --short HEAD 2>/dev/null | head -1)"
		fi
		[ -n "$rev" ] || rev=""
		echo "⚠️ 取不到 OpenWrt 官方 REVISION（getver.sh 没跑成）" >&2
		echo "   源码树: $src" >&2
		if [ -n "$rev" ]; then
			echo "   退回用短 hash: $rev（溯源够用，但格式和 r1-xxx 不同）" >&2
		else
			echo "   连短 hash 都拿不到，版本串将只剩时间戳" >&2
		fi
	fi
	printf '%s' "$rev"
}

# -----------------------------------------------------------------------------
# build_version — 完整版本标识，形如 r1-9b95be917b-20261004.0031
# -----------------------------------------------------------------------------
# 这个值会写进 CONFIG_VERSION_CODE，最终出现在
#   /etc/openwrt_release 的 DISTRIB_DESCRIPTION（LuCI 系统页显示的就是它）
#   /etc/openwrt_version
# 格式约束：**只能用 [0-9a-z.-]**，不能有空格、括号、斜杠 ——
#   这两个文件都有下游 shell 在读，带空格会被拆成两个参数。
build_version() { # $1=openwrt 源码目录  $2=时间戳
	local rev="$1" stamp="$2"
	printf '%s-%s' "$rev" "$stamp"
}

# -----------------------------------------------------------------------------
# find_sysupgrade_bin — 定位 sysupgrade 镜像，**带不带时间戳都找得到**
# -----------------------------------------------------------------------------
# ⚠️ 这是加时间戳后最容易翻车的地方。
#    原先 4 个脚本都硬编码了
#      openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.bin
#    一旦文件名后面多了 -20261004，这 4 处会同时「文件不存在」，
#    而体积守卫和内容抽查都会静默跳过检查 —— 固件出问题都没人发现。
#    所以统一走这个解析函数：带时间戳的优先，退回旧的，最后兜底匹配任意 sysupgrade。
find_sysupgrade_bin() { # $1=bin/targets/mediatek/filogic 目录
	local d="${1:?缺少固件输出目录}"
	local base="openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade"
	local f
	# 1. 带时间戳的（-YYYYMMDD.HHMM.bin）
	f="$(ls -1 "$d/$base"-*.bin 2>/dev/null | head -1)"
	[ -n "$f" ] && { printf '%s' "$f"; return 0; }
	# 2. 不带时间戳的（旧命名，向后兼容）
	f="$d/$base.bin"
	[ -f "$f" ] && { printf '%s' "$f"; return 0; }
	# 3. 兜底：目录里任意一个 sysupgrade 镜像
	f="$(ls -1 "$d"/*sysupgrade*.bin 2>/dev/null | head -1)"
	[ -n "$f" ] && { printf '%s' "$f"; return 0; }
	return 1
}

# -----------------------------------------------------------------------------
# find_firmware_bins — 列出该目录下所有镜像（供 artifact / 校验和用）
# -----------------------------------------------------------------------------
find_firmware_bins() { # $1=固件输出目录
	local d="${1:?缺少固件输出目录}"
	ls -1 "$d"/*.bin "$d"/*.itb 2>/dev/null | sort
}
