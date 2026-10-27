# Mac 远控（MacRemote）开发规格 · LocalSend 分叉版

> 折叠屏分工：**上半屏 = Mac 画面（H.264 硬解），下半屏 = 触控板 + 键盘条 + 文本输入条**。
> **Mac 端不新增 App**：直接分叉 LocalSend（Apache-2.0，官方支持 macOS），在它的 macOS Runner 里内置被控服务。用户那台 Mac 上仍然只有「LocalSend + Tailscale」两个图标。

---

## 1. 目标与约束

1. Mac 上**不新增独立 App**：被控能力作为 LocalSend 分叉版的一部分，与文件互传共用同一个图标；
2. 连接局域网或 tailnet 内的 Mac 主机，实时显示桌面（H.264 硬解，默认 1600px / 30fps / 8 Mbps，可调）；
3. 下半屏控制台：虚拟触控板（点击/滚动/拖拽/右键）+ 快捷键条 + 文本输入行（中文直输）；
4. 剪贴板双向同步；
5. 双网络路径：局域网直连 / tsnet 中继；
6. **线协议与鸿蒙端原生流管理器保持兼容**，不得为了 Mac 端改造而重写已跑通的解码链路。

不在本期范围：音频转发、多显示器切换 UI、非 macOS 主机、App Store 分发。

### 1.1 关键取舍（决策记录）

| 方案 | Mac 侧 | 结论 |
|---|---|---|
| 系统屏幕共享 + RFB 客户端 | 零安装 | 已否决：无 H.264，鸿蒙端要重写整套 RFB 解码，画质帧率弱 |
| 独立 Swift 菜单栏 App | 新增一个 App | 已否决：违背「不新增 App」 |
| **分叉 LocalSend** | 换掉已有的 LocalSend | **采用** |
| Go relay / tsnet | 不变 | 保留（异地场景必需） |

分叉**不会**减少原生工作量：采集/编码/注入仍是 Swift，且多了一层 Flutter 壳与通道。它换来的是「Mac 上只有一个熟悉的应用」，以及复用 LocalSend 的发现、设置页、开机自启、更新渠道。

## 2. 线协议（复用既有，不新造）

Mac 端按 scrcpy v2.7 同构协议说话，鸿蒙端直接复用：`ScrcpyStreamManager.startDirect(host, 27042, 27043, config, cb)` + `NativeStreamClient` 的 direct 路径。**帧格式与控制消息的字节定义以 `ControlPacket.ets` 为唯一权威。**

### 2.1 视频口 :27042（host → client）

1. 鉴权握手（§2.3）；
2. `1B` dummy `0x00` → `64B` 设备名（0 填充 UTF-8，如 `Slakeys-MacBook`）→ `12B` codec meta（`u32 BE "h264"`、`u32 width`、`u32 height`）；
3. 帧序列，每帧 `12B` 头：`u64`（最高位 = config 包标志，次高位 = 关键帧标志，低 62 位 PTS µs）+ `u32` payload 长度；payload 为 **Annex-B**（config 帧只含 SPS+PPS，IDR 帧可重复携带）。

### 2.2 控制口 :27043（双向）

host 解析以下子集：

| type | 消息 | host 处理 |
|---|---|---|
| 0 | INJECT_KEYCODE | Android keycode + metaState → macOS 虚拟键码 + CGEventFlags |
| 1 | INJECT_TEXT | UTF-8 → `CGEventKeyboardSetUnicodeString`（中文路径） |
| 2 | INJECT_TOUCH_EVENT | down/up/move + 坐标（u32 定点 12.20，乘 2^20）+ buttons → 鼠标移动/左键/右键（1=左 2=右 4=中；pointerId=-1 为鼠标） |
| 3 | INJECT_SCROLL_EVENT | hscroll/vscroll（i32 定点 12.20）→ CGEvent scroll wheel |
| 8 | GET_CLIPBOARD | 读 `NSPasteboard.general`，回设备消息 |
| 9 | SET_CLIPBOARD | 写剪贴板；请求「粘贴」时随后注入 ⌘V |
| 16 | START_APP（预留） | 一期忽略 |

设备消息（host → client，同端口）：`TYPE_CLIPBOARD(0)` + `u32 len` + UTF-8 文本。

### 2.3 鉴权（项目扩展）

视频口连接建立后 host 先不发 dummy 字节，而是：

1. host → client：`8B` 随机 challenge；
2. client → host：`32B = HMAC-SHA256(SHA-256(PIN), challenge)`；
3. 通过 → 继续正常握手；失败 → 发 `1B 0x01` 后断开。

控制口用同一 PIN 校验（首 4 字节做同样挑战），避免控制口被裸连。PIN 为 6 位数字，在 LocalSend 设置页展示。首次通过后记录设备指纹（tsnet IP + token 摘要），可勾选「记住此设备」跳过 PIN。连错 3 次冷却 30s。

### 2.4 坐标系

控制消息 x/y 为**视频流内坐标**（与 codec meta 的 width/height 同基准），host 按实际显示器缩放换算 CGEvent 全局坐标（主显左上为原点）。客户端无需感知 Mac 分辨率与缩放变化。

## 3. 总体架构

```
┌─ 折叠屏（HarmonyOS NEXT）───────────────────────────────┐
│ RemoteDesktopPage                                       │
│  ├─ 上半屏 XComponent ← VideoDecoderNative（既有硬解）   │
│  └─ 下半屏 手势 → ControlPacket → INJECT_TOUCH/KEY/TEXT │
│                     │                                   │
│ NativeStreamClient(direct)                              │
│        startDirect(127.0.0.1:27042, :27043) 或局域网 IP │
│                     │                                   │
│ Go relay: 127.0.0.1:port ──tsnet dial──►                │──┐
└─────────────────────────────────────────────────────────┘  │
                                      WireGuard/DERP 或局域网 │
                                                            ▼
┌─ Mac：LocalSend 分叉版（Flutter + Swift）────────────────┐
│ Dart 层：设置页 / PIN 展示 / 远程控制开关 / 已授权设备     │
│   ↕ MethodChannel（仅配置与状态，不承载媒体流）            │
│ Swift 层（app/macos/Runner/RemoteHost/）                  │
│   VideoServer.swift  :27042  SCStream → VT H.264 → 帧封装 │
│   ControlServer.swift :27043  控制消息 → CGEvent / 剪贴板 │
│   Auth.swift         PIN / HMAC / 设备白名单              │
│ LocalSend 原有文件互传（:53317）保持不变                   │
└───────────────────────────────────────────────────────────┘
```

媒体路径**完全不经过 Dart**：Swift 直接监听端口、直接推流，Dart 只负责开关、PIN、状态回显。这是性能与上游合并成本的双重要求。

## 4. Mac 端改造

### 4.1 分叉基线

- 源：`https://github.com/localsend/localsend`，`app/` 为 Flutter 工程，`app/macos/Runner` 为标准 Xcode 工程；
- 许可证 Apache-2.0：保留 `LICENSE`/`NOTICE`，在 `app/macos/Runner/RemoteHost/` 与 `app/lib/remote/` 顶部注明「modified by AnySend」；
- 改 bundle id 与显示名（如 `com.slakey.anysend.mac` / `AnySend`），避免与官方版共存时 TCC 授权串味。

### 4.2 目录结构（新增，尽量不碰上游文件）

```
app/
├── macos/
│   ├── Runner/
│   │   └── RemoteHost/            # 新增，全部自定义代码
│   │       ├── RemoteHostChannel.swift   # MethodChannel 注册与指令分发
│   │       ├── VideoServer.swift         # :27042 监听 / 鉴权 / 视频握手 / 帧发送
│   │       ├── ControlServer.swift       # :27043 监听 / 消息解析 / 设备消息回写
│   │       ├── Auth.swift                # PIN / challenge / HMAC / 白名单存档
│   │       ├── ScreenCaptureEngine.swift # SCStream 会话
│   │       ├── H264Encoder.swift         # VTCompressionSession + Annex-B
│   │       ├── FrameFramer.swift         # 12B 帧头打包
│   │       ├── InputInjector.swift       # CGEvent 注入
│   │       ├── Keymap.swift              # Android keycode → kVK
│   │       └── ClipboardBridge.swift
│   └── Runner.xcodeproj  # 仅新增文件引用 + entitlements
└── lib/
    └── remote/                    # 新增 Dart 侧
        ├── remote_settings_page.dart   # 开关 / PIN / 设备列表 / 权限引导
        └── remote_bridge.dart          # MethodChannel 封装
```

上游文件改动控制在两处：`MainFlutterWindow.swift`（注册通道，约 3 行）与设置页入口（一处路由）。目标是把 rebase 上游的冲突面压到最小。

### 4.3 视频管线

| 环节 | 实现 | 关键参数 |
|---|---|---|
| 采集 | ScreenCaptureKit `SCStream`，主显示器，排除自身窗口 | `minimumFrameInterval = 1/60`；`queueDepth = 3`；光标随帧 |
| 缩放 | 采集前按 `max_size`（默认 1600，可 2000/2584）等比设定输出尺寸 | 避免编码后缩放 |
| 编码 | VideoToolbox H.264 | `RealTime=true`、`AllowFrameReordering=false`、`AverageBitRate=8_000_000`、`MaxFrameDelayCount=1`、`ExpectedFrameRate=60` |
| Annex-B | 从 CMSampleBuffer 取 SPS/PPS；IDR 前拼 start code；SPS/PPS 变化单独发 config 帧 | flags：config 帧 bit63=1、IDR bit62=1 |
| 发送 | 独立发送队列，`TCP_NODELAY`；写入阻塞时丢弃非关键帧并计数 | 保 P 帧连续性 |

### 4.4 控制注入与权限

- `CGEventSourceCreate(kCGEventSourceStateCombinedSessionState)` + `CGEventPost(kCGHIDEventTap, ...)`；
- 鼠标 move / left down-up-drag / right / middle / scroll（`kCGScrollEventUnitPixel`）；
- 键盘 keycode + flags；文本走 `CGEventKeyboardSetUnicodeString`；
- 必需权限：**屏幕录制**、**辅助功能**。⚠️ 授权后必须完全退出（⌘Q）重启，否则「有画面、控制不动」；
- **签名要求**：TCC 按签名身份记忆授权，用 ad-hoc 签名每次重编译都会掉授权。必须用钥匙串里一张**自签证书**做 codesign，身份稳定，授权只弹一次。

### 4.5 键码映射（Android keycode → macOS kVK）

| Android | kVK | 说明 |
|---|---|---|
| 111 / 61 / 66 / 67 | 53 / 48 / 36 / 51 | Esc / Tab / Enter / Backspace |
| 19 / 20 / 21 / 22 | 126 / 125 / 123 / 124 | ↑ ↓ ← → |
| 62 | 49 | Space |
| 29–54 | 0–25 | A–Z：`kVK = keycode − 29` |
| 7–16 | 29–38 | 0–9：`kVK = keycode − 7 + 29` |
| metaState | CGEventFlags | CTRL(0x1000)→0x40000；SHIFT(0x1/0x2)→0x20000；ALT(0x4/0x8)→0x80000；META/Cmd(0x10000)→0x100000 |

表外 keycode 忽略并记日志；F1–F12 后续按需补。

### 4.6 Flutter 壳的职责

- 设置页新增「远程控制」分区：开关、6 位 PIN（可刷新）、已授权设备列表（可撤销）、权限状态检测（屏幕录制/辅助功能是否已授，未授则给一键跳转系统设置深链）；
- 开关状态经 MethodChannel 下发到 Swift，Swift 负责真正 start/stop 监听；
- 开机自启沿用 LocalSend 既有实现（若无则用 `SMAppService` 注册登录项）；
- 状态回显：监听中 / 已连接设备数 / 当前码率，由 Swift 通过 EventChannel 推给 Dart。

## 5. 传输桥：Go relay（tsnetbridge 新增）

现有 `dial/read/write` 走 worker + JSON + base64，扛不住 8 Mbps 流。新增本地端口转发：

```go
// go/tsnetbridge/bridge.go 新增
// export func RelayStart(host string, port int) int   // 返回本地端口，0 = 失败
// export func RelayStop(localPort int)
// 实现：net.Listen("tcp", "127.0.0.1:0") → goroutine tsnet Dial(host:port)
//       → 双向 io.Copy；任一端关闭即关断另一侧
```

导出链路：`cshared/main.go` → `cpp/napi_bridge.cpp` → `TsnapiLoader.ets` → `TailscaleManager`：

```ts
static async relayStart(host: string, port: number): Promise<number>
static relayStop(localPort: number): void
```

约束：只允许转发到 `100.64.0.0/10` 或用户登记的 peer IP；单 relay 连接上限 4（视频 + 控制 + 冗余）；吞吐 ≥ 30 Mbps。

## 6. 鸿蒙端改动清单

### 新增

| 文件 | 内容 |
|---|---|
| `ets/pages/RemoteDesktopPage.ets` | 会话主页（四态 + 上下分栏） |
| `ets/remote/MacRemoteSession.ets` | PIN 鉴权 → relayStart/直连 → `startDirect` → 统计聚合 |
| `ets/remote/TrackpadGesture.ets` | 手势 → `ControlPacket`（§8.3），MOVE 节流 60Hz |
| `ets/remote/KeyBar.ets` | 快捷键条 + 长按锁定修饰键 |
| `ets/remote/RemoteSettings.ets` | max_size / 码率 / relay 开关 / 记住设备（`mac_remote_` 前缀） |
| `ets/remote/RemoteModels.ets` | MacHostInfo、SessionStats |

### 修改

| 文件 | 改动 |
|---|---|
| `go/tsnetbridge/bridge.go`、`go/cmd/cshared/main.go` | RelayStart / RelayStop |
| `cpp/napi_bridge.cpp` | 注册 relay 两函数 |
| `ets/bridge/TsnapiLoader.ets`、`TailscaleManager.ets` | relay 包装与降级（native 缺失时仅直连） |
| `ets/scrcpy/client/tools/NativeStreamClient.ets` | direct 目标支持 127.0.0.1（relay）/ 局域网 IP；首帧前插入 §2.3 鉴权 |
| `ets/pages/Index.ets`、`TransferPage.ets` | 注册页面 + 「Mac 远控」入口卡片 |

**不做的事**：不新增原生解码器、不改 `cpp/scrcpy`、不改 `video_decoder.cpp`——它们继续服务安卓镜像。

## 7. UI：RemoteDesktopPage

四态：

1. **配置态**：peer 列表（`TailscaleManager.getPeers()` 过滤 Mac，标注 100.x）+ 直连 IP 输入（记住上次）+ PIN 输入（首次）+ 「记住此设备」+ 开始；底部提示当前模式。
2. **连接态**：步骤列表（鉴权 → 建链 → 取首帧），LoadingProgress + 取消。
3. **会话态**：上 60% 画面 / 下 40% 控制台，分隔条可拖 40%–75% 并持久化；键条横向滚动；输入行提交走 INJECT_TEXT；触控板手势按 §7.1。
4. **错误态**：鉴权失败（重输 PIN）/ 连接失败 / 首帧超时 / 解码异常，附重试与返回。

折叠外屏自动切 MINI 态（状态条 + 键条 + 输入行 + 缩略图），复用 `ControlPacket.Action` 的 CHANGE_TO_SMALL/FULL/MINI 机制。

### 7.1 触控板手势

| 手势 | 消息 |
|---|---|
| 单指点按 | DOWN+UP（buttons=1） |
| 按下移动 | 连续 MOVE（松手 UP） |
| 长按 >350ms 后移动 | 拖拽（全程 buttons=1） |
| 双指点按 | 右键（buttons=2） |
| 双指滑动 | SCROLL（vscroll 位移 × 灵敏度，方向可反转） |
| 三指点按 | 中键（buttons=4） |
| 悬停移动 | MOVE，pointerId=-1 |

MOVE 合并到每帧最多 1 条。

## 8. 分发与共存

- **构建**：`xcodebuild -workspace app/macos/Runner.xcworkspace -scheme Runner`（Flutter 侧 `flutter build macos --release`）；产物是 `.app`，拷给任何 Mac 即可运行；
- **签名**：自签证书 codesign，身份稳定以保证 TCC 记忆；首次打开需右键「打开」，或 `xattr -dr com.apple.quarantine <app>`；
- **端口**：官方 LocalSend 与本分叉都占用 `:53317`（发现/传输），**同一台 Mac 不能同时运行两者**；设置页要显式提示；
- **与官方互传兼容性**：文件互传仍遵循 LocalSend 协议，分叉版可以和官方客户端、以及 AnySend 互通。

## 9. 错误处理

- PIN 连错 3 次 → 冷却 30s，客户端提示「PIN 错误，请在 Mac 的 LocalSend 设置页查看」；
- 视频口握手 8s 超时 → 「主机无响应（确认 Mac 侧远程控制已开启、双端同网/tailnet）」；
- relay dial 失败 → 提示切直连；
- SCStream 中断（休眠 / 切换用户 / 权限被撤销）→ host 主动断流，客户端显示「主机画面中断」并可一键重连；
- 端口被占用（官方 LocalSend 在跑）→ 设置页直接报错并给出关闭指引；
- 页面退出（onWillDisappear）完整清理：relayStop、`startDirect` 停止、解码释放。

## 10. 性能预算

| 指标 | 目标 |
|---|---|
| 首帧（局域网直连） | < 2 s |
| 输入回显（局域网） | < 80 ms |
| 输入回显（tsnet，同城 4G/5G） | < 150 ms |
| tsnet 吞吐 | ≥ 30 Mbps（8 Mbps 码率零丢帧） |
| 稳定性 | 连续 30 min 不断流；切后台回前台自动恢复 |
| 解码 | 1600×900@60 走既有原生管线 |

## 11. 验证步骤

1. Mac：构建分叉版 → 自签 → 授予屏幕录制 + 辅助功能 → ⌘Q 重启 → 设置页开启远程控制并看到 PIN；
2. Mac 本机验证：`ffplay tcp://127.0.0.1:27042`（DEBUG 编译带跳过鉴权开关）出画面；
3. 局域网直连：鸿蒙端填 Mac 局域网 IP + PIN → 出画面；hilog 过滤 `tsnapi|MacRemote|ScrcpyStream` 无致命错误；
4. 控制闭环：触控板移动/点击/右键/滚动、键条 Ctrl+C / Cmd+Tab / Esc、输入行中文进 Mac 备忘录；
5. 剪贴板双向；
6. tsnet：手机关 WiFi 走 5G → relay 建立后出画面，记录吞吐；
7. 共存检查：同时启动官方 LocalSend，确认分叉版给出端口占用提示而非静默失败；
8. 稳定性：30 min 会话 + 5 次进出页面，`lsof -i :27042 :27043` 退出后为空；
9. 协议对拍：host 侧单测用 `ControlPacket.ets` 产出的字节作为 fixtures 逐条断言。

## 12. 里程碑

| 里程碑 | 内容 |
|---|---|
| M0 | 分叉与构建打通：改 bundle id/名称，macOS 能跑起来，RemoteHost 目录与 MethodChannel 骨架就位 |
| M1 | Swift 视频单向：SCStream + VT + 12B 帧封装 + 鉴权 + :27042，`ffplay` 看到画面 |
| M2 | Swift 控制闭环：:27043 解析 + CGEvent 注入 + 键码映射单测 |
| M3 | Flutter 壳：设置页开关 / PIN / 设备列表 / 权限引导 / 登录项；端口冲突提示 |
| M4 | 鸿蒙端会话页：四态 + 上下分栏 + 触控板 + 键条 + 输入行 + MINI 态 |
| M5 | tsnet relay + 剪贴板 + 错误态打磨 + §10 全项验收 |

**边界（明确不做）**：音频、Mac → 手机反向控制、显示器选择 UI、多会话并发、Windows/Linux host、App Store 上架。

## 13. 上游同步与合规

- 自定义代码集中在 `app/macos/Runner/RemoteHost/` 与 `app/lib/remote/`，上游文件只改两处（窗口注册 + 设置页入口），目的是让 `git rebase upstream/main` 的冲突面接近零；
- 每个改动过的上游文件顶部加「modified by AnySend at <commit>」，保留 Apache-2.0 许可与 NOTICE；
- 不向上游提 PR（被控功能与本项目定位绑定），但保持可用于自建分支的清晰分层。
