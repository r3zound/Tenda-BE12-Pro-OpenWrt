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
N_ARGONCFG=$(get FEED_NAME_ARGON_CFG);    ARGFG_REPO=$(get ARGON_CFG_REPO);   ARGFG_COMMIT=$(get ARGON_CFG_COMMIT)
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
validate_feed_name "luci"           "LUCI_REPO"             || FAIL=1
validate_feed_name "packages"       "PACKAGES_REPO"         || FAIL=1
validate_feed_name "$N_ARGON"       "FEED_NAME_THEME_ARGON"  || FAIL=1
validate_feed_name "$N_AURORA"      "FEED_NAME_THEME_AURORA" || FAIL=1
validate_feed_name "$N_ARGONCFG"   "FEED_NAME_ARGON_CFG"    || FAIL=1
validate_feed_name "$N_FRP"         "FEED_NAME_FRP_LUCI"     || FAIL=1
echo
validate_sha "$OPENWRT_COMMIT"  "openwrt"       || true
validate_sha "$LUCI_COMMIT"     "luci"          || true
validate_sha "$PACKAGES_COMMIT" "packages"      || true
validate_sha "$ARGON_COMMIT"    "argon"         || true
validate_sha "$AURORA_COMMIT"   "aurora"        || true
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
# ⚠️ 三条铁律（违反任何一条都会 Syntax error 或 git 报错）：
#    1) feed 名只允许 [A-Za-z0-9_] —— 禁止连字符
#    2) 禁止引号 —— 官方 split /\s+/ 不剥引号，"https 会被当成 URL 字面量
#    3) 禁止裸 '#' 空注释行 —— 官方 s/#.+$/ 需 # 后至少一个字符
# 
# ref 语法（scripts/feeds 第 227-228 行）：
#    分支用分号  src-git foo https://host/repo.git;main
#    commit 用 ^  src-git foo https://host/repo.git^<40位SHA>   ← 本项目用这个
# 
# 改 feed 名时同步改 versions.lock 的 FEED_NAME_* 键。
# ============================================================================

# ---- 官方 feeds（锁定 commit）---------------------------------------------
src-git luci $LUCI_REPO^$LUCI_COMMIT
src-git packages $PACKAGES_REPO^$PACKAGES_COMMIT

# ---- LuCI 主题（第三方，官方主线不含）-------------------------------------
src-git $N_ARGON $ARGON_REPO^$ARGON_COMMIT
src-git $N_AURORA $AURORA_REPO^$AURORA_COMMIT
src-git $N_ARGONCFG $ARGFG_REPO^$ARGFG_COMMIT

# ---- 应用 -----------------------------------------------------------------
src-git $N_FRP $FRP_REPO^$FRP_COMMIT

# ---- 刻意不引入 -----------------------------------------------------------
# mwan3   —— 见 README §4.3。官方 mwan3 是 iptables 实现，在 fw4/nftables 上
#            负载均衡已失效；且含 mwan3 的 sysupgrade 会静默装回失效版本。
#            改用 dl12345/mwan3 原生 nft 移植版，刷机后单独安装。
# passwall —— 已按需求移除（体积超限）。见 README §4.6。
# base-files —— 不是独立 feed，就在 openwrt 主仓 package/base-files 内。
#            官方 feeds.conf.default 中亦无此项，勿加。
# luci-theme-edge —— 已移除。唯一可用的源 zhucemax/openwrt-packages 是含数百个
#            包的大杂烩仓库（openclash/ssr-plus/xray-core/v2ray-geodata…），
#            全量安装会撑爆 rootfs，且其自带的 2019 版 luci-theme-argon 会与
#            本仓库的 2.4.7 冲突。详见 versions.lock 注释。
EOF

# ---- 语法校验：忠实复刻 OpenWrt scripts/feeds 的解析语义 -------------------
# 官方解析逻辑（scripts/feeds 的 parse_file 函数）：
#     chomp; s/#.+$//; next unless /\S/;
#     m!^src-([\w\-]+)((?:\s+--\w+(?:=\S+)?)*)\s+(\w+)(?:\s+(\S.*))?$!
#     否则 die "Syntax error in $fname, line $line"
#
# ⚠️ 三个已踩过的坑，都由本校验拦截：
#   1) feed 名含连字符 → (\w+) 匹配失败 → exit 25
#   2) 裸 "#" 行       → s/#.+$// 要求 # 后至少一个字符，孤立 # 不会被剥掉，
#                        于是被当作有效行送进主正则 → Syntax error
#   3) URL 两侧加引号   → split /\s+/ 不剥引号，git 收到 '"https' → 
#                        fatal: protocol '"https' is not supported
#   （ref 必须用 ^ (commit) 或 ; (branch) 分隔，见第 227-228 行）
echo
echo "${CYN}▸ 语法校验（复刻官方解析语义）${RST}"

if perl - feeds.conf <<'PERLCHK'
use strict; use warnings;
my $file = shift;
open(my $fh, '<', $file) or die "cannot open $file: $!";
my $line = 0; my @errs; my $n = 0;
while (my $raw = <$fh>) {
    chomp $raw;
    my $orig = $raw;
    $raw =~ s/#.+//;
    $line++;
    next if $raw !~ /\S/;
    my ($type, $flags, $name, $urls) =
        $raw =~ m!^src-([\w\-]+)((?:\s+--\w+(?:=\S+)?)*)\s+(\w+)(?:\s+(\S.*))?$!;
    if (!$type || !$name) {
        my $why = ($orig =~ /^#\s*$/)
            ? '裸 "#" 行 —— 官方 s/#.+$/ 不匹配，会被当作有效行'
            : '不匹配官方正则（检查 feed 名是否含连字符）';
        push @errs, "  line $line: $why\n            -> $orig";
        next;
    }
    $n++;
    if ($orig =~ /["']/) {
        push @errs, "  line $line: 含引号 —— 官方 split on whitespace 不剥引号，引号会进 URL\n            -> $orig";
    }
    if ($urls && $urls !~ m![\^;]!) {
        push @errs, "  line $line: ref 未用 ^ (commit) 或 ; (branch) 分隔\n            -> $orig";
    }
}
close $fh;
if (@errs) {
    print STDERR "  found " . scalar(@errs) . " syntax error(s):\n";
    print STDERR join("\n", @errs), "\n";
    exit 1;
}
print "  [OK] $n feed definition(s) passed\n";
exit 0;
PERLCHK
then
  echo "  ${GRN}OK${RST} 语法校验通过"
else
  echo
  echo "  ${RED}feeds.conf 存在语法错误${RST}"
  echo "  ${RED}铁律 1: feed 名只允许 [A-Za-z0-9_]，禁止连字符${RST}"
  echo "  ${RED}铁律 2: 禁止写裸 '#' 空注释行（官方 s/#.+\x2f// 不匹配）${RST}"
  die "feeds.conf 语法校验未通过"
fi

echo "${GRN}✅ feeds.conf 已生成并通过校验${RST}: $SRC/feeds.conf"
echo
echo "feed 列表（供 scripts/feeds install -p 使用）："
grep '^src-' feeds.conf | awk '{print "  -p " $2}' | sed 's/^/  /'
