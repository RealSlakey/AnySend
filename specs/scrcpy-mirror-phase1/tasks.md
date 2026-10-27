# scrcpy 镜像一期 · 任务分解

> ⚠️ **已废弃，仅作历史记录**：本方案的无线 ADB / SPAKE2 配对被 `specs/scrcpy-mirror-shizuku` 取代（安卓开热点时与该方案互斥）。
> 成果去向：T1 的 native 解码器（`vdInit/vdPush/vdRelease`）仍被现行方案直接复用；T2 的 ADB 协议层已由 ArkTS 迁到 C++（`cpp/scrcpy/adb/`，含 `AdbKeyPair`、`PairingAuth`），`ets/adb/` 下只剩 `MirrorAutoConnect.ets`；T3 的帧解析并入 `scrcpy/client/tools/`。

## T1 native 解码器（cpp）
- [x] `cpp/video_decoder.cpp`：单例封装 OH_AVCodec（surface 模式），互斥队列，NAPI 三函数 vdInit/vdPush/vdRelease
- [x] `cpp/CMakeLists.txt` + `cpp/napi_bridge.cpp` 注册；`ets/bridge/TsnapiLoader.ets` 接口与 Stub 同步
- 验证：hvigor 编译通过（native so 参与打包）

## T2 ADB 协议层（ets/adb/）
- [x] `AdbBuffer.ets`：小工具
- [x] `AdbAuth.ets`：cryptoFramework RSA-2048 生成/convertKey 加载/preferences 持久化；X.509 DER 解析取 n、e；mincrypt 524B 公钥（BigInt：n0inv、rr、小端 n）；SHA1withRSA 签名
- [x] `AdbConnection.ets`：TCPSocket（参照 DirectNetworkLayer 模式，connect 5s 超时）、24B 消息泵、CNXN/AUTH 状态机、AdbStream（OPEN/OKAY/WRTE lock-step/CLSE、onData/onClose）
- [x] `AdbClient.ets`：openShell（收集日志）、syncPush（SEND/DATA 32K/DONE，FAIL 文案解析）
- 验证：ArkTS 编译通过（真机联调在 T5）

## T3 scrcpy 客户端（ets/adb/ScrcpyClient.ets）
- [x] rawfile 读取 jar → syncPush → shell 启动 server（参数按 spec）→ localabstract 重试取流
- [x] 解析 dummy(1B)/deviceName(64B)/codecMeta(12B)/帧头(12B+payload)，状态+帧回调
- [x] close 全链路清理
- 验证：编译通过

## T4 UI（MirrorPage + 入口）
- [x] `MirrorPage.ets` 四态（配置/连接步骤/镜像悬浮条/错误分类）+ XComponent aspect-fit + 统计 chip + 返回清理
- [x] `TransferPage.ets` 入口卡片；`Index.ets` pageMap 注册
- 验证：编译通过

## T5 构建装机联调
- [x] hvigor clean assembleHap（非沙箱）出 signed hap
- [x] 向用户确认鸿蒙真机最新无线调试地址后装机（设备仍在线 192.168.5.185:38367，signed hap 已装机成功）
- [ ] 真机验证：授权弹窗→出画面；旋转不崩；退出无残留进程；重连 OK
- [x] 更新 project_memory.md

## 依赖顺序
T1 → T2 → T3 → T4 → T5（T1/T2 可并行；T5 需用户提供 hdc 端口）
