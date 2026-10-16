# 协议备忘

记录排查过程中沉淀下来的、可复用的技术结论。与具体项目无关，换实现也能用。

---

## 1. 登录流程的完整时序

大多数「扫码登录」文档只讲到扫码，实际完整链路是：

```
① 请求二维码
   POST {prefix}/Login/LoginGetQR
   ← { Code:1, Data:{ QrBase64, Uuid, QrUrl, ExpiredTime } }
   注意：此处 Redis 已写入占位记录（Uin=0, Wxid=""）—— 不代表任何成功

② 用户扫码 + 手机确认
   （发生在微信客户端，服务器不产生日志）

③ ★ 主动查询确认结果
   POST {prefix}/Login/LoginCheckQR?uuid={Uuid}
   ← { Code:0, Data:{ baseResponse:{ ret:0 } } }
   这一步才真正换取登录态（Uin / Sessionkey / SyncKey）并落库

④ 校验（权威判据）
   Redis 中该账号记录满足：Uin≠0 且 Wxid非空 且 Sessionkey非null
```

**关键点**：第 ③ 步在不同实现里可能是：

- **自动轮询**（最常见）—— 扫码后服务端自己定时查
- **显式调用**（本项目遇到的）—— 必须外部触发

遇到「扫码成功但登录态为空」，第一件事就是确认属于哪一种。

---

## 2. 版本号编码

### iOS / iPad

```
0x18003B20
  ││││││││
  │││││││└┴─ build        (低 16 位)
  ││││└┴┴─── 次版本
  ││└┴────── 保留 00
  └┴──────── 平台 0x18
```

### 其他平台前缀

| 平台 | 前缀 | 示例 |
|---|---|---|
| iOS / iPad | `0x18` | `0x18005020` |
| Android | `0x28` | `0x28003a35` |
| Windows | `0x63` | `0x63090C11` |
| Mac | `0x13` | `0x1308080B` |
| 车机 | `0x21` | `0x2100091B` |

### 换算工具

```python
def dec(v):
    return f"{(v>>24)&0xFF}.{(v>>16)&0xFF}.{v&0xFFFF}"

dec(0x18005020)   # '24.0.20512'
```

> 微信版本号的第三段是 build，不是「8.0.80」里的 80。
> 实际对应关系靠经验对照，别自己推导。

### 提升版本号的原因

微信服务端会校验客户端版本，过低直接拒绝（`ret: -106`）。
把版本号改新是常规做法，**但要注意**：

- 版本号不能乱填 —— 要和**设备型号 / 系统版本**大致匹配
- 改完必须验证真的写进了二进制（见 TROUBLESHOOTING 第 6 节）
- 8.0.62 被拒、8.0.80 通过 —— 说明门槛在两者之间

---

## 3. 动态库加载

协议内核通常是**预编译的 `.so`**（源码不公开），加载方式大致两类：

```go
// 不带路径 —— 依赖动态链接器搜索路径
dlopen("libv08.so")

// 带路径 —— 直接指定
dlopen("./lib/libv08.so")
```

第一类必须让搜索路径包含该目录：

```bash
echo '/path/to/lib' > /etc/ld.so.conf.d/wechat.conf
ldconfig
export LD_LIBRARY_PATH=/path/to/lib
```

**为什么强调**：`dlopen` 失败**不会让进程退出**，只是打印一行日志，
服务照常启动、端口照常监听、二维码照常生成 —— 但登录永远失败。
属于典型的静默失败。

排查：

```bash
docker logs <container> 2>&1 | grep -i "Failed to load library"
ldd /path/to/libv08.so | grep "not found"
```

---

## 4. 路由前缀

**swagger / 文档里写的路径通常不带前缀**，而实际注册时带前缀。
照抄文档必然 404。

已知出现过的前缀：`/api`、`/VXAPI`、`/v1`、`/v2`、无前缀。

两种定位手段：

```bash
# ① 暴力探测（可靠）
for p in /api "" /VXAPI /v1 /v2; do
  echo -n "$p -> "
  curl -s -o /dev/null -w '%{http_code}\n' -X POST \
    "http://127.0.0.1:8058$p/Login/LoginGetQR" \
    -H 'Content-Type: application/json' -d '{}'
done

# ② 从二进制提取（更快，但可能含未注册的字符串）
strings main | grep -oE '/Login/[A-Za-z0-9_]+' | sort -u
```

---

## 5. 关键接口速查

| 用途 | 路径（不含前缀） |
|---|---|
| 取二维码 | `POST /Login/LoginGetQR` |
| **确认登录** | `POST /Login/LoginCheckQR?uuid=` |
| 二次自动登录 | `POST /Login/LoginTwiceAutoAuth?wxid=` |
| 心跳 | `POST /Login/HeartBeat` |
| 自己资料 | `POST /User/GetContractProfile` |
| 好友列表 | `POST /Friend/GetContractList` |
| 发文本 | `POST /Msg/SendTxt` |
| 发图片 | `POST /Msg/UploadImg` |
| 群列表 | `POST /Group/GroupList` |

参数风格不统一（有的要 body JSON，有的要 query string），
**以实际探测为准**。

---

## 6. 登录态存储

多数实现把登录态放在 **Redis**，结构类似：

```json
{
  "Uin": 3947300652,
  "Wxid": "wxid_xxxxxxxx",
  "Uuid": "...",
  "Aeskey": "...",
  "Sessionkey": "..." | null,
  "SyncKey": null,
  "Deviceid_str": "49...",
  "ClientVersion": 402673696,
  "OsVersion": "18.8.1",
  "RomModel": "iPad14,4",
  "LoginDate": 0
}
```

**注意**：

- DB 号因实现而异（见过 1、2、7），要确认配置里的 `redisdbnum`
- **不要 FLUSHDB** —— 会丢登录态
- `Uin`/`Wxid`/`Sessionkey` 才是成功判据，key 存在≠已登录

---

## 7. 环境要求汇总

| 项目 | 要求 | 说明 |
|---|---|---|
| glibc | ≥ 2.38 | 协议内核链接需求；Ubuntu 24.04 满足 |
| libstdc++ | ≥ 3.4.32 | 同上 |
| Go | 1.24+ | 若从源码编译 |
| Redis | 任意近期版本 | 存登录态 |
| 内存 | ≥ 512MB | 实测服务本身约 10~30MB |
| 架构 | x86_64 | 需与协议包架构一致 |

**不需要**：Windows、微信客户端、图形界面、硬件虚拟化。
（这些都是「本地 hook 方案」才需要的，服务端协议方案不需要。）

---

## 8. 命名与概念澄清

| 说法 | 实际含义 |
|---|---|
| iPad 协议 / Pad 协议 | 模拟 iPad 微信客户端的通信协议（服务端实现，不跑微信） |
| hook / 注入 / DLL | 在真实微信客户端里注入代码（**需要 Windows + 微信**） |
| sidecar | 协议服务的适配层，本身不是协议实现 |
| 协议内核 | 真正实现加密通信的二进制（通常闭源、预编译） |
| 62 数据 / Data62 | 一种登录凭证格式，可免扫码登录 |
| A16 | 另一种登录方式（账号密码） |

**重要区分**：

- **服务端协议方案**（本项目）—— Linux 可跑，无需微信客户端
- **本地 hook 方案**（wxhook / WeChatFerry 等）—— **必须** Windows + 已登录的微信客户端

选型时先分清这两类，能省很多时间。
