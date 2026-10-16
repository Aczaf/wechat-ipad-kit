#!/usr/bin/env bash
# =============================================================================
#  步骤 2/5 :: 获取协议源码
#
#  说明：
#    本项目【不分发协议内核】。你需要自备一份协议实现源码。
#    默认使用社区公开的 meteor-nb/Ipad860（Go 语言实现），
#    可用 SOURCE_URL 环境变量指向你自己的仓库/压缩包。
#
#  只走 HTTPS zip 下载，不走 git clone —— 因为国内对 git:// 与
#  部分 GitHub 域名限制更多，zip 走加速代理更稳。
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

SRC_DIR="${SRC_DIR:-$PWD/wechat860-src}"
SOURCE_URL="${SOURCE_URL:-https://github.com/meteor-nb/Ipad860/archive/refs/heads/main.zip}"
ARCHIVE="$SRC_DIR.src.zip"

require_cmd curl  "请先安装 curl。"
has_cmd unzip || warn "未找到 unzip，稍后可能需要安装。"

# --------------------------------------------------------------- 幂等检查
if [ -f "$SRC_DIR/go.mod" ] && [ -d "$SRC_DIR/baseinfo" ]; then
  ok "源码已存在: $SRC_DIR，跳过下载。"
  log "如需重新拉取，请先删除该目录。"
  exit 0
fi

title "下载协议源码"
mkdir -p "$(dirname "$SRC_DIR")"

# 构造候选 URL（直连 + 多个加速代理）
urls=()
while IFS= read -r u; do urls+=("$u"); done < <(gh_mirrors "$SOURCE_URL")

fetch_first_ok "$ARCHIVE" "${urls[@]}" \
  || die "源码下载失败。可设置 SOURCE_URL 指向你自己的源码包后重试。"

# 校验是不是有效 zip（避免把错误页当成包）
if ! unzip -t "$ARCHIVE" >/dev/null 2>&1; then
  die "下载内容不是有效的 zip（可能是错误页）。请检查 SOURCE_URL 或换网络重试。"
fi
ok "zip 校验通过"

title "解压到 $SRC_DIR"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
unzip -q "$ARCHIVE" -d "$SRC_DIR.tmp"

# 压缩包通常多一层顶层目录，把它拍平
inner="$(find "$SRC_DIR.tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [ -n "$inner" ]; then
  shopt -s dotglob
  mv "$inner"/* "$SRC_DIR"/ 2>/dev/null || true
  shopt -u dotglob
fi
rm -rf "$SRC_DIR.tmp" "$ARCHIVE"

# --------------------------------------------------------------- 完整性检查
title "校验关键文件"
missing=0
check_file() {
  if [ -e "$SRC_DIR/$1" ]; then
    ok "$1"
  else
    warn "缺少 $1"; missing=1
  fi
}
check_file "go.mod"
check_file "main.go"
check_file "baseinfo/basedefine.go"
check_file "Algorithm/Util.go"
check_file "lib/libv08.so"
check_file "lib/libz.so"
check_file "conf/app.conf"

[ "$missing" -eq 0 ] || die "源码不完整，缺少必要文件。请确认用的是受支持的协议项目。"

title "完成"
log "源码目录: $SRC_DIR"
log "下一步  : bash scripts/03-build.sh"
