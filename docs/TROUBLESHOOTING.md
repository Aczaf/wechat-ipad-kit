# 排错手册

按发生频率从高到低排列。每条都写清 **现象 / 原因 / 解法**。

---

## 目录

1. [docker pull ubuntu 失败（403 / 502 / 超时）](#1-docker-pull-ubuntu-失败)
2. [协议内核加载失败：GLIBC_2.38 not found](#2-协议内核加载失败glibc_238-not-found)
3. [Failed to load library: libv08.so / libz.so](#3-failed-to-load-library)
4. [登录接口 404 —— 找不到正确 URL 前缀](#4-登录接口-404)
5. [★ 手机显示「已通过」，服务器登录态却是空的](#5--手机显示已通过服务器登录态却是空的)
6. [微信返回 -106「你的应用版本过低」](#6-微信返回-106你的应用版本过低)
7. [编译报错 / 依赖下载慢](#7-编译报错--依赖下载慢)
8. [登录态反复掉线](#8-登录态反复掉线)

---

## 1. docker pull ubuntu 失败

**现象**

```
Error response from daemon: unexpected status from HEAD request to
https://docker.xuanyuan.me/v2/library/ubuntu/manifests/24.04: 403 Forbidden
```

或镜像源返回 `502 Bad Gateway`、拉取卡在 `Pulling fs layer` 不动。

**原因**

国内网络下 Docker Hub 与多数公共加速器对 `library/ubuntu` 的访问不稳定，
部分加速器对该命名空间返回 403。换加速器往往只是碰运气。

**解法**

**本项目不依赖 Docker Registry。** `scripts/01-get-base-image.sh` 直接下载
Ubuntu 官方 cloud image 的 rootfs tarball，再 `docker import` 成本地镜像：

```
curl <清华/中科大/官方镜像源>/noble-server-cloudimg-amd64-root.tar.xz
docker import noble-rootfs.tar.xz ubuntu24:latest
```

完全绕开 Registry，可重复、可离线缓存（缓存在 `~/.cache/wechat-ipad-kit/`）。

---

## 2. 协议内核加载失败：GLIBC_2.38 not found

**现象**

```
Failed to load library: /lib/x86_64-linux-gnu/libc.so.6:
  version `GLIBC_2.38' not found (required by lib/libv08.so)
```

也可能同时报 `GLIBCXX_3.4.32 not found`。

**原因**

协议内核 `libv08.so` 是**预编译二进制，源码不公开**，它编译时链接了较新的 glibc。
而 Ubuntu 22.04 只有 GLIBC 2.35，24.04 才有 2.39。**你无法重新编译它**，
只能换一个能满足它的运行环境。

**解法**

本项目全程在 **Ubuntu 24.04 容器**内运行，容器自带 GLIBC 2.39 + GLIBCXX 3.4.33：

| | 需要 | Ubuntu 22.04 | Ubuntu 24.04 |
|---|---|---|---|
| glibc | ≥ 2.38 | 2.35 ❌ | 2.39 ✅ |
| libstdc++ | ≥ 3.4.32 | 3.4.30 ❌ | 3.4.33 ✅ |

验证（应在容器内执行）：

```bash
docker run --rm -v "$PWD/wechat860-src":/src ubuntu24:latest \
  bash -c "ldd /src/lib/libv08.so | grep -i 'not found' || echo '依赖满足'"
```

> **不要**为了省事去升级宿主系统 —— 影响面大且可能弄坏其他服务。
> 用容器隔离是正确做法。

---

## 3. Failed to load library

**现象**

```
[Error] v08.go:39 Failed to load library:  libv08.so: cannot open shared object file
[Error] zlib.go:28 Failed to load library:  libz.so: cannot open shared object file
```

服务仍然起来了、端口也在监听、**二维码甚至能正常生成** —— 于是很容易被忽略，
但登录一定失败。

**原因**

`lib/` 目录不在动态链接器的搜索路径里。协议实现用 `dlopen("libv08.so")` 这种
**不带路径**的方式加载，所以必须在搜索路径中。

**解法**

启动容器时注册该目录（本项目 `04-login.sh` 已内置）：

```bash
echo '/src/lib' > /etc/ld.so.conf.d/wechat.conf
ldconfig
export LD_LIBRARY_PATH=/src/lib      # 双保险
```

**为什么这个坑值得单独列**：它是**静默失败**。服务看起来完全正常，
只有登录永远不成功，且日志里的报错藏在启动信息中间。

检查方法：

```bash
docker logs wechat-ipad 2>&1 | grep -i "Failed to load library"
```

---

## 4. 登录接口 404

**现象**

```
POST /Login/LoginGetQR          → 404
POST /api/Login/LoginGetQR      → 404
POST /VXAPI/Login/LoginGetQR    → 200   ← 实际是这个
```

**原因**

不同来源的构建，URL 前缀不同。常见的有 `/api`、`/VXAPI`、`/v1`，也有无前缀的。
**swagger 文档里写的是不带前缀的路径，直接照抄会 404** —— 这是最容易误导人的地方。

**解法**

不要猜，**逐个探测**。本项目 `04-login.sh` 的 `detect_prefix()` 会自动完成：

```bash
for p in "/api" "" "/VXAPI" "/v1" "/v2"; do
  curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://127.0.0.1:8058$p/Login/LoginGetQR" \
    -H 'Content-Type: application/json' -d '{"DeviceName":"iPad"}'
done
```

返回 200 的那个就是正确前缀，结果会缓存在 `.state/prefix.txt`。

**辅助手段** —— 直接从二进制提取已注册的路由：

```bash
strings main | grep -oE '/Login/[A-Za-z0-9_]+' | sort -u
```

---

## 5. ★ 手机显示「已通过」，服务器登录态却是空的

> **这是整个流程里最隐蔽、最耗时的坑。** 我自己在这里卡了整整几轮。

**现象**

- 手机微信明确提示「已确认登录」
- 服务日志正常，二维码也正常生成
- 但 Redis 里的登录数据始终是空壳：

```json
{"Uin": 0, "Wxid": "", "Sessionkey": null, "LoginDate": 0}
```

- 业务接口一律返回 `{"Code":-8,"Message":"异常：[Key:]数据不存在"}`

**原因**

**这个协议实现的登录确认不是自动的。**

扫码只是在微信服务端标记「这个 uuid 被确认了」。要让协议实现去**拉取登录态**
（换取 Uin / Sessionkey / SyncKey 并写入缓存），必须**再显式调用一次**：

```
POST /api/Login/LoginCheckQR?uuid=<取码时返回的 uuid>
```

不调用它，`Uin`/`Wxid`/`Sessionkey` 永远不会被写入。

**为什么难发现**：大多数同类项目是**自动轮询**的，使用者形成了「扫完就完事」的预期；
而这里需要主动触发，文档里也只是一行 `@router /LoginCheckQR [post]` 的注释。

**解法**

本项目 `04-login.sh` 在扫码后会自动执行这一步，并在失败时给出明确提示。
手动执行：

```bash
UUID=$(cat .state/uuid.txt)
curl -X POST "http://127.0.0.1:8058/api/Login/LoginCheckQR?uuid=$UUID" \
     -H 'Content-Type: application/json' -d '{}'
```

**成功时应看到**：

```json
{"Code":0,"Success":true,"Message":"登录成功",
 "Data":{"baseResponse":{"ret":0,"errMsg":{"string":"Everything is ok"}}}}
```

**判据（三者必须同时满足，缺一不算成功）**：

```
Uin        ≠ 0
Wxid       非空字符串
Sessionkey 非 null
```

> 经验：不要用「Redis 里有没有 key」判断登录成功 —— 取二维码时就会写入一个
> 占位记录（`Uin=0`）。必须看上面三个字段。

---

## 6. 微信返回 -106「你的应用版本过低」

**现象**

```json
{"ret": -106,
 "errMsg": {"string": "<e><ShowType>4</ShowType><Content><![CDATA[
   你的应用版本过低，请升级至最新版本后再登录。]]></Content></e>"}}
```

**原因**

协议实现内置的**客户端版本号**太旧，微信服务端拒绝。

**版本号编码规则（iOS/iPad 系）**

```
0x18 00 3E 20
 │   │  │   └── build（低 16 位）
 │   │  └────── 次版本
 │   └───────── 保留（00）
 └───────────── 平台：0x18 = iOS/iPad
```

| 版本号 | 约对应 |
|---|---|
| `0x18003B20` | 8.0.59 |
| `0x18003E20` | 8.0.62 |
| `0x18005020` | **8.0.80** |
| `0x18005620` | 约 8.0.86（更保险） |

**实测结论**：`8.0.62` 仍然被判定「过低」；**`8.0.80` 可以放行**。

**解法**

编译前注入新版本号：

```bash
WECHAT_VER=0x18005020 bash scripts/03-build.sh
```

需要改的地方（`03-build.sh` 会自动处理，且**幂等**）：

- `Algorithm/Util.go` 的 `IPadVersion`、`IPadVersionx`
- `baseinfo/basedefine.go` 的 `ClientVersion`、`PlistVersion`

> **注意**：二维码流程实际用的是 `Algorithm.IPadVersion`（不是 `baseinfo` 里那个）。
> 两处都改才稳妥。

**验证版本号真的写进去了**（`03-build.sh` 会自动做）：

```bash
python3 -c "
import struct
d=open('wechat860-src/main','rb').read()
print('出现次数:', d.count(struct.pack('<i', 0x18005020)))
"
```

> 血泪教训：我曾用**心算**把 `402669088` 误判成旧版本，得出「改动没生效」的错误结论，
> 白折腾一轮。**十六进制换算一定要用代码验证。**

---

## 7. 编译报错 / 依赖下载慢

**现象**

`go: downloading ...` 卡住，或 `dial tcp ... i/o timeout`。

**解法**

编译环境镜像里已预设国内代理：

```bash
go env -w GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct
go env -w GOSUMDB=off          # 关闭校验和数据库，避免额外外网请求
go env -w GOTOOLCHAIN=local    # 禁止自动下载别的 Go 版本
```

如果 Go 本体下载失败，可换镜像：

```
https://golang.google.cn/dl/          # 官方国内镜像（默认）
https://mirrors.aliyun.com/golang/    # 阿里云
```

编译耗时参考：首次约 **1 分钟**（含依赖下载），产物约 **32MB**。

---

## 8. 登录态反复掉线

**现象**：登录成功后过一段时间失效。

**可能原因与对策**

| 原因 | 对策 |
|---|---|
| Redis 被清空 | 不要 `FLUSHDB`；登录态就存在 Redis 里 |
| 容器重启丢失 | 确保 Redis 持久化（挂载卷 + `appendonly yes`） |
| 设备 ID 频繁变化 | 固定 `DeviceId`，避免每次启动都换设备 |
| 长时间无活动 | 保持心跳（多数实现内置 `HeartBeat`） |
| 微信风控 | 见下 |

**关于风控（务必了解）**

个人微信自动化**始终处于微信官方打击范围**。跨项目一致的事实是：

- 封号风险由**账号行为**决定，与是否付费无关
- 新号建议先静置几天再自动化
- 避免高频操作、批量加好友、群发
- **强烈建议用小号测试**，不要用主力号

本工具包只解决「让协议跑起来」的工程问题，**不改变风控风险**。

---

## 附：信息收集（提 issue 用）

```bash
bash run.sh --check
```

会输出容器状态、动态库加载情况、Redis、登录态和日志末尾，直接贴出来即可。

请**务必打码**：`Wxid`、`Uin`、`Sessionkey`、`Pwd`、任何 token。
