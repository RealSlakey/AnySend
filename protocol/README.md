# LocalSend v2 协议规范（本项目实现参考）

> 本文档定义 Android(Kotlin) 和 HarmonyOS(ArkTS) 两端 LocalSend 协议实现的唯一标准。
> 两端字段名、端口、HTTP 路径必须严格一致。

## 常量

| 常量 | 值 | 说明 |
|---|---|---|
| PORT | 53317 | HTTP 服务端口（TCP） |
| PROTOCOL_VERSION | "2.0" | 协议版本号 |
| DISCOVERY_MULTICAST_ADDR | 224.0.0.167 | 组播地址（本项目不使用，改用 Tailscale Peer 发现） |
| DEVICE_TYPE_MOBILE | "mobile" | 设备类型：移动端 |
| DEVICE_TYPE_DESKTOP | "desktop" | 设备类型：桌面端 |

## HTTP API 路径

官方 LocalSend v2 只有 `prepare-upload` / `upload` 这一套；早期 AnySend 自造的
`send-request` / `send` 仍保留在接收端，仅为兼容旧版本客户端。

| 方法 | 路径 | 说明 | 归属 |
|---|---|---|---|
| GET | `/api/localsend/v2/info` | 获取接收端设备信息 | 标准 v2 |
| POST | `/api/localsend/v2/register` | 发送端注册自己，获取接收端设备信息 | 标准 v2 |
| POST | `/api/localsend/v2/prepare-upload` | 发送文件元数据，返回 `sessionId` + 每个文件的 token | 标准 v2 |
| POST | `/api/localsend/v2/upload?sessionId=&fileId=&token=` | 上传单个文件内容（body 为原始字节） | 标准 v2 |
| POST | `/api/localsend/v2/cancel?sessionId=` | 取消会话，释放接收端唯一的会话槽 | 标准 v2 |
| POST | `/api/localsend/v2/send-request` | `prepare-upload` 的旧别名（请求/响应体相同） | 兼容旧版 AnySend |
| POST | `/api/localsend/v2/send?sessionId=&fileId=&token=` | `upload` 的旧别名 | 兼容旧版 AnySend |

**发送端策略**：先打 `prepare-upload`，只有对端返回 404（旧版 AnySend）才回退
`send-request`。**不要**默认走旧路径，否则对官方 LocalSend 一定 404。

## 传输与配对码

- **接收端**：一律明文 HTTP，`/info` 返回 `"protocol": "http"`，官方客户端据此使用 HTTP。
- **发送端**：先发明文 HTTP；若连上了却读不到任何 HTTP 响应（状态 0），说明对端
  是 HTTPS-only（官方 LocalSend 默认开加密、每台设备一张自签证书），改用 TLS 重试，
  并在本次传输内记住该选择。
  - 自签证书**不校验链**（LocalSend 没有 CA 可链），链路仍然加密。
  - 鸿蒙端受系统 API 限制：`@ohos.net.socket` 的 `TLSSocket` 只接受系统 CA，无法信任
    自签证书，因此只能给出明确提示，不能直连 HTTPS 对端。
- **配对码（PIN）**：`prepare-upload` 请求体可带 `"pin": "1234"`；接收端未开启 PIN 时
  省略该字段。接收端要求 PIN 但未提供/不匹配时返回 **401**，发送端据此提示用户输入。

## 数据结构

### DeviceInfo

```json
{
  "alias": "My Android",
  "version": "2.0",
  "deviceModel": "Pixel 7",
  "deviceType": "mobile",
  "fingerprint": "a1b2c3d4e5f6",
  "port": 53317,
  "protocol": "http",
  "download": true
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| alias | string | 是 | 设备显示名称 |
| version | string | 是 | 协议版本，固定 "2.0" |
| deviceModel | string | 是 | 设备型号 |
| deviceType | string | 是 | mobile / desktop / web / headless / server |
| fingerprint | string | 是 | 设备唯一指纹（随机生成，持久化） |
| port | int | 是 | HTTP 服务端口，固定 53317 |
| protocol | string | 是 | 固定 "http" |
| download | bool | 是 | 是否支持下载，固定 true |

### FileInfo

```json
{
  "id": "file-uuid-1",
  "fileName": "photo.jpg",
  "size": 1234567,
  "fileType": "image/jpeg",
  "sha256": null,
  "preview": null
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| id | string | 是 | 文件唯一 ID（UUID） |
| fileName | string | 是 | 文件名（含扩展名） |
| size | int | 是 | 文件大小（字节） |
| fileType | string | 是 | MIME 类型 |
| sha256 | string \| null | 否 | 文件 SHA256 哈希（可空） |
| preview | string \| null | 否 | 缩略图 base64（可空） |

### Register 请求

- 方法: POST `/api/localsend/v2/register`
- Body: `DeviceInfo` JSON
- 响应 200: `DeviceInfo` JSON（接收端的设备信息）
- 响应 403: 被拒绝

### SendRequest 请求

```json
{
  "info": { ...DeviceInfo... },
  "files": {
    "file-uuid-1": { ...FileInfo... },
    "file-uuid-2": { ...FileInfo... }
  }
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| info | DeviceInfo | 是 | 发送端设备信息 |
| files | map<string, FileInfo> | 是 | 待发送文件映射，key 为 file id |
| pin | string | 否 | 接收端开启配对码保护时必填 |

### SendRequest 响应

成功 (200):
```json
{
  "sessionId": "session-uuid",
  "files": {
    "file-uuid-1": "token-1",
    "file-uuid-2": "token-2"
  }
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| sessionId | string | 是 | 传输会话 ID |
| files | map<string, string> | 是 | **仅包含被接受的文件**，value 为该文件的上传 token |

`files` 里没有的 fileId 即视为被拒绝；整单被拒返回 403，需要/错配对码返回 401。

### Upload 请求

- 方法: POST `/api/localsend/v2/upload?sessionId={sessionId}&fileId={fileId}&token={token}`
- Headers: `Content-Type: {fileType}`
- Body: 文件原始字节流
- 响应 200: 成功（空 body）；token 不匹配返回 403

### Cancel 请求

```json
{
  "sessionId": "session-uuid"
}
```

## 传输流程

```
发送端                                    接收端
  |                                          |
  |--- 1. GET /info ----------------------->| (可选，探测存活)
  |                                          |
  |--- 2. POST /register (DeviceInfo) ----->|
  |<-- 200 DeviceInfo ----------------------|
  |                                          |
  |--- 3. POST /prepare-upload ------------>|
  |       {info, files, pin?}                |
  |<-- 200 {sessionId, files{id:token}} ----|
  |       (401 = 需要配对码，404 = 旧版对端)   |
  |                                          |
  |--- 4. POST /upload?sessionId=&fileId=&token= -->|
  |       (每个 accept 的文件，body=字节)     |
  |<-- 200 ---------------------------------|
  |                                          |
  |--- 5. (可选) POST /cancel?sessionId= -->|
```

明文探测失败（连上但无响应）时，第 2 步及之后的所有请求改走 TLS 重放。

## 本项目定制说明

1. **设备发现不使用组播**：由于 Tailscale 不转发组播，本项目通过 Tailscale Peer API 获取对端 IP，跳过 LocalSend 的 UDP 组播发现阶段。
2. **传输走 Tailscale IP**：所有 HTTP 请求直接发往对端的 Tailscale IP:53317。
3. **register 步骤可省略**：若已通过 /info 获取接收端信息，可跳过 register 直接 prepare-upload。
