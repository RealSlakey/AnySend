# AnySend 屏幕镜像 · Shizuku 桥接方案

取代 `specs/scrcpy-mirror-phase1`（那版走 WiFi ADB / 无线调试 TLS + SPAKE2 配对，实测在「安卓开热点」场景下互斥不可用）。

## 目标

鸿蒙端镜像安卓屏幕并支持触摸控制，要求**无感连接**：零 adb、零无线调试、零配对弹窗。
- 阶段一（本轮）：同一局域网直连（安卓 TCP 监听 ← 鸿蒙直连）。
- 阶段二（本轮不做）：Tailscale 跨网兜底。
- 热点代码（Shizuku 开 AP）**保留但不启用**。

## 已源码确认的关键事实（勿再调研）

1. scrcpy-server v3.3.4 jar 已经 vendored：`harmonyos/entry/src/main/resources/rawfile/scrcpy-server-v3.3.4`（90,980 B）。
2. 启动方式：`CLASSPATH=<jar> app_process / com.genymobile.scrcpy.Server 3.3.4 scid=<hex> tunnel_forward=true video=true audio=false control=true ...`。
3. **forward 模式（tunnel_forward=true）**：server 自己创建 `LocalServerSocket("scrcpy_<scid>")` 并 **accept**，顺序 **video → audio → control**；客户端逐条 connect。故桥接进程是 LocalSocket 的**客户端**，角色与参考实现一致。
4. 抽象命名空间（`LocalSocket`）对同设备任意进程可见。
5. shell UID 2000 跑 `app_process` 与 `adb shell` 等价 → 录屏 + 注入触摸权限都够。
6. 原生层：`TcpChannel(host, port)`（getaddrinfo + connect + 重试）已实现且可用；`ScrcpyStreamManager` 的 video/control 线程通过 `createByteStream(adb_, channel_, stream_, name)` 取值，只要 `channel_` 非空即可工作 → **直连模式只需填 `videoChannel_/controlChannel_`，`adb_=nullptr`、`videoStreamId=controlStreamId=-1`**。
7. `localhost` 监听即可覆盖：桥监听绑 `0.0.0.0`。
8. 两端 Tailscale 都是**用户态 tsnet**（无内核网卡）：`MirrorAutoConnect.ets` 注释明确「系统 HTTP 栈不会走 tsnet」。故原生 `connect()` 到 100.x **不通** —— 阶段二必须走 Go 侧 tsnet↔localhost 代理。

## 架构

```
鸿蒙 MirrorPage
  ├─ (Tailscale) POST mirror-prepare → 安卓 LocalSendServer（复用 MirrorAutoConnect.askMirrorPrepare）
  └─ DirectStreamClient → nativeStartDirectStreams(host, videoPort, controlPort, surfaceId, cb, fps)
                                │
                     TcpChannel(video) / TcpChannel(control)   ← 局域网 IP
                                │
安卓 Shizuku UserService（shell UID 2000）= 镜像桥
  ├─ 收 App 传过来的 jar 字节 → 写 /data/local/tmp/scrcpy-server-v3.3.4
  ├─ Runtime.exec 起 scrcpy-server（forward 模式）
  ├─ TCP 监听 videoPort / controlPort（绑 0.0.0.0）
  └─ 每条网络连接 → LocalSocket.connect("scrcpy_<scid>") → 双向 pump（顺序 video → control）
```

顺序性：server 先 accept video 再 accept control；桥也按 video → control 串行配对，鸿蒙端 native 也按 video → control 顺序建连（`startDirect` 内保证）。三方顺序天然一致，无需额外协商。

## 文件与改动

### 安卓端

| 文件 | 改动 |
|---|---|
| `android/app/src/main/assets/scrcpy-server-v3.3.4` | 新增（从鸿蒙 rawfile 原样复制，90,980 B ≈ 89 KB，远低于 binder 1 MB 限制） |
| `android/app/src/main/aidl/com/slakey/anysend/IMirrorShizukuService.aidl` | 新增 `String startMirrorBridge(in byte[] jar, in String argsJson)` / `void stopMirrorBridge()` |
| `MirrorShizukuService.kt` | 新增镜像桥：写 jar → `Runtime.exec("/system/bin/sh -c \"...\"")` 起 server → 双 `ServerSocket` 监听 → `LocalSocket` 泵线程；`stopMirrorBridge()` 杀 server 进程 + 关监听 |
| `MirrorHotspotController.kt` | `USER_SERVICE_VERSION` → 3；新增 `startBridgeAndWait(context, jar: ByteArray, args: String): MirrorBridgeInfo?`（阻塞 ≤8 s），字段 `videoPort`/`controlPort`/`scid` |
| `protocol/LocalSendServer.kt` `handleMirrorPrepare()` | 读 assets jar → 算法同上 argsJson → 调桥 → 响应**新增** `videoPort`/`controlPort`/`scid`，保留现有全部字段（`ip`/`port`/`hotspotOn`/`ssid`/`password`/`wirelessPort`/`wirelessEnabled`） |

服务端 argsJson 内容（拍板值）：`scid=<8位hex> tunnel_forward=true video=true audio=false control=true max_size=1600 max_fps=60 video_bit_rate=8000000 cleanup=false log_level=info`。

### 鸿蒙 native

| 文件 | 改动 |
|---|---|
| `cpp/scrcpy/ScrcpyStreamManager.h` | 新增 `int32_t startDirect(const std::string& host, uint16_t videoPort, uint16_t controlPort, const Config&, StreamEventCallback)` |
| `cpp/scrcpy/manager/ScrcpyStreamManagerDirect.cpp` | 新增实现：`new TcpChannel(host, videoPort/controlPort)` 填 `videoChannel_/controlChannel_` → `running_=true` → `initPacketPools()` → 起 `videoThread_` / `controlThread_` / `controlSendThread_`；失败回滚并返回负码 |
| `cpp/scrcpy/CMakeLists.txt` | 源码列表加 `manager/ScrcpyStreamManagerDirect.cpp` |
| `cpp/scrcpy/napi_init.cpp` | 新增 `NativeStartDirectStreams(host, videoPort, controlPort, surfaceId, audioSampleRate, audioChannelCount, callback, videoFrameRate)`（照 `NativeStartStreams` 2846-2958 行的模式，`Config{reverse=false, expectVideo=true, expectAudio=false, expectControl=true, sendDummyByte=true}`），并注册到属性表 |
| `ets/types/libscrcpy_native.d.ts` | 新增 `nativeStartDirectStreams` 声明 |

### 鸿蒙 ArkTS

| 文件 | 改动 |
|---|---|
| `ets/scrcpy/client/tools/DirectStreamClient.ets` | 新增：`start(host, videoPort, controlPort, surfaceId, listener)` → 等 surface → `nativeStartDirectStreams`；`stop()` → `nativeStopStreamsAsync`；事件映射沿用 `NativeStreamListener` 语义 |
| `ets/adb/MirrorAutoConnect.ets` | `MirrorPrepareInfo`/`MirrorPrepareResp` 增加 `videoPort`/`controlPort`/`scid`；新增 `resolveBridgeTarget(onNote)`：tailnet 问 mirror-prepare → 拿到 `ip`+ports → TCP 探测局域网可达 → 返回 `{host, videoPort, controlPort, kind: 'lan'}` |
| `ets/pages/MirrorPage.ets` | 删除配对 sheet / 无线调试端口输入 / 手动地址；「开始镜像」= 自动 `resolveBridgeTarget` → `DirectStreamClient`；保留 connecting/mirroring/error 三态与悬浮信息条、3 s 自动隐藏逻辑 |

## 触摸控制

不在 ArkTS 实现。沿用参考实现：C++ 侧 `RegisterNativeXComponent` + XComponent 生命周期 `DispatchTouchEvent` → 组 `INJECT_TOUCH_EVENT` 写 control channel。**ArkTS 页面不得自行注入 touch 消息。**

## 阶段边界

- 阶段一：局域网直连（出画面 + 触摸 + 退出清理）。
- 阶段二：Tailscale 兜底（鸿蒙 Go 侧 `dial→127.0.0.1:<临时端口>` 泵、安卓 Go 侧 `listen→127.0.0.1:<桥端口>` 泵）。
- 不做：音频、剪贴板、旋转重配解码器。

## 验证步骤

1. 双端构建（必须 `dangerouslyDisableSandbox`）：
   - 鸿蒙 `node <hvigor.js> --mode module -p product=default -p buildMode=debug assembleHap --no-daemon`（cwd `harmonyos/`，`DEVECO_SDK_HOME` + DevEco node + openjdk@17）
   - 安卓 `JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew assembleDebug`（cwd `android/`）
2. 装机：`hdc tconn 192.168.80.90:38367 && hdc install -r <signed hap>`；`adb connect 192.168.80.132:5555 && adb -s 192.168.80.132:5555 install -r -d <apk>`。
   （hdc/安卓 IP 端口会变，装机前先确认在线）
3. 安卓端确认 Shizuku 运行且已授权（首次会弹一次允许框；之后不再弹）。
4. `curl -m 20 http://192.168.80.132:53317/api/anysend/v1/mirror-prepare` 应返回带 `videoPort`/`controlPort`/`scid` 的 JSON。
5. 鸿蒙端进入镜像页点「开始镜像」：15 s 内出画面。
6. 触摸：鸿蒙端点按/滑动能控制安卓。
7. 退出页面后安卓端 `ps -A | grep app_process` 无残留；再进可重连。

## 已知风险

- 若 Shizuku UserService 进程无网络权限或禁止 spawn 进程，需回退方案（改用 App 进程做 TCP 监听 + shell 侧 LocalSocket 泵）。
- 抽象 socket 名或 accept 顺序不匹配会导致卡在第一条流；排查时先看 hilog `[StreamManager]` / adb `logcat -s MirrorHotspot`。
- GPL-3.0：原生层整体移植自 LambdaYH/ScrcpyForHarmonyOS（GPL-3.0），对外分发会传染整个 App —— **仍需用户表态**。
