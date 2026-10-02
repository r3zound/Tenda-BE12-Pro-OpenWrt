#!/usr/bin/env bash
# =============================================================================
# gen-feeds.sh — 从 versions.lock 生成 feeds.conf
# -----------------------------------------------------------------------------
# 所有上游仓库都使用 commit SHA 锁定，保证构建可复现。
# 用法： ./scripts/gen-feeds.sh [openwrt源码目录]
#
# ⚠️ 命名铁律：feed 名只允许 [A-Za-z0-9_]。
#    OpenWrt 的 scripts/feeds 解析器正则为：
#      ^src-([\w\-]+)((?:\s+--\w+(?:=\S+)?)*)\s+(\w+)(?:\s+(\S.*))?$
#    其中 feed 名那一组是 (\w+) —— 连字符会导致
#    "Syntax error in feeds.conf, line N" 并 exit 25。
#    本脚本在生成后会强制校验，违规立即失败。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/versions.lock"
SRC="${1:-$ROOT/openwrt}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'

die()  { echo "${RED}❌ $*${RST}" >&2; exit 1; }
warn() { echo "${YEL}⚠️  $*${RST}"; }

[ -f "$LOCK" ] || die "找不到 versions.lock: $LOCK"

get() {
  local v
  v="$(grep -E "^$1=" "$LOCK" | head -1 | cut -d= -f2- || true)"
  [ -n "$v" ] || die "versions.lock 缺少键: $1"
  echo "$v"
}

# ---- 读取锁文件 -----------------------------------------------------------
OPENWRT_REPO=$(get OPENWRT_REPO)
OPENWRT_BRANCH=$(get OPENWRT_BRANCH)
OPENWRT_COMMIT=$(get OPENWRT_COMMIT)
LUCI_REPO=$(get LUCI_REPO)
LUCI_COMMIT=$(get LUCI_COMMIT)
PACKAGES_REPO=$(get PACKAGES_REPO)
PACKAGES_COMMIT=$(get PACKAGES_COMMIT)

N_ARGON=$(get FEED_NAME_THEME_ARGON);      ARGON_REPO=$(get THEME_ARGON_REPO);   ARGON_COMMIT=$(get THEME_ARGON_COMMIT)
N_AURORA=$(get FEED_NAME_THEME_AURORA);    AURORA_REPO=$(get THEME_AURORA_REPO); AURORA_COMMIT=$(get THEME_AURORA_COMMIT)
N_EDGE=$(get FEED_NAME_THEME_EDGE);        EDGE_REPO=$(get THEME_EDGE_REPO);     EDGE_COMMIT=$(get THEME_EDGE_COMMIT)
EDGE_BRANCH=$(get THEME_EDGE_BRANCH)
N_FRP=$(get FEED_NAME_FRP_LUCI);            FRP_REPO=$(get FRP_LUCI_REPO);       FRP_COMMIT=$(get FRP_LUCI_COMMIT)

# ---- 铁律校验：feed 名合法性 + SHA 格式 ------------------------------------
echo "${CYN}▸ 校验 feed 名与 commit${RST}"

validate_feed_name() {
  local name="$1" where="$2"
  if [[ ! "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "  ${RED}❌ feed 名非法: $name${RST}  (来源: $where)"
    echo "     OpenWrt scripts/feeds 用 (\\w+) 匹配 feed 名 —— 只允许字母/数字/下划线"
    echo "     连字符会触发: Syntax error in feeds.conf, line N  → exit 25"
    return 1
  fi
  echo "  ${GRN}✓${RST} $name"
}

validate_sha() {
  local sha="$1" where="$2"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    warn "$where 的 commit 不是 40 位 SHA: $sha （构建可能失败）"
    return 0
  fi
  echo "  ${GRN}✓${RST} $where @ ${sha:0:12}"
}

FAIL=0
validate_feed_name "luci"           "LUCI_REPO"          || FAIL=1
validate_feed_name "packages"       "PACKAGES_REPO"      || FAIL=1
validate_feed_name "$N_ARGON"       "FEED_NAME_THEME_ARGON"  || FAIL=1
validate_feed_name "$N_AURORA"      "FEED_NAME_THEME_AURORA" || FAIL=1
validate_feed_name "$N_EDGE"        "FEED_NAME_THEME_EDGE"   || FAIL=1
validate_feed_name "$N_FRP"         "FEED_NAME_FRP_LUCI"     || FAIL=1
echo
validate_sha "$OPENWRT_COMMIT"  "openwrt"      || true
validate_sha "$LUCI_COMMIT"     "luci"         || true
validate_sha "$PACKAGES_COMMIT" "packages"     || true
validate_sha "$ARGON_COMMIT"    "argon"        || true
validate_sha "$AURORA_COMMIT"   "aurora"       || true
validate_sha "$EDGE_COMMIT"     "edge"         || true
validate_sha "$FRP_COMMIT"      "luci-app-frpc" || true

[ "$FAIL" -eq 0 ] || die "feeds.conf 校验未通过，已中止（修复 versions.lock 后重试）"

# ---- 拉取 openwrt 源码 -----------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  echo
  echo "${CYN}▸ 克隆 OpenWrt${RST}"
  git clone --filter=blob:none "$OPENWRT_REPO" "$SRC"
fi

cd "$SRC"
if [ "$(git rev-parse HEAD 2>/dev/null || echo '')" != "$OPENWRT_COMMIT" ]; then
  echo "${CYN}▸ 检出 OpenWrt $OPENWRT_COMMIT${RST}"
  git fetch --depth 1 origin "$OPENWRT_COMMIT" 2>/dev/null || git fetch origin
  git checkout -B "$OPENWRT_BRANCH" "$OPENWRT_COMMIT"
fi

# ---- 生成 feeds.conf ------------------------------------------------------
cat > feeds.conf <<EOF
# ============================================================================
# 由 scripts/gen-feeds.sh 自动生成 —— 请勿手工编辑
# 源：versions.lock
# 生成时间：$(date -u '+%Y-%m-%d %H:%M:%S UTC')
#
# ⚠️ feed 名只允许 [A-Za-z0-9_]。改 name 时同步改 versions.lock 的
#    FEED_NAME_* 键，否则 scripts/feeds 会报 Syntax error 并 exit 25。
# ============================================================================

# ---- 官方 feeds（锁定 commit）---------------------------------------------
src-git luci "$LUCI_REPO" "$LUCI_COMMIT"
src-git packages "$PACKAGES_REPO" "$PACKAGES_COMMIT"

# ---- LuCI 主题（第三方，官方主线不含）-------------------------------------
src-git $N_ARGON "$ARGON_REPO" "$ARGON_COMMIT"
src-git $N_AURORA "$AURORA_REPO" "$AURORA_COMMIT"
# edge 主题取自聚合仓库；该包较旧（2021），若渲染异常见 README §4.5
src-git $N_EDGE "$EDGE_REPO" "$EDGE_COMMIT"

# ---- 应用 -----------------------------------------------------------------
src-git $N_FRP "$FRP_REPO" "$FRP_COMMIT"

# ---- 刻意不引入 -----------------------------------------------------------
# mwan3   —— 见 README §4.3。官方 mwan3 是 iptables 实现，在 fw4/nftables 上
#            负载均衡已失效；且含 mwan3 的 sysupgrade 会静默装回失效版本。
#            改用 dl12345/mwan3 原生 nft 移植版，刷机后单独安装。
# passwall —— 已按需求移除（体积超限）。见 README §4.6。
#
# base-files —— 不是独立 feed，就在 openwrt 主仓 package/base-files 内。
#            官方 feeds.conf.default 中亦无此项，勿加。
EOF

# ---- 用 OpenWrt 真实解析器复验 ---------------------------------------------
# scripts/feeds 若已就绪，直接用它验证语法（最权威）；否则退回正则自检
if [ -x ./scripts/feeds ]; then
  echo
  echo "${CYN}▸ 用 OpenWrt scripts/feeds 复验语法${RST}"
  if perl ./scripts/feeds list >/dev/null 2>/tmp/feeds-err.txt; then
    :
  fi
  if grep -qi 'syntax error' /tmp/feeds-err.txt 2>/dev/null; then
    cat /tmp/feeds-err.txt
    die "feeds.conf 语法校验未通过"
  fi
  rm -f /tmp/feeds-err.txt
  echo "  ${GRN}✓${RST} 语法校验通过"
else
  # 自检：逐行套用官方正则
  echo
  echo "${CYN}▸ 正则自检（scripts/feeds 未就绪）${RST}"
  local_rc=0
  while IFS= read -r line; do
    [[ "$line" =~ ^src- ]] || continue
    if ! echo "$line" | grep -qE '^src-([\w-]+)(( +--\w+(=\S+)?)*) +\w+( +\S.*)?$'; then
      echo "  ${RED}❌ 不匹配官方正则: $line${RST}"
      local_rc=1
    fi
  done < feeds.conf
  [ "$local_rc" -eq 0 ] || die "feeds.conf 语法自检未通过"
  echo "  ${GRN}✓${RST} 全部行匹配官方正则"
fi

echo
echo "${GRN}✅ feeds.conf 已生成并通过校验${RST}: $SRC/feeds.conf"
echo
echo "feed 列表（供 scripts/feeds install -p 使用）："
grep '^src-' feeds.conf | awk '{print "  -p " $2}' | sed 's/^/  /'
