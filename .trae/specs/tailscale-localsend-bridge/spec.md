# TailScale LocalSend Bridge - 产品需求文档

## Overview
- **Summary**: 构建一个跨平台文件互传应用，分别运行在 Android 手机和 HarmonyOS NEXT 手机上，内嵌 Tailscale（tsnet 用户态网络栈模式）实现跨网络虚拟内网，再基于 LocalSend 协议在两端之间传输文件。用户在系统分享面板中选择本应用即可自动连接 Tailscale、发现对端并发送文件，无需两台设备处于同一局域网。
- **Purpose**: 解决 Android 与 HarmonyOS NEXT 设备之间跨网络文件传输的便利性问题，利用 Tailscale 的 NAT 穿透和加密能力，叠加 LocalSend 的简洁传输协议。
- **Target Users**: 同时拥有 Android 和 HarmonyOS NEXT 手机、需要在两台设备间频繁传文件的用户。

## Goals
- 两台设备（Android + HarmonyOS NEXT）各自运行本应用后，可在任意网络环境下互传文件
- 用户通过系统分享面板即可发起传输，无需手动配置 IP
- 文件传输全程加密（Tailscale WireGuard 加密）
- 不依赖系统 VPN/TUN 权限（使用 tsnet 用户态网络栈）

## Non-Goals
- 不做即时通讯、文字消息功能
- 不做文件云端备份或同步
- 不做 iOS / Windows / macOS 端
- 不做 Tailscale 账号注册/管理（用户使用已有 Tailscale 账号登录）
- 不做断点续传（初版）

## Background & Context
- LocalSend 协议开源，使用 UDP 组播(224.0.0.167:53317)发现设备，HTTP(53317)传输文件
- Tailscale 默认不转发组播，因此设备发现阶段必须改用 Tailscale 的 Peer API 获取对端 Tailscale IP，而非依赖 LocalSend 的组播发现
- Tailscale 的 `tsnet` 库支持用户态网络栈（netstack）模式，无需 TUN 设备，适合内嵌到应用进程中
- HarmonyOS NEXT 不兼容 Android APK，需将 Go 编写的 tsnet 交叉编译为 .so 动态库，通过 NAPI 桥接供 ArkTS 调用
- Android 侧可使用 gomobile 将同一套 Go tsnet 桥接代码编译为 AAR 供 Kotlin 调用

## Functional Requirements
- **FR-1**: 应用启动后可通过 Tailscale 账号登录（支持 auth key 或浏览器交互式登录）
- **FR-2**: 登录成功后应用内嵌的 Tailscale 节点上线，加入用户的 Tailscale 网络
- **FR-3**: 应用可获取当前 Tailscale 网络中的 peer 列表（设备名 + Tailscale IP）
- **FR-4**: 应用在系统分享面板中注册为分享目标（接收文本/文件类型）
- **FR-5**: 用户从系统分享面板选择本应用后，应用展示当前可用的 peer 设备列表
- **FR-6**: 用户选择目标 peer 后，应用通过 LocalSend 协议（HTTP over Tailscale IP）发送文件
- **FR-7**: 接收端收到传输请求后展示文件信息和发送者，用户可接受或拒绝
- **FR-8**: 传输过程中发送端和接收端均显示进度
- **FR-9**: 传输完成后两端均显示结果通知
- **FR-10**: Android 端可发送给 HarmonyOS 端，HarmonyOS 端也可发送给 Android 端（双向互通）

## Non-Functional Requirements
- **NFR-1**: 跨网络可用：两台设备处于不同局域网/蜂窝网络时仍可传输
- **NFR-2**: 传输加密：所有数据通过 Tailscale WireGuard 隧道加密
- **NFR-3**: 无需 TUN 权限：使用 tsnet 用户态网络栈，不申请系统 VPN 权限
- **NFR-4**: 单文件传输大小无硬性限制（受设备存储约束）
- **NFR-5**: 应用后台运行时保持 Tailscale 连接活跃

## Constraints
- **Technical**:
  - HarmonyOS NEXT 不支持 Android APK，所有原生能力需通过 NAPI 实现
  - Tailscale（Go）需交叉编译为 OpenHarmony 目标的 .so 共享库
  - LocalSend 组播发现不可用，必须替换为 Tailscale Peer 发现
- **Business**: 无
- **Dependencies**:
  - Tailscale 账号（用户自备）
  - OpenHarmony NDK（构建 HarmonyOS 原生模块用）
  - Go 工具链（构建 tsnet 桥接库用）
  - Android SDK + NDK（构建 Android 端用）
  - DevEco Studio（构建 HarmonyOS 端用）

## Assumptions
- 用户已拥有 Tailscale 账号，且两台设备登录同一 Tailscale 网络
- 用户设备可访问 Tailscale 控制服务器（controlplane.tailscale.com）
- HarmonyOS NEXT 设备的 Linux 内核支持 Go runtime 所需的系统调用
- 两台设备的 Tailscale IP 可互相直连（或通过 DERP 中继）

## Acceptance Criteria

### AC-1: Tailscale 连接与 Peer 发现（Android）
- **Type**: `rule`
- **Given**: Android 应用已构建并安装，用户持有有效的 Tailscale 账号
- **When**: 用户在应用中完成 Tailscale 登录
- **Then**: 应用内嵌的 Tailscale 节点上线，并能获取到同网络下其他 peer 的设备名和 Tailscale IP 列表
- **Pass Condition**: 代码实现了 tsnet 启动、登录、获取 peer 列表的完整调用链；peer 列表数据结构包含设备名和 IP
- **Evidence**: Android 端 Kotlin 调用 tsnet AAR 的代码、peer 列表数据模型

### AC-2: Tailscale 连接与 Peer 发现（HarmonyOS）
- **Type**: `rule`
- **Given**: HarmonyOS 应用已构建（含原生 .so 模块）并安装，用户持有有效的 Tailscale 账号
- **When**: 用户在应用中完成 Tailscale 登录
- **Then**: 应用内嵌的 Tailscale 节点上线，并能获取到同网络下其他 peer 的设备名和 Tailscale IP 列表
- **Pass Condition**: 提供 Go tsnet 桥接源码（.so 编译产物）+ NAPI 桥接层 + ArkTS 调用代码，三者接口对齐
- **Evidence**: Go 桥接源码、NAPI C++ 层、ArkTS native import 代码、构建脚本

### AC-3: LocalSend 发送协议实现
- **Type**: `rule`
- **Given**: 发送端已连接 Tailscale 并获取到接收端的 Tailscale IP
- **When**: 用户选择接收端并发送文件
- **Then**: 发送端按 LocalSend v2 协议顺序调用：register → send-request → send，完成文件上传
- **Pass Condition**: 实现 LocalSend v2 的 register、send-request、send 三个 HTTP 调用，请求体格式与 LocalSend 协议规范一致
- **Evidence**: 发送端协议实现代码（Android Kotlin + HarmonyOS ArkTS 各一份）

### AC-4: LocalSend 接收协议实现
- **Type**: `rule`
- **Given**: 接收端已连接 Tailscale，HTTP 服务监听在 53317 端口
- **When**: 发送端按 LocalSend v2 协议发起 register → send-request → send
- **Then**: 接收端依次响应：返回设备信息、返回接受的文件列表、接收并保存文件到本地
- **Pass Condition**: 实现 LocalSend v2 的 /info、/register、/send-request、/send 四个 HTTP 端点，响应格式与协议规范一致
- **Evidence**: 接收端 HTTP 服务实现代码（Android Kotlin + HarmonyOS ArkTS 各一份）

### AC-5: 系统分享面板接入
- **Type**: `rule`
- **Given**: 应用已安装
- **When**: 用户在系统文件管理器/相册中选择"分享"
- **Then**: 本应用出现在分享目标列表中；选择后应用启动并携带被分享的文件信息
- **Pass Condition**: Android 端在 AndroidManifest 中注册 ACTION_SEND IntentFilter；HarmonyOS 端配置分享扩展（Share Extension）
- **Evidence**: AndroidManifest.xml 配置、HarmonyOS module.json5 分享扩展配置

### AC-6: 双向互通
- **Type**: `rule`
- **Given**: Android 和 HarmonyOS 两端均已登录同一 Tailscale 网络
- **When**: 从任意一端发起文件分享到另一端
- **Then**: 对端能收到传输请求，接受后文件完整传输
- **Pass Condition**: 两端的 LocalSend 协议实现字段名、端口、请求格式完全一致，可互相解析
- **Evidence**: 两端协议数据模型定义一致、端口常量一致、HTTP 路径一致

### AC-7: 跨网络传输能力
- **Type**: `rule`
- **Given**: 两台设备处于不同网络（如一台 WiFi、一台蜂窝数据）
- **When**: 发起文件传输
- **Then**: 传输通过 Tailscale 隧道完成，不依赖局域网组播或广播
- **Pass Condition**: 设备发现完全基于 Tailscale Peer API，未使用 LocalSend 组播发现；传输使用 Tailscale IP 直连
- **Evidence**: 代码中设备发现逻辑调用 tsnet peer 接口，无 UDP 组播调用

### AC-8: 传输进度与结果反馈
- **Type**: `rubric`
- **Dimension**: 传输过程的用户反馈完整性
- **Scale**: 1-5
- **Anchors**: 1 = 无进度反馈；3 = 仅显示开始/结束；5 = 实时显示已传字节/总字节、百分比，完成后明确通知
- **Pass Threshold**: >= 4
- **Evidence**: 发送端和接收端的进度 UI 实现代码

### AC-9: 代码结构与可构建性
- **Type**: `rubric`
- **Dimension**: 工程结构清晰度与可构建性
- **Scale**: 1-5
- **Anchors**: 1 = 代码混乱无构建说明；3 = 结构基本清晰但构建脚本缺失或不完整；5 = 目录结构清晰、构建脚本完整、README 说明详尽、可按步骤构建
- **Pass Threshold**: >= 4
- **Evidence**: 项目目录结构、各模块构建脚本、根 README

## Open Questions
- [ ] Tailscale 登录方式：优先支持 auth key（简单）还是交互式浏览器登录（体验好）？初版建议两者都支持，auth key 作为兜底。
- [ ] 接收端是否需要"自动接受"选项（免确认传输）？初版建议默认需要确认，提供设置项。
- [ ] 接收文件默认保存路径？Android 建议 Download 目录，HarmonyOS 建议文件管理根目录。
