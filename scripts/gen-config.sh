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

# ---- ccache 目录：必须和 CI 缓存步骤指向同一个地方 ----------------------------
# ⚠️⚠️ 这一行是 Run #28 之后才补的，坑 18 的**第二层**根因。
#
# 上游 rules.mk:347-354（immortalwrt openwrt-25.12，逐字）：
#     ifneq ($(CONFIG_CCACHE),)
#       HOSTCC:= ccache $(HOSTCC)
#       export CCACHE_BASEDIR:=$(TOPDIR)
#       export CCACHE_DIR:=$(if $(CONFIG_CCACHE_DIR),$(CONFIG_CCACHE_DIR),$(TOPDIR)/.ccache)
#
# 注意那个 **`export`**：OpenWrt 会把 CCACHE_DIR 覆盖成 `$(TOPDIR)/.ccache`
# 再传给所有子进程，**优先于 workflow 在 GITHUB_ENV 里设的 CCACHE_DIR**。
#
# 于是 Run #28 的实际状况是：
#   ccache 往   $GITHUB_WORKSPACE/openwrt/.ccache  写了 1.4 GiB
#   缓存步骤去  ~/.ccache  找            → 空目录 → "Path ... do(es) not exist"
# 两边永远对不上，每轮都是全冷编译，缓存一次都存不进去。
#
# 修法有两条路：
#   (a) 把缓存步骤的 path 改成 openwrt/.ccache —— **不可行**。
#       缓存恢复排在「生成 feeds.conf」之前（build.yml 第 75 行 vs 第 98 行），
#       恢复会先把 openwrt/ 目录建出来，后面 gen-feeds.sh 的 git clone 撞上
#       「destination path already exists and is not an empty directory」直接失败。
#   (b) 让 OpenWrt 同意用我们指定的目录 —— 就是这里。
#       CONFIG_CCACHE_DIR 是公开的 kconfig 选项（config/Config-devel.in:
#       `string "Set ccache directory" if CCACHE`），不是内部变量。
#
# 目录值由调用方给（CI 传 CCACHE_DIR），本地跑时退回 $HOME/.ccache。
# .config 是每次生成的、不入库，所以写绝对路径没问题。
CCACHE_TARGET_DIR="${CCACHE_DIR:-$HOME/.ccache}"
echo "CONFIG_CCACHE_DIR=\"$CCACHE_TARGET_DIR\"" >> .config
echo "▸ ccache 目录（写入 CONFIG_CCACHE_DIR）"
echo "  $CCACHE_TARGET_DIR"

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

# ⚠️ CCACHE_DIR 是 `string ... if CCACHE` —— CCACHE 不可见时会被 defconfig 删掉。
#    而 CCACHE 本身在 `if DEVEL` 菜单块内，DEVEL=n 时连带 CCACHE_DIR 一起消失。
#    这个坑已经栽过一次（坑 18），这里必须回读，不能只看写进去了。
echo "▸ 回读校验 ccache 相关符号…"
if ! grep -q '^CONFIG_CCACHE=y$' .config; then
  echo "  ❌ CONFIG_CCACHE 没进 .config —— ccache 不会参与编译（检查 CONFIG_DEVEL=y）"
  exit 1
fi
echo "  ✅ CONFIG_CCACHE=y"
if grep -q '^CONFIG_CCACHE_DIR=' .config; then
  got=$(sed -n 's/^CONFIG_CCACHE_DIR="\(.*\)"$/\1/p' .config)
  if [ "$got" = "$CCACHE_TARGET_DIR" ]; then
    echo "  ✅ CONFIG_CCACHE_DIR = $got"
  else
    echo "  ❌ CONFIG_CCACHE_DIR 被 defconfig 改成了 '$got'（期望 '$CCACHE_TARGET_DIR'）"
    exit 1
  fi
else
  echo "  ❌ CONFIG_CCACHE_DIR 丢失 —— rules.mk 会回退到 \$(TOPDIR)/.ccache，"
  echo "     和 CI 缓存步骤的 ~/.ccache 对不上（坑 18 第二层）"
  exit 1
fi

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
