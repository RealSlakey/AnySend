# Mac 远控任务清单 · 实际状态

> 对应 `specs/mac-remote-desktop/spec.md`。原清单按「Auth.swift / VideoServer.swift / H264Encoder.swift …」多文件拆分规划，实际实现集中在两个 Swift 文件，条目已按功能重写。
> 状态以 **2026-10-27 源码核对**为准：`[x]` 有代码可证，`⚠️` 需真机/真 Mac 确认，`[ ]` 未做。

## 已完成

- [x] 分叉 LocalSend 当被控端：bundle id `com.slakey.anysend.mac` / 显示名 AnySend，与官方版 TCC 隔离；Runner 内加原生层，Dart 侧只加 `lib/remote` 与 `lib/tailscale`
- [x] 被控端视频：ScreenCaptureKit 采集主显 → `VTCompressionSession`（H.264、无 B 帧）→ 12B 帧头 + Annex-B → `:27042`
- [x] 被控端控制：`:27043` 收按键（keycode → `CGEvent`）、文本（`CGEventKeyboardSetUnicodeString`，中文可直输）、触摸/滚轮（12.20 定点）、剪贴板双向（`NSPasteboard`）
- [x] 鉴权：两个端口各自校验「1B 长度 + UTF-8 PIN」，空 PIN 时与 scrcpy 协议完全一致
- [x] 主控端（Mac 操作安卓）：`AndroidMirrorController.swift`（1222 行），经 `POST /api/anysend/v1/mirror-prepare?hs=0` 发现端点 → 视频解码 → 触摸/按键注入
- [x] Flutter 壳：`lib/remote/{remote_host_section,remote_host_service,android_mirror_section,android_mirror_service}.dart`，入口挂在 `pages/tabs/remote_tab.dart`
- [x] 组网：**不用 tsnet**，改为把开源 `tailscaled`/`tailscale` 打进 `app/assets/tailscaled/`（约 40 MB），装成 root LaunchDaemon `com.slakey.anysend.tailscaled`（真实 utun），`--operator` 让 GUI 免 sudo 控制 LocalAPI
- [x] 权限：`Release.entitlements` / `DebugProfile.entitlements` 已含 `network.client` 与 `network.server`
- [x] 托盘与热键：`AppDelegate` 挂三条 MethodChannel（`main-delegate-channel` / `anysend/android-mirror-events` / `anysend/hotkey`），含托盘菜单、拖文件发送、剪贴板热键
- [x] 鸿蒙端会话页：`pages/MacRemotePage.ets`（1435 行）单文件实现，含 PIN 输入、触控板状态机（点按/拖拽/滚轮/长按）、笔记本态上下分栏

## 与原计划的偏差（后续改动请沿用现状，勿按旧文件规划找代码）

| 计划 | 实际 |
|---|---|
| `Auth.swift` / `VideoServer.swift` / `ScreenCaptureEngine.swift` / `H264Encoder.swift` / `FrameFramer.swift` / `ControlServer.swift` / `InputInjector.swift` / `Keymap.swift` / `ClipboardBridge.swift` 九个文件 | 全部内聚在 `RemoteHostController.swift`（919 行） |
| 鸿蒙 `RemoteModels.ets` / `RemoteSettings.ets` / `MacRemoteSession.ets` / `TrackpadGesture.ets` / `KeyBar.ets` / `RemoteDesktopPage.ets` | 内聚在 `MacRemotePage.ets` 单文件 |
| M5 计划 `bridge.go` 的 `RelayStart`/`RelayStop`（loopback → tsnet） | 未实现也**不需要**：Mac 走真实 utun，`go/tsnetbridge` 至今无 relay 接口 |
| 鉴权 challenge → HMAC-SHA256 + 设备指纹 | 仅明文 PIN 比对 |

## 未完成 / 待验证

- [ ] PIN 升级为 challenge + HMAC-SHA256，并记住已授权设备（spec §2.3）
- [ ] 采集时排除自身窗口（现为 `SCContentFilter(display:excludingWindows: [])`，整屏共享）
- [ ] 端口冲突检测：官方 LocalSend 占用 `:53317` 时给出明确提示与关闭指引
- [ ] `Keymap` 全表单测；用 `ControlPacket.ets` 产出字节作 fixtures 的协议对拍
- [ ] ⚠️ 指标实测：首帧延迟、局域网 / 跨网回显延迟、30 分钟稳定性（spec §10 指标表仍空缺）
- [ ] ⚠️ 退出清理回归：退出页面后 `lsof -i :27042 :27043` 应为空、无残留线程
- [ ] ⚠️ 折叠屏 FULL ↔ MINI 往返不崩溃、布局不残留
- [ ] ⚠️ 开机自启（上游 LocalSend 自带 LaunchAtLogin，本分叉未单独验证）
- [ ] 自签证书 + codesign 稳定签名，验证 TCC 授权重启后仍保留
