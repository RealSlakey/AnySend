// Shizuku UserService for the screen-mirror hotspot bootstrap.
//
// Ported verbatim from vFlow commit 7b0263ba (feat: Shizuku-based hotspot
// control via TetheringManager (Android 14+), ShizukuUserService.kt) — the
// only approach verified to work on the target Android 14 device. The
// operation order below is load-bearing and must NOT be reordered:
//   1. ServiceManager.getService("tethering") directly — this process already
//      runs as shell UID 2000, so NO ShizukuBinderWrapper (wrapping it in the
//      main process was tried and blocked by hidden-API enforcement).
//   2. ITetheringConnector$Stub.asInterface(binder)
//   3. TetheringRequest.Builder(0).build().getParcel() to build the request
//      parcel (direct "new TetheringRequestParcel()" reflection was tried and
//      failed: method found but invocation errors).
//   4. IIntResultListener via java.lang.reflect.Proxy + CompletableDeferred.
//   5. Brute-force every startTethering/stopTethering signature — the real
//      device exposes the 4-arg stopTethering(int, String, String,
//      IIntResultListener), which must be matched or the stop is a no-op.
//   6. After a successful call, manually sync Settings.Global wifi_ap_on /
//      tethering_on — the system does not update them on its own, which broke
//      toggling in the original session.

package com.slakey.anysend

import android.content.Context
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ResultReceiver
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.Collections
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class MirrorShizukuService(private val context: Context) : IMirrorShizukuService.Stub() {

    companion object {
        private const val TAG = "MirrorHotspot"
        private const val TETHERING_WIFI = 0
        // Must match the vendored jar in assets/scrcpy-server-v3.3.4.
        private const val SERVER_VERSION = "3.3.4"
        private const val MIRROR_JAR_PATH = "/data/local/tmp/scrcpy-server.jar"
        private const val MIRROR_LOG_PATH = "/data/local/tmp/anysend-scrcpy.log"
        private const val MIRROR_SOCKET_PREFIX = "scrcpy_"
        private const val ABSTRACT_CONNECT_ATTEMPTS = 25
        private const val ABSTRACT_CONNECT_INTERVAL_MS = 200L
        private const val COPY_BUFFER_SIZE = 64 * 1024
    }

    // ==================== screen-mirror bridge state ====================

    @Volatile
    private var mirrorProcess: Process? = null

    @Volatile
    private var videoListener: ServerSocket? = null

    @Volatile
    private var controlListener: ServerSocket? = null

    private val mirrorSockets: MutableList<Closeable> = Collections.synchronizedList(ArrayList())

    private val mirrorTeardownRequested = AtomicBoolean(false)

    /** Raise the Wi-Fi hotspot via TetheringConnector (shell UID). */
    override fun startHotspot(): Boolean {
        return try {
            Log.d(TAG, "开始通过 Shizuku 开启热点...")

            // 1. tethering 服务 Binder（服务进程本身已是 shell UID，无需包装）
            val tetheringBinder = getTetheringBinder() ?: return false

            // 2. ITetheringConnector 接口
            val stubClass = Class.forName("android.net.ITetheringConnector\$Stub")
            val asInterfaceMethod = stubClass.getMethod("asInterface", IBinder::class.java)
            val tetheringConnector = asInterfaceMethod.invoke(null, tetheringBinder)
            if (tetheringConnector == null) {
                Log.e(TAG, "ITetheringConnector.asInterface 返回 null")
                return false
            }
            Log.d(TAG, "已获取 ITetheringConnector: ${tetheringConnector.javaClass.name}")

            // 3. 构造 TetheringRequestParcel
            val requestParcel = createTetheringRequestParcel()
            if (requestParcel == null) {
                Log.e(TAG, "构造 TetheringRequestParcel 失败")
                return false
            }

            // 4. IIntResultListener 回调（动态代理）
            val listenerClass = Class.forName("android.net.IIntResultListener")
            val completable = CompletableDeferred<Int>()
            val listenerProxy = java.lang.reflect.Proxy.newProxyInstance(
                listenerClass.classLoader,
                arrayOf(listenerClass)
            ) { _, method, args ->
                if (method.name == "onResult") {
                    val resultCode = args[0] as Int
                    Log.d(TAG, "IIntResultListener.onResult: $resultCode")
                    completable.complete(resultCode)
                }
                null
            }

            // 5. 暴力尝试所有 startTethering 方法签名（顺序照搬原 commit）
            val packageName = context.packageName
            val startMethods = tetheringConnector.javaClass.methods.filter { it.name == "startTethering" }
            Log.d(TAG, "找到 ${startMethods.size} 个 startTethering 方法")

            var invoked = false
            for (method in startMethods) {
                val paramTypes = method.parameterTypes
                Log.d(TAG, "尝试: startTethering(${paramTypes.joinToString(", ") { it.simpleName }})")
                try {
                    when (paramTypes.size) {
                        4 -> {
                            // (TetheringRequestParcel, String, String, IIntResultListener)
                            if (paramTypes[0].name.contains("TetheringRequest") &&
                                paramTypes[3].name.contains("IIntResultListener")
                            ) {
                                Log.d(TAG, "匹配 4 参数签名 (IIntResultListener)")
                                method.invoke(tetheringConnector, requestParcel, packageName, null, listenerProxy)
                                invoked = true
                                break
                            }
                        }
                        3 -> {
                            if (paramTypes[0].name.contains("TetheringRequest")) {
                                if (paramTypes[2].name.contains("IIntResultListener")) {
                                    // (TetheringRequestParcel, String, IIntResultListener)
                                    Log.d(TAG, "匹配 3 参数签名 (IIntResultListener)")
                                    method.invoke(tetheringConnector, requestParcel, packageName, listenerProxy)
                                    invoked = true
                                    break
                                } else if (paramTypes[2] == ResultReceiver::class.java) {
                                    // (TetheringRequestParcel, String, ResultReceiver)
                                    Log.d(TAG, "匹配 3 参数签名 (ResultReceiver)")
                                    val receiver = createCallbackResultReceiver(completable)
                                    method.invoke(tetheringConnector, requestParcel, packageName, receiver)
                                    invoked = true
                                    break
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "调用失败: ${e.cause?.message ?: e.message}")
                }
            }

            // 新签名都失败时尝试旧签名
            if (!invoked) {
                Log.d(TAG, "尝试旧版方法签名...")
                for (method in startMethods) {
                    val paramTypes = method.parameterTypes
                    try {
                        if (paramTypes.size == 4 && paramTypes[0] == Int::class.javaPrimitiveType) {
                            // (int, ResultReceiver, boolean, String)
                            Log.d(TAG, "匹配旧版 4 参数签名")
                            val receiver = createCallbackResultReceiver(completable)
                            method.invoke(tetheringConnector, 0, receiver, false, packageName)
                            invoked = true
                            break
                        } else if (paramTypes.size == 3 && paramTypes[0] == Int::class.javaPrimitiveType) {
                            // (int, ResultReceiver, boolean)
                            Log.d(TAG, "匹配旧版 3 参数签名")
                            val receiver = createCallbackResultReceiver(completable)
                            method.invoke(tetheringConnector, 0, receiver, false)
                            invoked = true
                            break
                        }
                    } catch (e: Exception) {
                        Log.d(TAG, "旧版调用失败: ${e.cause?.message ?: e.message}")
                    }
                }
            }

            if (!invoked) {
                Log.e(TAG, "所有 startTethering 签名均失败")
                return false
            }

            // 6. 等待回调结果
            Log.d(TAG, "等待 startTethering 回调...")
            val resultCode = try {
                runBlocking {
                    withTimeout(5000L) { completable.await() }
                }
            } catch (e: Exception) {
                Log.w(TAG, "等待回调超时: ${e.message}")
                0 // 假设成功
            }

            Log.d(TAG, "startTethering 结果码: $resultCode")
            if (resultCode == 0) {
                // 系统不会自动更新这两个 settings，手动同步（否则状态切换失效）
                syncGlobalInt("wifi_ap_on", 1)
                syncGlobalInt("tethering_on", 1)
            }
            resultCode == 0
        } catch (e: Exception) {
            Log.e(TAG, "通过 Shizuku 开启热点失败: ${e.message}", e)
            false
        }
    }

    /** Close the Wi-Fi hotspot via TetheringConnector (shell UID). */
    override fun stopHotspot(): Boolean {
        val success = try {
            Log.d(TAG, "开始通过 Shizuku 关闭热点...")
            val tetheringBinder = getTetheringBinder() ?: return false

            val stubClass = Class.forName("android.net.ITetheringConnector\$Stub")
            val asInterfaceMethod = stubClass.getMethod("asInterface", IBinder::class.java)
            val tetheringConnector = asInterfaceMethod.invoke(null, tetheringBinder)
            if (tetheringConnector == null) {
                Log.e(TAG, "ITetheringConnector.asInterface 返回 null")
                return false
            }

            val stopMethods = tetheringConnector.javaClass.methods.filter { it.name == "stopTethering" }
            Log.d(TAG, "找到 ${stopMethods.size} 个 stopTethering 方法")

            var invoked = false
            for (method in stopMethods) {
                val paramTypes = method.parameterTypes
                Log.d(TAG, "尝试: stopTethering(${paramTypes.joinToString(", ") { it.simpleName }})")
                try {
                    when {
                        // 真机实际签名是 4 参数，必须匹配，否则"方法找到却不调用"
                        paramTypes.size == 4 && paramTypes[0] == Int::class.javaPrimitiveType -> {
                            val listenerClass = Class.forName("android.net.IIntResultListener")
                            val listenerProxy = java.lang.reflect.Proxy.newProxyInstance(
                                listenerClass.classLoader, arrayOf(listenerClass)
                            ) { _, _, _ -> null }
                            method.invoke(tetheringConnector, 0, context.packageName, null, listenerProxy)
                            Log.d(TAG, "已发送 stopTethering (4参数) 请求")
                            invoked = true
                            break
                        }
                        paramTypes.size == 3 && paramTypes[0] == Int::class.javaPrimitiveType -> {
                            val listenerClass = Class.forName("android.net.IIntResultListener")
                            val listenerProxy = java.lang.reflect.Proxy.newProxyInstance(
                                listenerClass.classLoader, arrayOf(listenerClass)
                            ) { _, _, _ -> null }
                            method.invoke(tetheringConnector, 0, context.packageName, listenerProxy)
                            Log.d(TAG, "已发送 stopTethering (3参数) 请求")
                            invoked = true
                            break
                        }
                        paramTypes.size == 2 && paramTypes[0] == Int::class.javaPrimitiveType -> {
                            method.invoke(tetheringConnector, 0, context.packageName)
                            Log.d(TAG, "已发送 stopTethering 请求")
                            invoked = true
                            break
                        }
                        paramTypes.size == 1 && paramTypes[0] == Int::class.javaPrimitiveType -> {
                            method.invoke(tetheringConnector, 0)
                            Log.d(TAG, "已发送 stopTethering 请求")
                            invoked = true
                            break
                        }
                    }
                } catch (e: Exception) {
                    Log.d(TAG, "调用失败: ${e.cause?.message ?: e.message}")
                }
            }

            if (!invoked) {
                Log.e(TAG, "所有 stopTethering 签名均失败")
            }
            invoked
        } catch (e: Exception) {
            Log.e(TAG, "通过 Shizuku 关闭热点失败: ${e.message}", e)
            false
        }
        if (success) {
            syncGlobalInt("wifi_ap_on", 0)
            syncGlobalInt("tethering_on", 0)
        }
        return success
    }

    /**
     * 同步 Settings.Global 的开关值。
     *
     * 本进程以 shell UID(2000) 运行，若直接用 ContentResolver 写入，AMS 会以
     * "Given calling package com.slakey.anysend does not match caller's uid 2000"
     * 拒绝（op-package 取的是宿主应用包名，与 uid 不符）。改用 settings CLI
     * 子进程写入，子进程不携带宿主包名声明，与 adb shell 等效。
     */
    private fun syncGlobalInt(key: String, value: Int) {
        try {
            val proc = ProcessBuilder("/system/bin/settings", "put", "global", key, value.toString())
                .redirectErrorStream(true)
                .start()
            val finished = proc.waitFor(2, TimeUnit.SECONDS)
            if (!finished) {
                proc.destroyForcibly()
                Log.w(TAG, "settings put global $key=$value 超时")
            } else if (proc.exitValue() != 0) {
                Log.w(TAG, "settings put global $key=$value 失败 exit=${proc.exitValue()}")
            }
        } catch (e: Exception) {
            Log.w(TAG, "settings put global $key=$value 异常: ${e.message}")
        }
    }

    /** Hotspot AP SSID (unquoted) via WifiManager.getWifiApConfiguration reflection. */
    override fun getHotspotSsid(): String {
        val cfg = apConfiguration() ?: return ""
        return try {
            val raw = cfg.javaClass.getField("SSID").get(cfg)
            when (raw) {
                is String -> raw.removeSurrounding("\"")
                is ByteArray -> String(raw).removeSurrounding("\"")
                else -> ""
            }
        } catch (e: Exception) {
            Log.w(TAG, "读取热点 SSID 失败: ${e.message}")
            ""
        }
    }

    /** Hotspot AP WPA key via WifiManager.getWifiApConfiguration reflection. */
    override fun getHotspotPassword(): String {
        val cfg = apConfiguration() ?: return ""
        return try {
            val raw = cfg.javaClass.getField("preSharedKey").get(cfg)
            if (raw is String) raw.removeSurrounding("\"") else ""
        } catch (e: Exception) {
            Log.w(TAG, "读取热点密码失败: ${e.message}")
            ""
        }
    }

    // ==================== screen-mirror bridge ====================
    //
    // Spawns scrcpy-server (forward tunnel mode) as this shell-UID process and
    // exposes its abstract sockets over TCP so the LAN peer can connect
    // directly: no adb, no wireless debugging, no pairing.
    //
    // The wire order is fixed by scrcpy's DesktopConnection.open(): the server
    // creates LocalServerSocket("scrcpy_<scid>") and accepts video -> audio ->
    // control in exactly that order, so this bridge must finish the video
    // LocalSocket connection before opening the control one.

    override fun startMirrorBridge(jar: ByteArray, argsJson: String): String {
        stopMirrorBridge()

        val scid = argsJson.split(' ')
            .firstOrNull { it.startsWith("scid=") }
            ?.substring("scid=".length)
            ?.trim()
            .orEmpty()
        if (scid.isEmpty()) {
            Log.e(TAG, "startMirrorBridge: argsJson 缺少 scid")
            return ""
        }

        return try {
            // 1. jar 落盘（shell UID 可直接写 /data/local/tmp）
            val jarFile = File(MIRROR_JAR_PATH)
            FileOutputStream(jarFile).use { it.write(jar) }
            jarFile.setReadable(true, false)
            Log.d(TAG, "scrcpy-server jar 已写入 ${jarFile.length()} 字节")

            // 2. 起 server：app_process 等价于 adb shell，录屏 + 注入权限都够。
            //    server 把版本号当作首个参数做严格校验，必须紧跟在类名之后。
            val cmd = ArrayList<String>()
            cmd.add("/system/bin/app_process")
            cmd.add("/")
            cmd.add("com.genymobile.scrcpy.Server")
            cmd.add(SERVER_VERSION)
            argsJson.split(' ').filter { it.isNotBlank() }.forEach { cmd.add(it) }

            val pb = ProcessBuilder(cmd)
            pb.environment()["CLASSPATH"] = MIRROR_JAR_PATH
            pb.redirectErrorStream(true)
            pb.redirectOutput(File(MIRROR_LOG_PATH))
            val proc = pb.start()
            mirrorProcess = proc
            Log.d(TAG, "scrcpy-server 已启动")

            // 3. 先建好两条监听（wildcard 绑定，热点网段可达）
            val video = ServerSocket(0, 4)
            val control = ServerSocket(0, 4)
            videoListener = video
            controlListener = control

            // 4. 给 app_process 一点启动时间；起不来就别让对端空等
            Thread.sleep(700)
            if (!proc.isAlive) {
                Log.e(TAG, "scrcpy-server 启动即退出，日志见 $MIRROR_LOG_PATH")
                stopMirrorBridge()
                return ""
            }

            // 5. 按 video -> control 顺序与 server 的 abstract socket 配对
            startMirrorPump(video, control, scid)

            val json = "{\"videoPort\":${video.localPort},\"controlPort\":${control.localPort},\"scid\":\"$scid\"}"
            Log.d(TAG, "镜像桥就绪 $json")
            json
        } catch (e: Exception) {
            Log.e(TAG, "startMirrorBridge 失败: ${e.message}", e)
            stopMirrorBridge()
            ""
        }
    }

    override fun stopMirrorBridge() {
        closeListener(videoListener)
        closeListener(controlListener)
        videoListener = null
        controlListener = null

        val sockets = synchronized(mirrorSockets) { mirrorSockets.toList() }
        mirrorSockets.clear()
        for (s in sockets) {
            try {
                s.close()
            } catch (_: Exception) {
            }
        }

        val proc = mirrorProcess
        mirrorProcess = null
        if (proc != null) {
            try {
                proc.destroy()
                if (!proc.waitFor(1, TimeUnit.SECONDS)) {
                    proc.destroyForcibly()
                }
            } catch (_: Exception) {
                proc.destroyForcibly()
            }
            Log.d(TAG, "scrcpy-server 已终止")
        }
    }

    /**
     * Accepts the LAN peer's video/control TCP connections in order and pipes
     * each one to its own LocalSocket connection on "scrcpy_<scid>".
     */
    private fun startMirrorPump(video: ServerSocket, control: ServerSocket, scid: String) {
        Thread {
            try {
                val videoTcp = video.accept()
                mirrorSockets.add(videoTcp)
                val videoLocal = connectAbstract(scid)
                mirrorSockets.add(videoLocal)
                pumpPair(videoTcp, videoLocal, watchPeerGone = true)

                val controlTcp = control.accept()
                mirrorSockets.add(controlTcp)
                val controlLocal = connectAbstract(scid)
                mirrorSockets.add(controlLocal)
                pumpPair(controlTcp, controlLocal, watchPeerGone = false)

                Log.d(TAG, "镜像桥双通道已配对")
            } catch (e: SocketException) {
                Log.d(TAG, "镜像桥监听已关闭")
            } catch (e: Exception) {
                Log.e(TAG, "镜像桥配对失败: ${e.message}", e)
            }
        }.also {
            it.isDaemon = true
            it.name = "mirror-pump"
            it.start()
        }
    }

    /** Bidirectional byte pump over TCP socket <-> abstract LocalSocket. */
    private fun pumpPair(tcp: Socket, local: LocalSocket, watchPeerGone: Boolean) {
        val toLocal = Thread {
            copy(tcp, local, watchPeerGone)
        }
        val toTcp = Thread {
            copy(local, tcp, false)
        }
        toLocal.name = "mirror-in-pump"
        toTcp.name = "mirror-out-pump"
        toLocal.isDaemon = true
        toTcp.isDaemon = true
        toLocal.start()
        toTcp.start()
    }

    /**
     * Copies [src] into [dst] until EOF. When [watchPeerGone] is set the EOF
     * comes from the LAN peer (the mirror page was closed), so the whole bridge
     * is torn down here — that keeps no scrcpy-server process behind.
     */
    private fun copy(src: Closeable, dst: Closeable, watchPeerGone: Boolean) {
        val buffer = ByteArray(COPY_BUFFER_SIZE)
        val source = when (src) {
            is Socket -> src.getInputStream()
            is LocalSocket -> src.inputStream
            else -> return
        }
        val target = when (dst) {
            is Socket -> dst.getOutputStream()
            is LocalSocket -> dst.outputStream
            else -> return
        }

        var peerGone = false
        try {
            while (true) {
                val read = source.read(buffer)
                if (read <= 0) {
                    peerGone = true
                    break
                }
                target.write(buffer, 0, read)
                target.flush()
            }
        } catch (_: Exception) {
            // 正常收尾（对端关闭或本地主动关闭）都会落到这里
        } finally {
            try {
                target.close()
            } catch (_: Exception) {
            }
        }

        if (watchPeerGone && peerGone && mirrorTeardownRequested.compareAndSet(false, true)) {
            Log.d(TAG, "对端已断开，回收镜像桥")
            stopMirrorBridge()
            mirrorTeardownRequested.set(false)
        }
    }

    /** Connect to the server's abstract socket, retrying while it starts up. */
    private fun connectAbstract(scid: String): LocalSocket {
        val name = MIRROR_SOCKET_PREFIX + scid
        var lastError: String = "unknown"
        for (attempt in 0 until ABSTRACT_CONNECT_ATTEMPTS) {
            val socket = LocalSocket()
            try {
                socket.connect(LocalSocketAddress(name, LocalSocketAddress.Namespace.ABSTRACT))
                Log.d(TAG, "已连接 abstract socket $name")
                return socket
            } catch (e: Exception) {
                lastError = e.message ?: e.javaClass.simpleName
                try {
                    socket.close()
                } catch (_: Exception) {
                }
                Thread.sleep(ABSTRACT_CONNECT_INTERVAL_MS)
            }
        }
        throw IllegalStateException("连接 $name 失败: $lastError")
    }

    private fun closeListener(listener: ServerSocket?) {
        if (listener == null) {
            return
        }
        try {
            listener.close()
        } catch (_: Exception) {
        }
    }

    private fun apConfiguration(): Any? {
        return try {
            val wm = context.getSystemService(Context.WIFI_SERVICE) as? android.net.wifi.WifiManager
            if (wm == null) {
                Log.w(TAG, "无法获取 WifiManager")
                return null
            }
            wm.javaClass.getMethod("getWifiApConfiguration").invoke(wm)
        } catch (e: Exception) {
            Log.w(TAG, "getWifiApConfiguration 反射失败: ${e.message}")
            null
        }
    }

    /** ServiceManager 直取 tethering binder（shell UID，无需包装）。 */
    private fun getTetheringBinder(): IBinder? {
        return try {
            val serviceManagerClass = Class.forName("android.os.ServiceManager")
            val getServiceMethod = serviceManagerClass.getMethod("getService", String::class.java)
            val rawBinder = getServiceMethod.invoke(null, "tethering") as? IBinder
            if (rawBinder == null) {
                Log.e(TAG, "ServiceManager.getService(\"tethering\") 返回 null")
                return null
            }
            Log.d(TAG, "已获取 tethering Binder (shell UID, 无需包装)")
            rawBinder
        } catch (e: Exception) {
            Log.e(TAG, "获取 tethering Binder 失败: ${e.message}", e)
            null
        }
    }

    /** TetheringRequest.Builder(0).build().getParcel() 造 parcel（原 commit 成功路径）。 */
    private fun createTetheringRequestParcel(): Any? {
        return try {
            val builderClass = Class.forName("android.net.TetheringManager\$TetheringRequest\$Builder")
            val builder = builderClass.getConstructor(Int::class.javaPrimitiveType).newInstance(TETHERING_WIFI)
            val buildMethod = builderClass.getMethod("build")
            val request = buildMethod.invoke(builder)
            val getParcelMethod = request.javaClass.getMethod("getParcel")
            val parcel = getParcelMethod.invoke(request)
            Log.d(TAG, "已通过 Builder 构造 TetheringRequestParcel: ${parcel?.javaClass?.name}")
            parcel
        } catch (e: Exception) {
            Log.e(TAG, "通过 Builder 构造失败，回退到直接构造: ${e.message}")
            createTetheringRequestParcelDirect()
        }
    }

    /** 直接反射构造 TetheringRequestParcel（原 commit 备用方案）。 */
    private fun createTetheringRequestParcelDirect(): Any? {
        return try {
            val parcelClass = Class.forName("android.net.TetheringRequestParcel")
            val constructor = parcelClass.getDeclaredConstructor()
            constructor.isAccessible = true
            val parcel = constructor.newInstance()
            try {
                parcelClass.getField("tetheringType").set(parcel, TETHERING_WIFI)
            } catch (_: Exception) {
            }
            try {
                parcelClass.getField("connectivityScope").set(parcel, 1) // GLOBAL
            } catch (_: Exception) {
            }
            try {
                parcelClass.getField("showProvisioningUi").set(parcel, false)
            } catch (_: Exception) {
            }
            Log.d(TAG, "已直接构造 TetheringRequestParcel")
            parcel
        } catch (e: Exception) {
            Log.e(TAG, "构造 TetheringRequestParcel 失败: ${e.message}", e)
            null
        }
    }

    private fun createCallbackResultReceiver(completable: CompletableDeferred<Int>): ResultReceiver {
        return object : ResultReceiver(Handler(Looper.getMainLooper())) {
            override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                Log.d(TAG, "ResultReceiver 回调: resultCode=$resultCode")
                completable.complete(resultCode)
            }
        }
    }
}
