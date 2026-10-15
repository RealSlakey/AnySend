# TS LocalSend Bridge

在 Android 和 HarmonyOS NEXT 手机之间跨网络传输文件的应用。内嵌 Tailscale（tsnet 用户态网络栈）实现虚拟内网穿透，基于 LocalSend v2 协议传输文件。两台设备无需处于同一局域网。

## 架构

```
┌──────────────────────┐                         ┌──────────────────────┐
│   Android 手机        │                         │  HarmonyOS NEXT 手机  │
│                      │                         │                      │
│  ┌────────────────┐  │   Tailscale 隧道加密     │  ┌────────────────┐  │
│  │ 分享面板 → App  │  │ ◄─────────────────────► │  │ 分享面板 → App  │  │
│  └────────┬───────┘  │   (WireGuard / DERP)    │  └────────┬───────┘  │
│           │          │                         │           │          │
│  ┌────────▼───────┐  │                         │  ┌────────▼───────┐  │
│  │ TailscaleManager│ │                         │  │ TailscaleManager│ │
│  │ (Kotlin, AAR)   │ │                         │  │ (ArkTS, NAPI)   │ │
│  └────────┬───────┘  │                         │  └────────┬───────┘  │
│           │          │                         │           │          │
│  ┌────────▼───────┐  │                         │  ┌────────▼───────┐  │
│  │ tsnet (Go AAR) │  │                         │  │ tsnet (Go .so)  │  │
│  │ 用户态 netstack │ │                         │  │ 用户态 netstack  │ │
│  └────────────────┘  │                         │  └────────────────┘  │
│                      │                         │                      │
│  LocalSend Sender/   │                         │  LocalSend Sender/   │
│  Server (Kotlin)     │                         │  Server (ArkTS)      │
│  端口 53317          │                         │  端口 53317          │
└──────────────────────┘                         └──────────────────────┘
```

### 关键设计

1. **内嵌 Tailscale，不依赖系统 VPN**：使用 `tsnet` 的用户态 netstack 模式，无需 TUN 权限，Tailscale 节点运行在应用进程内。
2. **设备发现用 Tailscale Peer API**：Tailscale 不转发组播，因此不使用 LocalSend 的 UDP 组播发现，改为通过 `tsnet` 获取同 tailnet 下的 peer 列表和 Tailscale IP。
3. **传输走 Tailscale IP**：LocalSend 的 HTTP 流量（端口 53317）通过 tsnet 的 dial/listen 走 Tailscale 隧道，全程 WireGuard 加密。
4. **Go 桥接库跨平台共享**：同一套 Go 代码（`go/tsnetbridge`）通过 gomobile 编译为 Android AAR，通过 c-shared + NAPI 编译为 HarmonyOS .so。

## 目录结构

```
.
├── protocol/                  # LocalSend v2 协议规范（两端实现的唯一参考）
├── go/                        # Go tsnet 桥接库（跨平台共享）
│   ├── tsnetbridge/           # 核心封装
│   └── cmd/cshared/           # c-shared 入口（HarmonyOS 用）
├── android/                   # Android 应用（Kotlin）
│   └── app/src/main/java/com/tslsb/app/
│       ├── bridge/            # TailscaleManager（封装 AAR）
│       ├── protocol/          # LocalSend 发送/接收
│       ├── App.kt
│       ├── MainActivity.kt
│       ├── ShareActivity.kt   # 系统分享入口
│       └── BridgeService.kt   # 前台保活服务
├── harmonyos/                 # HarmonyOS NEXT 应用（ArkTS）
│   └── entry/src/main/
│       ├── ets/
│       │   ├── bridge/        # TailscaleManager（封装 NAPI）
│       │   ├── protocol/      # LocalSend 发送/接收
│       │   ├── entryability/  # EntryAbility + ShareAbility
│       │   ├── extensionability/  # ShareExtensionAbility
│       │   └── pages/         # Index + Share
│       └── cpp/               # NAPI 桥接层
├── scripts/
│   ├── build-aar.sh           # 编译 Android AAR
│   └── build-so.sh            # 编译 HarmonyOS .so
└── .trae/specs/               # 需求规格与实现计划
```

## 前置依赖

| 依赖 | 用途 | 获取方式 |
|---|---|---|
| Go 1.22+ | 编译 tsnet 桥接库 | https://go.dev |
| Tailscale 账号 | 登录 tailnet | https://tailscale.com |
| Android Studio + NDK | 构建 Android 端 | https://developer.android.com/studio |
| gomobile | 编译 Android AAR | `go install golang.org/x/mobile/cmd/gomobile@latest` |
| OpenHarmony NDK | 交叉编译 Go → arm64 .so | https://gitee.com/openharmony |
| DevEco Studio | 构建 HarmonyOS 端 | https://developer.harmonyos.com |

## 构建步骤

### 1. 获取 Tailscale Auth Key

在 [Tailscale 控制台](https://login.tailscale.com/admin/settings/keys) 生成一个 Auth Key（建议勾选 reusable、ephemeral 可选）。

### 2. 构建 Android 端

```bash
# 1. 编译 tsnet AAR
export ANDROID_NDK_HOME=/path/to/android-ndk
gomobile init
./scripts/build-aar.sh
# 产物: android/app/libs/tsnetbridge.aar

# 2. 用 Android Studio 打开 android/ 目录，构建并安装 APK
# 或命令行:
cd android && ./gradlew assembleDebug
```

### 3. 构建 HarmonyOS 端

```bash
# 1. 交叉编译 Go tsnet 为 arm64 .so
export OHOS_NDK_HOME=/path/to/openharmony-ndk
./scripts/build-so.sh
# 产物: go/cmd/cshared/out/libtsnetbridge.so

# 2. 将 libtsnetbridge.so 复制到 HarmonyOS 工程的 libs 目录
mkdir -p harmonyos/entry/src/main/libs/arm64-v8a
cp go/cmd/cshared/out/libtsnetbridge.so harmonyos/entry/src/main/libs/arm64-v8a/

# 3. 用 DevEco Studio 打开 harmonyos/ 目录，构建 HAP 并安装
```

## 使用方法

1. **两台设备分别安装**对应平台的应用。
2. **登录 Tailscale**：打开应用，输入 Tailscale Auth Key，点击"登录并连接"。
3. **发送文件**：在文件管理器/相册中选择文件 → 分享 → 选择"TS LocalSend" → 从在线设备列表中选择目标设备 → 等待传输完成。
4. **接收文件**：应用在后台运行时自动接收（当前实现默认自动接受）。Android 保存到 Download 目录，HarmonyOS 保存到应用 files 目录。

## 协议说明

LocalSend v2 协议的完整定义见 [protocol/README.md](protocol/README.md)。核心流程：

```
发送端 register → send-request → send（逐个文件）
接收端 /info → /register → /send-request → /send
```

所有 HTTP 请求走 Tailscale IP:53317，不使用组播发现。

## 直连局域网模式（本地测试，无需 Tailscale）

如果本机没有 gomobile / OpenHarmony NDK 工具链，无法编译 Tailscale 原生库，可以使用**直连局域网模式**进行本地测试。此模式下应用走系统网络栈（Java Socket / @ohos.net.socket），两台设备只需连同一个 Wi-Fi 即可互传文件。

### 原生依赖是可选的

- **Android**：`android/app/libs/tsnetbridge.aar` 不存在时，Gradle 会自动编译 `src/stub/java/tsnetbridge/Tsnetbridge.java` 桩实现，项目仍可正常构建。
- **HarmonyOS**：`go/cmd/cshared/out/libtsnetbridge.so` 不存在时，CMake 会以 `TSNETBRIDGE_STUB` 宏编译 `napi_bridge.cpp`，生成桩版 `libtsnapi.so`，ArkTS 侧 `TsnapiLoader` 会自动检测并回退到直连模式。

### 本地测试步骤（Android ↔ HarmonyOS）

1. **两台设备连同一个 Wi-Fi**。
2. **接收端**打开应用，点击「启动接收服务（直连模式）」，记下界面显示的本机 IP（Android 自动显示；HarmonyOS 请到系统 Wi-Fi 设置查看）。
3. **发送端**在文件管理器/相册中选择文件 → 分享 → 选择「TS LocalSend」。
4. 在分享界面的「直连模式：输入接收方 IP」框中输入接收端 IP，点击「发送到该 IP」。
5. 等待传输完成。接收端：Android 保存到 Download 目录，HarmonyOS 保存到应用 files 目录。

> 也可以 Android↔Android 或 HarmonyOS↔HarmonyOS 互传，只要两端都用直连模式。

### 切回 Tailscale 模式

当工具链就绪后：
- Android：运行 `./scripts/build-aar.sh` 生成 `tsnetbridge.aar`，重新构建即可。
- HarmonyOS：运行 `./scripts/build-so.sh` 生成 `libtsnetbridge.so`，重新构建即可。

CMake / Gradle 会自动检测到原生库并启用 Tailscale 功能。

## 注意事项

- 两台设备必须登录**同一个** Tailscale 网络（tailnet）。
- HarmonyOS NEXT 端的 Go 交叉编译依赖 OpenHarmony NDK 的 clang，已在 linux/arm64 验证 c-shared 编译通过。
- 当前接收端默认自动接受所有文件，可在 `LocalSendServer` 中修改为需要用户确认。
- Tailscale Auth Key 请妥善保管，勿提交到代码仓库。
- 直连模式下请确保两台设备在同一局域网，且接收端防火墙未拦截 53317 端口。
