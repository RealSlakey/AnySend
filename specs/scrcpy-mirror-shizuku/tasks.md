# 任务清单 · Shizuku 镜像桥（阶段一：局域网直连）

## 安卓端

- [ ] **T1** 新建 `android/app/src/main/assets/`，把 `harmonyos/entry/src/main/resources/rawfile/scrcpy-server-v3.3.4` 复制为 `scrcpy-server-v3.3.4`
- [ ] **T2** `IMirrorShizukuService.aidl` 增 `String startMirrorBridge(in byte[] jar, in String argsJson)` / `void stopMirrorBridge()`
- [ ] **T3** `MirrorShizukuService.kt` 实现镜像桥（写 jar → spawn app_process → 双 ServerSocket → LocalSocket 泵，video→control 串行）
- [ ] **T4** `MirrorHotspotController.kt`：`USER_SERVICE_VERSION`→3，新增 `startBridgeAndWait(...)` 返回 `videoPort/controlPort/scid`
- [ ] **T5** `LocalSendServer.kt::handleMirrorPrepare` 读 assets jar、拼 argsJson、调桥、响应加 3 个字段（保留既有字段）
- [ ] **T6** 安卓构建 + 装机 + curl 验证 mirror-prepare 返回新字段

## 鸿蒙 native

- [ ] **T7** `ScrcpyStreamManager.h` 声明 `startDirect(...)`
- [ ] **T8** 新增 `manager/ScrcpyStreamManagerDirect.cpp` 实现（TcpChannel 直连 + 三条线程）
- [ ] **T9** `cpp/scrcpy/CMakeLists.txt` 加入新源文件
- [ ] **T10** `napi_init.cpp` 新增并注册 `NativeStartDirectStreams`
- [ ] **T11** `ets/types/libscrcpy_native.d.ts` 补声明

## 鸿蒙 ArkTS

- [ ] **T12** 新增 `ets/scrcpy/client/tools/DirectStreamClient.ets`
- [ ] **T13** `ets/adb/MirrorAutoConnect.ets`：`MirrorPrepareInfo` 加 3 字段 + 新增 `resolveBridgeTarget()`
- [ ] **T14** `ets/pages/MirrorPage.ets` 改「自动拿桥地址 → 直连」，删除配对/无线调试 UI

## 联调

- [ ] **T15** 双端构建（非沙箱）→ 装机
- [ ] **T16** 真机验证：出画面、触摸、退出无残留、可重连
- [ ] **T17** 清理 `[ADB]/[ADBCLIENT]/[SCRC]` 调试插桩
- [ ] **T18** 请用户表态 GPL-3.0 取舍

## 阶段二（本轮不做，仅登记）

- [ ] **T19** 鸿蒙 Go 侧 `dial`→localhost 代理；安卓 Go 侧 `listen`→localhost 代理；`resolveBridgeTarget` 增 tailnet 分支
