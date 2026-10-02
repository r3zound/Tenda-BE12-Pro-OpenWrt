#!/usr/bin/env bash
# =============================================================================
# size-guard.sh — 固件体积守卫
# -----------------------------------------------------------------------------
# 本机 ubi 分区总计 90 MB（0xd80000–0x6780000），扣除 UBI 冗余与元数据后
# 安全上限约 88 MB。这条守卫是防止「编译通过但刷完变砖」的最后一道闸。
#
# ⚠️ 测的是 squashfs **展开后**的真实体积（刷进去实际占多少），
#    不是压缩后的镜像大小 —— 二者能差 2 倍以上。
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
TARBALL="$BIN/openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.tar.gz"

WARN_IMG_MB=20
MAX_ROOTFS_MB=88

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

# ---- 1. 压缩包大小 ---------------------------------------------------------
IMG_KB=$(( $(stat -c%s "$IMG") / 1024 ))
printf "  sysupgrade 镜像   : %4d MB   " $(( IMG_KB / 1024 ))
if [ "$IMG_KB" -gt $(( WARN_IMG_MB * 1024 )) ]; then
  echo "${YEL}⚠️  超 ${WARN_IMG_MB}MB 告警线${RST}"
else
  echo "${GRN}✅${RST}"
fi

# ---- 2. 定位 rootfs 分片 ---------------------------------------------------
# ⚠️ sysupgrade.bin 内部结构：
#     sysupgrade-tenda_be12-pro/{CONTROL, kernel, root}
#   旧版本这里按 'rootfs/' 前缀匹配，永远匹配不到 → 守卫形同虚设。
SQFS="$TMPD/root"
if [ -f "$TARBALL" ]; then
  tar -xf "$TARBALL" -C "$TMPD" 2>/dev/null
  F=$(find "$TMPD" -type f -name root 2>/dev/null | head -1)
  [ -n "$F" ] && cp "$F" "$SQFS"
fi
if [ ! -s "$SQFS" ]; then
  rm -rf "${TMPD:?}"/* 2>/dev/null
  tar -xf "$IMG" -C "$TMPD" 2>/dev/null
  F=$(find "$TMPD" -type f -name root 2>/dev/null | head -1)
  [ -n "$F" ] && cp "$F" "$SQFS"
fi

if [ ! -s "$SQFS" ]; then
  echo "${YEL}⚠️  未能定位 rootfs 分片，跳过体积核算${RST}"
  echo "     镜像结构: $(tar -tf "$IMG" 2>/dev/null | head -5 | tr '\n' ' ')"
  exit 0
fi

# ---- 3. 解析 squashfs，算真实展开体积 --------------------------------------
python3 - "$SQFS" "$MAX_ROOTFS_MB" <<'PYEOF'
import struct, sys, lzma

R = "\033[31m"; G = "\033[32m"; Y = "\033[33m"; C = "\033[36m"; X = "\033[0m"

path = sys.argv[1]
limit_mb = float(sys.argv[2])
MB = 1048576

d = open(path, 'rb').read()
try:
    (magic, inodes, mkfs_time, block_size, fragments, compression, block_log,
     flags, no_ids, s_major, s_minor) = struct.unpack('<5I6H', d[:32])
    (root_inode, bytes_used, id_table_start, xattr_id_table_start,
     inode_table_start, directory_table_start, fragment_table_start,
     lookup_table_start) = struct.unpack('<8Q', d[32:96])
except Exception as e:
    print("  %s⚠️  squashfs 解析失败: %s%s" % (Y, e, X))
    sys.exit(0)

if magic != 0x73717368:
    print("  %s⚠️  非 squashfs (magic=%x)，跳过%s" % (Y, magic, X))
    sys.exit(0)

comp = {1:'gzip',2:'lzma',3:'lzo',4:'xz',5:'lz4',6:'zstd'}.get(compression, '?')
UNCOMPRESSED = 0x1000

# 走一遍数据块，累加解压后体积
off, end, nblk, ncomp, expanded = 96, fragment_table_start, 0, 0, 0
try:
    while off < end:
        bs = struct.unpack('<H', d[off:off+2])[0]
        plain = bool(bs & UNCOMPRESSED)
        size = bs & (UNCOMPRESSED - 1)
        nblk += 1
        if plain:
            expanded += block_size
            off += 2 + block_size
        else:
            ncomp += 1
            if compression == 4:
                try:
                    expanded += len(lzma.decompress(d[off+2:off+2+size]))
                except Exception:
                    expanded += block_size
            else:
                expanded += block_size
            off += 2 + size
except Exception:
    pass

total = max(expanded, lookup_table_start)   # 元数据区也占分区
used = total / MB

print("  %ssquashfs%s        : %d.%d / %s / 块 %d B" % (C, X, s_major, s_minor, comp, block_size))
print("  %s数据块%s           : %d 个 (其中压缩 %d)" % (C, X, nblk, ncomp))
print("  %s展开后 rootfs%s   : %6.2f MB   %s← 刷进去实际占用%s" % (C, X, used, G, X))
print("  %s压缩后 (镜像内)%s  : %6.2f MB" % (C, X, bytes_used / MB))
if total:
    print("  %s压缩率%s           : %4.0f%%" % (C, X, bytes_used / total * 100))
print()
print("  %subi 分区上限%s    : %6.2f MB   (0xd80000-0x6780000)" % (C, X, 90.0))
print("  %s守卫阈值%s        : %6.2f MB   (预留 UBI 冗余与元数据)" % (C, X, limit_mb))
print("  %s剩余余量%s        : %6.2f MB   ← 后续装插件的空间" % (C, X, limit_mb - used))
print()

if used > limit_mb:
    print("  %s❌ 构建判定失败%s：超出上限 %.2f MB" % (R, X, used - limit_mb))
    print("     裁剪方向见 README §4.6（包体积控制）")
    sys.exit(1)
elif used > limit_mb * 0.85:
    print("  %s⚠️  通过但接近上限 (>85%%)，建议检查包体积%s" % (Y, X))
    sys.exit(0)
else:
    print("  %s✅ 通过，余量充足%s" % (G, X))
    sys.exit(0)
PYEOF
STATUS=$?

# ---- 4. 定位大头 -----------------------------------------------------------
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
