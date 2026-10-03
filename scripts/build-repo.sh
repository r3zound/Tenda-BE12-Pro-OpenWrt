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
#   更狠的是：刷完机后官方 distfeeds.list 只有 4 个 feed、**没有 kmods feed**
#   （实测索引里 kmod 条目只有 3 个），也就是说**任何内核模块都装不了**。
#   自建源是唯一出路。
#
# 产物（扁平 apk 仓库）：
#   <输出>/packages.adb          索引
#   <输出>/packages.adb.sig      索引签名（若 apk mkndx 产出）
#   <输出>/<包名>-<版本>.apk      包文件
#
# =============================================================================
# 签名机制（全部来自 OpenWrt 源码实测，不是猜的）：
#   rules.mk:350              BUILD_KEY_APK_SEC = $(TOPDIR)/private-key.pem
#   rules.mk:351              BUILD_KEY_APK_PUB = $(TOPDIR)/public-key.pem
#   package/Makefile:87-96    索引：apk mkndx … $(if $(CONFIG_SIGNED_PACKAGES),--sign …)
#   package/base-files:127    公钥自动进镜像 /etc/apk/keys/
#
#   ⚠️ 三个必须知道的坑：
#   1. CONFIG_SIGNED_PACKAGES / SIGN_EACH_PACKAGE 默认都是 y，**我们没关**。
#   2. 如果 build root 里没有 private-key.pem，OpenWrt 会**自动生成一把
#      EC 临时密钥**（package/Makefile:91 `openssl ecparam -genkey`），
#      并把对应公钥打进固件。私钥当场丢弃 → 下次构建就是另一把钥匙，
#      老固件不再信任新源。**所以私钥必须是稳定的 CI secret。**
#   3. OpenWrt 原本的索引在 `package_merge_links` 里把各子目录的 .apk
#      **软链接**汇成一份扁平索引，产物是 bin/packages/<arch>/packages.adb。
#      同一个目录下还有 base/ luci/ routing/ 的**分 feed 索引**，
#      它们是那个扁平索引的**子集**，绝不能拿去发布。
#
# ⛔ 失败即不发布：校验不过就 exit 1，让 CI 不推。Pages 保留上一版好内容。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/openwrt}"
OUT="${2:-$ROOT/apk-repo}"
LOCK="$ROOT/versions.lock"

GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
ok()   { echo "${GRN}✅ $*${RST}"; }
warn() { echo "${YEL}⚠️  $*${RST}"; }
die()  { echo "${RED}❌ $*${RST}" >&2; exit 1; }
step() { echo; echo "${CYN}▸ $*${RST}"; }

[ -d "$SRC" ] || die "源码树不存在: $SRC"
[ -f "$LOCK" ] || die "找不到 $LOCK"
[ -f "$SRC/.config" ] || die "没有 $SRC/.config —— 固件还没生成配置？"

# ⚠️ 立刻把路径定成绝对路径。后面第 3 步会 `cd "$SRC"` 进 OpenWrt 树，
#    要是 OUT 还是相对的（CI 里传的是 ./apk-repo），产物就会落到
#    openwrt/apk-repo —— 后面 publish-repo.sh 和 artifact 上传全扑空，
#    而且**每一步都显示成功**（坑 9/10/11 的同款静默失败）。
SRC="$(cd "$SRC" && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
LOCK="$(cd "$(dirname "$LOCK")" && pwd)/$(basename "$LOCK")"

# ---- 面板清单：唯一真相源 = versions.lock --------------------------------------
# ⚠️⚠️ 这里曾经硬编码过一份面板名，和 versions.lock 完全对不上：
#       硬编码里有 luci-app-v2raya / luci-app-adguardhome / adblock-fast
#       —— 三个仓库**根本没 clone**；
#       而真正 clone 进来的 clash-rs / nekobox / hijpass / luci-app-xray /
#       openwrt-fchomo 又**一个都没编**。
#    副本清单必然会漂移。现在只认 versions.lock，一份就够。
#    （本项目的老教训：坑 1 / 坑 5 / 坑 12 / 坑 13 全是「抄了一份然后漂了」。）
step "解析面板清单"
if [ -n "${REPO_PANELS:-}" ]; then
  # 环境变量可以只编子集（调试用）
  # shellcheck disable=SC2206
  PANEL_DIRS=( $REPO_PANELS )
  ok "来自 REPO_PANELS（${#PANEL_DIRS[@]} 个）"
else
  PANEL_DIRS=()
  while IFS= read -r d; do
    [ -n "$d" ] && PANEL_DIRS+=( "$d" )
  done < <(grep -E '^REPO_PROXY_[A-Z0-9_]+=' "$LOCK" \
           | sed 's/^[^=]*=//' | cut -d'|' -f1 | grep -v '^[[:space:]]*$')
  ok "来自 versions.lock（${#PANEL_DIRS[@]} 个）"
fi
[ "${#PANEL_DIRS[@]}" -gt 0 ] || die "面板清单为空"

# ---- 从仓库 Makefile 里发现真正的包名 ----------------------------------------
# ⚠️ package/ 下的**目录名 ≠ OpenWrt 包名**：
#      目录 openwrt-passwall  里 define 的是 luci-app-passwall
#      目录 homeproxy        里 define 的是 luci-app-homeproxy
#      目录 luci-app-ssr-plus 里还额外 define 了 luci-app-ssr-subscriptions 等
#    拿目录名去 grep .apk 文件名，匹配不到任何东西 —— 而 `ls` 匹配不到会被
#    当成「面板缺失」告警，看起来像编译失败，其实是名字对不上。
#    顺带：kconfig 对不存在的符号既不报错也不警告，错了也是一路绿灯。
#
# ⚠️ 深度必须跟 OpenWrt 一致 = 5（include/toplevel.mk:106 SCAN_DIR="package"
#    SCAN_DEPTH=5）。实测 13 个面板仓库里 12 个的 Makefile 不在根目录：
#      openwrt-passwall → luci-app-passwall/Makefile      （深度 2）
#      coolsnowwolf/luci → applications/<pkg>/Makefile     （深度 3）
#    用 maxdepth 2 会漏掉 coolsnowwolf/luci 那一类，症状是「面板缺失」告警。
discover_pkgs() { # $1=package/ 下的目录
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 5 -name Makefile -type f 2>/dev/null | while IFS= read -r mf; do
    # 只认行首 define（允许前导空白）；被 # 注释掉的包不会命中
    grep -hoE '^[[:space:]]*define[[:space:]]+Package/[A-Za-z0-9._+-]+' "$mf" 2>/dev/null \
      | sed -E 's@.*/Package/@@; s@.*[[:space:]]Package/@@'
  done | sort -u
}

step "发现各仓库的真实包名"
PKGS_OF=()      # "目录=包1 包2 ..."
ALL_PKGS=()
for d in "${PANEL_DIRS[@]}"; do
  tgt="$SRC/package/$d"
  if [ ! -d "$tgt" ]; then
    warn "$d 还没 clone（先跑 fetch-proxy-packages.sh）"
    continue
  fi
  mapfile -t pk < <(discover_pkgs "$tgt")
  if [ "${#pk[@]}" -eq 0 ]; then
    warn "$d 里没找到 define Package/ —— 上游结构变了？"
    continue
  fi
  echo "  ${CYN}$d${RST} → ${pk[*]}"
  PKGS_OF+=( "$d=${pk[*]}" )
  ALL_PKGS+=( "${pk[@]}" )
done
[ "${#ALL_PKGS[@]}" -gt 0 ] || die "一个包名都没发现出来 —— 面板仓库结构变了，先人工看一眼"
ok "共发现 ${#ALL_PKGS[@]} 个包定义"

# 跨仓库重名会让 kconfig 里后者覆盖前者，必须报出来
dup="$(printf '%s\n' "${ALL_PKGS[@]}" | sort | uniq -d || true)"
if [ -n "$dup" ]; then
  warn "以下包名被多个仓库重复定义，kconfig 会取最后一个："
  printf '     %s\n' $dup
fi

# ---- 0. 签名私钥（硬性要求）--------------------------------------------------
step "检查签名私钥"
SECRET="$SRC/private-key.pem"
if [ ! -f "$SECRET" ]; then
  if [ "${ALLOW_UNSIGNED_REPO:-0}" = "1" ]; then
    warn "没有 $SECRET，但设了 ALLOW_UNSIGNED_REPO=1 —— 索引不签名发布"
    warn "设备侧必须 apk update --allow-untrusted，且每次都告警"
    SIGN_ARG=()
  else
    echo "${RED}❌ 缺少签名私钥 $SECRET —— 拒绝发布${RST}"
    echo "   没有它，OpenWrt 会现场生成一把 EC 临时密钥（package/Makefile:91），"
    echo "   私钥当场丢弃：这次编的固件认这次编的源，下次构建就互不认了。"
    echo "   CI 里请注入 secret TENDO_REPO_PRIVATE_KEY 到 openwrt/private-key.pem。"
    echo "   本地试验可以 ALLOW_UNSIGNED_REPO=1 放行。"
    exit 1
  fi
else
  ok "找到 $SECRET"
  SIGN_ARG=( --sign "$SECRET" )
fi

APKBIN="$SRC/staging_dir/host/bin/apk"
[ -x "$APKBIN" ] || die "找不到构建用的 apk: $APKBIN"

# ---- 1. 内核必须先编完 -------------------------------------------------------
# ⚠️ 包编译要读 .config 里的内核配置，kmod 更是直接依赖内核树。
step "确保内核已编完（包编译依赖它）"
cd "$SRC"
if [ ! -f "$SRC/.config" ]; then die "没有 .config"; fi
make target/linux/compile -j"$(nproc)" >/tmp/repo-kernel.log 2>&1 || {
  tail -30 /tmp/repo-kernel.log
  die "内核编译失败 —— 源和固件会不一致，终止"
}
ok "内核就绪"

# ---- 2. 把面板挂成 =m（只编不装进镜像）--------------------------------------
# ⚠️⚠️ 这一步是**必须的**，不是可选优化：
#    OpenWrt 对「没被选中的包」只生成 BuildTarget/ipkg/disabled，
#    那个目标**只有 clean 规则、没有 compile 规则**。
#    也就是说 `make package/xxx/compile` 会直接报 "No rule to make target"，
#    而面板又不进 .config（base.config 明确排除 mwan3/passwall/sing-box/xray，
#    CI 步骤 15 还断言它们不能 =y）。
#    =m 是正解：进 .config 让 make 认这个包，连带把依赖一起编出来，
#    但**不会**被打进固件镜像，体积守卫也不受影响。
#    （.config 是在固件已经编完之后才改的，不会回头重建镜像。）
step "把面板挂进 .config（=m：只编不装进镜像）"
cp .config /tmp/config.before-panels
: > /tmp/panel-pkgs.txt
printf '%s\n' "${ALL_PKGS[@]}" | sort -u > /tmp/panel-pkgs.txt
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # 已有显式配置的（=y / =n）不动
  if grep -qE "^CONFIG_PACKAGE_${p}=[^m]" .config; then continue; fi
  echo "CONFIG_PACKAGE_${p}=m"
done < /tmp/panel-pkgs.txt >> .config
echo "  新增 $(grep -cE '^CONFIG_PACKAGE_[A-Za-z0-9._+-]+=m$' .config) 个 =m 符号"
make defconfig >/tmp/defconfig.log 2>&1 || { tail -20 /tmp/defconfig.log; die "make defconfig 失败"; }

MISSING_M=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  grep -qE "^CONFIG_PACKAGE_${p}=" .config || { warn "$p 没进 .config（kconfig 把它丢了）"; MISSING_M=$((MISSING_M+1)); }
done < /tmp/panel-pkgs.txt
ok "面板符号就位（丢失 $MISSING_M 个）"

# ---- 3. 预编译面板（fail fast）----------------------------------------------
# ⚠️ 为什么要单独先编一遍（偷自 H5000M 的做法）：
#    `make world` 里 package/luci-app-* 排在第 ~160 分钟，
#    面板编译失败要等三小时才发现。提前编，失败只要十几分钟。
step "预编译面板"
PB_FAIL=0
for d in "${PANEL_DIRS[@]}"; do
  [ -d "$SRC/package/$d" ] || continue
  printf "  %-22s " "$d"
  if make "package/$d/compile" -j"$(nproc)" >"/tmp/repo-$d.log" 2>&1; then
    echo "${GRN}ok${RST}"
  else
    echo "${YEL}失败${RST}（/tmp/repo-$d.log）"
    tail -5 "/tmp/repo-$d.log" | sed 's/^/      /'
    PB_FAIL=$((PB_FAIL+1))
  fi
done
if [ "$PB_FAIL" -gt 0 ]; then
  warn "$PB_FAIL 个面板编译失败"
  warn "这是**预警**不是终止 —— 面板是可选的，固件本身不受影响"
fi

# ---- 4. 收包（扁平，检测重名冲突）--------------------------------------------
step "收集 .apk"
ARCH="$(grep -m1 '^CONFIG_TARGET_ARCH_PKGSET=' "$SRC/.config" | cut -d= -f2-)"
[ -n "$ARCH" ] || die "读不出 CONFIG_TARGET_ARCH_PKGSET"
PDIR="$SRC/bin/packages/$ARCH"
[ -d "$PDIR" ] || die "没有 $PDIR —— 固件还没编完？"

rm -rf "$OUT"; mkdir -p "$OUT"
COLL=0
while IFS= read -r f; do
  b="$(basename "$f")"
  if [ -e "$OUT/$b" ]; then
    cmp -s "$f" "$OUT/$b" || { echo "  ${RED}重名不同内容${RST} $b"; COLL=$((COLL+1)); }
  else
    cp -f "$f" "$OUT/$b"
  fi
done < <(find "$PDIR" -name '*.apk' -type f | sort)
CPCOUNT="$(ls -1 "$OUT"/*.apk 2>/dev/null | wc -l | tr -d ' ')"
[ "$CPCOUNT" -gt 0 ] || die "一个 .apk 都没收到"
ok "收拢 $CPCOUNT 个 .apk（$ARCH）"
[ "$COLL" -eq 0 ] || warn "$COLL 个重名文件内容不同，取了先遇到的那个"

# ---- 5. 自己生成 + 签名索引 --------------------------------------------------
# ⚠️⚠️ 为什么不用构建产物里现成的索引：
#    bin/packages/<arch>/ 下同时躺着
#       packages.adb      ← 扁平总索引（package_merge_links 软链接汇总）
#       base/packages.adb ← 只有 base feed 的子集
#       luci/packages.adb ← 只有 luci feed 的子集
#    设备实测 distfeeds.list 里这 4 个 URL 全都存在，很容易顺手 grab 到子集，
#    表现是「源里只有几十个包，面板和 kmod 全部 not available」。
#    自己 mkndx 就只认 $OUT 里这一份文件，索引与包一一对应，不可能对不上。
step "生成并签名索引（apk mkndx）"
( cd "$OUT" && "$APKBIN" mkndx \
    --root "$SRC" \
    --keys-dir "$SRC" \
    --allow-untrusted \
    "${SIGN_ARG[@]}" \
    --output packages.adb \
    *.apk ) >/tmp/mkndx.log 2>&1 || { cat /tmp/mkndx.log; die "apk mkndx 失败"; }
[ -s "$OUT/packages.adb" ] || die "索引为空"
ok "索引 $(wc -c < "$OUT/packages.adb") 字节"

# 签名是否**真的生效**了 —— 退出码 0 不代表签名写进去了。
# ⚠️ 为什么专门查这个：设备上的 apk（运行时版）根本没有 mkndx 子命令
#    （只有 add/del/update/install… 那几个），本地无法预演；
#    而 OpenWrt 默认生成的是 EC prime256v1 密钥，本项目用的是 RSA 3072，
#    这条路径上游自己从不走，属于「没验证过的假设」。
#    --sign 静默失败是最危险的：发布出去一个没签名的索引，
#    设备只会说 UNTRUSTED，而 Pages 上上一版好内容已经被覆盖了。
#    判据：同一批包签与不签，产物必须不同。相同 = --sign 没起作用 = 拒发。
if [ -n "$SECRET" ]; then
  ( cd "$OUT" && "$APKBIN" mkndx \
      --root "$SRC" --keys-dir "$SRC" --allow-untrusted \
      --output /tmp/unsigned-probe.adb \
      *.apk ) >/tmp/mkndx2.log 2>&1 || true
  if [ -f /tmp/unsigned-probe.adb ] && cmp -s "$OUT/packages.adb" /tmp/unsigned-probe.adb; then
    echo "  ${RED}❌ 签名索引和不签名索引逐字节相同 —— --sign 没有生效${RST}"
    die "拒绝发布一个没签名的索引（否则设备只会报 UNTRUSTED，Pages 还会被覆盖）"
  fi
  ok "签名确实生效（与不签名的产物不同）"
  rm -f /tmp/unsigned-probe.adb
fi

if [ -f "$OUT/packages.adb.sig" ]; then
  ok "签名文件 packages.adb.sig 已生成"
else
  echo "  ${YEL}·${RST} 没有独立的 packages.adb.sig（签名很可能内嵌在 adb 里，正常）"
fi

if "$APKBIN" adbdump --format json "$OUT/packages.adb" >/tmp/idx.json 2>/dev/null; then
  IDXCOUNT="$(grep -c '"name"' /tmp/idx.json || true)"
  ok "索引内含 $IDXCOUNT 个包条目"
  # 索引和包必须对得上：源里躺着的包却不在索引里，设备照样装不上
  if [ "$IDXCOUNT" -lt "$(( CPCOUNT * 90 / 100 ))" ]; then
    echo "  ${YEL}·${RST} 索引条目 $IDXCOUNT 明显少于包数 $CPCOUNT，查一下"
  fi
else
  warn "adbdump 解析不了索引（apk 版本差异），跳过条目数检查"
fi

# ---- 6. 硬校验（发布前的最后一道闸）------------------------------------------
step "★ 硬校验（不过就不发布）"
FAIL=0

# 6.1 内核模块版本必须等于固件内核号 —— 这是整个项目存在的理由
KVER=""
for cand in \
    "$SRC"/build_dir/target-*_generic*/linux-mediatek_mt7987a/linux-* \
    "$SRC"/build_dir/target-*/linux-*/linux-* ; do
  [ -d "$cand" ] && { KVER="$(basename "$cand" | sed 's/^linux-//')"; break; }
done
if [ -z "$KVER" ]; then
  KVER="$(grep -rm1 -oE 'linux-[0-9]+\.[0-9]+\.[0-9]+' "$SRC/target/linux/mediatek/Makefile" 2>/dev/null | head -1 | sed 's/^linux-//')"
fi
if [ -z "$KVER" ]; then
  die "探测不到内核版本号 —— 无法做 kmod 比对，拒绝发布（宁可不发也不发错的）"
fi
echo "  固件内核: $KVER"

BADKMOD=0; KMODN=0
for f in "$OUT"/kmod-*.apk; do
  [ -e "$f" ] || continue
  KMODN=$((KMODN+1))
  b="$(basename "$f")"
  # ⚠️ 原来这里写的是 case "$b" in *"$KVER"*|*-r*) —— 而 .apk 文件名几乎
  #    都带 "-r1"（如 kmod-tun-6.18.54-r1.apk），第二个分支永远命中，
  #    整条校验形同虚设。只能留一个分支。
  case "$b" in
    *"$KVER"*) ;;
    *) echo "  ${RED}✗${RST} $b 内核号与 $KVER 不符"; BADKMOD=$((BADKMOD+1)) ;;
  esac
done
echo "  检查了 $KMODN 个 kmod"
if [ "$BADKMOD" -gt 0 ]; then
  echo "  ${RED}❌ $BADKMOD 个 kmod 内核号对不上 —— 装上去必然 vermagic 失败，拒发${RST}"
  FAIL=1
else
  ok "全部 kmod 内核号与固件一致"
fi

# 6.2 透明代理命门必须有（设备刷完机装不了任何 kmod，全指望这个源）
step "★ 关键内核模块检查（透明代理的命门）"
for k in kmod-nft-tproxy; do
  if ls "$OUT"/"$k"-*.apk >/dev/null 2>&1; then
    ok "$k 已在源中"
  else
    echo "  ${RED}❌ $k 不在源里${RST}"
    echo "     ${RED}没有它，PassWall/OpenClash/HomeProxy 的透明代理模式起不来${RST}"
    echo "     ${RED}而刷完机后官方 distfeeds 里根本没有 kmods feed，只能从这个源拿${RST}"
    echo "     ${RED}它必须用 $KVER 现编，不能从任何外部源拿${RST}"
    FAIL=1
  fi
done

# 6.3 面板产出情况（只告警不阻断：面板可选，固件本身不受影响）
MISSING=""
for d in "${PANEL_DIRS[@]}"; do
  hit=0
  for spec in "${PKGS_OF[@]}"; do
    [ "${spec%%=*}" = "$d" ] || continue
    for p in ${spec#*=}; do
      ls "$OUT"/"$p"-*.apk >/dev/null 2>&1 && hit=1
    done
  done
  [ "$hit" -eq 1 ] || MISSING="$MISSING $d"
done
if [ -n "$MISSING" ]; then
  warn "这些面板没产出 .apk:$MISSING"
  warn "（面板可选，只告警不阻断）"
else
  ok "全部面板已产出"
fi

[ "$FAIL" -eq 0 ] || die "硬校验未通过，拒绝发布（Pages 会保留上一版好内容）"
ok "硬校验全部通过"

# ---- 7. 收尾 -----------------------------------------------------------------
cat > "$OUT/BUILD-INFO.txt" <<EOF
built_at:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
branch:    ${REPO_BRANCH:-unknown}
firmware:  ${FIRMWARE_COMMIT:-unknown}
kernel:    $KVER
arch:      $ARCH
packages:  $CPCOUNT
kmods:     $KMODN
index:     $(wc -c < "$OUT/packages.adb") bytes
signed:    $([ -n "$SECRET" ] && echo yes || echo no)
EOF

echo
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "${GRN}  自建源就绪${RST}"
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "  输出: $OUT"
echo "  包数: $CPCOUNT   kmod: $KMODN   内核: $KVER"
ls -1 "$OUT" | head -15 | sed 's/^/    /'
echo "    ..."
echo
echo "  ${YEL}下一步：publish-repo.sh 把这个目录推到 GitHub Pages${RST}"
