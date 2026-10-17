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

tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$tok" ]; then
  # 本地开发走 credential helper；CI 里没有 .gitconfig，用 env 里的 token（见上）。
  tok="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null \
       | grep '^password=' | head -1 | cut -d= -f2-)"
fi
[ -n "$tok" ] || die "拿不到 GitHub 凭据（设 GH_TOKEN，或在本地用 git credential）"

api() { # $1=method $2=url $3=body
  if [ -n "${3:-}" ]; then
    curl -s -X "$1" -H "Authorization: token $tok" \
         -H "Accept: application/vnd.github+json" -H "User-Agent: tenda-publish" \
         -H "Content-Type: application/json" -d "$3" "$2"
  else
    curl -s -X "$1" -H "Authorization: token $tok" \
         -H "Accept: application/vnd.github+json" -H "User-Agent: tenda-publish" "$2"
  fi
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

PUT_FAIL=0
put() { # $1=文件名
  f="$SRC/$1"
  [ -f "$f" ] || return 0
  # 只在目录列表里**精确匹配**同名项的 sha，不能全文乱取第一个 sha
  sha=""
  # ⚠️ 远端目录第一次不存在时，这里的 grep 必然返回 1。
  #    在 set -euo pipefail 下，赋值语句自己就会失败，后面的「按新文件上传」
  #    逻辑根本走不到 —— 现场表现是只打印「上传索引…」然后静默退出（坑 19 同款）。
  line="$(echo "$list" | tr '{' '\n' | grep -F "\"name\":\"$1\"" | head -1 || true)"
  if [ -z "$line" ]; then
    line="$(echo "$list" | tr '{' '\n' | grep -F "\"name\": \"$1\"" | head -1 || true)"
  fi
  sha="$(echo "$line" | grep -oE '"sha":\s*"[0-9a-f]{40}"' | head -1 | tr -d ' ' | cut -d'"' -f4 || true)"

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
    422) warn "$1 被拒（HTTP 422）—— 通常是 sha 提取失败，检查下面的响应"; head -c 200 /tmp/pr.out; echo; PUT_FAIL=$((PUT_FAIL+1)) ;;
    *)   warn "$1 上传失败 HTTP $code"; PUT_FAIL=$((PUT_FAIL+1)) ;;
  esac
}

# ---- 2. 先推包 ---------------------------------------------------------------
# ⚠️ 顺序很重要：必须先推包，最后推索引。
#    反过来（先索引后包）一旦中途失败，设备会拉到“新索引里有、仓库里没有”的包，
#    apk 直接报 unable to select packages。先推包时旧索引仍然完整可用，
#    最后一步索引更新成功才代表这一版真正对外生效。
echo "  上传包…"
cnt=0
for f in "$SRC"/*.apk; do
  [ -e "$f" ] || continue
  put "$(basename "$f")"
  cnt=$((cnt+1))
done
ok "共处理 $cnt 个包"

# ---- 3. BUILD-INFO ----------------------------------------------------------
put BUILD-INFO.txt

# ⚠️ 上传失败不能只 warn 后继续打印「发布完成」。
#    Contents API 遇到 401/403/429/5xx 时，旧逻辑会留下一个缺包的远端，
#    而 CI 步骤仍然绿；设备看到的正是「索引有、包下载不到」。
[ "$PUT_FAIL" -eq 0 ] || die "$PUT_FAIL 个文件上传失败，拒绝宣布发布完成"

# ---- 4. 最后推索引（这一版真正生效的开关）-----------------------------------
echo "  上传索引…"
put packages.adb
[ -f "$SRC/packages.adb.sig" ] && put packages.adb.sig
[ "$PUT_FAIL" -eq 0 ] || die "$PUT_FAIL 个文件上传失败，拒绝宣布发布完成"

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
