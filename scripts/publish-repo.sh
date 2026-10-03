#!/bin/sh
# =============================================================================
# publish-repo.sh — 把 build-repo.sh 的产物推到 tenda-repo 仓库
# -----------------------------------------------------------------------------
# 用法： ./scripts/publish-repo.sh <产物目录> <分支名> [目标仓库]
#   例： ./scripts/publish-repo.sh ./apk-repo main r3zound/tenda-repo
#
# 设计原则：**校验不过就一步都不推**。
#   上一次的产物已经在 Pages 上，推一半会让设备拉到索引却下不到包，
#   比不推更糟。build-repo.sh 失败时本脚本根本不会被调用（CI 里 && 串联）。
#
# 用 contents API 而不是 git push：
#   github.com:443 在国内时通时不通，API 走 api.github.com 稳定得多
#   （本项目坑 12 期间就是这么活下来的）。
# =============================================================================
set -euo pipefail

SRC="${1:?用法: publish-repo.sh <产物目录> <分支名> [仓库]}"
BRANCH="${2:?缺少分支名}"
DEST="${3:-r3zound/tenda-repo}"
API="https://api.github.com/repos/$DEST/contents"

GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
ok()   { echo "${GRN}✅ $*${RST}"; }
warn() { echo "${YEL}⚠️  $*${RST}"; }
die()  { echo "${RED}❌ $*${RST}" >&2; exit 1; }

[ -d "$SRC" ] || die "产物目录不存在: $SRC"
[ -s "$SRC/packages.adb" ] || die "没有 packages.adb —— 拒绝发布"

tok="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null \
       | grep '^password=' | head -1 | cut -d= -f2-)"
[ -n "$tok" ] || die "拿不到 GitHub 凭据"

api() { # $1=method $2=url $3=body
  curl -s -X "$1" -H "Authorization: token $tok" \
       -H "Accept: application/vnd.github+json" -H "User-Agent: tenda-publish" \
       ${3:+-H "Content-Type: application/json" -d "$3"} "$2"
}

# ---- 目标路径 ---------------------------------------------------------------
DIR="${BRANCH}"     # 仓库里放 /main/ 和 /immortalwrt-25.12/
echo "${CYN}▸ 发布到 $DEST 的 /$DIR/${RST}"

# ---- 1. 读远端现状（拿 sha 用于更新已有文件）---------------------------------
# ⚠️⚠️ GitHub contents API 返回的原始 JSON 是 "sha":"xxx"（冒号后**无空格**）。
#    如果 grep 写成 '"sha": "'，永远匹配不上 → 把「已存在」误判成「新增」→
#    PUT 不带 sha → GitHub 返回 422 "sha wasn't supplied" → 整个发布失败。
#    这个坑很隐蔽：本地测试看着像"没这个文件"，实际是远端明明有。
#    下面的正则用 \s* 同时兼容有无空格两种序列化。
echo "  读取远端文件列表…"
list="$(api GET "$API/$DIR")" || die "读远端目录失败"
names="$(echo "$list" | grep -oE '"name":\s*"[^"]+"' | tr -d ' ' | cut -d'"' -f4 || true)"

put() { # $1=文件名
  f="$SRC/$1"
  [ -f "$f" ] || return 0
  # 只在目录列表里**精确匹配**同名项的 sha，不能全文乱取第一个 sha
  sha=""
  line="$(echo "$list" | tr '{' '\n' | grep -F "\"name\":\"$1\"" | head -1)"
  if [ -z "$line" ]; then
    line="$(echo "$list" | tr '{' '\n' | grep -F "\"name\": \"$1\"" | head -1)"
  fi
  sha="$(echo "$line" | grep -oE '"sha":\s*"[0-9a-f]{40}"' | head -1 | tr -d ' ' | cut -d'"' -f4)"

  b64="$(base64 -w0 < "$f")"
  if [ -n "$sha" ]; then
    body="{\"message\":\"chore: update $1\",\"content\":\"$b64\",\"sha\":\"$sha\",\"branch\":\"main\"}"
  else
    body="{\"message\":\"chore: add $1\",\"content\":\"$b64\",\"branch\":\"main\"}"
  fi
  code=$(curl -s -o /tmp/pr.out -w "%{http_code}" -X PUT -H "Authorization: token $tok" \
         -H "Accept: application/vnd.github+json" -H "User-Agent: tenda-publish" \
         -H "Content-Type: application/json" -d "$body" "$API/$DIR/$1")
  case "$code" in
    200|201) printf "  %s✓%s %s\n" "$GRN" "$RST" "$1" ;;
    422) warn "$1 被拒（HTTP 422）—— 通常是 sha 提取失败，检查下面的响应"; head -c 200 /tmp/pr.out; echo ;;
    *)   warn "$1 上传失败 HTTP $code" ;;
  esac
}

# ---- 2. 先推索引（设备先看到新索引）-----------------------------------------
# ⚠️ 顺序很重要：索引和包不在同一时刻完成，中间有个窗口期设备可能
#    拉到新索引但下不到某些包。apk 会报 "unable to select packages" 后重试，
#    不算致命。真正的原子性 GitHub Pages 给不了，只能把窗口缩到最小。
echo "  上传索引…"
put packages.adb
[ -f "$SRC/packages.adb.sig" ] && put packages.adb.sig

# ---- 3. 再推包 ---------------------------------------------------------------
echo "  上传包…"
cnt=0
for f in "$SRC"/*.apk; do
  [ -e "$f" ] || continue
  put "$(basename "$f")"
  cnt=$((cnt+1))
done
ok "共处理 $cnt 个包"

# ---- 4. BUILD-INFO ----------------------------------------------------------
put BUILD-INFO.txt

# ---- 5. 启用 Pages ----------------------------------------------------------
echo
echo "  启用 GitHub Pages…"
api PUT "https://api.github.com/repos/$DEST/pages" '{"source":{"branch":"main","path":"/"}}' >/dev/null 2>&1 \
  && ok "Pages 已配置（main 分支根目录）" \
  || warn "Pages 配置未成功（可能已配置过，忽略）"

echo
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "${GRN}  发布完成${RST}"
echo "${GRN}═══════════════════════════════════════════════════════════${RST}"
echo "  https://r3zound.github.io/$DEST/$DIR/packages.adb"
echo
echo "  ${YEL}Pages 部署有 1-2 分钟延迟，之后设备才能拉到。${RST}"
echo "  ${YEL}设备侧：echo 'https://r3zound.github.io/$DEST/$DIR/packages.adb'${RST}"
echo "  ${YEL}        >> /etc/apk/repositories.d/customfeeds.list && apk update${RST}"
