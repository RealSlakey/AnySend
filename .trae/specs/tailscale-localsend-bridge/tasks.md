# TailScale LocalSend Bridge - 实现计划

## Task 1: 定义 LocalSend 协议共享数据模型与常量
- **Status**: `completed`
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 在项目根目录创建 `protocol/` 目录，以 Markdown + JSON Schema 形式定义 LocalSend v2 协议的所有数据结构和常量
- **Acceptance Criteria Addressed**: AC-3, AC-4, AC-6
- **Test Requirements**:
  - `rule` TR-1.1: 协议定义文档覆盖 LocalSend v2 的 register、send-request、send 三个请求和 info、register、send-request、send 四个响应端点的完整字段，字段名与 LocalSend 官方实现一致
  - `rule` TR-1.2: 端口常量、HTTP 路径、协议版本在文档中明确且唯一，两端实现以此为准
- **Completion Evidence**:
  - `protocol/README.md` 定义了 DeviceInfo、FileInfo、SendRequest、SendRequestResponse、CancelRequest 数据结构，端口 53317，7 个 HTTP 路径，协议版本 2.0

## Task 2: 实现 Go tsnet 桥接库（跨平台共享）
- **Status**: `completed`
- **Priority**: high
- **Depends On**: None
- **Description**:
  - Go 代码封装 Tailscale tsnet，导出 Start/GetSelfInfo/GetPeers/Dial/Listen/Accept/Read/Write/CloseConn/CloseListener/Close/IsStarted
  - c-shared 入口 `go/cmd/cshared/main.go`
- **Acceptance Criteria Addressed**: AC-1, AC-2, AC-7
- **Test Requirements**:
  - `rule` TR-2.1: Go 代码能通过 go build 编译
  - `rule` TR-2.2: 桥接库导出 Start/GetPeers/Dial/Listen/Close 五个核心函数
  - `rule` TR-2.3: tsnet 使用 netstack 用户态模式
- **Completion Evidence**:
  - `CGO_ENABLED=1 go build -buildmode=c-shared` 成功，产物 34MB .so
  - nm 验证导出 Start/GetPeers/GetSelfInfo/Dial/Listen/Accept/Read/Write/Close/CloseConn/CloseListener/IsStarted/FreeString
  - tsnet 默认使用 userspace netstack，无 TUN 设备

## Task 3: Android 工程脚手架
- **Status**: `completed`
- **Priority**: high
- **Depends On**: None
- **Description**: Gradle Android 工程（Kotlin），minSdk 24
- **Acceptance Criteria Addressed**: AC-9
- **Test Requirements**:
  - `rule` TR-3.1: 完整 Gradle 构建文件
  - `rule` TR-3.2: 包含 AndroidManifest、MainActivity、Application
- **Completion Evidence**:
  - `android/settings.gradle.kts`, `android/build.gradle.kts`, `android/app/build.gradle.kts`
  - `android/app/src/main/AndroidManifest.xml`, `App.kt`, `MainActivity.kt`

## Task 4: Android 端集成 tsnet（AAR + 调用层）
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 2, Task 3
- **Description**: build-aar.sh + TailscaleManager.kt 封装 AAR 调用
- **Acceptance Criteria Addressed**: AC-1, AC-7
- **Test Requirements**:
  - `rule` TR-4.1: build-aar.sh 包含 gomobile bind 命令
  - `rule` TR-4.2: TailscaleManager 封装 login/getPeers
  - `rule` TR-4.3: peer 列表含设备名和 IP
- **Completion Evidence**:
  - `scripts/build-aar.sh`
  - `android/app/src/main/java/com/tslsb/app/bridge/TailscaleManager.kt` 调用 `tsnetbridge.Tsnetbridge.*`

## Task 5: Android 端 LocalSend 协议实现
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 1, Task 4
- **Description**: LocalSendSender（register→send-request→send）+ LocalSendServer（4 端点）
- **Acceptance Criteria Addressed**: AC-3, AC-4, AC-6
- **Test Requirements**:
  - `rule` TR-5.1: Sender 实现 register/sendRequest/sendFile
  - `rule` TR-5.2: Server 实现 /info /register /send-request /send
  - `rule` TR-5.3: 端口 53317
- **Completion Evidence**:
  - `LocalSendSender.kt` 走 TailscaleManager.dial 原始 socket
  - `LocalSendServer.kt` 走 TailscaleManager.listen 原始 socket
  - 全部 HTTP 流量经 Tailscale 用户态网络栈

## Task 6: Android 系统分享面板接入
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 3
- **Description**: AndroidManifest 注册 ACTION_SEND IntentFilter
- **Acceptance Criteria Addressed**: AC-5
- **Test Requirements**:
  - `rule` TR-6.1: intent-filter 含 ACTION_SEND + 多 MIME
  - `rule` TR-6.2: ShareActivity 提取文件 URI
- **Completion Evidence**:
  - `AndroidManifest.xml` ShareActivity intent-filter（text/plain, image/*, video/*, audio/*, application/*, */*）
  - `ShareActivity.kt` extractFiles() 处理 SEND 和 SEND_MULTIPLE

## Task 7: Android 端 UI
- **Status**: `completed`
- **Priority**: medium
- **Depends On**: Task 4, Task 5
- **Description**: Peer 选择 + 传输进度 + 接收确认
- **Acceptance Criteria Addressed**: AC-8
- **Test Requirements**:
  - `rule` TR-7.1: Peer 列表调用 getPeers()
  - `rubric` TR-7.2: 进度反馈完整性；threshold >= 4
- **Completion Evidence**:
  - `ShareActivity.kt` 实时显示已传/总字节、百分比；完成后 Toast 通知。Score: 5

## Task 8: Android 端端到端串联
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 5, Task 6, Task 7
- **Description**: 分享→peer选择→发送 完整链路；接收→保存 完整链路
- **Acceptance Criteria Addressed**: AC-3, AC-4, AC-6, AC-8
- **Test Requirements**:
  - `rule` TR-8.1: 发送链路完整无 TODO
  - `rule` TR-8.2: 接收保存到 Download
- **Completion Evidence**:
  - ShareActivity → LocalSendSender 完整调用链
  - BridgeService 启动 LocalSendServer，文件保存到 Environment.DIRECTORY_DOWNLOADS

## Task 9: HarmonyOS 工程脚手架
- **Status**: `completed`
- **Priority**: high
- **Depends On**: None
- **Description**: HarmonyOS NEXT 工程（ArkTS，API 12+）
- **Acceptance Criteria Addressed**: AC-9
- **Test Requirements**:
  - `rule` TR-9.1: build-profile.json5, oh-package.json5, module.json5
  - `rule` TR-9.2: EntryAbility.ets, Index.ets
- **Completion Evidence**:
  - `harmonyos/build-profile.json5`, `harmonyos/oh-package.json5`, `harmonyos/entry/src/main/module.json5`
  - `EntryAbility.ets`, `pages/Index.ets`

## Task 10: HarmonyOS 端集成 tsnet（.so + NAPI）
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 2, Task 9
- **Description**: build-so.sh + napi_bridge.cpp + TailscaleManager.ets
- **Acceptance Criteria Addressed**: AC-2, AC-7
- **Test Requirements**:
  - `rule` TR-10.1: build-so.sh 含 Go 交叉编译（ohos clang）
  - `rule` TR-10.2: NAPI 注册 5+ 方法
  - `rule` TR-10.3: ArkTS TailscaleManager native import
- **Completion Evidence**:
  - `scripts/build-so.sh`（CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC=ohos-clang）
  - `harmonyos/entry/src/main/cpp/napi_bridge.cpp` 注册 start/getPeers/getSelfInfo/dial/listen/accept/read/write/closeConn/closeListener/close/isStarted
  - `TailscaleManager.ets` import tsnapi from 'libtsnapi.so'

## Task 11: HarmonyOS 端 LocalSend 协议实现
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 1, Task 10
- **Description**: LocalSendSender.ets + LocalSendServer.ets
- **Acceptance Criteria Addressed**: AC-3, AC-4, AC-6
- **Test Requirements**:
  - `rule` TR-11.1: Sender 实现 register/sendRequest/sendFile
  - `rule` TR-11.2: Server 实现 4 端点
  - `rule` TR-11.3: 端口 53317
- **Completion Evidence**:
  - `LocalSendSender.ets` 走 TailscaleManager.dial
  - `LocalSendServer.ets` 走 TailscaleManager.listen

## Task 12: HarmonyOS 系统分享面板接入
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 9
- **Description**: module.json5 配置 Share Extension + ShareAbility
- **Acceptance Criteria Addressed**: AC-5
- **Test Requirements**:
  - `rule` TR-12.1: extensionAbilities type=share + skills MIME
  - `rule` TR-12.2: 分享扩展提取文件 URI
- **Completion Evidence**:
  - `module.json5` ShareExtensionAbility + ShareAbility，skills 含 image/video/audio/text/application MIME
  - `ShareExtensionAbility.ets` 从 want.parameters 取 contentUris

## Task 13: HarmonyOS 端 UI
- **Status**: `completed`
- **Priority**: medium
- **Depends On**: Task 10, Task 11
- **Description**: Peer 选择页 + 传输进度
- **Acceptance Criteria Addressed**: AC-8
- **Test Requirements**:
  - `rule` TR-13.1: Peer 列表调用 getPeers()
  - `rubric` TR-13.2: 进度反馈；threshold >= 4
- **Completion Evidence**:
  - `pages/Share.ets` 实时进度条 + 已传/总字节 + 完成 Toast。Score: 5

## Task 14: HarmonyOS 端端到端串联
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 11, Task 12, Task 13
- **Description**: 分享→peer选择→发送 完整链路
- **Acceptance Criteria Addressed**: AC-3, AC-4, AC-6, AC-8
- **Test Requirements**:
  - `rule` TR-14.1: 发送链路完整无 TODO
  - `rule` TR-14.2: 接收保存完整
- **Completion Evidence**:
  - Share.ets → LocalSendSender 完整调用链
  - LocalSendServer.handleSend 保存到 context.filesDir

## Task 15: 跨平台协议一致性验证
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 8, Task 14
- **Description**: 对比两端协议实现
- **Acceptance Criteria Addressed**: AC-6
- **Test Requirements**:
  - `rule` TR-15.1: 字段名一一对应
  - `rule` TR-15.2: 端口/路径/版本一致
- **Completion Evidence**:
  - grep 验证：PORT=53317, PROTOCOL_VERSION="2.0", 7 个 PATH 常量两端完全一致
  - DeviceInfo(8字段)、FileInfo(6字段)、SendRequest、SendRequestResponse 字段名一一对应

## Task 16: 构建脚本与 README 文档
- **Status**: `completed`
- **Priority**: medium
- **Depends On**: Task 8, Task 14
- **Description**: README.md + 构建脚本
- **Acceptance Criteria Addressed**: AC-9
- **Test Requirements**:
  - `rubric` TR-16.1: 工程结构与可构建性；threshold >= 4
  - `rule` TR-16.2: 根目录含 Android 和 HarmonyOS 构建脚本
- **Completion Evidence**:
  - `README.md` 含架构图、目录结构、前置依赖、Android/HarmonyOS 构建步骤、使用方法
  - `scripts/build-aar.sh` + `scripts/build-so.sh` 均已 chmod +x
  - Score: 5（结构清晰、脚本完整、说明详尽）

## Issue I-1: 多文件发送未实现
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 8, Task 14
- **Discovered By**: Review R1
- **Description**:
  - Android ShareActivity.kt 和 HarmonyOS Share.ets 均只发送第一个文件，未遍历 accepted 列表逐个调用 sendFile
- **Acceptance Criteria Addressed**: AC-3, AC-8
- **Test Requirements**:
  - `rule` TR-I-1.1: 发送端遍历所有 accepted 文件并逐个上传，聚合总进度
- **Completion Evidence**:
  - Android: ShareActivity.kt 遍历 acceptedFiles，逐个 sendFile，totalBytes/sentBytes 聚合进度
  - HarmonyOS: Share.ets 遍历 accepted，逐个 sendFile，聚合 totalBytes/sentBytes 进度
  - 两端完成后显示文件数量

## Issue I-2: HarmonyOS 分享 URI 未转换为可读路径
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 14
- **Discovered By**: Review R1
- **Description**:
  - Share.ets 直接把 content:// 或 file:// URI 当文件路径传给 fs.statSync/openSync，运行时会失败
- **Acceptance Criteria Addressed**: AC-5, AC-3
- **Test Requirements**:
  - `rule` TR-I-2.1: 能正确处理 file:// 和 content:// URI，打开并读取文件内容
- **Completion Evidence**:
  - LocalSendSender.ets 新增 extractFileName() 和 getFileSize()，使用 fs.openSync(uri) + fs.fstatSync(fd) 处理 content:// URI
  - sendFile 使用 fs.openSync(filePath) 支持路径和 URI
  - Share.ets 直接传 sharedUris 给 sendRequest

## Issue I-3: Android fileMap 构造后未使用
- **Status**: `completed`
- **Priority**: high
- **Depends On**: Task 8
- **Discovered By**: Review R1
- **Description**:
  - ShareActivity.kt 中 fileMap 定义后未参与文件匹配，实际用 sharedFiles.first()
- **Acceptance Criteria Addressed**: AC-3
- **Test Requirements**:
  - `rule` TR-I-3.1: 按 SendRequestResponse.files 的 fileId 回查对应文件
- **Completion Evidence**:
  - LocalSendSender.sendRequest 返回 SendRequestResult(response, fileIdToFile)
  - ShareActivity 用 resp.fileIdToFile[fileId] 回查文件，删除无用的 fileMap
