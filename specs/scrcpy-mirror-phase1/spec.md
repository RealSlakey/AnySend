# AnySend 鸿蒙端 · scrcpy 屏幕镜像一期（只看不点）

## 目标

在 AnySend 鸿蒙客户端新增"屏幕镜像"功能：通过 WiFi ADB 直连安卓设备（传统 adbd tcp 模式，如 192.168.5.108:5555），推送并运行 scrcpy-server v2.7，实时硬解渲染安卓屏幕画面。一期为只读镜像（无触摸注入），UI 精致完整（四态齐全）。

## 已验证的协议事实（源码级确认，勿再调研）

### ADB 协议
- 直连 adbd TCP（非 adb server），仅支持 daemon 侧服务：`shell:`、`sync:`、`tcp:`、`localabstract:` 等；**不支持 host:forward**，因此不经 forward，直接 `OPEN localabstract:scrcpy_<scid>` 取流
- 消息 24B 头：`cmd u32, arg0 u32, arg1 u32, dataLen u32, checksum u32(数据字节和), magic u32(cmd^0xFFFFFFFF)`，小端
- 握手：客户端发 `CNXN version=0x01000001 maxdata=1MB banner="host::"`；无 DelayedAck 特性 → 设备回退经典逐包 OKAY 流控
- AUTH：设备发 `AUTH type=1`（20B token）→ 客户端回 `AUTH type=2`（RSA-SHA1 PKCS#1 v1.5 签名 256B）→ 若设备不认识则再发新 token → 客户端回 `AUTH type=3`（公钥串）；设备端弹授权框，用户允许后回 `CNXN`
- **公钥格式为 mincrypt RSAPublicKey 结构体（524 字节，全小端）**：`modulusLenWords u32(=64) + n0inv i32(=-modInverse(n mod 2^32, 2^32)) + n 256B(小端) + rr 256B(=2^4096 mod n) + exponent u32(=65537)`，整体 base64 后接 `" AnySend\0"`（来源：ya-webadb public-key.ts，与 AOSP android_pubkey.cpp 一致）
- 流复用：`OPEN localId` → 设备 `OKAY(remoteId, localId)`；收到 WRTE 必须立即回 OKAY；发送 WRTE 后须等 OKAY 才能发下一包（lock-step）；CLSE 关闭
- sync v1 推送：`sync:` 流，`SEND` + u32 len + `"path,0644"` → `DATA` + u32 len + chunk（≤32KB）→ `DONE` + u32 mtime → 等待 `OKAY` / `FAIL+len+msg`

### scrcpy v2.7
- server jar（Apache-2.0，已下载至 `harmonyos/entry/src/main/resources/rawfile/scrcpy-server.jar`）push 到 `/data/local/tmp/scrcpy-server.jar`
- 启动：`shell:` 服务执行 `CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 2.7 scid=<8位小写hex> tunnel_forward=true video=true audio=false control=false max_size=1600 video_bit_rate=8000000 max_fps=60 log_level=info cleanup=false`（server 严格校验版本号 "2.7"）
- server 监听 `localabstract:scrcpy_%08x`（scid 十六进制小写零填充 8 位）；**scid 参数按十六进制解析**
- video socket（第一连接）：server 先发 1B dummy(0x00) → 64B 设备名（0 填充 UTF-8）→ 12B codec meta（codecId u32 BE "h264"=0x68323634, width u32, height u32）→ 帧序列
- 帧头 12B：`u64`（最高位=config 包标志，次高位=关键帧标志，低 62 位 PTS）+ `u32` payload 长度；payload 为 Annex-B（start code 分隔的 SPS/PPS/IDR/P 帧）

### 解码（本机 SDK 实测）
- 本 SDK（HarmonyOS NEXT 6.x）**无 ArkTS 低阶 VideoDecoder**（@ohos.multimedia.media 已移除 createVideoDecoder）→ 必须 native OH_AVCodec surface 模式
- 头文件：`sysroot/usr/include/multimedia/player_framework/native_avcodec_{base,videodecoder}.h`；链接 `libnative_media_core.so + libnative_media_vdec.so + libnative_window.so`
- `OH_NativeWindow_CreateNativeWindowFromSurfaceId(uint64_t, OHNativeWindow**)` 存在（external_window.h:763），surfaceId 由 `XComponentController.getXComponentSurfaceId(): string` 获取
- 回调式 API：`OH_AVCodecCallback{onStreamChanged/onNeedInputBuffer/onNewOutputBuffer/onError}`；输入 `OH_AVBuffer_GetAddr + OH_AVBuffer_SetBufferAttr(size,flags) + OH_VideoDecoder_PushInputBuffer`；surface 模式输出直接 Free
- NAPI 模块复用 `libtsnapi.so`（nm_modname "tsnapi"，Init 在 napi_bridge.cpp:710-750，napi_define_properties 注册函数表）

## 方案架构

```
MirrorPage(ets) ── ScrcpyClient(ets) ── AdbClient(ets: shell+sync) ── AdbConnection(ets: TCP+复用) ── AdbAuth(ets: cryptoFramework RSA)
      │                    │
      │                    └─ localabstract 视频流 → 帧解析(去 12B 头) ─┐
      └─ XComponent(surface) ── surfaceId ── vdInit/vdPush/vdRelease ── video_decoder.cpp(native OH_AVCodec)
```

- 帧缓冲：ArkTS 侧解析帧后直接 vdPush；native 侧互斥锁保护的 pending 队列（上限 512 块，溢出丢最旧），codec 线程从队列填充输入 buffer（codec 线程禁止触碰 NAPI）
- 主线程 6 秒看门狗：全部网络/解码均为异步回调，无同步阻塞
- 帧率/码率统计在 ArkTS 侧每秒汇总

## 文件清单

### 新增
| 文件 | 内容 |
|---|---|
| `ets/adb/AdbBuffer.ets` | Uint8Array 拼接/切片/小端读写工具类 |
| `ets/adb/AdbAuth.ets` | RSA-2048 密钥生成/持久化(preferences "adb_mirror")、X.509 DER 解析取 n/e、mincrypt 公钥编码、token 签名 |
| `ets/adb/AdbConnection.ets` | TCPSocket 连接 + 消息泵 + CNXN/AUTH 握手 + AdbStream 复用（lock-step 写队列、关闭回调） |
| `ets/adb/AdbClient.ets` | `openShell(cmd)` 日志流、`syncPush(path, mode, data)` |
| `ets/scrcpy/ScrcpyClient.ets` | 编排：push jar → 启动 server → localabstract 连接重试(250ms×32) → dummy/deviceMeta/codecMeta/帧解析 → 回调；close() 清理 |
| `ets/pages/MirrorPage.ets` | NavDestination 页面，四态 UI（见下） |
| `cpp/video_decoder.cpp` | NAPI：`vdInit(surfaceId,w,h)` / `vdPush(ArrayBuffer,flags)` / `vdRelease()`，单实例 OH_AVCodec 封装 |

### 修改
| 文件 | 改动 |
|---|---|
| `cpp/CMakeLists.txt` | video_decoder.cpp 并入 tsnapi target；链接 libnative_media_core.so/libnative_media_vdec.so/libnative_window.so |
| `cpp/napi_bridge.cpp` | Init 函数表追加 vdInit/vdPush/vdRelease |
| `ets/bridge/TsnapiLoader.ets` | TsnapiApi 接口+Stub 增加 vd* 三函数（native 缺失时优雅降级） |
| `ets/pages/Index.ets` | pageMap 注册 `MirrorPage` |
| `ets/pages/TransferPage.ets` | 状态卡下方新增"屏幕镜像"入口卡片（图标+标题+副标题+箭头，AppNav.push('MirrorPage')） |

## UI 设计（MirrorPage 四态）

1. **配置态**：居中卡片：SymbolGlyph 图标 + "屏幕镜像"标题 + 说明文案；设备地址输入（TextInput，默认 192.168.5.108:5555，持久化上次值）；"开始镜像"主按钮（品牌色）；底部隐私/权限提示小字
2. **连接态**：步骤指示列表（建立连接→密钥授权→推送服务→启动镜像→接收视频流，完成项打勾、当前项 LoadingProgress），显著提示"如首次连接，请在安卓手机上允许 USB 调试授权"；"取消"按钮
3. **镜像态**：纯黑背景，XComponent（aspect-fit 居中，保持视频宽高比）；顶部悬浮半透明条：左返回/断开、中设备名+分辨率、右 fps 码率 chip；底部轻微渐变遮罩
4. **错误态**：居中错误图标+具体文案（区分：连接失败/授权被拒/推送失败/版本不符/取流超时）+ "重试"与"返回"按钮

样式约束：全部使用 DesignTokens + `sys.color`/`app.color` 语义色，禁止内联 hex；触控目标 ≥40vp；动效时长用 MOTION_*。

## 错误处理

- TCP 连接失败/超时（5s）→ "无法连接到设备"
- AUTH 后 30s 未收到 CNXN → "等待手机授权超时（请在安卓手机上允许调试）"
- sync FAIL → "推送 scrcpy 服务失败：<msg>"
- server 进程退出（shell 流关闭且视频流未建立）→ 显示 shell 日志尾部作为错误详情
- localabstract 取流 8s 超时 → "启动镜像服务超时"
- 页面退出（onWillDisappear/onBackPressed）→ 必须完整清理：CLSE 流、关闭 socket、vdRelease，防止 server 进程残留

## 验证步骤

1. `hvigor clean assembleHap`（非沙箱）编译通过并产出 signed hap
2. 装机到鸿蒙真机（hdc 需用户确认最新 IP:端口）
3. 安卓机 192.168.5.108 确认 adb tcpip 5555 存活；首连时在安卓端允许授权
4. 进入 设备→屏幕镜像→开始镜像：30s 内出现画面；hilog 过滤 `tsnapi|Scrcpy|Adb` 无致命错误
5. 稳定性：连续镜像 ≥5 分钟不断流；安卓端旋转屏幕不崩溃；退出页面后安卓端 `ps -A | grep app_process` 无残留；再次进入可重连

## 一期边界（明确不做）

- 触摸/按键注入（二期）、音频、剪贴板、熄屏常控（三期）
- 旋转仅保证不崩溃（不重配解码器尺寸）
- 不支持多设备并发镜像、不支持 H265/AV1
