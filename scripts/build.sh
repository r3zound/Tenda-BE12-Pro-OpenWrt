#!/usr/bin/env bash
# =============================================================================
# build.sh — Tenda BE12 Pro 固件一键构建
# -----------------------------------------------------------------------------
# 用法：
#   ./scripts/build.sh                    # 完整构建
#   ./scripts/build.sh -j8                # 指定并行度
#   ./scripts/build.sh --variant slim     # 带变体标识（影响 config.buildinfo）
#   ./scripts/build.sh --clean            # 清理后重建
#   ./scripts/build.sh --dl                # 仅下载源码，不编译
#
# 环境变量：
#   OPENWRT_SRC   OpenWrt 源码目录（默认 ./openwrt）
#   VARIANT       变体名（默认 default）
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${OPENWRT_SRC:-$ROOT/openwrt}"
VARIANT="${VARIANT:-default}"
JOBS="$(nproc 2>/dev/null || echo 4)"
DL_ONLY=0
CLEAN=0

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'

usage() {
  cat <<EOF
用法: $0 [选项]
  -j N          并行任务数（默认 \$(nproc) = $JOBS）
  --variant V   变体名，写入 config.buildinfo
  --clean       构建前清理
  --dl          只下载源码与 feeds，跳过编译
  -h            显示帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="$2"; shift 2 ;;
    -j*) JOBS="${1#-j}"; shift ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --variant=*) VARIANT="${1#--variant=}"; shift ;;
    --clean) CLEAN=1; shift ;;
    --dl) DL_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

step() { echo; echo "${CYN}▸ $*${RST}"; }
ok()   { echo "${GRN}✅ $*${RST}"; }
warn() { echo "${YEL}⚠️  $*${RST}"; }
die()  { echo "${RED}❌ $*${RST}" >&2; exit 1; }

# ---- 0. 环境检查 -----------------------------------------------------------
step "环境检查"
for c in git make gcc g++ python3 perl unzip rsync bc; do
  command -v "$c" >/dev/null 2>&1 || die "缺少依赖: $c"
done
ok "依赖齐备"
echo "  源码目录 : $SRC"
echo "  并行任务 : $JOBS"
echo "  变体     : $VARIANT"

# 磁盘空间检查（OpenWrt 完整编译需 40-60GB）
AVAIL_GB=$(df -BG --output=avail "$SRC" 2>/dev/null | tail -1 | tr -dc '0-9')
[ -n "$AVAIL_GB" ] && [ "$AVAIL_GB" -lt 40 ] && \
  die "磁盘空间不足：剩余 ${AVAIL_GB}GB，需要 ≥ 40GB"
ok "磁盘空间 ${AVAIL_GB:-?}GB"

[ "$CLEAN" -eq 1 ] && { step "清理"; rm -rf "$SRC/dl" "$SRC/build_dir" "$SRC/staging_dir" "$SRC/bin"; ok "已清理"; }

# ---- 1. 生成 feeds.conf（锁定 commit）-------------------------------------
step "生成 feeds.conf"
"$ROOT/scripts/gen-feeds.sh" "$SRC" >/dev/null || die "feeds 生成失败"
ok "feeds.conf 就绪（全部锁定 commit）"

# ---- 2. 更新 feeds ---------------------------------------------------------
step "拉取 feeds"
cd "$SRC"
./scripts/feeds update -a || die "feeds update 失败"
./scripts/feeds install -a -p luci \
  luci luci-base luci-compat luci-mod-admin-full luci-mod-network luci-mod-system \
  luci-mod-status luci-mod-firewall luci-mod-dhcp luci-app-firewall \
  luci-app-attendedsysupgrade luci-app-statistics luci-app-package-manager \
  luci-theme-bootstrap luci-i18n-base-zh-cn || die "luci feed 安装失败"
./scripts/feeds install -a -p luci-theme-argon   || warn "argon 主题 feed 安装失败（该主题将缺失）"
./scripts/feeds install -a -p luci-theme-aurora  || warn "aurora 主题 feed 安装失败（该主题将缺失）"
./scripts/feeds install -a -p luci-theme-edge    || warn "edge 主题 feed 安装失败（该主题将缺失）"
./scripts/feeds install -a -p luci-app-frpc      || warn "luci-app-frpc 安装失败（FRP 界面将缺失）"
./scripts/feeds install -a -p frp                || die "官方 frp 包安装失败"
ok "feeds 安装完成"

# ---- 3. 生成 .config -------------------------------------------------------
step "生成 .config"
"$ROOT/scripts/gen-config.sh" "$SRC" || die "配置生成失败"

# ---- 4. 注入预置文件 -------------------------------------------------------
# OpenWrt 通过 CONFIG_TARGET_ROOTFS_INCLUDE_KERNEL + FILES_DIR 注入
step "注入预置文件"
if [ -d "$ROOT/files/etc" ]; then
  for f in "$ROOT/files/etc/config/"*; do
    [ -f "$f" ] && echo "  · /etc/config/$(basename "$f")"
  done
  for f in "$ROOT/files/etc/uci-defaults/"*; do
    [ -f "$f" ] && echo "  · /etc/uci-defaults/$(basename "$f")"
  done
  ok "预置文件已就绪（构建时由 FILES_DIR 注入）"
else
  warn "未找到 files/etc，使用 OpenWrt 默认配置"
fi

# ---- 5. 下载源码（可选）---------------------------------------------------
step "下载所有源码"
make download -j"$JOBS" V=s || die "源码下载失败"
ok "源码下载完成"

if [ "$DL_ONLY" -eq 1 ]; then
  echo; ok "--dl 模式结束，跳过编译"
  exit 0
fi

# ---- 6. 编译 ---------------------------------------------------------------
step "编译固件（这会花很长时间）"
echo "  提示：frp 是 Go 包，首次编译会额外拉取 Go 工具链"
make -j"$JOBS" V=s || die "编译失败"

# ---- 7. 记录构建信息 -------------------------------------------------------
step "记录构建信息"
{
  echo "variant: $VARIANT"
  echo "built_at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "host: $(uname -srm)"
  echo "openwrt_commit: $(git rev-parse HEAD)"
  echo "feeds_conf:"; sed 's/^/  /' feeds.conf
  echo "config:"; sed 's/^/  /' .config
} > "$SRC/bin/targets/mediatek/filogic/config.buildinfo"
ok "config.buildinfo 已生成"

# ---- 8. 校验和 -------------------------------------------------------------
step "生成校验和"
( cd "$SRC/bin/targets/mediatek/filogic" && sha256sum *.bin > sha256sums 2>/dev/null ) || true
ok "sha256sums 已生成"

# ---- 9. 体积守卫 -----------------------------------------------------------
step "体积守卫"
"$ROOT/scripts/size-guard.sh" "$SRC" "$VARIANT" || die "体积超限，构建判定失败（详见上方排行）"

# ---- 完成 ------------------------------------------------------------------
IMG="$SRC/bin/targets/mediatek/filogic/openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.bin"
echo
echo "═══════════════════════════════════════════════════════════"
echo "${GRN}  构建完成${RST}"
echo "═══════════════════════════════════════════════════════════"
echo "  固件: $IMG"
echo "  大小: $(du -h "$IMG" | cut -f1)"
echo
echo "  ${YEL}刷机前请务必校验：${RST}"
echo "    cd $(dirname "$IMG") && sha256sum -c sha256sums"
echo
echo "  ${YEL}刷机步骤见 README §7${RST}"
echo "  ${RED}刷完必看 README §8 救援流程${RST}"
echo "═══════════════════════════════════════════════════════════"
