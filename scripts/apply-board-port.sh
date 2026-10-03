#!/usr/bin/env bash
# =============================================================================
# apply-board-port.sh — 把 Tenda BE12 Pro 移植进 ImmortalWrt 25.12 源码树
# -----------------------------------------------------------------------------
# 用法： ./scripts/apply-board-port.sh [源码目录]
#        源码目录默认 $ROOT/openwrt
#
# 做两件事：
#   1. 把 mt7987a-tenda-be12-pro.dts 拷到 target/linux/mediatek/dts/
#   2. 把 board-port.mk 的内容追加到 target/linux/mediatek/image/filogic.mk
#
# 幂等：靠 TENDA-PORT 标记判断，重复执行不会重复追加。
#
# ⚠️ 为什么用「追加」而不是打 unified diff 补丁：
#    filogic.mk 每次上游更新都会整体变动，diff 的上下文行三行就飘。
#    追加在文件末尾对 make 语义完全等价（image/ 下都是普通 include 的 make 文件），
#    对上游改动的免疫性最好。标记保证不会重复。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/openwrt}"
PATCH_DIR="$ROOT/patches/immortalwrt-25.12"

DTS_NAME="mt7987a-tenda-be12-pro.dts"
DTS_DST="$SRC/target/linux/mediatek/dts/$DTS_NAME"
FLMK="$SRC/target/linux/mediatek/image/filogic.mk"
MARKER="# >>> TENDA-PORT be12-pro >>>"

GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
ok()   { echo "${GRN}✅ $*${RST}"; }
warn() { echo "${YEL}⚠️  $*${RST}"; }
die()  { echo "${RED}❌ $*${RST}" >&2; exit 1; }
step() { echo; echo "${CYN}▸ $*${RST}"; }

# ---- 0. 前置检查 -------------------------------------------------------------
step "前置检查"
[ -d "$SRC" ] || die "源码目录不存在: $SRC（先跑 gen-feeds.sh 克隆源码）"
[ -f "$FLMK" ] || die "找不到 $FLMK —— 这不像一个 OpenWrt/ImmortalWrt 源码树"
[ -d "$SRC/target/linux/mediatek/dts" ] || die "找不到 target/linux/mediatek/dts 目录"
[ -f "$PATCH_DIR/$DTS_NAME" ] || die "缺少移植文件 patches/immortalwrt-25.12/$DTS_NAME"
[ -f "$PATCH_DIR/board-port.mk" ] || die "缺少移植文件 patches/immortalwrt-25.12/board-port.mk"
ok "源码树与移植文件齐备"

# ---- 1. 设备树 ---------------------------------------------------------------
step "移植设备树 $DTS_NAME"
if [ -f "$DTS_DST" ] && cmp -s "$PATCH_DIR/$DTS_NAME" "$DTS_DST"; then
  ok "已存在且内容一致，跳过"
else
  if [ -f "$DTS_DST" ]; then
    cp "$DTS_DST" "$DTS_DST.bak.$(date +%s)"
    warn "已存在但内容不同，已备份旧文件"
  fi
  cp "$PATCH_DIR/$DTS_NAME" "$DTS_DST"
  ok "已写入 $DTS_DST"
fi
# 回读校验：拷过去不等于 git 认（坑 9/10/11/12 同一个教训）
n=$(wc -l < "$DTS_DST")
[ "$n" -gt 300 ] && ok "回读校验：$n 行" || die "DTS 只有 $n 行，拷贝可能失败"

# ---- 2. 板级定义追加到 filogic.mk -------------------------------------------
step "移植板级定义到 filogic.mk"
if grep -qF "$MARKER" "$FLMK"; then
  ok "已打过标记，跳过追加"
else
  {
    echo ""
    echo "$MARKER"
    echo "# 由 $0 追加，请勿手工编辑。删除后重跑本脚本即可恢复。"
    echo "# 详见 patches/immortalwrt-25.12/board-port.mk 头部的说明。"
    cat "$PATCH_DIR/board-port.mk"
    echo "# <<< TENDA-PORT be12-pro <<<"
  } >> "$FLMK"
  ok "已追加到 filogic.mk 末尾"
fi

# ---- 3. 回读校验（三项都必须在，缺一不可）-----------------------------------
step "回读校验"
FAIL=0
grep -qF "$MARKER" "$FLMK" || { warn "filogic.mk 里没有 TENDA-PORT 标记"; FAIL=1; }
grep -q "define Build/tenda-mkdualimageheader" "$FLMK" \
  || { warn "缺 Build/tenda-mkdualimageheader —— 原厂 bootloader 不认镜像"; FAIL=1; }
grep -q "define Device/tenda_be12-pro" "$FLMK" \
  || { warn "缺 Device/tenda_be12-pro 设备定义"; FAIL=1; }
grep -q "^TARGET_DEVICES += tenda_be12-pro" "$FLMK" \
  || { warn "缺 TARGET_DEVICES += tenda_be12-pro —— 设备不会出现在配置菜单"; FAIL=1; }
[ -f "$DTS_DST" ] || { warn "DTS 不在预期位置"; FAIL=1; }

# make 语法级检查：把 filogic.mk 交给 make 解析一次
if command -v make >/dev/null 2>&1; then
  if make -f "$FLMK" -n print-% >/dev/null 2>&1 \
     || make -f "$FLMK" -n --no-print-directory print-% >/dev/null 2>&1; then
    ok "filogic.mk make 语法可解析"
  else
    # make 解析会执行 $(shell) 之类，未定义变量会报错，不能简单判失败。
    # 改成只看有没有明显语法错误。
    if make -f "$FLMK" -n 2>&1 | grep -qiE "syntax error|missing separator"; then
      warn "filogic.mk 疑似有 make 语法错误"
      make -f "$FLMK" -n 2>&1 | grep -iE "syntax error|missing separator" | head -3 | sed 's/^/     /'
      FAIL=1
    else
      ok "filogic.mk 无 make 语法错误"
    fi
  fi
fi

[ "$FAIL" -eq 0 ] || die "板级移植校验未通过，中止（避免白跑一次 80 分钟编译）"

echo
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "${GRN}  板级移植完成${RST}"
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "  DTS        : ${DTS_DST#$SRC/}"
echo "  板子定义   : target/linux/mediatek/image/filogic.mk（文件末尾）"
echo
echo "  ${YEL}下一步：重新生成配置（设备定义变了，旧 .config 没有新符号）${RST}"
echo "    ./scripts/gen-config.sh $SRC"
echo "    grep DEVICE_tenda_be12-pro $SRC/.config"
