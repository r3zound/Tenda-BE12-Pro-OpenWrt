#!/usr/bin/env bash
# =============================================================================
# gen-feeds.sh — 从 versions.lock 生成 feeds.conf
# -----------------------------------------------------------------------------
# 所有上游仓库都使用 commit SHA 锁定，保证构建可复现。
# 用法： ./scripts/gen-feeds.sh [openwrt源码目录]
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/versions.lock"
SRC="${1:-$ROOT/openwrt}"

[ -f "$LOCK" ] || { echo "❌ 找不到 versions.lock: $LOCK"; exit 1; }

# 读取锁文件
get() { grep -E "^$1=" "$LOCK" | head -1 | cut -d= -f2- ; }

OPENWRT_REPO=$(get OPENWRT_REPO)
OPENWRT_BRANCH=$(get OPENWRT_BRANCH)
OPENWRT_COMMIT=$(get OPENWRT_COMMIT)
LUCI_REPO=$(get LUCI_REPO)
LUCI_COMMIT=$(get LUCI_COMMIT)
PACKAGES_REPO=$(get PACKAGES_REPO)
PACKAGES_COMMIT=$(get PACKAGES_COMMIT)
BF_REPO=$(get BASE_FILES_REPO)
BF_BRANCH=$(get BASE_FILES_BRANCH)
BF_COMMIT=$(get BASE_FILES_COMMIT)
ARGON_REPO=$(get THEME_ARGON_REPO)
ARGON_COMMIT=$(get THEME_ARGON_COMMIT)
AURORA_REPO=$(get THEME_AURORA_REPO)
AURORA_COMMIT=$(get THEME_AURORA_COMMIT)
EDGE_REPO=$(get THEME_EDGE_REPO)
EDGE_BRANCH=$(get THEME_EDGE_BRANCH)
EDGE_COMMIT=$(get THEME_EDGE_COMMIT)
FRP_REPO=$(get FRP_LUCI_REPO)
FRP_BRANCH=$(get FRP_LUCI_BRANCH)
FRP_COMMIT=$(get FRP_LUCI_COMMIT)

# 拉取 openwrt 源码
if [ ! -d "$SRC/.git" ]; then
  echo "▸ 克隆 OpenWrt @ $OPENWRT_COMMIT"
  git clone --filter=blob:none "$OPENWRT_REPO" "$SRC"
fi

cd "$SRC"
if [ "$(git rev-parse HEAD)" != "$OPENWRT_COMMIT" ]; then
  echo "▸ 检出 OpenWrt $OPENWRT_COMMIT"
  git fetch --depth 1 origin "$OPENWRT_COMMIT" 2>/dev/null || git fetch origin
  git checkout -B main "$OPENWRT_COMMIT"
fi

cat > feeds.conf <<EOF
# ============================================================================
# 由 scripts/gen-feeds.sh 自动生成 —— 请勿手工编辑
# 源：versions.lock
# 生成时间：$(date -u '+%Y-%m-%d %H:%M:%S UTC')
# ============================================================================

# ---- 官方 feeds（锁定 commit）---------------------------------------------
src-git luci "$LUCI_REPO" "$LUCI_COMMIT"
src-git packages "$PACKAGES_REPO" "$PACKAGES_COMMIT"
EOF

if [ "$BF_COMMIT" != "AUTO" ]; then
  echo "src-git base-files \"$BF_REPO\" \"$BF_COMMIT\"" >> feeds.conf
else
  echo "src-git base-files \"$BF_REPO\" \"$BF_BRANCH\"" >> feeds.conf
fi

cat >> feeds.conf <<EOF

# ---- LuCI 主题（第三方，官方主线不含）-------------------------------------
src-git luci-theme-argon "$ARGON_REPO" "$ARGON_COMMIT"
src-git luci-theme-aurora "$AURORA_REPO" "$AURORA_COMMIT"
# edge 主题取自聚合仓库；该包较旧（2021），若渲染异常见 README §4.2
src-git luci-theme-edge "$EDGE_REPO" "$EDGE_COMMIT"

# ---- 应用 -----------------------------------------------------------------
src-git luci-app-frpc "$FRP_REPO" "$FRP_COMMIT"

# ---- 刻意不引入 -----------------------------------------------------------
# mwan3   —— 见 README §4.3。官方 mwan3 是 iptables 实现，在 fw4/nftables 上
#            负载均衡已失效；且含 mwan3 的 sysupgrade 会静默装回失效版本。
#            改用 dl12345/mwan3 原生 nft 移植版，刷机后单独安装。
# passwall —— 已按需求移除（体积超限）。见 README §4.6。
EOF

echo "✅ feeds.conf 已生成：$SRC/feeds.conf"
echo
cat feeds.conf
