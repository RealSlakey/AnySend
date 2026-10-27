# Mac 远控（MacRemote）任务清单 · LocalSend 分叉版

> 对应 `specs/mac-remote-desktop/spec.md`。
> 约定：[ ] 未开始 / [x] 完成 / ⚠️ 有外部依赖（真机、Mac、权限）。
> 路线：分叉 LocalSend 当被控端（Mac 不新增 App），线协议复用已跑通的 scrcpy v2.7 + `ControlPacket.ets`。

## M0 分叉与构建打通

- [ ] clone `localsend/localsend`，建自己的 remote 分支，锁定基线 commit 并记录
- [ ] 改 bundle id / 显示名（`com.slakey.anysend.mac` / `AnySend`），避免与官方版 TCC 串味
- [ ] 在 `app/macos/Runner/RemoteHost/` 建空模块 + `RemoteHostChannel.swift` 注册 MethodChannel
- [ ] `MainFlutterWindow.swift` 接入通道（只改这一处）
- [ ] `flutter build macos --release` 跑通；确认 entitlements 已含 `network.server` / `network.client`
- [ ] 钥匙串建自签证书，codesign 稳定签名；验证 TCC 授权重启后仍保留

## M1 Swift 视频单向（只看不点）

- [ ] `Auth.swift`：PIN 生成/展示、challenge → HMAC-SHA256 校验、设备指纹存档
- [ ] `VideoServer.swift`：:27042 监听、accept、鉴权、TCP_NODELAY、发送队列
- [ ] `ScreenCaptureEngine.swift`：SCStream 采集主显、排除自身窗口、按 max_size 缩放
- [ ] `H264Encoder.swift`：VTCompressionSession（RealTime / 无 B 帧 / 8 Mbps / delay=1）+ Annex-B
- [ ] `FrameFramer.swift`：12B 帧头（config/keyframe 标志 + PTS）打包
- [ ] ⚠️ 授权屏幕录制 + 辅助功能 → ⌘Q 重启；`ffplay tcp://127.0.0.1:27042` 看到画面（DEBUG 跳过鉴权开关）

## M2 Swift 控制闭环

- [ ] `ControlServer.swift`：:27043 监听、PIN 校验、消息分发、CLIPBOARD 回写
- [ ] `InputInjector.swift`：CGEvent 鼠标 move/click/drag、滚动、键盘 keycode + flags、Unicode 文本
- [ ] `Keymap.swift`：spec §4.5 映射表 + 全表逐项单测
- [ ] `ClipboardBridge.swift`：NSPasteboard 读写
- [ ] ⚠️ 用临时脚本/自测工具直连 :27043 验证点击、滚动、中文注入进备忘录

## M3 Flutter 壳

- [ ] `remote_bridge.dart`：MethodChannel / EventChannel 封装
- [ ] `remote_settings_page.dart`：「远程控制」分区——开关、6 位 PIN（可刷新）、已授权设备（可撤销）、记住设备
- [ ] 权限状态检测：屏幕录制 / 辅助功能未授时给一键跳系统设置深链
- [ ] 开机自启（沿用 LocalSend 既有实现或 `SMAppService`）
- [ ] 状态回显：监听中 / 连接数 / 码率
- [ ] 端口冲突提示：检测到官方 LocalSend 占用 :53317 时明确报错并给关闭指引
- [ ] 设置页入口路由（上游文件第二处改动）

## M4 鸿蒙端会话页

- [ ] `RemoteModels.ets` / `RemoteSettings.ets`：类型与 preferences（`mac_remote_*`）
- [ ] `MacRemoteSession.ets`：PIN 鉴权 → relayStart/直连 → `startDirect` → 统计聚合
- [ ] `NativeStreamClient.ets`：首帧前插入鉴权步骤；direct 目标支持 127.0.0.1（relay）与局域网 IP
- [ ] `TrackpadGesture.ets`：spec §7.1 手势映射 + MOVE 节流
- [ ] `KeyBar.ets`：快捷键 chips + 长按锁定修饰键
- [ ] `RemoteDesktopPage.ets`：四态 + 上下分栏（默认 60:40，可拖 40%–75%，持久化）
- [ ] Index.pageMap 注册 + TransferPage 入口卡片
- [ ] ⚠️ 折叠展开/合上往返：FULL ↔ MINI 切换不崩溃、布局不残留

## M5 tsnet relay 与验收

- [ ] `bridge.go`：RelayStart/RelayStop（127.0.0.1 loopback → tsnet dial，仅允许 100.64.0.0/10）
- [ ] `cshared/main.go` + `napi_bridge.cpp` + `TsnapiLoader.ets` + `TailscaleManager.ets` 导出链
- [ ] ⚠️ 5G 关 WiFi 走 tsnet 全链路出画面，记录吞吐（≥ 30 Mbps）
- [ ] 剪贴板双向：GET_CLIPBOARD 回显到输入行、SET_CLIPBOARD + ⌘V
- [ ] 错误态细分：PIN 错误 / 主机无响应 / relay 失败回落 / 画面中断重连 / 端口冲突
- [ ] MINI 态外壳
- [ ] spec §10 指标全项实测并记录（首帧 / 回显延迟局域网+tsnet / 30min 稳定性）
- [ ] ⚠️ 退出清理回归：页面退出后 `lsof -i :27042 :27043` 为空、无残留线程、hilog 无泄漏报错
- [ ] 协议对拍：host 单测用 `ControlPacket.ets` 产出字节作 fixtures
- [ ] 共存回归：官方 LocalSend 与本分叉不同时运行，分叉版能正常互传文件
- [ ] README 更新：新增「Mac 远控」章节（分叉构建、权限、PIN、两种模式、端口冲突）
- [ ] `specs/scrcpy-mirror-phase1` 无回归：安卓镜像全流程复测
