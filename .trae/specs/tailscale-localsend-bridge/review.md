# TailScale LocalSend Bridge - 独立审查

## 审查检查点

- [x] CP-R1: Go tsnet 桥接库编译通过
  - **Type**: `rule`
  - **Covers**: AC-1, AC-2, AC-7, TR-2.1
  - **Evidence**: `go build ./tsnetbridge/` 退出码 0；c-shared 编译也通过

- [x] CP-R2: Go c-shared 导出全部所需符号
  - **Type**: `rule`
  - **Covers**: AC-1, AC-2, TR-2.2
  - **Evidence**: nm -D 验证 13 个符号全部存在

- [x] CP-R3: 两端 LocalSend 协议常量一致
  - **Type**: `rule`
  - **Covers**: AC-6, TR-15.1, TR-15.2
  - **Evidence**: PORT/PATH/VERSION/DeviceInfo/FileInfo 字段完全一致

- [x] CP-R4: 设备发现走 Tailscale Peer API（无组播）
  - **Type**: `rule`
  - **Covers**: AC-7
  - **Evidence**: 全仓 grep 无组播调用，GetPeers 走 LocalClient.Status()

- [x] CP-R5: HTTP 传输走 Tailscale socket（非系统网络栈）
  - **Type**: `rule`
  - **Covers**: AC-7
  - **Evidence**: Sender 用 TailscaleManager.dial，Server 用 TailscaleManager.listen，无 OkHttp/@ohos.net.http

- [x] CP-R6: Android 分享面板接入正确
  - **Type**: `rule`
  - **Covers**: AC-5, TR-6.1
  - **Evidence**: AndroidManifest ShareActivity intent-filter 含 SEND + 多 MIME

- [x] CP-R7: HarmonyOS 分享扩展接入正确
  - **Type**: `rule`
  - **Covers**: AC-5, TR-12.1
  - **Evidence**: module.json5 ShareExtensionAbility type=share + skills MIME

- [x] CP-R8: LocalSend 发送协议实现完整
  - **Type**: `rule`
  - **Covers**: AC-3
  - **Evidence**: 两端 register→sendRequest→sendFile 三步齐全

- [x] CP-R9: LocalSend 接收协议实现完整
  - **Type**: `rule`
  - **Covers**: AC-4
  - **Evidence**: 两端 /info /register /send-request /send 四路由齐全

- [x] CP-R10: 构建脚本完整
  - **Type**: `rule`
  - **Covers**: AC-9, TR-16.2
  - **Evidence**: build-aar.sh (gomobile bind) + build-so.sh (Go cross-compile)

- [x] CP-U1: 传输进度用户反馈完整性
  - **Type**: `rubric`
  - **Covers**: AC-8, TR-7.2, TR-13.2
  - **Score**: 4/5 (threshold >=4, pass)
  - **Evidence**: 两端实时进度条+字节数+完成通知；扣分：多文件只发第一个

- [x] CP-U2: 工程结构清晰度与可构建性
  - **Type**: `rubric`
  - **Covers**: AC-9, TR-16.1
  - **Score**: 5/5 (threshold >=4, pass)
  - **Evidence**: 目录清晰、README 含架构图+构建步骤、脚本完整

## Review History

### Review R1
- **Result**: `fail`（存在 3 个 actionable 代码缺陷，需修复）
- **Evidence**: 见下方发现
- **Actionable Findings**:
  - I-1: 多文件发送未实现（两端均只发第一个文件）
  - I-2: HarmonyOS 分享 URI 未转换为可读文件路径
  - I-3: Android fileMap 构造后未使用，文件匹配逻辑缺失

### Review R2
- **Result**: `pass`
- **Evidence**: 独立审查员验证 I-1/I-2/I-3 全部修复，无新增 actionable 问题
  - Android ShareActivity.kt 遍历 acceptedFiles + fileIdToFile 回查 + 聚合进度
  - HarmonyOS Share.ets 遍历 accepted + 聚合进度
  - LocalSendSender.ets 用 fs.openSync(uri)+fstatSync 处理 content:// URI
  - 两端常量一致、走 TailscaleManager、无组播调用
- **Cleanup**: 删除 Share.ets 中被覆盖的冗余 totalBytes 循环
