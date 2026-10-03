#!/usr/bin/env bash
# =============================================================================
# verify-firmware.sh — 固件内容抽查
# -----------------------------------------------------------------------------
# 编译成功 ≠ 内容正确。
#
# 本项目连续两轮构建都遇到「CI 全绿、体积守卫也过，但固件内容不对」：
#
#   ① 三个 LuCI 主题（argon / aurora / argon-config）没进固件。
#      原因：这些仓库的 Makefile 在根目录，而 include/scan.mk 用
#      `find -L feeds/<名字> -mindepth 1 -name Makefile` 扫描，
#      根目录被排除 → 索引为空 → .config 里没有符号 → kconfig 不报错。
#
#   ② 全部预置文件没进固件：/etc/config/network、/etc/uci-defaults/
#      99-tenda-custom、/usr/lib/tenda/install-mwan3.sh 全都不在。
#      刷完是官方默认 192.168.1.1，双 WAN 接口划分和 mwan3 助手都没有。
#      （OpenWrt 根本没有 FILES_DIR 这种注入机制，必须做成包）
#
# 这两个问题看 CI 绿不绿、看守卫生不通过，**都发现不了**。
# 只有把 squashfs 真正解开、看里面的文件才能发现。
#
# 用法： ./scripts/verify-firmware.sh [openwrt源码目录]
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/stamp.sh
. "$ROOT/scripts/lib/stamp.sh"
SRC="${1:-$ROOT/openwrt}"
BIN="$SRC/bin/targets/mediatek/filogic"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'

echo "═══════════════════════════════════════════════════════════"
echo " 固件内容抽查"
echo "═══════════════════════════════════════════════════════════"
echo

# ---- 1. 准备 unsquashfs -----------------------------------------------------
# shellcheck source=scripts/lib/ensure-unsquashfs.sh
USQ="$(source "$ROOT/scripts/lib/ensure-unsquashfs.sh" && _ensure)" || {
  echo "${RED}❌ 拿不到 unsquashfs，无法抽查${RST}"
  exit 2
}
echo "  unsquashfs: $USQ"

# ---- 2. 取出 rootfs 分片 ---------------------------------------------------
# ⚠️ 用解析函数而不是写死文件名 —— stamp-firmware.sh 会加 -YYYYMMDD.HHMM 后缀。
#    写死的后果特别隐蔽：这里「找不到文件」就 exit 2，
#    而 build.yml 里这一步失败会让整轮固件白跑八十多分钟。
IMG="$(find_sysupgrade_bin "$BIN")" || {
  echo "${RED}❌ 未找到 sysupgrade 镜像: $BIN${RST}"
  echo "   目录里现有："; ls -1 "$BIN" 2>/dev/null | sed "s/^/     /"
  exit 2
}
echo "  镜像: $(basename "$IMG")"

tar -xf "$IMG" -C "$TMPD" 2>/dev/null
ROOTFS="$(find "$TMPD" -type f -name root 2>/dev/null | head -1)"
[ -n "$ROOTFS" ] || {
  echo "${RED}❌ 镜像里找不到 rootfs 分片${RST}"
  echo "   镜像结构: $(tar -tf "$IMG" 2>/dev/null | head -5 | tr '\n' ' ')"
  exit 2
}

# ---- 3. 解包 squashfs ------------------------------------------------------
# ⚠️⚠️ 不要用 unsquashfs 的退出码判断成败。
#    实测（Run #13）：解包完全成功、产物齐全（1411 个文件 / 40MB），
#    但 unsquashfs 仍然返回非 0 —— 它把末尾的告警也计进退出码。
#    早期版本这里写 `|| { echo 解包失败; exit 2; }`，于是明明解包成功
#    却被判为失败，整个构建白跑。
#    正确判据是**产物本身**：目录建出来了没有、文件数够不够。
#
extract_ok() {
	local dst="$1" tool="$2" n
	rm -rf "$dst"
	"$tool" -f -d "$dst" "$ROOTFS" >/dev/null 2>&1 || true
	[ -d "$dst" ] || return 1
	n="$(find "$dst" -type f 2>/dev/null | wc -l)"
	[ "$n" -ge 50 ] || return 1
	# 再抽查一个标志性文件，避免解出一堆空壳
	[ -e "$dst/etc/uci-defaults" ] || [ -e "$dst/usr/lib" ] || return 1
	return 0
}

DST="$TMPD/rootfs"
if ! extract_ok "$DST" "$USQ"; then
  echo "  ${YEL}⚠️  $USQ 解包结果不可用，尝试从源码编译一个完整的 unsquashfs${RST}"
  rm -rf "$DST"
  # 强制走源码编译路径
  if ( source "$ROOT/scripts/lib/ensure-unsquashfs.sh" && _ensure --build ) >/tmp/usq2.txt 2>/dev/null; then
    USQ2="$(tail -1 /tmp/usq2.txt)"
    if [ -n "$USQ2" ] && extract_ok "$DST" "$USQ2"; then
      USQ="$USQ2"
      echo "  ${GRN}✓${RST} 改用 $USQ"
    fi
  fi
fi

if [ ! -d "$DST" ] || [ "$(find "$DST" -type f 2>/dev/null | wc -l)" -lt 50 ]; then
  echo "${RED}❌ 无法解开 squashfs${RST}"
  echo "   unsquashfs: $USQ"
  "$USQ" -s "$ROOTFS" 2>&1 | head -20
  exit 2
fi

R="$DST"
echo "  解包完成: $(find "$R" -type f | wc -l) 个文件，$(du -sm --apparent-size "$R" | cut -f1) MB"
echo

FAIL=0
ok_()   { echo "    ${GRN}✅${RST} $1"; }
bad_()  { echo "    ${RED}❌${RST} $1"; FAIL=1; }
warn_() { echo "    ${YEL}⚠️ ${RST} $1"; }

# ---- 3. 必须存在的文件 -----------------------------------------------------
echo "  ${CYN}【必须存在】${RST}"
while IFS='|' read -r label path; do
  [ -z "${label:-}" ] && continue
  if [ -e "$R/$path" ]; then ok_ "$label"; else bad_ "$label  ($path)"; fi
done <<'EOF'
预置网段+双WAN /etc/config/network|/etc/config/network
首次启动脚本 99-tenda-custom|/etc/uci-defaults/99-tenda-custom
mwan3 安装助手|/usr/lib/tenda/install-mwan3.sh
bootstrap 主题|/www/luci-static/bootstrap
argon 主题|/www/luci-static/argon
aurora 主题|/www/luci-static/aurora
frpc 守护进程|/usr/bin/frpc
frpc LuCI 配置|/etc/config/frpc
EOF

# ---- 3.1 版本标识：这里才是真正的判据 ---------------------------------------
# ⚠️⚠️ 校验版本串**只能在这里做**，不能在 .config 里查。
#    之前两次都栽在 .config 上（Run #20 / #21）：
#      往 .config 写 CONFIG_VERSION_CODE → defconfig 静默删掉
#      写 CONFIG_VERSIONOPT=y → 也被 defconfig 改写成 "is not set"
#    因为那个菜单块是 `if IMAGEOPT` 的，IMAGEOPT 不开就是不可见的，
#    不可见的 bool 会被强制回默认值，而日志里一切看着正常。
#    现在改走 REVISION 环境变量（include/toplevel.mk:13 官方支持），
#    产物只能到这里验 —— 而且这里验的正是**用户会看到的那一串**。
echo
echo "  ${CYN}【版本标识】${RST}"
REL="$R/etc/openwrt_release"
VERF="$R/etc/openwrt_version"
if [ ! -f "$REL" ]; then
  bad_ "固件里没有 /etc/openwrt_release"
elif [ -z "${REVISION:-}" ]; then
  warn_ "REVISION 未设置（本地跑抽查脚本时正常，CI 里必须有）"
  echo "      当前固件里的实际内容："
  sed 's/^/        /' "$REL" | head -8
else
  echo "    期望含: $REVISION"
  if grep -qF "$REVISION" "$REL"; then
    ok_ "openwrt_release 里有本次构建的版本标识"
    grep -E "^DISTRIB_(RELEASE|REVISION|DESCRIPTION)" "$REL" | sed 's/^/      /'
  else
    bad_ "openwrt_release 里没有 $REVISION —— 版本串没生效"
    echo "      实际内容："
    sed 's/^/        /' "$REL" | head -8
  fi
  if [ -f "$VERF" ] && grep -qF "$REVISION" "$VERF"; then
    ok_ "openwrt_version 里有本次构建的版本标识"
  elif [ -f "$VERF" ]; then
    bad_ "openwrt_version 里没有 $REVISION（内容: $(cat "$VERF" 2>/dev/null)）"
  fi
  # 反向：不能只剩光秃秃的 git revision，说明 REVISION 没注入成功
  if grep -qE "DISTRIB_DESCRIPTION='[^']*SNAPSHOT r[0-9]+-[0-9a-f]+'$" "$REL" 2>/dev/null; then
    bad_ "版本串只有上游 revision，没有我们的时间戳 —— REVISION 注入失败"
  fi
  # 文件名前后缀不能撞车：IMG_PREFIX_VERCODE 生效时文件里会出现两段日期
  if grep -qE "[0-9]{8}\.[0-9]{4}-.*-[0-9]{8}\.[0-9]{4}" "$REL" 2>/dev/null; then
    bad_ "版本串里出现了两段日期 —— CONFIG_VERSION_CODE_FILENAMES 被打开了"
  fi
fi

# ---- 4. 预置内容抽查（不只看文件在不在，内容也要对）-----------------------
echo
echo "  ${CYN}【预置内容】${RST}"
if [ -f "$R/etc/config/network" ]; then
  grep -q "192\.168\.100\.254" "$R/etc/config/network" \
    && ok_ "LAN 地址 = 192.168.100.254" \
    || bad_ "LAN 地址不是 192.168.100.254"
  grep -q "lan3" "$R/etc/config/network" \
    && ok_ "含 lan3（移动 WAN2 接口）" \
    || bad_ "缺 lan3 —— 双 WAN 接口划分没生效"
  grep -q "eth2" "$R/etc/config/network" \
    && ok_ "含 eth2（电信 WAN1 接口）" \
    || bad_ "缺 eth2 —— WAN1 接口没生效"
else
  bad_ "读不到 /etc/config/network，无法校验预置内容"
fi

if [ -f "$R/etc/uci-defaults/99-tenda-custom" ]; then
  head -1 "$R/etc/uci-defaults/99-tenda-custom" | grep -q '^#!' \
    && ok_ "99-tenda-custom 有 shebang（会执行）" \
    || bad_ "99-tenda-custom 缺 shebang，不会被执行"
  # CRLF 会让 sh 报 $'\r': command not found
  grep -qU $'\r' "$R/etc/uci-defaults/99-tenda-custom" \
    && bad_ "99-tenda-custom 含 CRLF 换行 —— 在设备上会执行失败" \
    || ok_ "99-tenda-custom 换行符正常（LF）"

  # ⚠️ shell 语法检查。这个不能省：
  #    uci-defaults 里用了 <<-UCI（带横杠才剥 TAB，同时允许 $变量 展开）。
  #    一旦误写成 <<UCI，结束符必须顶格，而脚本里是缩进的 → 结束符不匹配 →
  #    shell 一直读到 EOF → "Syntax error: end of file unexpected"，
  #    整个首次启动配置**静默不执行**，设备起来是半成品。
  #    这类错误在设备上极难排查，sh -n 一秒就能抓到。
  if sh -n "$R/etc/uci-defaults/99-tenda-custom" 2>/tmp/shn.err; then
    ok_ "99-tenda-custom shell 语法正确"
  else
    bad_ "99-tenda-custom 存在 shell 语法错误：$(head -1 /tmp/shn.err)"
  fi

  # 顺带确认 heredoc 结束符写法没踩坑
  if grep -qE "<<[A-Za-z_]+[^ -]" "$R/etc/uci-defaults/99-tenda-custom" \
     && grep -q $'^\t\+' <<<"$(grep -nE '<<[A-Za-z_]+' "$R/etc/uci-defaults/99-tenda-custom" | head -1)"; then
    warn "  提示：存在 <<WORD（不带 -）且内容有缩进，确认结束符是顶格的"
  fi

  # ---- 预置内容（uci batch）必须真的写进去了 ----
  # dhcp / firewall / dropbear / system 改由这个脚本在首次开机时下发，
  # 所以检查点从「文件是否存在」变成了「脚本里有没有对应的 uci 语句」。
  while IFS='|' read -r what needle; do
    [ -z "${what:-}" ] && continue
    grep -qF -- "$needle" "$R/etc/uci-defaults/99-tenda-custom" \
      && ok_ "预置 $what" \
      || bad_ "预置 $what 缺失（uci batch 里找不到: $needle）"
  done <<'EOF'
DHCP 池起点 .100|set dhcp.lan.start='100'
DHCP 池数量 100|set dhcp.lan.limit='100'
防火墙 wan 区挂 wan2|network='wan2'
防火墙 lan 区放行|input='ACCEPT'
时区 CST-8|set system.@system[0].timezone='CST-8'
主机名 Tenda-BE12-Pro|set system.@system[0].hostname='Tenda-BE12-Pro'
EOF

  # ---- 段类型守卫（本项目的第 9 个静默坑）----
  # ⚠️ `set <包>.<段>=<值>` 在 uci batch 里是**给段赋类型**，不是赋选项值。
  #    dnsmasq 的 init 脚本只遍历 `config_foreach filter_dnsmasq dhcp`，
  #    所以一旦把 dhcp.lan 的类型写成 interface / dnsmasq，LAN 段就被整个跳过，
  #    不生成 dhcp-range —— 刷完客户端拿不到 IP。
  #
  #    为什么前面的检查拦不住：
  #      · uci batch 正常返回 0，没有任何报错
  #      · start / limit 等选项**确实写进去了**（所以回读校验报 4/4 通过）
  #      · 上面那几条 grep 只找选项语句，看不见类型
  #      · CI 绿、体积守卫过、sysupgrade -T 也过（它只校验镜像结构，不看运行）
  #    唯一能看出来的办法是 `uci export dhcp | grep '^config'`，
  #    正确形态必须是 `config dhcp 'lan'`。
  #
  #    设备上的验证命令：
  #      uci export dhcp | grep '^config'      # 期望看到 config dhcp 'lan'
  #      grep dhcp-range /var/etc/dnsmasq.conf.*
  if grep -qE "^[[:space:]]*set[[:space:]]+dhcp\.lan=(dnsmasq|'interface'|\"interface\")([[:space:]]|$)" \
       "$R/etc/uci-defaults/99-tenda-custom"; then
    bad_ "dhcp.lan 段类型被改坏 —— dnsmasq 只处理 config dhcp 类型，LAN 将不发 dhcp-range"
  elif grep -qE "^[[:space:]]*set[[:space:]]+dhcp\.lan='dhcp'[[:space:]]*$" \
       "$R/etc/uci-defaults/99-tenda-custom"; then
    ok_ "dhcp.lan 段类型正确（set dhcp.lan='dhcp'）"
  else
    bad_ "找不到 set dhcp.lan='dhcp' —— 段类型是否正确无法判定，请人工确认"
  fi

  # ---- mwan3 安装器守卫 ----
  # 两个坑都是「脚本能跑、没有任何报错、但永远装不上」：
  #   ① 用字符串拼下载地址 → 实测 HTTP 404（tag 的 -1 被重复拼了一次）
  #   ② 用了 uclient-fetch 不支持的 wget 参数（-o / --show-progress）→ 下载直接失败
  MW3="$R/usr/lib/tenda/install-mwan3.sh"
  if [ -f "$MW3" ]; then
    if grep -qE 'wget[^|]*(-o |--show-progress)' "$MW3"; then
      bad_ "install-mwan3.sh 用了 uclient-fetch 不支持的 wget 参数（-o / --show-progress）—— 下载必然失败"
    else
      ok_ "install-mwan3.sh 的 wget 参数兼容 uclient-fetch"
    fi
    if grep -q 'mwan3-\${ver}' "$MW3"; then
      bad_ "install-mwan3.sh 仍在用字符串拼 mwan3 下载地址（实测 404）"
    else
      ok_ "install-mwan3.sh 从 release assets 列表挑下载地址"
    fi
  else
    bad_ "固件里没有 /usr/lib/tenda/install-mwan3.sh"
  fi

  # ---- 无线预置守卫 ----
  # 首次启动脚本负责下发 SSID / 密码 / 加密方式并启用两个 radio。
  # 这里只做静态抽查：语句在不在、country 是不是 CN、radio 有没有被误关。
  if grep -q "setup_wifi" "$R/etc/uci-defaults/99-tenda-custom" 2>/dev/null; then
    ok_ "首启脚本含 setup_wifi"
  else
    bad_ "首启脚本里没有 setup_wifi —— 无线不会被预置"
  fi
  if grep -qE "^[[:space:]]*uci set wireless\.radio[01]\.country='CN'" \
       "$R/etc/uci-defaults/99-tenda-custom" 2>/dev/null; then
    ok_ "无线国家码预置为 CN（不设会按错误监管域工作）"
  else
    bad_ "无线 country 未预置为 CN —— 发射功率/DFS 行为会按错误法规走"
  fi
  if grep -qE "default_radio[01]\.disabled='1'" "$R/etc/uci-defaults/99-tenda-custom" 2>/dev/null; then
    bad_ "首启脚本里还有把 radio 关掉的语句"
  else
    ok_ "首启脚本没有误关 radio"
  fi

  # ---- 无线配置必须预置在固件里（第 10 个静默坑）----
  # /etc/config/wireless **默认不在 rootfs 里**，它由 /sbin/wifi config
  # （ucode /lib/wifi/mac80211.uc，源数据 /etc/board.json）在运行时生成。
  # 只靠首启脚本 uci set 会有两个致命问题：
  #   ① 生成时机在 uci-defaults 之后，会把首启脚本的修改整个洗掉
  #   ② wireless 配置还不存在时，`uci set wireless.default_radio0.disabled='1'`
  #      会造出一个**类型叫 default_radio0 的伪段**（不是 wifi-iface），
  #      commit 成功、netifd 不认 —— 旧版 disable_wifi() 就是这么静默失效的，
  #      设备实际以**无密码开放网络 OpenWrt** 上线。
  # 所以必须把带正确段类型的完整 wireless 配置预置进固件，
  # 让 mac80211.uc 的 radio_exists() 跳过生成。
  WLC="$R/etc/config/wireless"
  if [ ! -f "$WLC" ]; then
    bad_ "固件里没有 /etc/config/wireless —— 首启脚本的 uci set 会造出错误类型的伪段并被生成器洗掉"
  else
    ok_ "/etc/config/wireless 已预置"
    # 段类型：只能是 wifi-device / wifi-iface，出现别的就是伪段
    if grep -E "^[[:space:]]*config " "$WLC" | grep -qvE "^config (wifi-device|wifi-iface) "; then
      bad_ "/etc/config/wireless 里有非 wifi-device/wifi-iface 的段（伪段，netifd 不认）"
    else
      ok_ "/etc/config/wireless 的段类型正确（全部是 wifi-device / wifi-iface）"
    fi
    # 两个 radio 都要在，且要有 path（mac80211.uc 的 radio_exists() 按 path 匹配，
    # 缺 path 就匹配不上，生成器照样会重新生成并覆盖）
    for r in 0 1; do
      if grep -qE "^[[:space:]]*config wifi-device '?radio$r'?" "$WLC" \
         && grep -qE "^[[:space:]]*option path " "$WLC"; then
        :
      else
        bad_ "/etc/config/wireless 缺 radio$r 或缺 option path —— 生成器会覆盖整个文件"
      fi
    done
    grep -qE "^[[:space:]]*option path " "$WLC" \
      && ok_ "/etc/config/wireless 声明了 option path（radio_exists() 可匹配）"
    # SSID / 加密 / 国家码
    grep -qE "^[[:space:]]*option ssid 'ASUS'" "$WLC" \
      && ok_ "预置 SSID = ASUS" \
      || bad_ "/etc/config/wireless 里没有 SSID 'ASUS'"
    grep -qE "^[[:space:]]*option encryption 'psk2'" "$WLC" \
      && ok_ "预置加密 = psk2（WPA2-PSK）" \
      || bad_ "/etc/config/wireless 里没有 encryption 'psk2'（sae 会变成 WPA3）"
    grep -qE "^[[:space:]]*option country 'CN'" "$WLC" \
      && ok_ "预置国家码 = CN" \
      || bad_ "/etc/config/wireless 里没有 country 'CN'"
    grep -qE "^[[:space:]]*option key 'abcd1234\.'" "$WLC" \
      && ok_ "预置密码存在（公开默认值，用户知情决定）" \
      || bad_ "/etc/config/wireless 里没有预置密码"
    # 绝不能出现开放网络
    if grep -qE "^[[:space:]]*option encryption 'none'" "$WLC"; then
      bad_ "/etc/config/wireless 里有 encryption 'none' —— 会开出一个无密码的开放网络"
    else
      ok_ "没有 encryption 'none'（不会开开放网络）"
    fi
  fi

  # ---- LuCI 主题注册守卫（第 11 个静默坑）----
  # LuCI 主题下拉框在「系统 → 系统 → 设计」，数据源是
  # /www/luci-static/resources/view/system/system.js:
  #     const th = Object.keys(uci.get('luci','themes') || {}).sort();
  # 也就是**只认 luci.themes 段的选项**，段空了/没了下拉框就是空的。
  #
  # 旧版 register_themes 的写法（已造成真实故障：设备上下拉框完全空白）：
  #     uci -q delete luci.themes
  #     uci set luci.themes.$t="/luci-static/$t"     ← 3 段式
  # `uci set` 命令行在**段不存在时不会自动建段**，直接报
  # `uci: Invalid argument` 并返回 1；而函数没有任何错误检查，
  # 于是「删掉主题包注册好的段 → 重建失败 → 下拉框空白」，日志还打「已注册」。
  # 只有 `uci batch`（以及 `uci add`）会顺带建段。
  TSC="$R/etc/uci-defaults/99-tenda-custom"
  if grep -qE "^[[:space:]]*uci[[:space:]]+set[[:space:]]+luci\.themes\." "$TSC" 2>/dev/null; then
    bad_ "首启脚本用 uci set 写 luci.themes —— 段不存在时它不建段、直接报 Invalid argument（坑 11）"
  else
    ok_ "没有用 uci set 写 luci.themes（不走那条必失败的路径）"
  fi
  if grep -qE "uci[[:space:]]+batch" "$TSC" 2>/dev/null; then
    ok_ "主题注册走 uci batch（会顺带建段）"
  else
    bad_ "主题注册没有走 uci batch —— luci.themes 段建不出来，下拉框会是空的"
  fi
  # 默认主题：用户要求 eamonxg/luci-theme-aurora 作内置默认
  if grep -qE "^LUCI_DEFAULT_THEME='aurora'" "$TSC" 2>/dev/null; then
    ok_ "默认主题为 aurora（eamonxg/luci-theme-aurora，用户 2026-10-03 指定）"
  else
    bad_ "默认主题不是 aurora —— 检查 LUCI_DEFAULT_THEME 的值"
  fi
  # 选项名不能带连字符：uci batch 的 set 解析器不接受，会静默丢弃该条
  if grep -qE "set luci\.themes\.[A-Za-z0-9_]*-" "$TSC" 2>/dev/null; then
    bad_ "luci.themes 的选项名里带连字符 —— uci batch 会静默丢弃（用 BootstrapDark 而非 bootstrap-dark）"
  else
    ok_ "luci.themes 选项名无连字符"
  fi
  # 必须有回读校验（坑 9/10/11 共同教训：赋值成功 ≠ 生效）
  if grep -q "luci.themes" "$TSC" 2>/dev/null \
     && grep -qE "uci -q show luci .*luci\\\\.themes\\\\." "$TSC" 2>/dev/null; then
    ok_ "主题注册有回读校验（uci show 确认选项真的落库）"
  else
    bad_ "主题注册缺少回读校验 —— 无法发现注册静默失败"
  fi
  # aurora 必须真的打进固件
  if [ -f "$R/usr/share/ucode/luci/template/themes/aurora/header.ut" ]; then
    ok_ "固件内含 aurora 主题模板（header.ut）"
  else
    bad_ "固件里没有 aurora 的 header.ut —— 主题装了也渲染不出来"
  fi

  # ---- apk 软件源守卫（第 12 个坑）----
  # 绝大多数「OpenWrt 镜像站」**只同步 releases/，不同步 snapshots/**。
  # 清华 TUNA / 北外 BFSU / 南大 NJU / 上交 SJTUG / 中科院 ISCAS / 阿里云 aliyn
  # 全都不含 snapshots 目录 —— 把它们填进 distfeeds.list 会得到 HTTP 404，
  # apk 表现为 "unexpected end of file" + "N unavailable"，一个包装不上。
  # CERNET 镜像帮助页原话：「USTC 提供了对 snapshots 的反代」。
  #
  # 旧版默认 https://mirrors.aliyun.com/openwrt 已造成真实故障（Run #15~18 全中）。
  # 注意检查方式：必须**排除注释行和 bad 清单自身**。
  #   - 注释里会写「阿里云 404」当反面教材，那是说明文字不是源；
  #   - `local bad="... mirrors.aliyun.com/openwrt ..."` 这一行正是**要替换掉的目标**，
  #     它必须存在（守卫 3 还要查它），如果一并判死就成了「修好也过不了」的死锁。
  if grep -vE "^[[:space:]]*(#|local bad=)" "$TSC" 2>/dev/null \
     | grep -qE "mirrors\.(aliyun|tuna\.tsinghua|bfsu)\.|mirror\.(nju|sjtug\.sjtu|iscas\.ac)\."; then
    bad_ "首启脚本里出现了没有 snapshots 的镜像站（aliyun/TUNA/BFSU/NJU/SJTUG/ISCAS）—— 装包会全 404（坑 12）"
  else
    ok_ "未把不含 snapshots 的镜像站当源使用（注释与 bad 清单除外）"
  fi
  # 默认必须是 USTC
  if grep -qE "^[[:space:]]*local mirror=\"\$\{TENDA_MIRROR:-https://mirrors\.ustc\.edu\.cn/openwrt\}\"" "$TSC" 2>/dev/null; then
    ok_ "默认软件源为 USTC 中科大（唯一提供 snapshots 反代的国内站）"
  else
    bad_ "默认软件源不是 mirrors.ustc.edu.cn/openwrt —— 检查 TENDA_MIRROR 的默认值"
  fi
  # 不能只替换 downloads.openwrt.org：已经写成 aliyun 的文件永远换不掉
  if grep -qE "local bad=\"[^\"]*mirrors\.aliyun\.com/openwrt" "$TSC" 2>/dev/null; then
    ok_ "坏源清单（bad）含阿里云 —— 能救回已被写坏的 distfeeds.list"
  else
    bad_ "switch_mirror 的 bad 清单里没有阿里云 —— 已被写坏的源永远换不掉"
  fi
  # 换完必须回读校验，不能只信 sed 退出码（坑 9/10/11 共同教训）
  if grep -qE "grep -qE \"\\\$\{bad\}\" \"\\\$repos\"" "$TSC" 2>/dev/null; then
    ok_ "换源后有回读校验（确认坏源真的没了）"
  else
    bad_ "换源缺少回读校验 —— sed 没匹配上也会报成功（坑 12 的第二个静默点）"
  fi
  # 包数兜底：apk update 返回 0 不代表索引有内容
  if grep -q 'apk list 2>/dev/null | wc -l' "$TSC" 2>/dev/null; then
    ok_ "换源有包数兜底（残索引不会伪装成成功）"
  else
    bad_ "换源缺包数兜底 —— apk update 返回 0 不代表索引有内容"
  fi

  # ---- 内核模块源守卫（第 14 个坑）----
  # 本机构建的固件刷完后**一个内核模块都装不了**：OpenWrt 只在
  # CONFIG_BUILDBOT 时才往 distfeeds.list 写 kmods 那一行
  # （include/feeds.mk 的 FeedSourcesAppendAPK），本机构建的固件没有这行。
  # 现象是 LuCI 里 mwan3 详情页底部「依赖的软件包 kmod-ip6tables
  # 在所有仓库都未提供」，同样的还有 kmod-nft-compat /
  # kmod-ipt-conntrack-extra / kmod-ipt-ipopt。
  # 后果：任何依赖新内核模块的面板（透明代理的 kmod-nft-tproxy 尤其）都装不了。
  if grep -q '^add_kmods_feed()' "$TSC" 2>/dev/null; then
    ok_ "首启脚本有 add_kmods_feed（自动补内核模块源）"
  else
    bad_ "首启脚本没有 add_kmods_feed —— 刷完机装不了任何内核模块（坑 14）"
  fi
  # ⚠️ 必须 -L：USTC 对 snapshots 是 301 重定向到 downloads.openwrt.org，
  #    不跟重定向拿到的是 209 字节的 nginx 跳转页，一个 href 都没有。
  #    少了 -L，探测永远「找不到条目」，而日志看起来像正常告警。
  if grep -qE 'curl -sL --max-time [0-9]+ "\$dir"' "$TSC" 2>/dev/null; then
    ok_ "列 kmods 目录时跟了重定向（curl -sL，USTC 对 snapshots 是 301）"
  else
    bad_ "列 kmods 目录没跟重定向 —— USTC 是 301 到官方站，探测必然失败（坑 14）"
  fi
  # 必须从 distfeeds.list 反推目录，写死 targets/mediatek/filogic 换个 target 就废
  if grep -qE 'base="\$\(grep -v .\^#. "\$dist" \| grep ./targets/. \| head -1\)"' "$TSC" 2>/dev/null; then
    ok_ "kmods 目录从 distfeeds.list 反推（换 target / arch 不会失效）"
  else
    bad_ "kmods 目录没有从 distfeeds.list 反推 —— 换 target 或 arch 就会指错地方"
  fi
  # 探测失败只告警不阻断：内核模块装不上不该拦住整个首启
  if grep -q 'add_kmods_feed$' "$TSC" 2>/dev/null; then
    ok_ "add_kmods_feed 已在首启流程里调用"
  else
    bad_ "定义了 add_kmods_feed 却没调用 —— 等于没写"
  fi

  # ---- 双 WAN 负载均衡守卫（第 13 个坑）----
  # 防火墙的软/硬件卸载会在 **ingress 钩子**把连接钉死在链路上，
  # **完全绕过 mwan3 的 mangle 打标链** → balanced 策略形同虚设，
  # 表现为第二条 WAN 的 rx/tx 长期只有几百字节。负载均衡与卸载**互斥**。
  # 实测见 SNAPSHOT固件配置教程/fix-mwan3-balance.sh。
  # 必须**显式**设 0：靠 fw4 默认不保险（默认会随版本变，且用户一勾
  # LuCI 的「软件流量分载」就翻车），所以这里只认显式赋值。
  if grep -qE "set firewall\.@defaults\[0\]\.flow_offloading='0'" "$TSC" 2>/dev/null \
     && grep -qE "set firewall\.@defaults\[0\]\.flow_offloading_hw='0'" "$TSC" 2>/dev/null; then
    ok_ "首启脚本显式关闭了 flow_offloading / flow_offloading_hw（mwan3 负载均衡的前提）"
  else
    bad_ "首启脚本没显式关闭 flow_offloading / flow_offloading_hw —— 负载均衡会静默失效（坑 13）"
  fi
  if grep -qE "set firewall\.@defaults\[0\]\.flow_offloading(_hw)?='1'" "$TSC" 2>/dev/null; then
    bad_ "首启脚本把流量卸载又打开了 —— 和负载均衡直接冲突"
  fi

  # ---- mwan3 配置生成器守卫 ----
  IM3="$R/usr/lib/tenda/install-mwan3.sh"
  if [ -f "$IM3" ]; then
    ok_ "固件内含 install-mwan3.sh"
    if grep -qE '^[[:space:]]*write_config\(\)' "$IM3" 2>/dev/null; then
      ok_ "安装脚本带 write_config()（装完自动写 /etc/config/mwan3）"
    else
      bad_ "install-mwan3.sh 没有 write_config() —— 权重/策略/规则全靠人手动配"
    fi
    if grep -qE 'WAN_A_WEIGHT:-3' "$IM3" 2>/dev/null \
       && grep -qE 'WAN_B_WEIGHT:-1' "$IM3" 2>/dev/null; then
      ok_ "默认权重 3:1（电信 1000M : 移动 300M）"
    else
      bad_ "默认权重不是 3:1 —— 检查 WAN_A_WEIGHT / WAN_B_WEIGHT"
    fi
    if grep -qE "config policy 'balanced'" "$IM3" 2>/dev/null; then
      ok_ "生成的配置里有 balanced（均衡）策略"
    else
      bad_ "生成的配置里没有 balanced 策略 —— 那就不是负载均衡，是故障转移"
    fi
    # 段名 ≤15 字符是硬约束：mwan3 会静默跳过超长段名
    if grep -qE 'check_balance\(\)' "$IM3" 2>/dev/null && grep -qE '15 字符' "$IM3" 2>/dev/null; then
      ok_ "带 check_balance() 体检，且说明了 15 字符段名上限"
    else
      bad_ "install-mwan3.sh 缺 check_balance() 体检或未说明 15 字符段名上限"
    fi
    # 出口设备名不能靠字符串拼：PPPoE 会被 netifd 改名成 pppoe-wanX
    if grep -qE 'dev_of\(\)' "$IM3" 2>/dev/null; then
      ok_ "从 ubus 解析出口设备名（不靠字符串拼 pppoe-*）"
    else
      bad_ "没有 dev_of() —— PPPoE 出口设备名会写错，体检永远读不到 wan2 流量"
    fi
  else
    bad_ "固件里没有 install-mwan3.sh —— 刷机后没法装 mwan3"
  fi

  # ---- 危险命令守卫 ----
  # AN8855AE 交换芯片下 /etc/init.d/network restart 会导致 LAN 失联、需断电，
  # 预置文件里绝不能把它当成操作指引告诉用户。
  if grep -qE "^[[:space:]]*#.*/etc/init\.d/network[[:space:]]+restart" \
       "$R/etc/uci-defaults/99-tenda-custom" "$R/etc/config/network" 2>/dev/null; then
    bad_ "预置文件里出现了 /etc/init.d/network restart —— 本机用它会 LAN 失联（见 README §8）"
  else
    ok_ "预置文件未出现 /etc/init.d/network restart"
  fi
fi

# ---- 5. 必须不存在的包 -----------------------------------------------------
echo
echo "  ${CYN}【必须不存在】${RST}"
for pat in mwan3 passwall sing-box openclash xray; do
  if [ -d "$R/usr/share/$pat" ] || [ -d "$R/etc/config/$pat" ] \
     || find "$R/etc/uci-defaults" -name "*${pat}*" 2>/dev/null | grep -q .; then
    bad_ "$pat 不该在镜像里，却找到了"
  else
    ok_ "$pat 已排除"
  fi
done

# ---- 6. 汇总 ---------------------------------------------------------------
echo
if [ "$FAIL" -ne 0 ]; then
  echo "  ${RED}❌ 固件内容抽查未通过${RST}"
  echo
  echo "     两个已知的坑，对号入座："
  echo "       · 主题缺失    → Makefile 在仓库根目录，feeds 的 find -mindepth 1"
  echo "                      索引不到，.config 里压根没有符号。"
  echo "                      解法见 scripts/fetch-extra-packages.sh"
  echo "       · 预置文件缺失 → OpenWrt 没有 FILES_DIR 注入机制，必须做成包。"
  echo "                      解法见 package/tenda-preset/"
  echo
  echo "═══════════════════════════════════════════════════════════"
  exit 1
fi

echo "  ${GRN}✅ 固件内容抽查通过${RST}"
echo "═══════════════════════════════════════════════════════════"
