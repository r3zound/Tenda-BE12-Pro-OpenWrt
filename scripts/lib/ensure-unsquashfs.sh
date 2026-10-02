#!/usr/bin/env bash
# =============================================================================
# ensure-unsquashfs.sh — 确保有一个可用的 unsquashfs，输出其绝对路径
# -----------------------------------------------------------------------------
# 为什么需要它：
#   早前 size-guard / verify-firmware 都是手写 squashfs superblock 解析器，
#   结果把未压缩块标志位搞错（0x1000 实际应为 0x2000），把 13MB 的
#   文件内容算成了「全部内容」—— 展开体积报 13.09MB（真值 40MB），
#   而且连 'dhcp'、'aarch64' 这种必然存在的串都搜不到。
#   手搓二进制格式解析器就是给自己埋雷，能用现成工具就别手写。
#
# 获取顺序：
#   1) PATH 里已有 → 直接用
#   2) apt-get / dnf / yum 装 squashfs-tools
#   3) 源码编译（需要 gcc + zlib + liblzma）
#
# 用法：  USQ="$(source scripts/lib/ensure-unsquashfs.sh && _ensure)"
#         或  scripts/lib/ensure-unsquashfs.sh      # 直接打印路径
# =============================================================================

_ensure() {
  if command -v unsquashfs >/dev/null 2>&1; then
    command -v unsquashfs
    return 0
  fi

  echo "  unsquashfs 不在 PATH，尝试安装 …" >&2

  if command -v apt-get >/dev/null 2>&1; then
    (apt-get install -y squashfs-tools >&2 2>&1) \
      || (apt-get update -qq >&2 && apt-get install -y squashfs-tools >&2 2>&1) || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y squashfs-tools >&2 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y squashfs-tools >&2 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache squashfs-tools >&2 2>&1 || true
  fi

  if command -v unsquashfs >/dev/null 2>&1; then
    command -v unsquashfs
    return 0
  fi

  # ---- 源码编译兜底 --------------------------------------------------------
  command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1 || {
    echo "  ❌ 没有 gcc/cc，无法源码编译" >&2
    return 1
  }
  command -v make >/dev/null 2>&1 || {
    echo "  ❌ 没有 make，无法源码编译" >&2
    return 1
  }

  local tmp
  tmp="$(mktemp -d)"
  echo "  从源码编译 squashfs-tools …" >&2

  if curl -sL --max-time 180 \
      "https://github.com/plougher/squashfs-tools/archive/refs/tags/4.6.1.tar.gz" \
      -o "$tmp/sq.tgz" 2>/dev/null && [ -s "$tmp/sq.tgz" ]; then
    tar xzf "$tmp/sq.tgz" -C "$tmp" 2>/dev/null
    local d
    d="$(find "$tmp" -maxdepth 2 -name squashfs-tools -type d | head -1)"
    if [ -n "$d" ] && (cd "$d" && make unsquashfs XZ_SUPPORT=1 >&2 2>&1); then
      echo "$d/unsquashfs"
      return 0
    fi
  fi

  echo "  ❌ 拿不到可用的 unsquashfs" >&2
  return 1
}

# 直接执行时打印路径
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _ensure
fi
