# AnySend

手机与 Mac 之间互传文件、镜像屏幕、远程操控的一体化工具。三端（Android / HarmonyOS NEXT / macOS）共用两套线协议：**LocalSend v2** 传文件，**scrcpy v2/v3** 传画面与控制。网络层不要求设备在同一局域网——移动端内嵌 `tsnet` 用户态隧道，macOS 侧装开源 `tailscaled`，两条路都汇到同一个 tailnet。

```
┌──────────────┐        ┌──────────────────┐        ┌──────────────┐
│ Android 手机  │        │ HarmonyOS NEXT   │        │    macOS     │
│ Kotlin       │        │ ArkTS + C++      │        │ Flutter 分叉 │
└──────┬───────┘        └────────┬─────────┘        └──────┬───────┘
       │                         │                         │
       │◄──── LocalSend v2 :53317（文件）──────────────────►│
       │◄──── scrcpy 流 :27042 / :27043（画面与控制）──────►│
       │                         │                         │
  ┌────▼─────┐             ┌─────▼──────┐           ┌──────▼───────┐
  │ tsnet AAR│             │ tsnet .so  │           │ tailscaled   │
  │ 用户态栈  │             │ 用户态栈    │           │ 真实 utun 网卡│
  └──────────┘             └────────────┘           └──────────────┘
```

## 能力矩阵

| 能力 | Android | HarmonyOS NEXT | macOS |
|---|---|---|---|
| 文件互传 | `protocol/LocalSendServer.kt`（724 行） | `protocol/LocalSendServer.ets` | LocalSend 原生能力 |
| 局域网组播发现 | `protocol/LanDiscovery.kt` | `protocol/` 同名实现 | LocalSend 原生能力 |
| 屏幕镜像（**被控**安卓） | — | `pages/MirrorPage.ets`、`pages/AppStreamPage.ets` | `Runner/AndroidMirrorController.swift`（1222 行） |
| 桌面远控（**被控** Mac） | — | — | `Runner/RemoteHostController.swift`（919 行） |
| 桌面远控（**主控** Mac） | `remote/MacRemoteClient.kt`、`RemoteMacActivity.kt` | `pages/MacRemotePage.ets`（1435 行） | — |
| 短信收发中转 | `sms/`（读写 + 中继 + Shizuku 写权限） | `sms/SmsStore.ets`、`pages/SmsListPage.ets` 等 | — |
| 跨网隧道 | 内嵌 tsnet（AAR） | 内嵌 tsnet（c-shared .so） | 内置 tailscaled（root LaunchDaemon） |

## 目录结构

```
.
├── protocol/      LocalSend v2 协议说明（两端实现的唯一参考）
├── go/            tsnet 桥接库，跨平台共享
│   ├── tsnetbridge/   封装 Start/GetPeers/Dial/Listen/Read/Write/Accept
│   └── cmd/cshared/   c-shared 入口（HarmonyOS 用）
├── android/       Kotlin 应用，包名 com.slakey.anysend
├── harmonyos/     ArkTS + C++，含自研 ADB 客户端与 scrcpy 流管理器
├── macos/         LocalSend 分叉（Flutter），远控/镜像加在 Runner 原生层
├── specs/         三份开发规格与任务清单
└── scripts/       build-aar.sh / build-so.sh
```

## 网络层：三条路径

1. **局域网直连**：系统网络栈，两端填对端 IP 即可，不依赖任何隧道。适合同 Wi-Fi 调试与日常家用。
2. **移动端内嵌 tsnet**：`tsnet` 以用户态 netstack 运行，不需要 TUN 权限、不需要系统 VPN，Socket 流量经 `Dial/Listen` 走 WireGuard 加密隧道。设备发现不用 UDP 组播（Tailscale 不转发），改从 `GetPeers` 取同 tailnet 的节点与 100.64/10 地址。
3. **macOS 原生 tailscaled**：Mac 侧不嵌 Go 桥，而是把开源 `tailscaled`/`tailscale` 二进制打在 `app/assets/tailscaled/`（约 40 MB），由应用经管理员授权装成 root LaunchDaemon（`com.slakey.anysend.tailscaled`，真实 `utun` 网卡），再用 `--operator` 让 GUI 免 sudo 控制 LocalAPI。因此 Mac 端跨网远控不需要 relay 做 loopback 转发。

## 线协议

- **文件**：LocalSend v2，端口 `53317`。发送端 `register` → `send-request` → 逐个 `send`；接收端提供 `/info`、`/register`、`/send-request`、`/send`。细节见 `protocol/README.md`。
- **画面**：端口 `27042`。建连后 `1B dummy` → `64B` 设备名（UTF-8 零填充）→ `12B` codec meta（`u32 "h264"` / `width` / `height`）→ 帧序列；每帧头 `12B`（`u64` 最高位 config 包、次高位关键帧、低 62 位 PTS µs）+ `u32` 长度，payload 为 Annex-B。
- **控制**：端口 `27043`，scrcpy 控制消息子集（按键、文本、触摸、滚动、剪贴板）。字节定义以 `harmonyos/entry/src/main/ets/scrcpy/client/tools/ControlPacket.ets` 为唯一权威。
- **镜像引导**：主控端先 `POST /api/anysend/v1/mirror-prepare?hs=0` 到对端 LocalSend 端口，Android 侧经 Shizuku 起 scrcpy-server 并返回 `videoPort`/`controlPort`/`scid`。

安卓镜像的实现路径：Shizuku UserService 以 shell UID（2000）执行 `app_process` 拉起 `scrcpy-server v3.3.4`（forward 模式），进程内桥接 `LocalSocket` ↔ TCP，两端按 video → control 顺序配对，无需 adb、无需无线调试配对。

跨网镜像另有一条旁路：桥监听的端口只对局域网/热点可见（手机的 tsnet 是用户态栈，tailnet 包到不了这些 socket），因此 `MirrorTailnetProxy` 在 tailnet 上固定监听 `27052`/`27053`，逐条 pipe 到 `127.0.0.1:<桥端口>`。有真实网卡的对端（Mac 的 utun）直接连这两个端口；鸿蒙端因同样是用户态栈，跨网时回落到「加入安卓热点」这条路。

## 构建

### Android

```bash
# 1) tsnet AAR（可选；缺失时自动编译 src/stub 桩实现，只能直连局域网）
export ANDROID_NDK_HOME=/path/to/android-ndk
./scripts/build-aar.sh          # 产物 android/app/libs/tsnetbridge.aar

# 2) 应用
cd android && ./gradlew assembleDebug
```

### HarmonyOS NEXT

```bash
# 1) tsnet .so（可选；缺失时 CMake 以 TSNETBRIDGE_STUB 编译桩实现）
export OHOS_NDK_HOME=/path/to/openharmony-ndk
./scripts/build-so.sh
mkdir -p harmonyos/entry/src/main/libs/arm64-v8a
cp go/cmd/cshared/out/libtsnetbridge.so harmonyos/entry/src/main/libs/arm64-v8a/

# 2) 用 DevEco Studio 打开 harmonyos/ 构建 HAP
```

> **原生层依赖（重要）**：`harmonyos/entry/src/main/cpp/scrcpy/CMakeLists.txt` 会 `add_subdirectory(thirdparty/boringssl)` 并链接 `ssl`/`crypto`，所以 `thirdparty/boringssl`（约 226 MB）与 `thirdparty/concurrentqueue`（约 16 MB）是**构建必需**的。这两个目录体积过大，未纳入 git（见 `.gitignore`），换机器或重新克隆后需要自行放回原目录，否则鸿蒙原生层无法编译。

### macOS

```bash
cd macos
fvm install            # 版本由 .fvmrc 固定（Flutter 3.41.9）
fvm flutter pub get
fvm flutter build macos --release
```

bundle id 为 `com.slakey.anysend.mac`，与官方 LocalSend 分开，避免 TCC 授权串味。首次使用远控需授予「屏幕录制」与「辅助功能」，改授权后需重启应用。安装 tailscaled 需一次管理员授权。

## 使用要点

- **传文件**：任一端的分享面板选中文件 → 选择 AnySend → 选目标设备。
- **镜像安卓**：安卓端完成 Shizuku 授权并启动接收服务，鸿蒙/Mac 端在镜像页连接；同一局域网最稳，跨网依赖隧道。
- **远控 Mac**：Mac 端在「远控」分区打开开关、设 6 位 PIN；手机端输入 PIN 连接。PIN 为长度前缀 + UTF-8 明文的简单校验，仅在可信 tailnet 内使用。
- **接收落盘**：Android 存 `Download`，HarmonyOS 存应用 `files` 目录。

## 已知限制

- 移动端 tsnet 与 Mac 端 tailscaled 是两套实现，账号/节点状态互不可见，需分别登录同一 tailnet。
- macOS 被控端未排除自身窗口（`SCContentFilter(excludingWindows: [])`），整屏共享。
- PIN 鉴权无 challenge/HMAC、无设备指纹记忆；控制口与视频口各自校验。
- 鸿蒙原生层依赖本地 `thirdparty/`（见上），仓库不自带。
- 无自动化测试；`specs/` 各任务的实测项（首帧延迟、30 分钟稳定性、折叠屏切换）仍需真机复核。

## 文档

| 文件 | 内容 |
|---|---|
| `protocol/README.md` | LocalSend v2 线协议 |
| `specs/scrcpy-mirror-shizuku/spec.md` | 安卓镜像（Shizuku 桥）现行方案 |
| `specs/scrcpy-mirror-phase1/spec.md` | 早期无线 ADB 方案，已被取代，留作历史 |
| `specs/mac-remote-desktop/spec.md` | Mac 远控规格 |
