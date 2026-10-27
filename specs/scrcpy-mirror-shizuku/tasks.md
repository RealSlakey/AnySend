# 任务清单 · Shizuku 镜像桥

> 现行方案，取代 `specs/scrcpy-mirror-phase1`（无线 ADB / SPAKE2 配对那条路在「安卓开热点」场景下互斥，已废弃）。
> 状态以 **2026-10-27 源码核对**为准：`[x]` 有代码或产物可证，`⚠️` 需真机确认，`[ ]` 未做。

## 安卓端

- [x] **T1** `android/app/src/main/assets/scrcpy-server-v3.3.4`（90,980 B，与鸿蒙 rawfile 同一份）
- [x] **T2** `IMirrorShizukuService.aidl` 增 `startMirrorBridge(byte[] jar, String argsJson)` / `stopMirrorBridge()`（= 6）
- [x] **T3** `MirrorShizukuService.kt`：写 jar → `app_process` 起 server → 双 `ServerSocket` → `LocalSocket` 泵（video→control 串行）
- [x] **T4** `MirrorHotspotController.kt::startBridgeAndWait()` 返回 `MirrorBridgeInfo(videoPort, controlPort, scid)`
- [x] **T5** `LocalSendServer.kt::handleMirrorPrepare()` 读 assets jar、拼 argsJson、响应加 3 字段，并在启用隧道时拉起 `MirrorTailnetProxy`
- [x] **T6** 安卓构建通过（`android/app/build/outputs/apk/debug/app-debug.apk`，2026-10-26）

## 鸿蒙 native

- [x] **T7** `ScrcpyStreamManager.h` 声明 `startDirect(host, videoPort, controlPort, Config, cb)`
- [x] **T8** `manager/ScrcpyStreamManagerDirect.cpp` 实现（`TcpChannel` 直连 + video/control 双线程 + 失败回滚）
- [x] **T9** `cpp/scrcpy/CMakeLists.txt` 已加入新源文件
- [x] **T10** `napi_init.cpp` 新增并注册 `NativeStartDirectStreams`（异步 work 版）
- [x] **T11** `ets/types/libscrcpy_native.d.ts` 已补 `nativeStartDirectStreams`

## 鸿蒙 ArkTS

- [x] **T12** `ets/scrcpy/client/tools/DirectStreamClient.ets`
- [x] **T13** `ets/adb/MirrorAutoConnect.ets`：`MirrorPrepareInfo` 加 3 字段 + `resolveBridgeTarget()`（tailnet 探测 → 同网直连 → 加入热点三级回落）
- [x] **T14** `ets/pages/MirrorPage.ets`、`AppStreamPage.ets` 改为「自动拿桥地址 → 直连」，配对/无线调试 UI 已移除
- [x] **T17** 调试插桩已清理（全仓已无 `[ADB]/[ADBCLIENT]/[SCRC]` 标记）

## 联调

- [x] **T15** 双端产物均已出（APK 2026-10-26、`entry-default-signed.hap` 2026-10-26）
- [ ] **T16** ⚠️ 真机验收：出画面、触摸、退出无残留、可重连 —— 需在真机上逐项过一遍并记录
- [ ] **T18** GPL-3.0 取舍仍待拍板（scrcpy-server jar 随包分发）

## 跨网（原「阶段二」，实际已实现，做法不同于原计划）

- [x] **T19** 安卓侧新增 `MirrorTailnetProxy.kt`：在 tailnet 固定监听 `27052`/`27053`，逐条 pipe 到 `127.0.0.1:<桥端口>`，保持 video→control 顺序。有真实网卡的对端（Mac `utun`）可直接连。
- [ ] 遗留：鸿蒙侧仍是用户态 tsnet，原生 `connect()` 到 100.x 不通，跨网只能靠「加入安卓热点」回落。若要鸿蒙也直连 27052/27053，需在 `go/tsnetbridge` 补 dial→localhost 代理并暴露给 native。
