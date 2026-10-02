#!/usr/bin/env bash
# =============================================================================
# size-guard.sh — 固件体积守卫
# -----------------------------------------------------------------------------
# 本机 ubi 分区总计 90 MB（0xd80000–0x6780000），扣除 UBI 冗余与元数据后
# 安全上限约 88 MB。这条守卫是防止「编译通过但刷完变砖」的最后一道闸。
#
# 用法： ./scripts/size-guard.sh [openwrt源码目录] [变体名]
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/openwrt}"
VARIANT="${2:-default}"
BIN="$SRC/bin/targets/mediatek/filogic"

IMG="$BIN/openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.bin"

# ---- 阈值 ------------------------------------------------------------------
WARN_IMG_MB=20          # 镜像超过此值告警
MAX_ROOTFS_MB=88        # rootfs 占用上限，超过则构建失败
MAX_ROOTFS_KB=$(( MAX_ROOTFS_MB * 1024 ))

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'

if [ ! -f "$IMG" ]; then
  echo "❌ 未找到镜像：$IMG"
  echo "   先执行完整构建：make -j\$(nproc)"
  exit 2
fi

echo "═══════════════════════════════════════════════════════════"
echo " 固件体积守卫 — 变体: $VARIANT"
echo "═══════════════════════════════════════════════════════════"
echo

# ---- 1. 镜像大小 -----------------------------------------------------------
IMG_MB=$(echo "scale=2; $(stat -c%s "$IMG") / 1048576" | bc)
printf "镜像大小      : %8.2f MB   %s\n" "$IMG_MB" "$IMG"
if (( $(echo "$IMG_MB > $WARN_IMG_MB" | bc -l) )); then
  echo "               ${YEL}⚠️  超过 ${WARN_IMG_MB}MB 告警阈值${RST}"
fi
echo

# ---- 2. rootfs 实际占用 ----------------------------------------------------
# 从 tar.gz sysupgrade 包中提取 rootfs，计算其展开体积
TARBALL="$BIN/openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.tar.gz"
ROOTFS_MB="0"
if [ -f "$TARBALL" ]; then
  ROOTFS_BYTES=$(tar -tzvf "$TARBALL" 2>/dev/null \
    | awk '$NF ~ /^rootfs\// {s+=$3} END {print s+0}')
  ROOTFS_MB=$(echo "scale=2; $ROOTFS_BYTES / 1048576" | bc)
  printf "rootfs 展开   : %8.2f MB\n" "$ROOTFS_MB"
else
  echo "rootfs 展开   :  (未找到 tar.gz，跳过)"
fi
echo "rootfs 上限   : %8.2f MB   (ubi 分区 90MB - UBI 开销)" "$MAX_ROOTFS_MB"
echo

# ---- 3. 逐包体积排行（定位大头）-------------------------------------------
PKGDIR="$BIN/packages"
if [ -d "$PKGDIR" ]; then
  echo "▸ 体积 Top 20 包："
  find "$PKGDIR" -name '*.apk' -o -name '*.ipk' 2>/dev/null \
    | xargs -r stat -c '%s %n' 2>/dev/null \
    | sort -rn | head -20 \
    | awk '{printf "  %8.2f MB  %s\n", $1/1048576, $2}' \
    | sed "s|$PKGDIR/||"
  echo
fi

# ---- 4. 判定 ---------------------------------------------------------------
STATUS=0
if [ -n "$ROOTFS_MB" ] && [ "$ROOTFS_MB" != "0" ]; then
  if (( $(echo "$ROOTFS_MB > $MAX_ROOTFS_MB" | bc -l) )); then
    echo "${RED}❌ 构建失败${RST}：rootfs ${ROOTFS_MB}MB 超过上限 ${MAX_ROOTFS_MB}MB"
    echo "   超额 $(echo "$ROOTFS_MB - $MAX_ROOTFS_MB" | bc) MB"
    echo "   → 裁剪方向见 README §4.6（包体积控制）"
    STATUS=1
  else
    REMAIN=$(echo "$MAX_ROOTFS_MB - $ROOTFS_MB" | bc)
    echo "${GRN}✅ 通过${RST}：rootfs ${ROOTFS_MB}MB，余量 ${REMAIN}MB"
  fi
fi

echo
echo "═══════════════════════════════════════════════════════════"
exit $STATUS
