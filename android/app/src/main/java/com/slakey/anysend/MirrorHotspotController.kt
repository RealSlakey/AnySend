package com.slakey.anysend

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import android.util.Log
import rikka.shizuku.Shizuku
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Mirror hot-spot controller for the screen-mirror bootstrap flow.
 *
 * When the HarmonyOS peer asks AnySend to prepare mirroring
 * (POST /api/anysend/v1/mirror-prepare), the server calls [requestHotspotOn].
 * The actual tethering call happens in the Shizuku UserService process
 * ([MirrorShizukuService], shell UID 2000) — the only path that works on
 * Android 14. This class only binds that service and invokes it; it never
 * blocks the HTTP response, and the HarmonyOS peer keeps scanning :5555 while
 * the hotspot comes up.
 *
 * First run requires the one-time Shizuku permission dialog on this device;
 * after the user taps allow the pending start request is executed
 * automatically. Shizuku itself must be running (wireless debugging).
 */
object MirrorHotspotController {

    private const val TAG = "MirrorHotspot"
    private const val PERM_REQUEST_CODE = 8001
    // Bump when MirrorShizukuService (or its AIDL) changes so Shizuku
    // restarts the UserService process with the new methods.
    private const val USER_SERVICE_VERSION = 3
    // Longest the mirror-prepare HTTP handler blocks: startHotspot internally
    // awaits the IIntResultListener callback for up to 5 s.
    private const val PREPARE_WAIT_MS = 8000L
    // The bridge only writes the jar, spawns app_process and opens two
    // ServerSockets, so it settles well within this budget.
    private const val BRIDGE_WAIT_MS = 8000L

    /** LAN endpoints the HarmonyOS peer connects to for the mirror streams. */
    data class MirrorBridgeInfo(val videoPort: Int, val controlPort: Int, val scid: String)

    private val executor = Executors.newSingleThreadExecutor()
    private val permRequested = AtomicBoolean(false)
    private val startPending = AtomicBoolean(false)
    private val bridgePending = AtomicBoolean(false)

    @Volatile
    var lastSsid: String = ""
        private set

    @Volatile
    var lastPassword: String = ""
        private set

    /** Result of the latest startHotspot round. */
    @Volatile
    var lastStarted: Boolean = false
        private set

    /** Result of the latest startMirrorBridge round (null when it failed). */
    @Volatile
    var lastBridge: MirrorBridgeInfo? = null
        private set

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var service: IMirrorShizukuService? = null

    // Released once the latest prepare round finished (start + config read),
    // so the HTTP handler can block until the result is known.
    @Volatile
    private var prepareLatch: CountDownLatch? = null

    // Released once the latest bridge round finished.
    @Volatile
    private var bridgeLatch: CountDownLatch? = null

    @Volatile
    private var bridgeJar: ByteArray? = null

    @Volatile
    private var bridgeArgs: String = ""

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            Log.d(TAG, "Shizuku UserService 已连接")
            val svc = IMirrorShizukuService.Stub.asInterface(binder)
            service = svc
            if (startPending.compareAndSet(true, false)) {
                executor.execute { callStart(svc) }
            }
            if (bridgePending.compareAndSet(true, false)) {
                executor.execute { callStartBridge(svc) }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
        }
    }

    /** Fire-and-forget: raise the hotspot in the background. Never throws. */
    fun requestHotspotOn(context: Context) {
        val app = context.applicationContext ?: return
        appContext = app
        executor.execute {
            val cached = service
            if (cached != null) {
                callStart(cached)
                return@execute
            }
            if (!bindService(app)) {
                finishPrepare()
                return@execute
            }
            startPending.set(true)
        }
    }

    /**
     * Blocking variant used by the mirror-prepare HTTP handler: raises the
     * hotspot and waits until the result and the AP config are known.
     * Returns true when startHotspot reported success.
     */
    fun requestHotspotOnAndWait(context: Context): Boolean {
        val app = context.applicationContext ?: return false
        appContext = app
        val latch = CountDownLatch(1)
        prepareLatch = latch
        executor.execute {
            val cached = service
            if (cached != null) {
                callStart(cached)
                return@execute
            }
            if (!bindService(app)) {
                finishPrepare()
                return@execute
            }
            startPending.set(true)
        }
        return try {
            val done = latch.await(PREPARE_WAIT_MS, TimeUnit.MILLISECONDS)
            done && lastStarted
        } catch (e: InterruptedException) {
            false
        }
    }

    /** Tear the hotspot down (unused today; kept for the mirror teardown flow). */
    fun requestHotspotOff(context: Context) {
        val app = context.applicationContext ?: return
        appContext = app
        executor.execute {
            val cached = service
            if (cached != null) {
                callStop(cached)
            } else {
                bindService(app)
            }
        }
    }

    /**
     * Blocking variant used by the mirror-prepare HTTP handler: spawns the
     * scrcpy-server bridge in the Shizuku UserService and waits until the LAN
     * endpoints are known. Returns null when the bridge could not be started.
     */
    fun startBridgeAndWait(context: Context, jar: ByteArray, argsJson: String): MirrorBridgeInfo? {
        val app = context.applicationContext ?: return null
        appContext = app
        bridgeJar = jar
        bridgeArgs = argsJson
        lastBridge = null
        val latch = CountDownLatch(1)
        bridgeLatch = latch

        executor.execute {
            val cached = service
            if (cached != null) {
                callStartBridge(cached)
                return@execute
            }
            if (!bindService(app)) {
                finishBridge()
                return@execute
            }
            bridgePending.set(true)
        }

        return try {
            val done = latch.await(BRIDGE_WAIT_MS, TimeUnit.MILLISECONDS)
            if (done) lastBridge else null
        } catch (e: InterruptedException) {
            null
        }
    }

    private fun callStartBridge(svc: IMirrorShizukuService) {
        try {
            val jar = bridgeJar
            if (jar == null) {
                lastBridge = null
                return
            }
            val json = svc.startMirrorBridge(jar, bridgeArgs)
            lastBridge = parseBridgeInfo(json)
            Log.d(TAG, "startMirrorBridge -> $json")
        } catch (e: Exception) {
            lastBridge = null
            service = null // binder 可能已死，下次重新 bind
            Log.e(TAG, "startMirrorBridge failed: ${e.message}", e)
        } finally {
            finishBridge()
        }
    }

    /** Release the blocking mirror-prepare waiter (no-op when none). */
    private fun finishBridge() {
        bridgeLatch?.countDown()
        bridgeLatch = null
    }

    /**
     * The bridge returns a fixed-shape JSON blob, so a tiny regex parse keeps
     * this free of any JSON dependency inside the controller.
     */
    private fun parseBridgeInfo(json: String?): MirrorBridgeInfo? {
        if (json.isNullOrBlank()) {
            return null
        }
        val videoPort = Regex("\"videoPort\"\\s*:\\s*(\\d+)")
            .find(json)?.groupValues?.get(1)?.toIntOrNull()
        val controlPort = Regex("\"controlPort\"\\s*:\\s*(\\d+)")
            .find(json)?.groupValues?.get(1)?.toIntOrNull()
        val scid = Regex("\"scid\"\\s*:\\s*\"([0-9a-fA-F]+)\"")
            .find(json)?.groupValues?.get(1).orEmpty()
        if (videoPort == null || controlPort == null || scid.isEmpty()) {
            Log.e(TAG, "镜像桥返回内容无法解析: $json")
            return null
        }
        return MirrorBridgeInfo(videoPort, controlPort, scid)
    }

    private fun callStart(svc: IMirrorShizukuService) {
        try {
            val ok = svc.startHotspot()
            lastStarted = ok
            Log.d(TAG, "startHotspot -> $ok")
            try {
                lastSsid = svc.hotspotSsid
                lastPassword = svc.hotspotPassword
            } catch (e: Exception) {
                Log.w(TAG, "读取热点配置失败: ${e.message}")
            }
        } catch (e: Exception) {
            lastStarted = false
            service = null // binder 可能已死，下次重新 bind
            Log.e(TAG, "startHotspot failed: ${e.message}", e)
        } finally {
            finishPrepare()
        }
    }

    /** Release the blocking mirror-prepare waiter (no-op when none). */
    private fun finishPrepare() {
        prepareLatch?.countDown()
        prepareLatch = null
    }

    private fun callStop(svc: IMirrorShizukuService) {
        try {
            val ok = svc.stopHotspot()
            Log.d(TAG, "stopHotspot -> $ok")
        } catch (e: Exception) {
            service = null
            Log.e(TAG, "stopHotspot failed: ${e.message}", e)
        }
    }

    /** Bind the Shizuku UserService; returns false if Shizuku is not ready. */
    private fun bindService(context: Context): Boolean {
        return try {
            if (!Shizuku.pingBinder()) {
                Log.w(TAG, "Shizuku 未运行，无法开启热点")
                return false
            }
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                if (permRequested.compareAndSet(false, true)) {
                    Log.d(TAG, "请求 Shizuku 权限（首次）")
                    Shizuku.addRequestPermissionResultListener(
                        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
                            if (requestCode == PERM_REQUEST_CODE &&
                                grantResult == PackageManager.PERMISSION_GRANTED
                            ) {
                                val ctx = appContext
                                if (ctx != null) {
                                    executor.execute {
                                        if (bindService(ctx)) {
                                            startPending.set(true)
                                        }
                                    }
                                }
                            }
                        }
                    )
                    Shizuku.requestPermission(PERM_REQUEST_CODE)
                }
                return false
            }
            Log.d(TAG, "绑定 Shizuku UserService...")
            val args = Shizuku.UserServiceArgs(ComponentName(context, MirrorShizukuService::class.java))
                .processNameSuffix("mirror_shizuku")
                .version(USER_SERVICE_VERSION)
            Shizuku.bindUserService(args, connection)
            true
        } catch (e: Exception) {
            Log.e(TAG, "绑定 Shizuku UserService 失败: ${e.message}", e)
            false
        }
    }
}
