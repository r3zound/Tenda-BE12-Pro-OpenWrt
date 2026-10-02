#!/usr/bin/env bash
# =============================================================================
# gen-config.sh — 从 configs/*.config 生成 .config
# -----------------------------------------------------------------------------
# 用法： ./scripts/gen-config.sh [openwrt源码目录]
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# 让 make 解析依赖并补全
echo "▸ 运行 make defconfig 解析…"
make defconfig

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
