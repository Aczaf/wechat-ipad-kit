#!/usr/bin/env bash
# =============================================================================
#  步骤 3/5 :: 注入版本号 + 容器内编译
#
#  解决什么：
#    ① 宿主 GLIBC 太旧 → 全程在 Ubuntu24 容器里编译，产物链接容器内的新 glibc。
#    ② 微信服务端返回 -106「你的应用版本过低」→ 编译前把客户端版本号改新。
#    ③ libv08.so / libz.so 找不到 → 装进容器后用 ldconfig 注册。
#
#  版本号规则（iOS 系）：
#    形如 0x18 00 3E 20
#         │  │  │  └─ build 低 16 位
#         │  │  └──── 次版本
#         │  └─────── 保留（00）
#         └────────── 平台：0x18=iOS/iPad
#    例：0x18003B20≈8.0.59  0x18003E20≈8.0.62  0x18005020≈8.0.80
#    实测 8.0.62 仍被判定过低；8.0.80 可通过。可用 WECHAT_VER 覆盖。
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

SRC_DIR="${SRC_DIR:-$PWD/wechat860-src}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu24:latest}"
BUILDER_IMAGE="${BUILDER_IMAGE:-wechat-ipad-builder:latest}"
GO_VERSION="${GO_VERSION:-1.24.0}"
# 默认 0x18005020（≈8.0.80）；实测 8.0.62 会被微信拒绝
WECHAT_VER="${WECHAT_VER:-0x18005020}"

[ -f "$SRC_DIR/go.mod" ] || die "找不到源码（$SRC_DIR）。请先运行 scripts/02-fetch-source.sh"

title "注入客户端版本号: $WECHAT_VER"

# 计算人类可读版本，仅用于日志
human_ver="$(python3 - "$WECHAT_VER" <<'PY' 2>/dev/null || echo '?'
import sys
v = int(sys.argv[1], 16)
print(f"{(v>>24)&0xFF}.{(v>>16)&0xFF}.{v&0xFFFF}")
PY
)"
info "对应版本约为 $human_ver"

# 备份 + 原地替换（幂等：重复执行也安全）
patch_ver() {
  local file="$1" pattern="$2" desc="$3"
  [ -f "$SRC_DIR/$file" ] || { warn "跳过 $file（不存在）"; return 0; }
  [ -f "$SRC_DIR/$file.orig" ] || cp "$SRC_DIR/$file" "$SRC_DIR/$file.orig"
  # 用 .orig 作基准，保证多次执行结果一致
  if sed -E "s|${pattern}|var \3 = ${4:-int32}($WECHAT_VER) // patched|" \
       "$SRC_DIR/$file.orig" > "$SRC_DIR/$file"; then
    ok "$desc  ($file)"
  else
    warn "$desc 替换失败 ($file)"
  fi
}

# IPadVersion / IPadVersionx —— 二维码与登录流程实际使用的版本号
sed -E "s|var IPadVersion = int32\(0x[0-9A-Fa-f]+\)[^\n]*|var IPadVersion = int32($WECHAT_VER) // patched|" \
    "$SRC_DIR/Algorithm/Util.go.orig" 2>/dev/null >/dev/null || cp "$SRC_DIR/Algorithm/Util.go" "$SRC_DIR/Algorithm/Util.go.orig"
sed -E -i "s|var IPadVersion = int32\(0x[0-9A-Fa-f]+\)[^\n]*|var IPadVersion = int32($WECHAT_VER) // patched|" "$SRC_DIR/Algorithm/Util.go"
sed -E -i "s|var IPadVersionx = int32\(0x[0-9A-Fa-f]+\)[^\n]*|var IPadVersionx = int32($WECHAT_VER) // patched|" "$SRC_DIR/Algorithm/Util.go"
ok "Algorithm/Util.go"

sed -E -i "s|var ClientVersion = uint32\(0x[0-9A-Fa-f]+\)[^\n]*|var ClientVersion = uint32($WECHAT_VER) // patched|" "$SRC_DIR/baseinfo/basedefine.go"
sed -E -i "s|var PlistVersion = uint32\(0x[0-9A-Fa-f]+\)[^\n]*|var PlistVersion = uint32($WECHAT_VER) // patched|" "$SRC_DIR/baseinfo/basedefine.go"
ok "baseinfo/basedefine.go"

title "当前版本号定义"
grep -nE "IPadVersion = |IPadVersionx = " "$SRC_DIR/Algorithm/Util.go" || true
grep -nE "ClientVersion = uint32" "$SRC_DIR/baseinfo/basedefine.go" || true

# --------------------------------------------------------------- 构建器镜像
if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
  title "构建编译环境镜像（首次较慢）"
  docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 \
    || die "基础镜像 $BASE_IMAGE 不存在。请先运行 scripts/01-get-base-image.sh"

  BUILD_CTX="$(mktemp -d)"
  cat > "$BUILD_CTX/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/usr/local/go/bin:\$PATH

# 换国内 apt 源（失败不影响后续，保留原源即可）
RUN sed -i 's@//archive.ubuntu.com@//mirrors.aliyun.com@g; \\
            s@//security.ubuntu.com@//mirrors.aliyun.com@g' \\
        /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true

RUN apt-get update -qq && \\
    apt-get install -y -qq ca-certificates curl xz-utils git gcc g++ libc6-dev >/dev/null

# 安装 Go（走官方国内镜像）
RUN curl -fsSL -o /tmp/go.tgz https://golang.google.cn/dl/go${GO_VERSION}.linux-amd64.tar.gz \\
 && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \\
 && go version

# Go 模块代理（国内）
RUN go env -w GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct \\
 && go env -w GOSUMDB=off \\
 && go env -w GOTOOLCHAIN=local
EOF
  docker build -t "$BUILDER_IMAGE" "$BUILD_CTX" || die "编译环境镜像构建失败。"
  rm -rf "$BUILD_CTX"
  ok "编译环境就绪: $BUILDER_IMAGE"
else
  ok "编译环境已存在: $BUILDER_IMAGE"
fi

# --------------------------------------------------------------- 编译
title "容器内编译（首次会拉取大量 Go 依赖）"
docker run --rm \
  -v "$SRC_DIR":/src \
  -w /src \
  -e GOFLAGS=-mod=mod \
  "$BUILDER_IMAGE" \
  bash -lc 'export PATH=/usr/local/go/bin:$PATH && go build -o main . ' \
  || die "编译失败。请检查上面的 Go 报错信息。"

[ -x "$SRC_DIR/main" ] || die "编译结束但未生成 main 可执行文件。"

title "验证版本号是否真的写进二进制"
python3 - "$SRC_DIR/main" "$WECHAT_VER" <<'PY' || true
import struct, sys
path, ver = sys.argv[1], int(sys.argv[2], 16)
blob = open(path, 'rb').read()
pat = struct.pack('<i', ver)
n = blob.count(pat)
print(f"  目标版本常量 0x{ver:08X} 在二进制中出现 {n} 次")
if n == 0:
    print("  [WARN] 未找到该常量，版本号替换可能未生效！")
    sys.exit(1)
PY

title "完成"
log "可执行文件: $SRC_DIR/main  ($(du -h "$SRC_DIR/main" | cut -f1))"
log "下一步    : bash scripts/04-login.sh"
