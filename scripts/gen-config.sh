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
# 落点是 CONFIG_VERSION_CODE，它是 OpenWrt 留给二次编译方的官方字段：
#   package/base-files/files/etc/openwrt_release 的 DISTRIB_DESCRIPTION='%D %V %C'
#   %C 就是它 → LuCI「系统 → 系统」显示的那行版本串
#   /etc/openwrt_version 也是它
# 没设它时 OpenWrt 回退成 git revision（r1-9b95be917b），看不到构建时间。
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

{
  echo ""
  echo "# ---- 本项目附加：版本标识（build-stamp.sh 生成）----"
  echo "CONFIG_VERSION_CODE=\"$TENDA_BUILD_VERSION\""
  # 必须钉死为 n：它的 Kconfig 默认是 y，一旦为 y，
  # include/image.mk:49 的 IMG_PREFIX_VERCODE 会把版本码作为**前缀**
  # 插进 .bin 文件名，和我们自己在 stamp-firmware.sh 里加的**后缀**撞车，
  # 结果是 r1-...-20261004.0031-openwrt-...-sysupgrade-20261004.0031.bin
  # 两头都有日期。所以这里文件名的形态由我们自己掌控。
  echo "# CONFIG_VERSION_CODE_FILENAMES is not set"
} >> .config

echo "▸ 版本标识：$TENDA_BUILD_VERSION"
echo "  (LuCI 系统页会显示 OpenWrt SNAPSHOT $TENDA_BUILD_VERSION)"

# 让 make 解析依赖并补全
echo "▸ 运行 make defconfig 解析…"
make defconfig

# ---- 回读校验：写进 .config 不等于 make 认了 --------------------------------
echo "▸ 回读校验版本相关符号…"
vfail=0
if grep -q "^CONFIG_VERSION_CODE=\"$TENDA_BUILD_VERSION\"$" .config; then
  echo "  ✅ CONFIG_VERSION_CODE = $TENDA_BUILD_VERSION"
else
  echo "  ❌ CONFIG_VERSION_CODE 没进 .config 或被 defconfig 改写（LuCI 会显示旧版本串）"
  vfail=1
fi
# CONFIG_VERSION_CODE_FILENAMES 必须仍然是关的，否则文件名会出现两段日期
if grep -qE '^CONFIG_VERSION_CODE_FILENAMES=y$' .config; then
  echo "  ❌ CONFIG_VERSION_CODE_FILENAMES 被 defconfig 打开了 —— .bin 文件名会出现前缀+后缀两段日期"
  vfail=1
else
  echo "  ✅ CONFIG_VERSION_CODE_FILENAMES 未开启（文件名前缀交给 stamp-firmware.sh）"
fi
[ "$vfail" -eq 0 ] || { echo; echo "❌ 版本标识校验失败，终止。"; exit 1; }

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
