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
IMG="$BIN/openwrt-mediatek-filogic-tenda_be12-pro-squashfs-sysupgrade.bin"
[ -f "$IMG" ] || { echo "${RED}❌ 未找到镜像: $IMG${RST}"; exit 2; }

tar -xf "$IMG" -C "$TMPD" 2>/dev/null
ROOTFS="$(find "$TMPD" -type f -name root 2>/dev/null | head -1)"
[ -n "$ROOTFS" ] || {
  echo "${RED}❌ 镜像里找不到 rootfs 分片${RST}"
  echo "   镜像结构: $(tar -tf "$IMG" 2>/dev/null | head -5 | tr '\n' ' ')"
  exit 2
}

"$USQ" -f -d "$TMPD/rootfs" "$ROOTFS" >/dev/null 2>&1 || {
  echo "${RED}❌ unsquashfs 解包失败${RST}"
  "$USQ" -s "$ROOTFS" 2>&1 | head -20
  exit 2
}
R="$TMPD/rootfs"
echo "  解包完成: $(find "$R" -type f | wc -l) 个文件，$(du -sm --apparent-size "$R" | cut -f1) MB"
echo

FAIL=0
ok_()   { echo "    ${GRN}✅${RST} $1"; }
bad_()  { echo "    ${RED}❌${RST} $1"; FAIL=1; }

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
