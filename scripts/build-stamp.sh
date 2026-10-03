#!/usr/bin/env bash
# =============================================================================
# build-stamp.sh — 算一次构建时间戳（北京时间），供 CI 全程复用
# -----------------------------------------------------------------------------
# 用法：
#   ./scripts/build-stamp.sh <openwrt源码目录>
#
# 输出 KEY=VALUE 形式的若干行，可以直接
#   ./scripts/build-stamp.sh "$OPENWRT_SRC" >> "$GITHUB_ENV"
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/stamp.sh
. "$ROOT/scripts/lib/stamp.sh"

SRC="${1:-$ROOT/openwrt}"

STAMP="$(bj_stamp)"
if [ -z "$STAMP" ]; then
	echo "❌ 算不出北京时间戳，终止（版本串会缺时间，不能带病往下走）" >&2
	exit 1
fi

REV="$(build_revision "$SRC")"
VER="$(build_version "$REV" "$STAMP")"
READABLE="$(bj_stamp_readable)"

echo "TENDA_BUILD_STAMP=$STAMP"
echo "TENDA_BUILD_REV=$REV"
echo "TENDA_BUILD_VERSION=$VER"
echo "TENDA_BUILD_READABLE=$READABLE"
