package com.slakey.anysend.remote

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import com.slakey.anysend.AppActions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.DataInputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Android as the *controlling* end of a Mac — the peer of the Mac's
 * `RemoteHostController.swift`.
 *
 * Wire protocol (scrcpy v2, same as the HarmonyOS client):
 *   video  1 dummy byte + 64-byte host name + 12-byte codec meta
 *          frames: 8-byte pts+flags, 4-byte size, Annex-B payload
 *   control scrcpy control messages (see [MacRemoteControl])
 *
 * The Mac listens on 27042 (video) / 27043 (control) and, when a PIN is
 * configured, expects a 1-byte-length UTF-8 prefix on both sockets first.
 */
class MacRemoteClient(
    private val host: String,
    private val pin: String,
    private val surface: Surface,
    private val onVideoSize: (width: Int, height: Int, name: String) -> Unit,
    private val onError: (String) -> Unit,
    private val onFirstFrame: () -> Unit,
    private val onClipboard: (String) -> Unit = {},
) {
    companion object {
        private const val TAG = "MacRemote"
        const val VIDEO_PORT = 27042
        const val CONTROL_PORT = 27043
        private const val HEADER_SIZE = 77
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private var videoSocket: Socket? = null
    private var controlSocket: Socket? = null
    private var controlOut: OutputStream? = null
    private var decoder: MediaCodec? = null
    private val pipes = ArrayList<TailnetPipe>()

    @Volatile
    private var stopped = false

    private var videoWidth = 1920
    private var videoHeight = 1080

    /** Live screen geometry used by the input layer when building touch messages. */
    val screenWidth: Int get() = videoWidth
    val screenHeight: Int get() = videoHeight

    fun start() {
        job = scope.launch {
            try {
                val endpoints = resolveEndpoints()
                val video = connect(endpoints.videoHost, endpoints.videoPort)
                videoSocket = video
                val control = connect(endpoints.controlHost, endpoints.controlPort)
                controlSocket = control
                controlOut = control.getOutputStream()

                if (pin.isNotEmpty()) {
                    sendPin(video.getOutputStream())
                    sendPin(control.getOutputStream())
                }
                startControlReader(control)
                decodeLoop(video)
            } catch (e: Exception) {
                if (!stopped) {
                    onError(e.message ?: "连接失败")
                }
            }
        }
    }

    fun stop() {
        stopped = true
        job?.cancel()
        runCatching { decoder?.stop() }
        runCatching { decoder?.release() }
        decoder = null
        runCatching { videoSocket?.close() }
        runCatching { controlSocket?.close() }
        videoSocket = null
        controlSocket = null
        controlOut = null
        pipes.forEach { it.close() }
        pipes.clear()
    }

    // ---------------- transport ----------------

    private data class Endpoints(
        val videoHost: String,
        val videoPort: Int,
        val controlHost: String,
        val controlPort: Int,
    )

    /**
     * Same-subnet Macs are reachable on the system socket stack; everything
     * else has to go through the embedded tsnet node.
     *
     * Note: never probe by opening a TCP connection here — the Mac host treats
     * the first connection on 27042 as the real video client and immediately
     * starts sending its handshake and keyframes into it.
     */
    private suspend fun resolveEndpoints(): Endpoints {
        if (sharesSubnet(host)) {
            return Endpoints(host, VIDEO_PORT, host, CONTROL_PORT)
        }
        val net = com.slakey.anysend.bridge.TailscaleManager.currentNetworkLayer()
        if (net != null) {
            val videoPipe = TailnetPipe.open(net, host, VIDEO_PORT)
            val controlPipe = TailnetPipe.open(net, host, CONTROL_PORT)
            if (videoPipe != null && controlPipe != null) {
                pipes.add(videoPipe)
                pipes.add(controlPipe)
                return Endpoints("127.0.0.1", videoPipe.localPort, "127.0.0.1", controlPipe.localPort)
            }
            videoPipe?.close()
            controlPipe?.close()
        }
        // Last resort: try the address directly (works when the OS itself has
        // a Tailscale utun, i.e. the phone also runs the Tailscale app).
        return Endpoints(host, VIDEO_PORT, host, CONTROL_PORT)
    }

    /** True when the target sits in the same /24 as one of our IPv4 addresses. */
    private fun sharesSubnet(target: String): Boolean {
        val prefix = target.substringBeforeLast('.', "")
        if (prefix.isEmpty()) return false
        val local = AppActions.getLocalIpAddresses()
        return local.any { it.startsWith("$prefix.") }
    }

    private suspend fun connect(host: String, port: Int): Socket = withContext(Dispatchers.IO) {
        val socket = Socket()
        socket.tcpNoDelay = true
        socket.connect(InetSocketAddress(host, port), 6000)
        socket
    }

    private fun sendPin(out: OutputStream) {
        val bytes = pin.toByteArray(Charsets.UTF_8)
        out.write(byteArrayOf(bytes.size.toByte()))
        out.write(bytes)
        out.flush()
    }

    // ---------------- video ----------------

    private suspend fun decodeLoop(socket: Socket) = withContext(Dispatchers.IO) {
        val input = DataInputStream(socket.getInputStream())
        val header = ByteArray(HEADER_SIZE)
        // A wrong/blank PIN makes the Mac wait for its prefix instead of sending
        // the handshake, so fail with a readable message rather than hanging.
        socket.soTimeout = 10_000
        try {
            input.readFully(header)
        } catch (e: java.net.SocketTimeoutException) {
            throw IllegalStateException("Mac 未响应，请检查 PIN 是否正确、被控端是否已开启")
        } finally {
            socket.soTimeout = 0
        }

        val nameBytes = header.copyOfRange(1, 65).takeWhile { it != 0.toByte() }.toByteArray()
        val name = String(nameBytes, Charsets.UTF_8)
        // 1 dummy + 64 name, then codec id / width / height.
        val width = readInt(header, 69)
        val height = readInt(header, 73)
        if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
            throw IllegalStateException("Mac 返回的画面尺寸异常（${width}×${height}）")
        }
        videoWidth = width
        videoHeight = height
        onVideoSize(videoWidth, videoHeight, name)

        var firstFrame = true
        val frameHeader = ByteArray(12)
        val codec = MediaCodecHolder()
        try {
            while (!stopped) {
                input.readFully(frameHeader)
                var flags = 0L
                for (i in 0 until 8) {
                    flags = (flags shl 8) or (frameHeader[i].toLong() and 0xFF)
                }
                val size = readInt(frameHeader, 8)
                if (size <= 0 || size > 32 * 1024 * 1024) {
                    throw IllegalStateException("非法的帧长度：$size")
                }
                val payload = ByteArray(size)
                input.readFully(payload)
                val isConfig = flags and (1L shl 63) != 0L
                val pts = flags and ((1L shl 62) - 1)

                if (isConfig) {
                    codec.configure(payload)
                    continue
                }
                val codecRef = codec.codec ?: continue
                // H.264 P-frames reference earlier pictures, so a dropped frame
                // would smear the picture until the next IDR. Wait for an input
                // buffer instead of silently dropping (patience > one frame).
                var index = -1
                var waited = 0
                while (index < 0 && waited < 500 && !stopped) {
                    index = codecRef.dequeueInputBuffer(10_000)
                    if (index < 0) waited += 10
                }
                if (stopped) break
                if (index >= 0) {
                    val buffer = codecRef.getInputBuffer(index)
                    if (buffer != null) {
                        buffer.clear()
                        buffer.put(payload)
                        codecRef.queueInputBuffer(index, 0, payload.size, pts, 0)
                    } else {
                        codecRef.queueInputBuffer(index, 0, 0, pts, 0)
                    }
                }
                if (drain(codecRef) && firstFrame) {
                    firstFrame = false
                    onFirstFrame()
                }
            }
        } finally {
            codec.release()
        }
    }

    /** Renders whatever is ready; returns true when at least one frame was shown. */
    private fun drain(codec: MediaCodec): Boolean {
        val info = MediaCodec.BufferInfo()
        var rendered = false
        while (true) {
            val outIndex = codec.dequeueOutputBuffer(info, 0)
            if (outIndex >= 0) {
                codec.releaseOutputBuffer(outIndex, true)
                rendered = true
            } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                // Surface rendering handles the format change itself.
            } else {
                break
            }
        }
        return rendered
    }

    /** Lazily creates the decoder once SPS/PPS arrive. */
    private inner class MediaCodecHolder {
        var codec: MediaCodec? = null
        private var sps: ByteArray? = null
        private var pps: ByteArray? = null

        fun configure(annexB: ByteArray) {
            for (nalu in splitNalus(annexB)) {
                when (nalu.firstOrNull()?.toInt()?.and(0x1F)) {
                    7 -> sps = nalu
                    8 -> pps = nalu
                }
            }
            if (codec != null) return
            val s = sps ?: return
            val p = pps ?: return
            try {
                val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, videoWidth, videoHeight)
                format.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(s))
                format.setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(p))
                val created = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                created.configure(format, surface, null, 0)
                created.start()
                codec = created
            } catch (e: Exception) {
                Log.e(TAG, "decoder start failed: ${e.message}")
                onError("解码器启动失败：${e.message}")
            }
        }

        fun release() {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            codec = null
        }
    }

    // ---------------- control ----------------

    private fun startControlReader(socket: Socket) {
        scope.launch {
            try {
                val input = DataInputStream(socket.getInputStream())
                while (!stopped) {
                    val type = input.read()
                    if (type < 0) break
                    if (type == 0) {
                        // Mac -> client clipboard: 4-byte length + UTF-8.
                        val length = input.readInt()
                        if (length <= 0 || length > 1_000_000) break
                        val bytes = ByteArray(length)
                        input.readFully(bytes)
                        onClipboard(String(bytes, Charsets.UTF_8))
                    } else {
                        break
                    }
                }
            } catch (_: Exception) {
            }
        }
    }

    fun send(packet: ByteArray) {
        val out = controlOut ?: return
        try {
            out.write(packet)
            out.flush()
        } catch (e: Exception) {
            Log.w(TAG, "control send failed: ${e.message}")
        }
    }

    private fun readInt(bytes: ByteArray, offset: Int): Int {
        return ((bytes[offset].toInt() and 0xFF) shl 24) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 8) or
            (bytes[offset + 3].toInt() and 0xFF)
    }

    private fun splitNalus(data: ByteArray): List<ByteArray> {
        // Start-code positions as (naluStart, naluStartAfterStartCode).
        val marks = ArrayList<Pair<Int, Int>>()
        var i = 0
        while (i + 3 <= data.size) {
            if (i + 4 <= data.size && data[i] == 0.toByte() && data[i + 1] == 0.toByte() &&
                data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()
            ) {
                marks.add(i to i + 4)
                i += 4
            } else if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte()) {
                marks.add(i to i + 3)
                i += 3
            } else {
                i++
            }
        }
        if (marks.isEmpty()) {
            return if (data.isEmpty()) emptyList() else listOf(data.trimmed())
        }
        val out = ArrayList<ByteArray>(marks.size)
        for ((index, mark) in marks.withIndex()) {
            val end = if (index + 1 < marks.size) marks[index + 1].first else data.size
            if (end > mark.second) {
                out.add(data.copyOfRange(mark.second, end).trimmed())
            }
        }
        return out
    }

    /** Annex-B allows trailing zero bytes between NAL units; csd blobs must not keep them. */
    private fun ByteArray.trimmed(): ByteArray {
        var end = size
        while (end > 0 && this[end - 1] == 0.toByte()) {
            end--
        }
        return if (end == size) this else copyOf(end)
    }
}
