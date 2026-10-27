package com.slakey.anysend

import android.util.Log
import com.slakey.anysend.protocol.NetworkLayer
import com.slakey.anysend.protocol.TailscaleNetworkLayer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Exposes the Shizuku mirror bridge on the Tailscale tailnet.
 *
 * The bridge itself opens two wildcard `ServerSocket`s (LAN / hotspot only):
 * the phone's tsnet node is a userspace netstack, so a tailnet packet arriving
 * at the phone never reaches those sockets. A peer that is not on the same
 * Wi-Fi (the Mac client over a real `utun`, for example) therefore cannot
 * connect to the reported LAN ports.
 *
 * This proxy listens on two fixed tailnet ports and pipes each accepted tsnet
 * connection to `127.0.0.1:<bridge port>`, preserving scrcpy's accept order:
 * the video proxy dials the local video port first, the control proxy second.
 */
object MirrorTailnetProxy {
    private const val TAG = "MirrorTailnet"

    /** Fixed tailnet ports the peers connect to (video first, then control). */
    const val VIDEO_PORT = 27052
    const val CONTROL_PORT = 27053

    private const val BUFFER = 64 * 1024

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var videoJob: Job? = null
    private var controlJob: Job? = null

    @Volatile
    private var activeKeys: Pair<Int, Int>? = null

    /**
     * Start (or restart) the proxy for the given local bridge ports. Repeated
     * calls for the same bridge are ignored so a second mirror-prepare request
     * does not tear down a live session.
     */
    fun start(net: NetworkLayer, localVideoPort: Int, localControlPort: Int) {
        if (net !is TailscaleNetworkLayer) {
            return
        }
        val keys = localVideoPort to localControlPort
        if (activeKeys == keys && videoJob?.isActive == true && controlJob?.isActive == true) {
            return
        }
        stop()
        activeKeys = keys
        videoJob = scope.launch { serve(net, VIDEO_PORT, localVideoPort) }
        controlJob = scope.launch { serve(net, CONTROL_PORT, localControlPort) }
        Log.d(TAG, "镜像桥已暴露到 tailnet :$VIDEO_PORT -> $localVideoPort, :$CONTROL_PORT -> $localControlPort")
    }

    fun stop() {
        videoJob?.cancel()
        controlJob?.cancel()
        videoJob = null
        controlJob = null
        activeKeys = null
    }

    /**
     * Accept tailnet connections forever and pump each of them to the local
     * bridge port. The listener handle is closed when the job is cancelled.
     */
    private suspend fun serve(net: NetworkLayer, tailnetPort: Int, localPort: Int) {
        val listener = net.listen("tcp", ":$tailnetPort")
        if (listener <= 0L) {
            Log.w(TAG, "tailnet listen on :$tailnetPort failed")
            return
        }
        try {
            while (true) {
                val conn = net.accept(listener)
                if (conn <= 0L) {
                    break
                }
                scope.launch { pump(net, conn, localPort) }
            }
        } catch (e: Exception) {
            Log.d(TAG, "tailnet listener :$tailnetPort closed: ${e.message}")
        } finally {
            net.closeListener(listener)
        }
    }

    private suspend fun pump(net: NetworkLayer, conn: Long, localPort: Int) {
        withContext(Dispatchers.IO) {
            var socket: Socket? = null
            try {
                val s = Socket()
                s.connect(InetSocketAddress("127.0.0.1", localPort), 4000)
                s.tcpNoDelay = true
                socket = s

                // tailnet -> local bridge
                val forward = launch {
                    try {
                        while (true) {
                            val data = net.read(conn, BUFFER) ?: break
                            if (data.isEmpty()) break
                            s.getOutputStream().write(data)
                            s.getOutputStream().flush()
                        }
                    } catch (_: Exception) {
                    } finally {
                        runCatching { s.close() }
                    }
                }
                // local bridge -> tailnet
                val back = launch {
                    try {
                        val buf = ByteArray(BUFFER)
                        while (true) {
                            val n = s.getInputStream().read(buf)
                            if (n < 0) break
                            net.write(conn, buf.copyOf(n))
                        }
                    } catch (_: Exception) {
                    } finally {
                        runCatching { s.close() }
                    }
                }
                forward.join()
                back.cancel()
            } catch (e: Exception) {
                Log.d(TAG, "本地镜像端口 $localPort 连接失败: ${e.message}")
                socket?.let { runCatching { it.close() } }
            } finally {
                net.closeConn(conn)
            }
        }
    }
}
