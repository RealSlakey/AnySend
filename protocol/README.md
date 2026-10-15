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

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/localsend/v2/info` | 获取接收端设备信息 |
| POST | `/api/localsend/v2/register` | 发送端注册自己，获取接收端设备信息 |
| POST | `/api/localsend/v2/send-request` | 发送文件元数据请求，接收端返回接受/拒绝 |
| POST | `/api/localsend/v2/send` | 上传文件内容 |
| POST | `/api/localsend/v2/cancel` | 取消传输会话 |

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

### SendRequest 响应

成功 (200):
```json
{
  "sessionId": "session-uuid",
  "files": {
    "file-uuid-1": "accept",
    "file-uuid-2": "cancel"
  }
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| sessionId | string | 是 | 传输会话 ID |
| files | map<string, string> | 是 | 文件决策，value 为 "accept" 或 "cancel" |

全部拒绝时返回 403。

### Send 请求

- 方法: POST `/api/localsend/v2/send?sessionId={sessionId}&fileId={fileId}`
- Headers: `Content-Type: {fileType}`
- Body: 文件原始字节流
- 响应 200: 成功（空 body）

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
  |--- 3. POST /send-request -------------->|
  |       {info, files}                      |
  |<-- 200 {sessionId, files{id:decision}} -|
  |       (或 403 全部拒绝)                   |
  |                                          |
  |--- 4. POST /send?sessionId=&fileId= -->|
  |       (每个 accept 的文件，body=字节)     |
  |<-- 200 ---------------------------------|
  |                                          |
  |--- 5. (可选) POST /cancel ------------->|
```

## 本项目定制说明

1. **设备发现不使用组播**：由于 Tailscale 不转发组播，本项目通过 Tailscale Peer API 获取对端 IP，跳过 LocalSend 的 UDP 组播发现阶段。
2. **传输走 Tailscale IP**：所有 HTTP 请求直接发往对端的 Tailscale IP:53317。
3. **register 步骤可省略**：若已通过 /info 获取接收端信息，可跳过 register 直接 send-request。
