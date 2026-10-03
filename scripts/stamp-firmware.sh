#!/usr/bin/env bash
# =============================================================================
# stamp-firmware.sh — 给固件文件名追加构建时间戳
# -----------------------------------------------------------------------------
# 用法： ./scripts/stamp-firmware.sh [openwrt源码目录] [时间戳]
#
# 做的是 **rename**，不是复制 —— 复制会同时留下新旧两个文件，
# artifact 里就会有两个同内容不同名的 .bin。
#
# ⚠️⚠️ 为什么不用 OpenWrt 自带的能力：
#    include/image.mk:49
#      IMG_PREFIX_VERCODE:=$(if $(CONFIG_VERSION_CODE_FILENAMES),
#                              $(call sanitize,$(VERSION_CODE))-)
#    它产生的是**前缀**：
#      r1-9b95be917b-20261004.0031-openwrt-...-sysupgrade.bin
#    而我们要的是后缀
#      openwrt-...-sysupgrade-sysupgrade-20261004.0031.bin ← 形态更符合直觉
#    所以这里自己改名，并且**必须把 CONFIG_VERSION_CODE_FILENAMES 钉死为 n**
#    （它的 Kconfig 默认是 y，不钉死会前缀后缀一起来，变成两头都有日期）。
#
#    改名不影响刷机：sysupgrade 流程只认镜像里的 supported_devices 字段，
#    不看文件名。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/stamp.sh
. "$ROOT/scripts/lib/stamp.sh"

SRC="${1:-$ROOT/openwrt}"
STAMP="${2:-${TENDA_BUILD_STAMP:-}}"
BIN="$SRC/bin/targets/mediatek/filogic"

GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
ok()   { echo "${GRN}✅${RST} $*"; }
warn() { echo "${YEL}⚠️ ${RST}$*"; }
die()  { echo "${RED}❌${RST} $*" >&2; exit 1; }

[ -n "$STAMP" ] || die "没有时间戳（传第二个参数，或设 TENDA_BUILD_STAMP）"
case "$STAMP" in
	[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9][0-9]) : ;;
	*) die "时间戳格式不对: $STAMP（期望 YYYYMMDD.HHMM）" ;;
esac
[ -d "$BIN" ] || die "找不到固件输出目录: $BIN"

echo "▸ 给固件文件名追加时间戳 $STAMP"

# 已经打过戳的跳过（幂等：重跑 CI 的后置步骤不会变成 xxx-20261004.0031-20261004.0031.bin）
n=0
for f in "$BIN"/*.bin "$BIN"/*.itb; do
	[ -e "$f" ] || continue
	base="$(basename "$f")"
	case "$base" in
		*"-$STAMP".*|*-"$STAMP")  ok "$base 已带时间戳，跳过"; continue ;;
	esac
	# 在扩展名前插入 -<stamp>
	newname="$base"
	case "$base" in
		*.bin) newname="${base%.bin}-$STAMP.bin" ;;
		*.itb) newname="${base%.itb}-$STAMP.itb" ;;
		*)     continue ;;
	esac
	[ -e "$BIN/$newname" ] && { ok "$newname 已存在，跳过"; continue; }
	mv -f "$f" "$BIN/$newname"
	echo "  $base  →  $newname"
	n=$((n+1))
done

[ "$n" -gt 0 ] && ok "改名 $n 个文件" || warn "没有文件被改名"

# ---- 回读校验：改名之后必须还找得到 sysupgrade 镜像 ------------------------
# ⚠️ 这一步不能省。「mv 返回 0」不代表后续脚本还找得到文件 ——
#    4 个脚本（build.sh / size-guard.sh / verify-firmware.sh / CI 的 release）
#    都要定位这个镜像，这里当场验一次，比刷机时才发现强得多。
echo
if img="$(find_sysupgrade_bin "$BIN")"; then
	ok "sysupgrade 镜像: $(basename "$img")"
	sz="$(wc -c < "$img" | tr -d ' ')"
	echo "  大小: $((sz / 1024 / 1024)) MB"
	case "$(basename "$img")" in
		*"-$STAMP.bin") ok "文件名确实带上了时间戳" ;;
		*) warn "镜像文件名里没有时间戳：$(basename "$img")" ;;
	esac
else
	die "改名后反而找不到 sysupgrade 镜像了 —— 固件这轮是坏的"
fi

echo
echo "${GRN}当前目录下的镜像：${RST}"
find_firmware_bins "$BIN" | sed 's|.*/|  |'
