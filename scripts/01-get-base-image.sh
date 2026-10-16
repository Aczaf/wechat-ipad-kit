#!/usr/bin/env bash
# =============================================================================
#  步骤 1/5 :: 获取 Ubuntu 24.04 基础镜像
#
#  解决什么：
#    国内环境 docker pull ubuntu:24.04 常常失败（403/502/超时）。
#    本脚本直接下载 Ubuntu 官方 cloud image 的 rootfs tarball，
#    再用 docker import 变成镜像 —— 完全绕开 Docker Registry。
#
#  为什么要 24.04：
#    协议内核 libv08.so 需要 GLIBC_2.38 与 GLIBCXX_3.4.32。
#    Ubuntu 22.04 只有 GLIBC 2.35；Ubuntu 24.04 提供 2.39，满足要求。
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

IMAGE_TAG="${IMAGE_TAG:-ubuntu24:latest}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/wechat-ipad-kit}"
ROOTFS="$CACHE_DIR/noble-rootfs.tar.xz"
MIN_SIZE=150000000          # 约 150MB，小于此值说明下载不完整

mkdir -p "$CACHE_DIR"
require_cmd docker "请先安装 Docker。"
require_cmd curl   "请先安装 curl。"

# --------------------------------------------------------------- 幂等检查
if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  ok "基础镜像 $IMAGE_TAG 已存在，跳过。"
  glibc_in_image="$(docker run --rm "$IMAGE_TAG" bash -c 'ldd --version | head -1' 2>/dev/null || echo '未知')"
  info "镜像内 glibc: $glibc_in_image"
  exit 0
fi

title "下载 Ubuntu 24.04 rootfs（约 220MB）"

# 多个镜像源，任一可用即可。清华 / 中科大 / 官方
SOURCES=(
  "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/noble/current/noble-server-cloudimg-amd64-root.tar.xz"
  "https://mirrors.ustc.edu.cn/ubuntu-cloud-images/noble/current/noble-server-cloudimg-amd64-root.tar.xz"
  "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-root.tar.xz"
  "https://mirrors.aliyun.com/ubuntu-cloud-images/noble/current/noble-server-cloudimg-amd64-root.tar.xz"
)

if [ -f "$ROOTFS" ] && [ "$(stat -c%s "$ROOTFS" 2>/dev/null || echo 0)" -gt "$MIN_SIZE" ]; then
  ok "已存在可用缓存: $ROOTFS"
else
  rm -f "$ROOTFS"
  fetch_first_ok "$ROOTFS" "${SOURCES[@]}" \
    || die "所有镜像源均下载失败。请检查网络，或手动下载 rootfs 放到 $ROOTFS"
fi

actual="$(stat -c%s "$ROOTFS")"
[ "$actual" -ge "$MIN_SIZE" ] || die "下载文件过小（$actual 字节），可能不完整，请删除后重试。"
ok "rootfs 就绪：$((actual / 1024 / 1024)) MB"

title "导入为 Docker 镜像：$IMAGE_TAG"
docker import "$ROOTFS" "$IMAGE_TAG"
docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || die "docker import 后仍找不到镜像。"

# --------------------------------------------------------------- 验证 GLIBC
title "验证 GLIBC 版本（关键）"
image_glibc="$(docker run --rm "$IMAGE_TAG" bash -c 'ldd --version | head -1 | grep -oE "[0-9]+\.[0-9]+$"')"
info "镜像内 GLIBC = $image_glibc"

if ver_ge "$image_glibc" "2.38"; then
  ok "GLIBC $image_glibc >= 2.38，满足协议内核要求。"
else
  die "GLIBC $image_glibc < 2.38，无法加载协议内核。请确认下载的是 Ubuntu 24.04 (noble)。"
fi

title "完成"
log "镜像 : $IMAGE_TAG"
log "下一步: bash scripts/02-fetch-source.sh"
