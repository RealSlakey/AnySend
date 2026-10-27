package com.slakey.anysend.protocol

import android.content.ContentValues
import android.content.Context
import android.os.Environment
import android.provider.MediaStore
import java.net.Inet4Address
import java.net.NetworkInterface
import com.google.gson.Gson
import com.slakey.anysend.history.TransferHistory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * LocalSend receiver. Listens on every provided [NetworkLayer] on TCP :53317
 * (Tailscale + direct LAN) and serves the LocalSend v2 HTTP API. A layer that
 * fails to listen is skipped without affecting the others. File acceptance is
 * delegated to a callback so the UI can prompt the user.
 */
class LocalSendServer(
    private val context: Context,
    private val selfInfo: DeviceInfo,
    private val networks: List<NetworkLayer>
) {
    private companion object {
        /** Vendored scrcpy-server jar shipped in the APK assets. */
        const val MIRROR_SERVER_ASSET = "scrcpy-server-v3.3.4"
    }

    private val gson = Gson()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val layerHandles = LinkedHashMap<NetworkLayer, Long>()
    private var running = false

    /** Pending session decisions: fileId -> accept(true)/reject(false) */
    private val decisions = ConcurrentHashMap<String, Boolean>()

    /** One accepted send-request: who sent it, which files, how many arrived. */
    private class PendingSession(
        val senderAlias: String,
        val files: Map<String, FileInfo>
    ) {
        val received = AtomicInteger(0)
    }

    /** sessionId -> session metadata (bounded, eldest evicted). */
    private val pendingSessions = object : LinkedHashMap<String, PendingSession>(16, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, PendingSession>?): Boolean {
            return size > 32
        }
    }

    /** Callback invoked when a send-request arrives. UI should prompt user. */
    var onSendRequest: ((sender: DeviceInfo, files: Map<String, FileInfo>) -> Unit)? = null

    /**
     * Optional SMS relay routes under /api/sms/. Null disables the SMS API —
     * the server then answers 404 so unpaired peers learn nothing.
     */
    var smsRelay: com.slakey.anysend.sms.SmsRelay? = null

    /** Set the decision for a session (called by UI after user chooses). */
    fun setSessionDecision(sessionId: String, acceptedFileIds: Set<String>) {
        acceptedFileIds.forEach { decisions[it] = true }
    }

    fun start() {
        if (running) return
        running = true
        networks.forEach { net -> runLayer(net) }
    }

    private fun runLayer(net: NetworkLayer) {
        scope.launch {
            val listenerHandle = net.listen("tcp", ":${LocalSendConst.PORT}")
            if (listenerHandle <= 0L) {
                android.util.Log.w("LocalSendServer", "listen on one network layer failed")
                return@launch
            }
            synchronized(layerHandles) { layerHandles[net] = listenerHandle }
            while (running) {
                val conn = net.accept(listenerHandle)
                if (conn > 0L) {
                    scope.launch { handleConnection(net, conn) }
                } else {
                    break // listener closed (e.g. stop())
                }
            }
        }
    }

    fun stop() {
        running = false
        synchronized(layerHandles) {
            layerHandles.forEach { (net, h) -> net.closeListener(h) }
            layerHandles.clear()
        }
    }

    private suspend fun handleConnection(net: NetworkLayer, conn: Long) {
        try {
            val request = readHttpRequest(net, conn) ?: return
            val response = routeOrSms(request, conn)
            writeHttpResponse(net, conn, response)
        } catch (e: Exception) {
            // ignore broken connections
        } finally {
            net.closeConn(conn)
        }
    }

    private data class HttpRequest(
        val method: String,
        val path: String,
        val query: Map<String, String>,
        val headers: Map<String, String>,
        val body: ByteArray
    )

    private suspend fun readHttpRequest(net: NetworkLayer, conn: Long): HttpRequest? {
        // Byte-level buffering: the body must never pass through String
        // conversion (UTF-8 JSON and binary uploads would both corrupt).
        var rawBytes = ByteArray(0)
        var headerEnd = -1
        while (headerEnd < 0) {
            val n = net.read(conn, 8192) ?: break
            if (n.isEmpty()) break
            rawBytes = appendBytes(rawBytes, n)
            headerEnd = findHeaderEnd(rawBytes)
        }
        if (headerEnd < 0) return null

        val headerSection = String(rawBytes, 0, headerEnd, Charsets.UTF_8)
        val lines = headerSection.split("\r\n")
        val requestLine = lines[0].split(" ")
        if (requestLine.size < 2) return null
        val method = requestLine[0]
        val fullPath = requestLine[1]
        val (path, query) = parsePath(fullPath)

        val headers = mutableMapOf<String, String>()
        for (i in 1 until lines.size) {
            val idx = lines[i].indexOf(':')
            if (idx > 0) {
                headers[lines[i].substring(0, idx).trim().lowercase()] =
                    lines[i].substring(idx + 1).trim()
            }
        }

        // Large uploads from the official client arrive either with a
        // Content-Length or chunked (Transfer-Encoding: chunked, e.g. reqwest
        // streams). Both are handled here without quadratic re-copying.
        val chunked = (headers["transfer-encoding"] ?: "").lowercase().contains("chunked")
        val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
        val bodyStart = headerEnd + 4
        val finalBody: ByteArray = if (chunked) {
            readChunkedBody(net, conn, rawBytes, bodyStart)
        } else {
            val body = ByteArray(contentLength)
            var have = 0
            if (rawBytes.size > bodyStart) {
                have = minOf(rawBytes.size - bodyStart, contentLength)
                System.arraycopy(rawBytes, bodyStart, body, 0, have)
            }
            while (have < contentLength) {
                val n = net.read(conn, 65536) ?: break
                if (n.isEmpty()) break
                val copy = minOf(n.size, contentLength - have)
                System.arraycopy(n, 0, body, have, copy)
                have += copy
            }
            if (have == contentLength) body else body.copyOf(have)
        }

        return HttpRequest(method, path, query, headers, finalBody)
    }

    private fun findCrlf(data: ByteArray, from: Int): Int {
        var i = from
        while (i + 1 < data.size) {
            if (data[i] == 0x0d.toByte() && data[i + 1] == 0x0a.toByte()) return i
            i++
        }
        return -1
    }

    private fun concatParts(parts: List<ByteArray>, total: Int): ByteArray {
        val out = ByteArray(total)
        var off = 0
        for (p in parts) {
            System.arraycopy(p, 0, out, off, p.size)
            off += p.size
        }
        return out
    }

    /** Decode a chunked transfer-encoded body, reading more data as needed. */
    private suspend fun readChunkedBody(net: NetworkLayer, conn: Long, raw: ByteArray, start: Int): ByteArray {
        // `pending` holds only unconsumed bytes; consumed data is sliced off
        // so later appends stay cheap.
        var pending = if (raw.size > start) raw.copyOfRange(start, raw.size) else ByteArray(0)
        var pos = 0
        val parts = ArrayList<ByteArray>()
        var total = 0
        while (true) {
            // 1. Read the chunk-size line (hex, optional extensions after ';').
            var eol = findCrlf(pending, pos)
            while (eol < 0) {
                val n = net.read(conn, 65536) ?: return concatParts(parts, total)
                if (n.isEmpty()) return concatParts(parts, total)
                pending = appendBytes(pending, n)
                eol = findCrlf(pending, pos)
            }
            val sizeLine = String(pending, pos, eol - pos, Charsets.UTF_8)
            val chunkSize = sizeLine.substringBefore(';').trim().toIntOrNull(16)
                ?: return concatParts(parts, total)
            if (chunkSize < 0 || chunkSize > 1 shl 30) {
                return concatParts(parts, total)
            }
            val dataStart = eol + 2
            // 2. Wait for the whole data chunk plus its trailing CRLF.
            while (pending.size < dataStart + chunkSize + 2) {
                val n = net.read(conn, 65536)
                if (n == null || n.isEmpty()) {
                    val take = minOf(maxOf(0, pending.size - dataStart), chunkSize)
                    if (take > 0) {
                        parts.add(pending.copyOfRange(dataStart, dataStart + take))
                        total += take
                    }
                    return concatParts(parts, total)
                }
                pending = appendBytes(pending, n)
            }
            // 3. Consume the chunk; keep the tail bytes for the next round.
            parts.add(pending.copyOfRange(dataStart, dataStart + chunkSize))
            total += chunkSize
            pending = pending.copyOfRange(dataStart + chunkSize + 2, pending.size)
            pos = 0
            if (chunkSize == 0) {
                // Final chunk: optional trailers then CRLF; the connection
                // closes after the response anyway.
                break
            }
        }
        return concatParts(parts, total)
    }

    private fun parsePath(fullPath: String): Pair<String, Map<String, String>> {
        val qIdx = fullPath.indexOf('?')
        return if (qIdx < 0) {
            fullPath to emptyMap()
        } else {
            val path = fullPath.substring(0, qIdx)
            val query = fullPath.substring(qIdx + 1).split("&")
                .associate {
                    val eq = it.indexOf('=')
                    if (eq > 0) it.substring(0, eq) to it.substring(eq + 1)
                    else it to ""
                }
            path to query
        }
    }

    /** SMS relay routes take precedence when configured. */
    private suspend fun routeOrSms(req: HttpRequest, conn: Long): HttpResponse {
        if (req.path.startsWith("/api/sms/")) {
            val relay = smsRelay ?: return HttpResponse(404, "text/plain", "SMS relay disabled".toByteArray())
            val r = relay.handle(req.method, req.path, req.query, req.headers, req.body)
            if (r != null) {
                return HttpResponse(
                    r.status, "application/json",
                    (r.json + "\n").toByteArray(),
                    if (r.status == 200) "OK" else if (r.status == 401) "Unauthorized"
                    else if (r.status == 403) "Forbidden" else "Error"
                )
            }
        }
        return route(req, conn)
    }

    private fun route(req: HttpRequest, conn: Long): HttpResponse {
        return when {
            req.method == "GET" && req.path == LocalSendConst.PATH_INFO ->
                HttpResponse(200, "application/json", gson.toJson(selfInfo).toByteArray())

            req.method == "POST" && req.path == LocalSendConst.PATH_REGISTER -> {
                // Sender registers; we respond with our info.
                HttpResponse(200, "application/json", gson.toJson(selfInfo).toByteArray())
            }

            req.method == "POST" && req.path == LocalSendConst.PATH_SEND_REQUEST -> {
                handleSendRequest(req)
            }

            // Official LocalSend app route: same handler and same response
            // shape (official v2 expects files: {fileId: token-string}).
            req.method == "POST" && req.path == LocalSendConst.PATH_PREPARE_UPLOAD -> {
                handleSendRequest(req)
            }

            req.method == "POST" && req.path == LocalSendConst.PATH_SEND -> {
                handleSend(req, conn)
            }

            // Official upload route; token query param is not validated
            // (auto-accept mode).
            req.method == "POST" && req.path == LocalSendConst.PATH_UPLOAD -> {
                handleSend(req, conn)
            }

            req.method == "POST" && req.path == LocalSendConst.PATH_CANCEL -> {
                HttpResponse(200, "application/json", "{}".toByteArray())
            }

            // AnySend mirror-prepare (GET + POST): raise the hotspot (stub)
            // and report our IPv4 + adbd port as pure JSON, deliberately
            // separate from the LocalSend v2 response shapes above.
            // ?vd=1 asks for a virtual-display session (see mirrorServerArgs).
            req.method == "POST" && req.path == LocalSendConst.PATH_MIRROR_PREPARE -> handleMirrorPrepare(req)
            req.method == "GET" && req.path == LocalSendConst.PATH_MIRROR_PREPARE -> handleMirrorPrepare(req)

            // 应用推流：可启动应用清单（含图标），供鸿蒙端宫格选择。
            req.method == "GET" && req.path == LocalSendConst.PATH_APPS -> handleApps(req)

            else -> HttpResponse(404, "text/plain", "Not Found".toByteArray())
        }
    }

    /**
     * Mirror bootstrap: raise the hotspot via Shizuku (blocking, ≤8 s), then
     * spawn scrcpy-server through the Shizuku bridge and report our IPv4 +
     * the two LAN stream ports + the AP SSID/key, so the HarmonyOS peer can
     * join the hotspot and connect directly without adb.
     *
     * `?vd=1` spawns the server on a fresh virtual display instead of the
     * phone screen, so the peer can run an app there (it starts it with a
     * START_APP control message) without the phone showing anything.
     *
     * `?w=&h=&dpi=` size that virtual display to the peer's own display area
     * (which then also matches the video's aspect ratio, so the peer renders it
     * full-bleed). Omitted ⇒ the virtual display copies the phone's own screen
     * geometry.
     */
    private fun handleMirrorPrepare(req: HttpRequest): HttpResponse {
        val virtualDisplay = req.query["vd"] == "1"
        val vdWidth = req.query["w"]?.toIntOrNull() ?: 0
        val vdHeight = req.query["h"]?.toIntOrNull() ?: 0
        val vdDpi = req.query["dpi"]?.toIntOrNull() ?: 0
        // A peer that reaches us over the tailnet (the Mac client) does not need
        // the hotspot at all, so it sends hs=0 to skip the tethering call.
        val needHotspot = req.query["hs"] != "0"
        val started = if (needHotspot) {
            com.slakey.anysend.MirrorHotspotController.requestHotspotOnAndWait(context)
        } else {
            false
        }
        val ip = mirrorIpv4()
        val hs = com.slakey.anysend.MirrorHotspotController

        // Forward tunnel mode: app_process = shell UID, so screen capture and
        // touch injection are both allowed without any adb session.
        val scid = mirrorScid()
        val argsJson = mirrorServerArgs(scid, virtualDisplay, vdWidth, vdHeight, vdDpi)
        val jar = readMirrorServerJar()
        val bridge = if (jar == null) {
            null
        } else {
            hs.startBridgeAndWait(context, jar, argsJson)
        }

        // The bridge's TCP ports live on the system stack (LAN / hotspot only).
        // Re-expose them on the tailnet so a peer on another network — the Mac
        // AnySend over its real utun, for instance — can reach them too.
        var tailnetVideoPort = 0
        var tailnetControlPort = 0
        var tailnetIp = ""
        if (bridge != null) {
            val tsLayer = networks.firstOrNull { it is TailscaleNetworkLayer }
            if (tsLayer != null) {
                com.slakey.anysend.MirrorTailnetProxy.start(tsLayer, bridge.videoPort, bridge.controlPort)
                tailnetVideoPort = com.slakey.anysend.MirrorTailnetProxy.VIDEO_PORT
                tailnetControlPort = com.slakey.anysend.MirrorTailnetProxy.CONTROL_PORT
                // The peer may only know our LAN address; tell it which tailnet
                // address to dial for the proxied ports.
                tailnetIp = try {
                    kotlinx.coroutines.runBlocking {
                        com.slakey.anysend.bridge.TailscaleManager.getSelfInfo()?.tailscaleIP ?: ""
                    }
                } catch (e: Exception) {
                    ""
                }
            }
        }

        val body = gson.toJson(mapOf(
            "ok" to true,
            "ip" to ip,
            "port" to 5555,
            "hotspotRequested" to needHotspot,
            "hotspotOn" to started,
            "ssid" to hs.lastSsid,
            "password" to hs.lastPassword,
            "wirelessPort" to wirelessDebugPort(),
            "wirelessEnabled" to wirelessDebugEnabled(),
            "videoPort" to (bridge?.videoPort ?: 0),
            "controlPort" to (bridge?.controlPort ?: 0),
            "tailnetVideoPort" to tailnetVideoPort,
            "tailnetControlPort" to tailnetControlPort,
            "tailnetIp" to tailnetIp,
            "scid" to (bridge?.scid ?: scid)
        ))
        return HttpResponse(200, "application/json", body.toByteArray())
    }

    /** Random 8-hex scid, matching scrcpy's "scrcpy_<scid>" socket naming. */
    private fun mirrorScid(): String =
        String.format(java.util.Locale.US, "%08x", java.util.Random().nextInt() and 0x7fffffff)

    /**
     * scrcpy-server launch options (forward tunnel, video + control, no audio).
     *
     * `virtualDisplay` adds a fresh virtual display and turns off its system
     * decorations; `display_ime_policy=local` keeps the soft keyboard inside
     * that display (with the default policy it would pop up on the phone's own
     * screen, invisible to the peer streaming the virtual display).
     *
     * The virtual display is sized by `new_display=WxH/DPI` when the peer sent
     * its own display geometry, so the streamed video has the peer's aspect
     * ratio and pixel density instead of this phone's. `max_size` must stay
     * above that height or scrcpy would scale the frames back down.
     * Empty `new_display=` (no geometry) copies the phone's own screen.
     */
    private fun mirrorServerArgs(
        scid: String,
        virtualDisplay: Boolean,
        vdWidth: Int,
        vdHeight: Int,
        vdDpi: Int
    ): String {
        // cleanup=true（默认）: the server destroys the virtual display it created
        // when the session ends. Leaving it false leaks one 虚拟显示 per session on
        // the phone (observed: a stale `scrcpy` display surviving the server).
        val base = "scid=$scid tunnel_forward=true video=true audio=false control=true " +
            "max_size=2048 max_fps=60 video_bit_rate=12000000 cleanup=true log_level=info"
        if (!virtualDisplay) {
            return base
        }
        val displayArg = if (vdWidth > 0 && vdHeight > 0) {
            val dpiPart = if (vdDpi > 0) "/$vdDpi" else ""
            "new_display=${vdWidth}x${vdHeight}$dpiPart"
        } else {
            "new_display="
        }
        return "$base $displayArg vd_system_decorations=false display_ime_policy=local"
    }

    /**
     * Launchable-app inventory for 应用推流: package name + user-visible label +
     * a 96 px PNG icon as base64. Cached after the first call — enumerating
     * icons is expensive and the list rarely changes within a session.
     */
    private fun handleApps(req: HttpRequest): HttpResponse {
        // `?refresh=1` re-reads the inventory (the peer's refresh button), so a
        // newly installed app shows up without restarting the app.
        if (req.query["refresh"] == "1") {
            appsCache.set(null)
        }
        val body = gson.toJson(mapOf("ok" to true, "apps" to loadLaunchableApps()))
        return HttpResponse(200, "application/json", body.toByteArray())
    }

    private val appsCache =
        java.util.concurrent.atomic.AtomicReference<List<Map<String, String>>?>(null)

    private fun loadLaunchableApps(): List<Map<String, String>> {
        appsCache.get()?.let { return it }
        val list = ArrayList<Map<String, String>>()
        try {
            val pm = context.packageManager
            val intent = android.content.Intent(android.content.Intent.ACTION_MAIN)
                .addCategory(android.content.Intent.CATEGORY_LAUNCHER)
            val resolved = pm.queryIntentActivities(intent, 0)
            val seen = HashSet<String>()
            for (ri in resolved) {
                val pkg = ri.activityInfo?.packageName ?: continue
                if (!seen.add(pkg)) continue
                val label = try {
                    ri.loadLabel(pm).toString()
                } catch (e: Exception) {
                    pkg
                }
                list.add(mapOf(
                    "pkg" to pkg,
                    "label" to label,
                    "icon" to appIconBase64(ri)
                ))
            }
            list.sortBy { it["label"] ?: "" }
        } catch (e: Exception) {
            android.util.Log.e("LocalSendServer", "枚举可启动应用失败: ${e.message}")
        }
        val capped: List<Map<String, String>> =
            if (list.size > 120) ArrayList(list.subList(0, 120)) else list
        appsCache.set(capped)
        return capped
    }

    /** Square PNG (96 px) for one launcher entry, base64 (empty on failure). */
    private fun appIconBase64(ri: android.content.pm.ResolveInfo): String {
        return try {
            val drawable = ri.loadIcon(context.packageManager)
            val size = 96
            val bitmap = android.graphics.Bitmap.createBitmap(
                size, size, android.graphics.Bitmap.Config.ARGB_8888
            )
            val canvas = android.graphics.Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            val out = java.io.ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            android.util.Base64.encodeToString(out.toByteArray(), android.util.Base64.NO_WRAP)
        } catch (e: Exception) {
            ""
        }
    }

    /** scrcpy-server jar straight out of the APK assets (≈ 89 KB). */
    private fun readMirrorServerJar(): ByteArray? {
        return try {
            context.assets.open(MIRROR_SERVER_ASSET).use { it.readBytes() }
        } catch (e: Exception) {
            android.util.Log.e("LocalSendServer", "读取 $MIRROR_SERVER_ASSET 失败: ${e.message}")
            null
        }
    }

    /**
     * Wireless-debugging (adb over TLS) port. Reports the port adbd published
     * for the `_adb-tls-connect` service, so a paired peer can connect directly
     * instead of running mDNS discovery. 0 when wireless debugging is off.
     */
    private fun wirelessDebugPort(): Int = readSystemProp("service.adb.tls.port").toIntOrNull() ?: 0

    /** True when Android's wireless debugging switch is on. */
    private fun wirelessDebugEnabled(): Boolean =
        readSystemProp("persist.adb.tls_server.enable") == "1" || wirelessDebugPort() > 0

    /** Read a world-readable system property via getprop (no root needed). */
    private fun readSystemProp(name: String): String {
        return try {
            val p = ProcessBuilder("/system/bin/getprop", name)
                .redirectErrorStream(true)
                .start()
            val out = p.inputStream.bufferedReader().readText().trim()
            p.waitFor()
            out
        } catch (e: Exception) {
            ""
        }
    }

    /**
     * Best-effort local IPv4: hotspot interfaces (names containing
     * swlan/ap/wlan1) win, then wlan0-style Wi-Fi; loopback excluded.
     * Empty string when nothing usable is found.
     */
    private fun mirrorIpv4(): String {
        val hotspot = ArrayList<String>()
        val wifi = ArrayList<String>()
        try {
            val en = NetworkInterface.getNetworkInterfaces() ?: return ""
            while (en.hasMoreElements()) {
                val ni = en.nextElement()
                if (ni.isLoopback || !ni.isUp) continue
                for (ia in ni.inetAddresses) {
                    if (ia !is Inet4Address || ia.isLoopbackAddress) continue
                    val name = ni.name.lowercase()
                    val ip = ia.hostAddress ?: continue
                    when {
                        listOf("swlan", "ap", "wlan1").any { name.contains(it) } -> hotspot.add(ip)
                        name.contains("wlan") -> wifi.add(ip)
                    }
                }
            }
        } catch (e: Exception) {
            return ""
        }
        return hotspot.firstOrNull() ?: wifi.firstOrNull() ?: ""
    }

    /** Accept all files and create a session (auto-accept). */
    private fun handleSendRequest(req: HttpRequest): HttpResponse {
        val sendReq = try {
            gson.fromJson(String(req.body), SendRequest::class.java)
        } catch (e: Exception) {
            return HttpResponse(400, "text/plain", "Bad Request".toByteArray())
        }
        val sessionId = UUID.randomUUID().toString()
        // Notify UI; in this minimal impl we auto-accept all (configurable).
        onSendRequest?.invoke(sendReq.info, sendReq.files)
        // Auto-accept by default
        sendReq.files.keys.forEach { decisions[it] = true }
        val accepted = sendReq.files.mapValues { "accept" }
        synchronized(pendingSessions) {
            pendingSessions[sessionId] = PendingSession(
                senderAlias = sendReq.info.alias.ifBlank { "未知设备" },
                files = sendReq.files
            )
        }
        val resp = SendRequestResponse(sessionId = sessionId, files = accepted)
        return HttpResponse(200, "application/json", gson.toJson(resp).toByteArray())
    }

    private fun handleSend(req: HttpRequest, conn: Long): HttpResponse {
        val sessionId = req.query["sessionId"] ?: return HttpResponse(400, "text/plain", "missing sessionId".toByteArray())
        val fileId = req.query["fileId"] ?: return HttpResponse(400, "text/plain", "missing fileId".toByteArray())
        val session = synchronized(pendingSessions) { pendingSessions[sessionId] }
        val meta = session?.files?.get(fileId)
        // Keep the sender's original filename; fall back to a safe stub.
        val rawName = meta?.fileName ?: "received_${fileId.take(8)}"
        val safeName = rawName.replace(Regex("[\\\\/:*?\"<>|\u0000]"), "_").ifBlank { "file.bin" }
        val savedPath: String = try {
            saveReceivedFile(safeName, req.body)
        } catch (e: Exception) {
            return HttpResponse(500, "text/plain", "save failed".toByteArray())
        }
        // Record in transfer history (receive direction).
        TransferHistory.add(
            context, "receive",
            session?.senderAlias ?: "未知设备",
            safeName, req.body.size.toLong(), savedPath
        )
        if (session != null) {
            session.received.incrementAndGet()
            if (session.received.get() >= session.files.size) {
                synchronized(pendingSessions) { pendingSessions.remove(sessionId) }
            }
        }
        return HttpResponse(200, "application/json", "{}".toByteArray())
    }

    /**
     * Persist an uploaded file under Downloads/AnySend with its original name.
     * Raw path first; on scoped-storage failure fall back to MediaStore and
     * return the content:// Uri as the record path.
     */
    private fun saveReceivedFile(fileName: String, body: ByteArray): String {
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "AnySend"
        )
        dir.mkdirs()
        val outFile = TransferHistory.dedupeFile(dir, fileName)
        try {
            FileOutputStream(outFile).use { fos ->
                fos.write(body)
            }
            return outFile.absolutePath
        } catch (e: Exception) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, TransferHistory.mimeOf(fileName))
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/AnySend")
            }
            val uri = context.contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
            ) ?: throw e
            context.contentResolver.openOutputStream(uri)?.use { it.write(body) }
            return uri.toString()
        }
    }

    private suspend fun writeHttpResponse(net: NetworkLayer, conn: Long, resp: HttpResponse) {
        val header = "HTTP/1.1 ${resp.status} ${resp.statusText}\r\n" +
                "Content-Type: ${resp.contentType}\r\n" +
                "Content-Length: ${resp.body.size}\r\n" +
                "Connection: close\r\n\r\n"
        net.write(conn, header.toByteArray())
        if (resp.body.isNotEmpty()) {
            net.write(conn, resp.body)
        }
    }

    private fun appendBytes(dst: ByteArray, src: ByteArray): ByteArray {
        val out = ByteArray(dst.size + src.size)
        dst.copyInto(out, 0)
        src.copyInto(out, dst.size)
        return out
    }

    /** Find the '\r\n\r\n' header/body separator. Returns -1 when absent. */
    private fun findHeaderEnd(bytes: ByteArray): Int {
        for (i in 0 until bytes.size - 3) {
            if (bytes[i] == 13.toByte() && bytes[i + 1] == 10.toByte() &&
                bytes[i + 2] == 13.toByte() && bytes[i + 3] == 10.toByte()
            ) {
                return i
            }
        }
        return -1
    }

    private data class HttpResponse(
        val status: Int,
        val contentType: String,
        val body: ByteArray,
        val statusText: String = when (status) {
            200 -> "OK"
            400 -> "Bad Request"
            403 -> "Forbidden"
            404 -> "Not Found"
            else -> "OK"
        }
    )
}
