#!/usr/bin/env bash
# =============================================================================
#  步骤 4/5 :: 启动服务 + 扫码登录 + 显式确认
#
#  ★ 本脚本解决整个流程里最隐蔽的一个坑 ★
#
#  现象：手机微信明明显示「已通过」，但服务器上登录态一直是空的。
#  原因：这个协议实现的登录确认【不是自动的】。
#        扫码后必须再显式调用一次：
#            POST /api/Login/LoginCheckQR?uuid=<取码时返回的 uuid>
#        不调用它，Uin / Wxid / Sessionkey 永远不会被写入。
#        外部看就是「扫码成功但机器人没反应」，极难自行定位。
#
#  另一个坑：URL 前缀。不同构建前缀不同（实测 /api、/VXAPI、无前缀都有），
#            本脚本会自动探测。
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

SRC_DIR="${SRC_DIR:-$PWD/wechat860-src}"
BUILDER_IMAGE="${BUILDER_IMAGE:-wechat-ipad-builder:latest}"
CONTAINER="${CONTAINER:-wechat-ipad}"
HOST_PORT="${HOST_PORT:-8058}"
REDIS_DB="${REDIS_DB:-2}"
STATE_DIR="${STATE_DIR:-$PWD/.state}"
LOG_FILE="${LOG_FILE:-$PWD/wechat-ipad.log}"

mkdir -p "$STATE_DIR"
UUID_FILE="$STATE_DIR/uuid.txt"

require_cmd docker "请先安装 Docker。"
require_cmd curl   "请先安装 curl。"

# --------------------------------------------------------------- 依赖：Redis
ensure_redis() {
  if has_cmd redis-cli && redis-cli ping >/dev/null 2>&1; then
    ok "Redis 可用"
    return 0
  fi
  warn "本机未检测到可用 Redis。"
  log  "协议实现依赖 Redis 存放登录缓存。可选："
  log  "  a) 安装: sudo apt-get install -y redis-server && sudo systemctl start redis-server"
  log  "  b) 用 Docker: docker run -d --name wechat-redis -p 6379:6379 redis:7-alpine"
  if has_cmd docker; then
    if confirm "现在用 Docker 起一个 Redis?"; then
      docker rm -f wechat-redis >/dev/null 2>&1 || true
      docker run -d --name wechat-redis -p 6379:6379 --restart unless-stopped redis:7-alpine >/dev/null
      sleep 2
      has_cmd redis-cli && redis-cli ping >/dev/null 2>&1 && ok "Redis 已启动" || warn "Redis 启动后仍无法连接，请自行处理"
    fi
  fi
}

# ------------------------------------------------------------- 启动（幂等）
start_service() {
  title "在容器内启动协议服务"
  [ -x "$SRC_DIR/main" ] || die "找不到可执行文件 $SRC_DIR/main。请先运行 scripts/03-build.sh"

  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

  # 关键：把 libv08.so / libz.so 所在目录注册进动态链接器搜索路径
  #      并额外设置 LD_LIBRARY_PATH 双保险
  docker run -d --name "$CONTAINER" \
    --network host \
    --restart unless-stopped \
    -v "$SRC_DIR":/src \
    -w /src \
    -e LD_LIBRARY_PATH=/src/lib \
    "$BUILDER_IMAGE" \
    bash -c "echo '/src/lib' > /etc/ld.so.conf.d/wechat.conf && ldconfig && cd /src && exec ./main" \
    >/dev/null

  info "容器已启动，等待初始化…"
  local _i
  for _i in $(seq 1 30); do
    sleep 1
    if curl -fsS -o /dev/null -m 2 "http://127.0.0.1:$HOST_PORT/" 2>/dev/null; then break; fi
  done

  # 检查 .so 是否加载成功（这是最容易被忽略的静默失败）
  if docker logs "$CONTAINER" 2>&1 | grep -qi "Failed to load library"; then
    warn "检测到动态库加载失败！协议内核未生效，登录必定失败。"
    docker logs "$CONTAINER" 2>&1 | grep -i "Failed to load library" | head -5
    log  "排查：确认 lib/libv08.so 存在，且容器内 ldconfig 已注册该目录。"
  fi

  ss -tlnp 2>/dev/null | grep -q ":$HOST_PORT " \
    && ok "服务已监听 $HOST_PORT" \
    || warn "未检测到端口 $HOST_PORT，请查看容器日志: docker logs $CONTAINER"
}

# ------------------------------------------------------------- 探测路由前缀
# 不同构建的 URL 前缀不同，靠探测确定，而不是猜
detect_prefix() {
  if [ -f "$STATE_DIR/prefix.txt" ]; then
    cat "$STATE_DIR/prefix.txt"; return 0
  fi
  title "探测 API 路由前缀"
  local p code
  for p in "/api" "" "/VXAPI" "/v1" "/v2"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 -X POST \
            "http://127.0.0.1:$HOST_PORT$p/Login/LoginGetQR" \
            -H 'Content-Type: application/json' -d '{"DeviceName":"iPad"}' 2>/dev/null || echo 000)"
    if [ "$code" = "200" ]; then
      ok "前缀 = '${p:-（无）}'"
      printf '%s' "$p" > "$STATE_DIR/prefix.txt"
      printf '%s' "$p"
      return 0
    fi
    info "前缀 '${p:-（无）}' → HTTP $code"
  done
  die "未能探测到可用的登录接口。请确认服务已启动，或手动检查 docker logs $CONTAINER"
}

# ------------------------------------------------------------------ 取二维码
get_qr() {
  local prefix="$1"
  title "请求登录二维码"
  curl -sS -m 60 -X POST "http://127.0.0.1:$HOST_PORT$prefix/Login/LoginGetQR" \
    -H 'Content-Type: application/json' \
    -d '{"DeviceName":"iPad"}' \
    -o "$STATE_DIR/qr.json" -w 'HTTP %{http_code}  %{size_download}B\n'

  python3 - "$STATE_DIR" <<'PY' || die "二维码解析失败，请查看 $STATE_DIR/qr.json"
import base64, json, os, sys
d = os.path.abspath(sys.argv[1])
resp = json.load(open(os.path.join(d, 'qr.json'), encoding='utf-8-sig'))
data = resp.get('Data') or {}
qr = data.get('QrBase64') or ''
uuid = data.get('Uuid') or ''
if not qr:
    print("  响应中没有二维码字段：", json.dumps(resp, ensure_ascii=False)[:300]); sys.exit(1)
raw = base64.b64decode(qr.split(',', 1)[-1])
open(os.path.join(d, 'qr.png'), 'wb').write(raw)
open(os.path.join(d, 'uuid.txt'), 'w').write(uuid)
print(f"  二维码已保存 : {os.path.join(d, 'qr.png')}  ({len(raw)} 字节)")
print(f"  UUID        : {uuid}")
PY
}

# --------------------------------------------------------- 显式确认（最关键）
confirm_login() {
  local prefix="$1" uuid="$2"
  title "★ 显式确认登录（关键步骤，缺了它登录永远不会完成）"
  info "调用 POST $prefix/Login/LoginCheckQR?uuid=$uuid"

  local resp
  resp="$(curl -sS -m 60 -X POST \
            "http://127.0.0.1:$HOST_PORT$prefix/Login/LoginCheckQR?uuid=$uuid" \
            -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo '{}')"
  printf '%s' "$resp" > "$STATE_DIR/checkqr.json"

  python3 - "$STATE_DIR" <<'PY'
import json, os, re, sys
d = os.path.abspath(sys.argv[1])
try:
    r = json.load(open(os.path.join(d, 'checkqr.json'), encoding='utf-8-sig'))
except Exception:
    print("  [WARN] 响应无法解析，原始内容：")
    print("        " + open(os.path.join(d, 'checkqr.json'), encoding='utf-8',
                             errors='replace').read()[:300])
    sys.exit(2)

    data = r.get('Data') or {}
br   = data.get('baseResponse') or {}
ret  = br.get('ret')
msg  = ((br.get('errMsg') or {}).get('string') or '')
text = re.search(r'<!\[CDATA\[(.*?)\]\]>', msg, re.S)
text = text.group(1) if text else msg

print(f"  Code={r.get('Code')}  Success={r.get('Success')}  Message={r.get('Message')}")
print(f"  ret={ret}")
if text:
    print(f"  微信返回: {text[:200]}")

if ret == -106:
    print()
    print("  >>> 应用版本过低。请提高版本号后重新编译：")
    print("      WECHAT_VER=0x18005620 bash scripts/03-build.sh   # ≈8.0.86")
    sys.exit(1)
if ret == 0 and r.get('Success'):
    print()
    print("  >>> 微信已接受登录")
    sys.exit(0)
sys.exit(2)
PY
}

# ------------------------------------------------------------------ 校验登录态
verify_state() {
  title "校验登录态（权威判据）"
  if ! has_cmd redis-cli; then
    warn "缺少 redis-cli，跳过自动校验。请自行检查 Redis DB $REDIS_DB。"
    return 2
  fi
  local found=0
  local key
  for key in $(redis-cli -n "$REDIS_DB" --scan 2>/dev/null | grep -vE '^(wechat|devId):'); do
    local out
    out="$(redis-cli -n "$REDIS_DB" GET "$key" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
uin=d.get("Uin") or 0
wxid=d.get("Wxid") or ""
sk=d.get("Sessionkey")
if uin and wxid and sk is not None:
    print(f"OK|{wxid}|{uin}")
' 2>/dev/null)"
    if [ -n "$out" ]; then
      found=1
      log "  ✅ 登录成功"
      log "     Wxid : $(echo "$out" | cut -d'|' -f2)"
      log "     Uin  : $(echo "$out" | cut -d'|' -f3)"
      log "     Redis DB$REDIS_DB key: $key"
    fi
  done
  [ "$found" -eq 1 ] && return 0
  warn "未发现有效登录态（Uin/Wxid/Sessionkey 未全部就绪）"
  return 1
}

# ================================================================== 主流程
main() {
  require_cmd python3 "解析二维码需要 python3。"
  ensure_redis
  start_service

  local prefix; prefix="$(detect_prefix)"
  get_qr "$prefix"

  local uuid; uuid="$(cat "$UUID_FILE" 2>/dev/null || echo '')"

  echo
  printf '%s' "$C_BOLD"
  log "════════════════════════════════════════════════════════════"
  log "  请用微信扫描二维码："
  log "    $STATE_DIR/qr.png"
  log ""
  log "  在手机端点击【确认登录】后，回到这里按回车继续。"
  log "  注意：二维码通常 2~5 分钟过期。"
  log "════════════════════════════════════════════════════════════"
  printf '%s' "$C_RESET"
  read -r _

  confirm_login "$prefix" "$uuid" || true

  # 扫码后等一下再查，给服务端一点写入时间
  sleep 2
  if verify_state; then
    title "完成"
    log "登录态已建立，可继续: bash scripts/05-verify.sh"
  else
    title "尚未登录"
    log "常见原因："
    log "  1) 手机还没点【确认登录】→ 再运行本脚本重试"
    log "  2) 二维码已过期        → 重新运行本脚本"
    log "  3) 版本号仍偏低        → WECHAT_VER=0x18005620 bash scripts/03-build.sh 后重试"
    log "  4) 协议内核未加载      → docker logs $CONTAINER | grep 'Failed to load library'"
    exit 1
  fi
}

main "$@"
