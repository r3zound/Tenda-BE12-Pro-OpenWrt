#!/usr/bin/env bash
# =============================================================================
# gen-config.sh — 从 configs/*.config 生成 .config
# -----------------------------------------------------------------------------
# 用法： ./scripts/gen-config.sh [openwrt源码目录]
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/stamp.sh
. "$ROOT/scripts/lib/stamp.sh"

SRC="${1:-$ROOT/openwrt}"
CFGDIR="$ROOT/configs"

[ -d "$SRC" ] || { echo "❌ OpenWrt 源码目录不存在: $SRC"; exit 1; }

cd "$SRC"

# 合并所有 config 片段
echo "▸ 合并配置片段…"
rm -f .config
for f in "$CFGDIR"/*.config; do
  [ -f "$f" ] || continue
  echo "  · $(basename "$f")"
  cat "$f" >> .config
done

# 预置文件注入
echo "▸ 注入预置文件 (files/ → FILES_DIR)…"
FILES_DIR="$ROOT/files"
if [ ! -d "$FILES_DIR/etc" ]; then
  echo "  ⚠️  未找到 files/etc，将使用 OpenWrt 默认配置"
  echo "     刷机后需手工配置网络，详见 README §7 阶段三"
fi

# ---- 版本标识：把编译时间（北京时间）烧进固件 --------------------------------
# ⚠️⚠️ 走的是 **REVISION 环境变量**，不是 CONFIG_VERSION_CODE。
#
# 为什么（Run #20 / #21 连栽两次才搞明白）：
#   /etc/openwrt_release 的 DISTRIB_DESCRIPTION='%D %V %C'，
#   %C 来自 CONFIG_VERSION_CODE，看着像是该往 .config 里写。
#   但 package/base-files/image-config.in:161-163：
#       menuconfig VERSIONOPT
#           bool "Version configuration options" if IMAGEOPT
#           default n
#   所有 CONFIG_VERSION_* 都在这个菜单块里，而它自己又 `if IMAGEOPT`。
#   IMAGEOPT 没开 → VERSIONOPT 不可见 → **不可见的 bool 会被 kconfig 强制回默认值**。
#   实测：写进去的 `CONFIG_VERSIONOPT=y` 被 defconfig 改写成
#         `# CONFIG_VERSIONOPT is not set`，而日志里照样打印
#         "# configuration written to .config"，一切看着正常。
#   （Run #21 打印出来的 .config 实际内容就只有那一行 is not set。）
#
# 正确入口是 include/toplevel.mk:13：
#   else ifeq (…$(origin REVISION)…, …environmentenvironment)
#     # Recursive calls of the top-level Makefile get both from its environment.
#   else
#     REVISION:=$(shell $(TOPDIR)/scripts/getver.sh)
#   export REVISION
#
# 也就是说 **REVISION 可以从环境注入**，源码注释明说就是为了让递归 make 拿到它。
# 注入后 VERSION_CODE := $(if $(VERSION_CODE),$(VERSION_CODE),$(REVISION))
# 会用上我们的值 → DISTRIB_DESCRIPTION / DISTRIB_REVISION / openwrt_version 全对。
# 附带好处：完全不碰 kconfig，就没有「defconfig 会不会把它吃掉」的问题。
#
# ⚠️ 时间戳在**构建机上算一次**然后烧死，不是开机时算 —— 设备时区是 CST-8
#    但这里不该依赖它，否则改时区就得出两个版本号。
#
# ⚠️ CI 里由 build-stamp.sh 算好后经 $GITHUB_ENV 传进来（全程必须同一个值）；
#    本地直接跑本脚本时自己算一份。
if [ -z "${TENDA_BUILD_VERSION:-}" ]; then
	TENDA_BUILD_STAMP="$(bj_stamp)"
	TENDA_BUILD_REV="$(build_revision "$SRC")"
	TENDA_BUILD_VERSION="$(build_version "$TENDA_BUILD_REV" "$TENDA_BUILD_STAMP")"
fi

export REVISION="${REVISION:-$TENDA_BUILD_VERSION}"
echo "▸ 版本标识（经 REVISION 环境变量注入）"
echo "  REVISION = $REVISION"
echo "  LuCI 系统页会显示: OpenWrt SNAPSHOT $REVISION"

# 保险：万一将来有人打开了 VERSIONOPT，CONFIG_VERSION_CODE_FILENAMES 的
# Kconfig 默认 y 会给 .bin 加**前缀**，和 stamp-firmware.sh 的**后缀**撞车。
echo "# CONFIG_VERSION_CODE_FILENAMES is not set" >> .config

# 让 make 解析依赖并补全
echo "▸ 运行 make defconfig 解析…"
make defconfig

# ---- 回读校验 ---------------------------------------------------------------
# ⚠️ 这里**不能**检查 .config 里的 CONFIG_VERSION_CODE —— 走 REVISION 路线
#    根本不会有那一行，检查它必然误报（Run #21 就死在这）。
#    真正的判据在 verify-firmware.sh：它解开 squashfs 直接看
#    /etc/openwrt_release 里的真实内容，那才是用户看到的东西。
echo "▸ 回读校验版本相关符号…"
if grep -qE '^CONFIG_VERSION_CODE_FILENAMES=y$' .config; then
  echo "  ❌ CONFIG_VERSION_CODE_FILENAMES 被 defconfig 打开了"
  echo "     .bin 文件名会出现前缀+后缀两段日期"
  grep -E 'CONFIG_VERSION_CODE_FILENAMES' .config | sed 's/^/       /'
  echo
  echo "❌ 版本标识校验失败，终止。"
  exit 1
fi
echo "  ✅ CONFIG_VERSION_CODE_FILENAMES 未开启（文件名前缀交给 stamp-firmware.sh）"
echo "  ℹ️  版本串不经过 .config，靠 REVISION 注入，最终由 verify-firmware.sh 校验"

# 校验关键项
echo
echo "▸ 校验关键配置："
fail=0
check() {
  if grep -qx "$1" .config; then
    printf "  ✅ %s\n" "$1"
  else
    printf "  ❌ %s  (缺失或被依赖覆盖)\n" "$1"
    fail=1
  fi
}
check "CONFIG_TARGET_mediatek=y"
check "CONFIG_TARGET_mediatek_filogic=y"
check "CONFIG_TARGET_mediatek_filogic_DEVICE_tenda_be12-pro=y"
check "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
check "CONFIG_PACKAGE_luci=y"
check "CONFIG_LUCI_LANG_zh_Hans=y"

echo
echo "▸ 已选主题："
grep -E '^CONFIG_PACKAGE_luci-theme-' .config | sed 's/CONFIG_PACKAGE_/  /;s/=y/ ✅/;s/=n/ ❌/' || true

echo
echo "▸ 镜像包数量：$(grep -c '^CONFIG_PACKAGE_.*=y' .config || echo 0)"

if [ "$fail" -ne 0 ]; then
  echo
  echo "❌ 关键配置校验失败，终止。"
  exit 1
fi

echo
echo "✅ .config 已生成：$SRC/.config"
