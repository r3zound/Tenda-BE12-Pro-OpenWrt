#!/usr/bin/env bash
# =============================================================================
# fetch-proxy-packages.sh — 把代理面板仓库拉进 package/
# -----------------------------------------------------------------------------
# 用法： ./scripts/fetch-proxy-packages.sh [openwrt源码目录]
#
# ⚠️ 为什么全部走 package/ 而不是 feeds：
#    include/scan.mk 用 `find -L feeds/<名字> -mindepth 1 -name Makefile` 扫描，
#    而这些仓库的 Makefile 基本都在**仓库根目录**，-mindepth 1 把它们排除了 →
#    feeds install 静默无输出、索引为空、.config 里没有符号 →
#    编译一路绿灯，固件里就是没有面板。
#    这就是本项目「坑 1 / 坑 5」的同款问题，已经栽过一次。
#
# 本脚本只负责 clone，编译在 build-repo.sh 里做。
# 仓库清单在 versions.lock 的 REPO_PROXY_* 段，改那里不改这里。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/openwrt}"
LOCK="$ROOT/versions.lock"

GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
ok()   { echo "${GRN}✅ $*${RST}"; }
warn() { echo "${YEL}⚠️  $*${RST}"; }
die()  { echo "${RED}❌ $*${RST}" >&2; exit 1; }
step() { echo; echo "${CYN}▸ $*${RST}"; }

[ -d "$SRC/package" ] || die "源码树不对: $SRC/package 不存在"
[ -f "$LOCK" ] || die "找不到 $LOCK"

# ---- 读清单 -----------------------------------------------------------------
# 格式：REPO_PROXY_<NAME>=<clone目标目录名>|<git地址>|<分支>
# 用 | 分隔是因为 URL 里有斜杠但没有竖线，比逗号安全。
proxies() {
  grep -E '^REPO_PROXY_[A-Z0-9_]+=' "$LOCK" | while IFS= read -r line; do
    val="${line#*=}"
    echo "$val"
  done
}

step "解析 versions.lock 里的面板清单"
COUNT=0
proxies | while IFS='|' read -r dest url branch; do
  [ -n "$dest" ] || continue
  echo "  $dest  ←  $url  ($branch)"
done
COUNT=$(proxies | grep -c . || true)
[ "$COUNT" -gt 0 ] || die "versions.lock 里没有任何 REPO_PROXY_* 条目"
ok "共 $COUNT 个面板仓库"

# ---- clone ------------------------------------------------------------------
# ⚠️ 用 --depth 1 + --branch 浅克隆：20 个仓库全量历史会拖垮 CI。
#    代价是拿不到历史 commit，想锁版本得在 versions.lock 里显式写分支或 tag。
# ⚠️ 幂等：目标目录已存在且是 git 仓库就跳过。要强制刷新先删目录。
step "拉取面板仓库到 package/"
FETCH_FAIL=0
proxies | while IFS='|' read -r dest url branch; do
  [ -n "$dest" ] || continue
  target="$SRC/package/$dest"
  if [ -d "$target/.git" ]; then
    echo "  ${YEL}·${RST} $dest 已存在，跳过（要刷新请删 $target）"
    continue
  fi
  # destination path must not exist（坑 1 踩过：git clone 目标存在且非空会直接拒绝）
  [ -e "$target" ] && { echo "  ${YEL}!${RST} $dest 目标已存在但不是 git 仓库，跳过"; continue; }
  if git clone --depth 1 --branch "$branch" "$url" "$target" >/dev/null 2>&1; then
    echo "  ${GRN}✓${RST} $dest"
  else
    echo "  ${RED}✗${RST} $dest  clone 失败: $url ($branch)"
    echo "      —— 面板仓库改名/删分支都会这样，不影响固件本身构建"
  fi
done

# ---- 回读校验 ---------------------------------------------------------------
# ⚠️ clone 返回 0 不等于包能被扫到：必须有 Makefile，否则 .config 里不会有符号。
step "回读校验（深度 5 内必须有 Makefile，深度对齐 OpenWrt SCAN_DEPTH）"
MISSING=0
proxies | while IFS='|' read -r dest url branch; do
  [ -n "$dest" ] || continue
  target="$SRC/package/$dest"
  # ⚠️ maxdepth 5 不是随便写的：include/toplevel.mk:106 里 OpenWrt 扫 package/
  #    用的是 SCAN_DEPTH=5。实测 13 个面板仓库里 12 个的包 Makefile 不在根目录，
  #    这里要是写成 maxdepth 2，就会把 openwrt-passwall 那类全部误判成「结构变了」。
  if find "$target" -maxdepth 5 -name Makefile -type f -print -quit 2>/dev/null | grep -q .; then
    :
  else
    echo "  ${YEL}·${RST} $dest 深度 5 内没有 Makefile —— 这个面板不会被编（上游结构变了？）"
  fi
done

echo
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "${GRN}  面板仓库就位${RST}"
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "  目录: $SRC/package/"
echo
echo "  ${YEL}注意：单个面板 clone 失败不会中断构建。${RST}"
echo "  ${YEL}这是有意的 —— 上游面板仓库改名很频繁，${RST}"
echo "  ${YEL}不应该因为一个面板挂了就编不出固件。${RST}"
echo "  真正需要严格的是内核模块（kmod），那些在 base.config 里，见 build-repo.sh。${RST}"
