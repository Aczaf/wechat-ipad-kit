#!/usr/bin/env bash
# =============================================================================
#  wechat-ipad-kit :: 通用工具函数
# =============================================================================
set -o pipefail

# ---------------------------------------------------------------- 颜色输出
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s[INFO]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s[FAIL]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
title() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# ---------------------------------------------------------------- 环境探测
has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  has_cmd "$1" || die "缺少命令 '$1'，请先安装。$2"
}

# 检测是否在容器内（容器内不需要 docker）
in_container() {
  [ -f /.dockerenv ] || grep -qaE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null
}

# 检测宿主 glibc 版本，如 2.35
glibc_version() {
  ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo "0.0"
}

# 版本比较：ver_ge 2.39 2.38  → true
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# ---------------------------------------------------------------- 下载辅助
# 依次尝试多个 URL 前缀（用于绕过 GitHub 直连问题）
# 用法: fetch_first_ok <输出文件> <url...>
fetch_first_ok() {
  local out="$1"; shift
  local url
  for url in "$@"; do
    info "尝试下载: $url"
    if curl -fsSL --retry 2 --connect-timeout 20 -o "$out" "$url" && [ -s "$out" ]; then
      ok "下载成功 ($(du -h "$out" | cut -f1))"
      return 0
    fi
    warn "该地址失败，尝试下一个"
  done
  return 1
}

# 给 GitHub 链接套上加速前缀（依次尝试）
gh_mirrors() {
  local path="$1"
  printf '%s\n' \
    "$path" \
    "https://ghfast.top/$path" \
    "https://gh-proxy.com/$path" \
    "https://ghproxy.net/$path"
}

# ---------------------------------------------------------------- 交互确认
confirm() {
  local prompt="${1:-继续?}" reply
  if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
  printf '%s [y/N] ' "$prompt"
  read -r reply
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}
