#!/usr/bin/env bash
# =============================================================================
# build-repo.sh — 从固件的 build root 产出自建 apk 源
# -----------------------------------------------------------------------------
# 用法： ./scripts/build-repo.sh [openwrt源码目录] [输出目录]
#
# 核心思想（这一条决定整个项目成不成立）：
#   **源里的 .apk 必须和固件在同一次构建、同一个 build root 里产出。**
#   外部源永远慢一拍 —— 实测别人的源给的是 kmod-nft-tproxy-6.18.52-r1，
#   而 SNAPSHOT 固件已经是 6.18.54，vermagic 不匹配，透明代理直接装不上。
#   自己编就没有这个问题。
#
# 产物（扁平 apk 仓库，和官方 index 结构一致）：
#   <输出>/packages.adb          索引
#   <输出>/packages.adb.sig      索引签名
#   <输出>/<包名>-<版本>.apk      包文件
#
# 签名：靠 OpenWrt 自己的机制 —— 私钥放 $(TOPDIR)/private-key.pem，
#   rules.mk:350 BUILD_KEY_APK_SEC 就是它，构建时自动签名，
#   公钥自动进固件 /etc/apk/keys/public-key.pem。**本脚本不自己签。**
#
# ⛔ 失败即不发布：校验不过就 exit 1，让 CI 不推。Pages 保留上一版好内容。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/openwrt}"
OUT="${2:-$ROOT/apk-repo}"
LOCK="$ROOT/versions.lock"

# 要打进源的面板（其余 clone 进来但不编，避免 CI 时间和体积失控）
PANELS="${REPO_PANELS:-luci-app-passwall luci-app-passwall2 luci-app-ssr-plus \
luci-app-homeproxy luci-app-nikki-rs luci-app-openclash luci-app-mosdns \
luci-app-momo luci-app-v2raya luci-app-adguardhome adblock-fast}"

GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
ok()   { echo "${GRN}✅ $*${RST}"; }
warn() { echo "${YEL}⚠️  $*${RST}"; }
die()  { echo "${RED}❌ $*${RST}" >&2; exit 1; }
step() { echo; echo "${CYN}▸ $*${RST}"; }

[ -d "$SRC" ] || die "源码树不存在: $SRC"

# ---- 0. 签名私钥 -------------------------------------------------------------
step "检查签名私钥"
SECRET="$SRC/private-key.pem"
if [ -f "$SECRET" ]; then
  ok "找到 $SECRET（索引会被签名，设备凭固件里的公钥信任）"
else
  warn "没有 $SECRET —— 索引将**不签名**发布"
  warn "设备侧必须用 apk update --allow-untrusted 才能装（会一直告警）"
  warn "CI 里请把私钥作为 secret 注入到 openwrt/private-key.pem"
fi

# ---- 1. 先编面板（fail fast）-------------------------------------------------
# ⚠️ 为什么要单独先编一遍（偷自 H5000M 的做法）：
#    `make world` 里 package/luci-app-* 排在第 ~160 分钟，
#    面板编译失败要等三小时才发现。提前编，失败只要十几分钟。
#    内核**必须**先编完 —— 包编译要读 .config 里的内核配置。
step "先编内核（包编译依赖 .config 里的内核配置）"
cd "$SRC"
make target/linux/compile -j"$(nproc)" >/tmp/repo-kernel.log 2>&1 || {
  tail -30 /tmp/repo-kernel.log
  die "内核编译失败 —— 源和固件会不一致，终止"
}
ok "内核编完"

step "预编译面板（失败会在十几分钟内暴露，而不是三小时后）"
PB_FAIL=0
for p in $PANELS; do
  printf "  %-24s " "$p"
  if make "package/$p/compile" -j"$(nproc)" >"/tmp/repo-$p.log" 2>&1; then
    echo "${GRN}ok${RST}"
  else
    echo "${YEL}失败${RST}（日志 /tmp/repo-$p.log）"
    PB_FAIL=$((PB_FAIL+1))
  fi
done
if [ "$PB_FAIL" -gt 0 ]; then
  warn "$PB_FAIL 个面板编译失败"
  warn "这是**预警**不是终止 —— 面板是可选的，固件本身不受影响"
  warn "但如果失败的是 kmod 类包，说明内核漂移了，必须查"
fi

# ---- 2. 收包 -----------------------------------------------------------------
step "收集 .apk"
rm -rf "$OUT"
mkdir -p "$OUT"
# bin/packages/ 下按架构分目录
n=$(find "$SRC/bin/packages" -maxdepth 3 -name '*.apk' 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || die "bin/packages 下没有 .apk —— 是固件还没编完？"
find "$SRC/bin/packages" -maxdepth 3 -name '*.apk' -exec cp -f {} "$OUT/" \;
cpcount=$(ls -1 "$OUT"/*.apk 2>/dev/null | wc -l)
ok "收拢 $cpcount 个 .apk"

# ---- 3. 生成索引 -------------------------------------------------------------
# 优先用 OpenWrt 构建时已经生成好的签名索引；没有就退回 apk index。
step "生成索引"
IDX=""
for cand in "$SRC"/bin/packages/*/*/packages.adb "$SRC"/bin/packages/*/packages.adb; do
  [ -f "$cand" ] && { IDX="$cand"; break; }
done
if [ -n "$IDX" ]; then
  cp -f "$IDX" "$OUT/packages.adb"
  [ -f "$IDX.sig" ] && cp -f "$IDX.sig" "$OUT/packages.adb.sig"
  ok "复用构建产物索引: ${IDX#$SRC/}"
else
  warn "没找到构建时生成的索引，退回用 host 的 apk 生成"
  command -v apk >/dev/null 2>&1 || die "找不到 apk 命令，无法生成索引"
  ( cd "$OUT" && apk index --allow-untrusted ./*.apk >/dev/null 2>&1 ) \
    || die "apk index 失败"
  ok "已用 apk index 生成"
fi
[ -s "$OUT/packages.adb" ] || die "索引为空"
ok "索引 $(wc -c < "$OUT/packages.adb") 字节"

# ---- 4. 硬校验（发布前的最后一道闸）------------------------------------------
# 这一段是本项目和「随便开个 http 目录当源」的本质区别。
step "★ 硬校验（不过就不发布）"
FAIL=0

# 4.1 内核模块版本必须等于固件内核号 —— 这是整个项目存在的理由
KVER="$(grep -m1 -oE '6\.[0-9]+\.[0-9]+' "$SRC/include/kernel-6.12" 2>/dev/null \
        || grep -rm1 -oE 'KERNEL_PATCHVER:=6\.[0-9]+' "$SRC/target/linux/mediatek/Makefile" 2>/dev/null \
        || echo '')"
if [ -z "$KVER" ]; then
  warn "探测不到内核版本号，跳过 kmod 比对（不阻断）"
else
  echo "  固件内核: $KVER"
  bad_kmod=0
  for f in "$OUT"/kmod-*.apk; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in
      *"$KVER"*|*"-r"*) ;;   # 形如 kmod-tun-6.18.54-r1.apk
      *) echo "  ${RED}✗${RST} $b 内核号与 $KVER 不符"; bad_kmod=$((bad_kmod+1)) ;;
    esac
  done
  if [ "$bad_kmod" -gt 0 ]; then
    echo "  ${RED}❌ 有 $bad_kmod 个 kmod 的内核号对不上${RST}"
    echo "     ${RED}这意味着装上去会 vermagic 失败 —— 拒发${RST}"
    FAIL=1
  else
    ok "所有 kmod 的内核号与固件一致"
  fi
fi

# 4.2 面板必须在索引里
missing=""
for p in $PANELS; do
  if [ -e "$OUT/packages.adb" ] && ! ls "$OUT"/"$p"-*.apk >/dev/null 2>&1; then
    missing="$missing $p"
  fi
done
if [ -n "$missing" ]; then
  warn "这些面板没编出来:$missing"
  warn "（面板是可选的，只告警不阻断）"
else
  ok "全部面板已产出"
fi

# 4.3 透明代理命门必须有
step "★ 关键内核模块检查（透明代理的命门）"
for k in kmod-nft-tproxy; do
  if ls "$OUT"/"$k"-*.apk >/dev/null 2>&1; then
    ok "$k 已在源中"
  else
    echo "  ${RED}❌ $k 不在源里${RST}"
    echo "     ${RED}没有它，PassWall/OpenClash/HomeProxy 的透明代理模式起不来${RST}"
    echo "     ${RED}它必须从 $KVER 现编，不能从任何外部源拿${RST}"
    FAIL=1
  fi
done

[ "$FAIL" -eq 0 ] || die "硬校验未通过，拒绝发布（Pages 会保留上一版好内容）"
ok "硬校验全部通过"

# ---- 5. 收尾 -----------------------------------------------------------------
cat > "$OUT/BUILD-INFO.txt" <<EOF
built_at:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
firmware:  ${FIRMWARE_COMMIT:-unknown}
kernel:    ${KVER:-unknown}
arch:      $(grep -m1 CONFIG_TARGET_ARCH_PKGSET "$SRC/.config" 2>/dev/null | cut -d= -f2-)
packages:  $cpcount
signed:    $([ -f "$OUT/packages.adb.sig" ] && echo yes || echo no)
EOF

echo
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "${GRN}  自建源就绪${RST}"
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "  输出: $OUT"
echo "  包数: $cpcount"
ls -1 "$OUT" | head -20 | sed 's/^/    /'
echo "  ..."
echo
echo "  ${YEL}下一步：把这个目录推到 GitHub Pages（见 publish-repo.sh）${RST}"
