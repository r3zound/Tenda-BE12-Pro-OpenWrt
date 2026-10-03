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

# ---- 1.5 板级移植 -----------------------------------------------------------
# ⛔ 这一步是本分支存在的全部意义。
# ImmortalWrt openwrt-25.12 **没有** Tenda BE12 Pro 这个板子
# （实测 filogic.mk 里 0 次提及），必须把设备树、板子定义和
# 原厂私有镜像头脚本补进去，否则 make menuconfig 里根本选不到这台设备。
# 详见 patches/immortalwrt-25.12/board-port.mk 头部说明。
# 幂等，可重复执行。
step "板级移植（设备树 + 板子定义 + 镜像头）"
"$ROOT/scripts/apply-board-port.sh" "$SRC" || die "板级移植失败"

# ---- 2. 更新 feeds ---------------------------------------------------------
step "拉取 feeds"
cd "$SRC"
./scripts/feeds update -a || die "feeds update 失败"
./scripts/feeds install -a -p luci || die "luci feed 安装失败"
# frpc / luci-app-frpc 都用官方包
./scripts/feeds install frp/frpc || die "官方 frpc 包安装失败"
ok "feeds 安装完成"

# ---- 2.5 挂载第三方包到 package/ -------------------------------------------
# ⚠️ argon / aurora 主题**不能**走 feeds：
#    include/scan.mk 用 `find -L feeds/<名字> -mindepth 1 -name Makefile` 扫描，
#    而这两个仓库的 Makefile 就在根目录，-mindepth 1 把它排除了 →
#    feeds install 静默无输出、索引为空、.config 里没有符号 →
#    编译一路绿灯，固件里就是没有主题。绕开 feeds 直挂 package/。
step "挂载第三方包"
"$ROOT/scripts/fetch-extra-packages.sh" "$SRC" || die "第三方包挂载失败"

# ---- 2.6 挂载预置配置包 ----------------------------------------------------
# OpenWrt 没有 FILES_DIR 这种自定义 rootfs 注入机制，想往镜像里塞文件
# 正规做法就是做一个包。本包由 package/tenda-preset 提供，内容来自 files/。
step "挂载预置配置包"
rm -rf "$SRC/package/tenda-preset"
cp -r "$ROOT/package/tenda-preset" "$SRC/package/tenda-preset"
# ⚠️ files/ **必须保留** —— Makefile 的 install 规则靠 `$(CP) ./files/...` 读取它。
#    这里曾经有个 "rm -rf files" 的"优化"，结果 make 到 install 阶段才炸，
#    白跑一次 80 分钟编译。
#    （顺带说明：package/ 下的 files/ 里没有 Makefile，include/scan.mk
#      的 find -name Makefile 扫不到它，不会造成额外的包定义。）
ok "tenda-preset 已挂载（预置网段 / 双 WAN / mwan3 助手）"

# ---- 3. 生成 .config -------------------------------------------------------
step "生成 .config"
"$ROOT/scripts/gen-config.sh" "$SRC" || die "配置生成失败"

# ---- 3.5 关键包校验 ---------------------------------------------------------
# kconfig 遇到未知符号既不报错也不警告，所以必须在 make 之前自己拦一道。
step "校验关键包"
cd "$SRC"
CHECK_FAIL=0
for p in luci luci-base luci-theme-bootstrap luci-theme-argon luci-theme-aurora \
         luci-app-argon-config luci-app-frpc frpc tenda-preset; do
  if grep -qE "^CONFIG_PACKAGE_${p}=y" .config; then
    ok "$p"
  else
    warn "$p 未进入 .config —— 包没被发现，或 base.config 漏配"
    CHECK_FAIL=1
  fi
done
# 语言包符号名不带 CONFIG_PACKAGE_ 前缀
if grep -qE '^CONFIG_LUCI_LANG_zh_Hans=y' .config; then
  ok "简体中文"
else
  warn "CONFIG_LUCI_LANG_zh_Hans 未启用"
  CHECK_FAIL=1
fi
for p in mwan3 passwall sing-box xray; do
  if grep -qE "^CONFIG_PACKAGE_${p}=y" .config; then
    warn "$p 不该在镜像里，却进了 .config"
    CHECK_FAIL=1
  else
    ok "$p 已排除"
  fi
done
[ "$CHECK_FAIL" -eq 0 ] || die "关键包校验未通过，已中止（避免白跑一次 80 分钟编译）"

# ---- 4. 确认预置文件已入包 -------------------------------------------------
# ⚠️ 这一步以前只是一句注释：「OpenWrt 通过 CONFIG_TARGET_ROOTFS_INCLUDE_KERNEL
#    + FILES_DIR 注入」—— **那套机制根本不存在**。代码只是打印了文件名，
#    什么都没接上，于是 Run #5 的固件里 /etc/config/network、
#    99-tenda-custom、install-mwan3.sh 全都没有，刷完是官方默认 192.168.1.1。
#    现在预置配置由 package/tenda-preset 真正打进固件（见上面「挂载预置配置包」）。
step "确认预置文件已入包"
for f in etc/config/network etc/config/firewall etc/config/dhcp \
         etc/config/system etc/uci-defaults/99-tenda-custom \
         usr/lib/tenda/install-mwan3.sh; do
  if [ -e "$SRC/package/tenda-preset/files/$f" ]; then
    ok "  $f"
  else
    die "  预置文件缺失: $f（tenda-preset 包不完整）"
  fi
done

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
