#!/usr/bin/env bash
# =============================================================================
#  一键跑完整流程
#
#      bash run.sh              # 全流程：取镜像 → 拉源码 → 编译 → 登录
#      bash run.sh --from 3     # 从第 3 步开始（编译）
#      bash run.sh --check      # 只做健康检查
#
#  环境变量可覆盖：
#      WECHAT_VER=0x18005620    # 自定义客户端版本号
#      SRC_DIR=/path/to/src     # 自备协议源码目录
#      HOST_PORT=8058           # 服务端口
#      REDIS_DB=2               # Redis 库号
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$HERE/scripts/lib/common.sh"

FROM=1
CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from)  FROM="${2:-1}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --yes|-y) export ASSUME_YES=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

if [ "$CHECK_ONLY" = "1" ]; then
  exec bash "$HERE/scripts/05-verify.sh"
fi

STEPS=(
  "01-get-base-image.sh|获取 Ubuntu 24.04 基础镜像（绕开 Docker Hub）"
  "02-fetch-source.sh  |获取协议源码"
  "03-build.sh         |注入版本号 + 容器内编译"
  "04-login.sh         |启动服务 + 扫码登录（含显式确认）"
  "05-verify.sh        |健康检查"
)

printf '%s' "$C_BOLD"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║           微信 iPad 协议 · 一键部署工具包                    ║
║                                                              ║
║  把「拿到协议包却跑不起来」的常见障碍自动化处理：            ║
║    · Docker Hub 被墙      → 走 Ubuntu 官方 rootfs            ║
║    · GLIBC 版本过低       → 全程在 Ubuntu 24.04 容器内编译   ║
║    · 协议内核 .so 加载失败 → 自动注册动态库路径              ║
║    · 微信报「版本过低」   → 自动注入新版客户端版本号         ║
║    · 扫码后登录不完成     → 自动执行显式确认调用             ║
╚══════════════════════════════════════════════════════════════╝
BANNER
printf '%s\n' "$C_RESET"

i=0
for s in "${STEPS[@]}"; do
  i=$((i + 1))
  file="${s%%|*}"; desc="${s##*|}"
  if [ "$i" -lt "$FROM" ]; then
    info "跳过 步骤 $i: $desc"
    continue
  fi
  title "步骤 $i/5  $desc"
  bash "$HERE/scripts/$file" || {
    rc=$?
    die "步骤 $i 失败（退出码 $rc）。修复后可用 --from $i 从这一步继续。"
  }
done

title "全部完成 🎉"
log "服务端口     : ${HOST_PORT:-8058}"
log "二维码       : ${STATE_DIR:-$PWD/.state}/qr.png"
log "健康检查     : bash run.sh --check"
log "排错手册     : docs/TROUBLESHOOTING.md"
