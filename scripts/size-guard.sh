#!/usr/bin/env bash
# =============================================================================
# size-guard.sh — 固件体积守卫
# -----------------------------------------------------------------------------
# ## 先说清楚「该量什么」
#
# 本机 UBI 分区总计 90 MB（0xd80000–0x6780000），它被切成：
#
#   rootfs        ← squashfs 镜像，**只读**，是固件本体
#   rootfs_data   ← overlay，后续装插件/存配置都吃这块
#
# 90MB 里真正会「涨」的是 overlay，不是 rootfs。所以预算要拆成两段看：
#
#   ① rootfs（squashfs 镜像大小）—— 编译出来就固定了
#      决定 90MB 里还剩多少给 overlay。这是要设红线的那个数。
#   ② 展开体积（apparent size）—— 只是参考，说明基础系统摊开多大
#      它不等于占用分区，压缩比通常 3~4 倍。
#
# 早期版本把「展开体积」当红线，是个概念错误：展开 29MB 不代表要占 29MB。
#
# ## 历史教训（三次踩坑）
#
#   v1: `tar -tzvf | awk '$NF ~ /^rootfs\//'` —— sysupgrade.bin 内部是
#       sysupgrade-<board>/{CONTROL,kernel,root}，根本没有 rootfs/ 前缀，
#       永远匹配不到 → 变量恒为 0 → **守卫从未执行过**，却一直显示"通过"。
#
#   v2: 改成按文件名 root 定位，量 tar 成员 size —— 量到的是压缩后大小，
#       概念仍不对（拿 rootfs 的预算去比压缩镜像）。
#
#   v3: 手写 superblock 解析器 —— 未压缩块标志位用错（0x1000 应为 0x2000），
#       把 13MB 当成全部文件内容，展开体积报成 13.09MB（真值 40MB）。
#       **能用的现成工具就别手写二进制解析器。** 现改用 unsquashfs。
#
# 用法： ./scripts/size-guard.sh [openwrt源码目录] [变体名]
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/openwrt}"
VARIANT="${2:-default}"
BIN="$SRC/bin/targets/mediatek/filogic"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

IMG="$BIN/openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.bin"

# ---- 阈值 ------------------------------------------------------------------
# UBI 分区 90MB。rootfs 占用后剩下的给 overlay。
# 官方 OpenWrt 会自动把 rootfs_data 撑满剩余空间，所以只要 rootfs 别太胖
# 就没事。这里设一条相对宽松的红线：rootfs 超过 45MB 才需要人看一眼，
# 因为那会把插件空间压到 40MB 以下。
MAX_ROOTFS_MB=45
# 镜像体积告警线（这个才是你下载的那个 .bin）
WARN_IMG_MB=25

UBI_TOTAL_MB=90
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'

echo "═══════════════════════════════════════════════════════════"
echo " 固件体积守卫 — 变体: $VARIANT"
echo "═══════════════════════════════════════════════════════════"
echo

[ -f "$IMG" ] || {
  echo "${RED}❌ 未找到镜像: $IMG${RST}"
  echo "   先执行完整构建: make -j\$(nproc)"
  exit 2
}

# ---- 1. sysupgrade 镜像大小 ------------------------------------------------
IMG_MB=$(( $(stat -c%s "$IMG") / 1048576 ))
printf "  %ssysupgrade 镜像%s   : %3d MB   " "$CYN" "$RST" "$IMG_MB"
if [ "$IMG_MB" -gt "$WARN_IMG_MB" ]; then
  echo "${YEL}⚠️  超 ${WARN_IMG_MB}MB 告警线${RST}"
else
  echo "${GRN}✅${RST}"
fi

# ---- 2. 准备 unsquashfs ----------------------------------------------------
# shellcheck source=scripts/lib/ensure-unsquashfs.sh
USQ="$(source "$ROOT/scripts/lib/ensure-unsquashfs.sh" && _ensure)" || {
  echo "${RED}❌ 拿不到 unsquashfs，无法核算体积${RST}"
  exit 2
}

# ---- 3. 取出 rootfs 分片 ---------------------------------------------------
tar -xf "$IMG" -C "$TMPD" 2>/dev/null
ROOTFS="$(find "$TMPD" -type f -name root 2>/dev/null | head -1)"
[ -n "$ROOTFS" ] || {
  echo "${RED}❌ 镜像里找不到 rootfs 分片${RST}"
  echo "   镜像结构: $(tar -tf "$IMG" 2>/dev/null | head -5 | tr '\n' ' ')"
  exit 2
}

SQFS_MB=$(( $(stat -c%s "$ROOTFS") / 1048576 ))
SQFS_KB=$(( $(stat -c%s "$ROOTFS") / 1024 ))

# ---- 4. 展开体积（参考值）--------------------------------------------------
# ⚠️ 不要用 unsquashfs 的退出码判断成败（Run #13 实测：解包成功但退出码非 0）。
#    判据是产物：目录建出来了、文件数够不够。
# ⚠️ 也不要像早期那样 `|| true` 之后还继续报"通过" —— 那会让体积守卫
#    在完全没测到的情况下显示绿色，等于形同虚设。测不到就明确报出来。
rm -rf "$TMPD/rootfs"
"$USQ" -f -d "$TMPD/rootfs" "$ROOTFS" >/dev/null 2>&1 || true

APP_MB="—"
NFILE="—"
if [ -d "$TMPD/rootfs" ]; then
  NFILE=$(find "$TMPD/rootfs" -type f 2>/dev/null | wc -l)
  if [ "$NFILE" -ge 50 ]; then
    APP_MB=$(du -sm --apparent-size "$TMPD/rootfs" 2>/dev/null | cut -f1)
  fi
fi

if [ "$NFILE" -lt 50 ] 2>/dev/null; then
  echo "  ${RED}❌ rootfs 解包失败（只解出 ${NFILE} 个文件），无法核算展开体积${RST}"
  echo "     rootfs 占用仍可测（$(stat -c%s "$ROOTFS") 字节），但展开体积未知。"
  echo "     体积守卫判定为**不可信**，请检查 unsquashfs 是否支持 xz："
  echo "       $USQ"
  exit 2
fi

# ---- 5. 输出与判定 ---------------------------------------------------------
# UBI 开销：每 128KB LEB 有 2 字节 ECC，约 1.6%；再加上 rootfs_data 要留最小空间
UBI_OVERHEAD_MB=4
OVERLAY_MB=$(( UBI_TOTAL_MB - SQFS_MB - UBI_OVERHEAD_MB ))

echo "  ${CYN}rootfs(squashfs)${RST} : ${SQFS_MB} MB   ${CYN}← 刷进去实际占分区${RST}"
echo "  ${CYN}展开体积${RST}        : ${APP_MB} MB   （${NFILE} 个文件，仅参考）"
echo
echo "  ${CYN}UBI 分区总计${RST}  : ${UBI_TOTAL_MB} MB"
echo "  ${CYN}rootfs 占用${RST}    : ${SQFS_MB} MB"
echo "  ${CYN}UBI/ECC 开销${RST}  : ${UBI_OVERHEAD_MB} MB"
echo "  ${CYN}rootfs_data${RST}    : ${OVERLAY_MB} MB   ${CYN}← 装插件、存配置的空间${RST}"
echo

STATUS=0
if [ "$SQFS_MB" -gt "$MAX_ROOTFS_MB" ]; then
  echo "  ${RED}❌ 构建判定失败${RST}：rootfs ${SQFS_MB}MB 超过红线 ${MAX_ROOTFS_MB}MB"
  echo "     rootfs_data 只剩 ${OVERLAY_MB}MB，装插件会很紧张。"
  echo "     裁剪方向见 README §4.6"
  STATUS=1
elif [ "$OVERLAY_MB" -lt 25 ]; then
  echo "  ${YEL}⚠️  rootfs_data 仅剩 ${OVERLAY_MB}MB，建议检查包体积${RST}"
  STATUS=0
else
  echo "  ${GRN}✅ 通过${RST}：rootfs_data 剩 ${OVERLAY_MB}MB，插件空间充足"
fi

# ---- 6. 体积 Top -----------------------------------------------------------
PKGDIR="$BIN/packages"
if [ -d "$PKGDIR" ]; then
  echo
  echo "  体积 Top 15 包:"
  find "$PKGDIR" \( -name '*.apk' -o -name '*.ipk' \) -printf '%s %p\n' 2>/dev/null \
    | sort -rn | head -15 \
    | awk '{printf "    %7.2f MB  %s\n", $1/1048576, $2}' \
    | sed "s|$PKGDIR/||"
fi

echo
echo "═══════════════════════════════════════════════════════════"
exit $STATUS
