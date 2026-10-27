package com.slakey.anysend.remote

import android.util.Log
import com.slakey.anysend.protocol.NetworkLayer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * Bridges one tailnet endpoint (the Mac's 27042 / 27043) onto a loopback port so
 * the rest of the client can keep using plain sockets.
 *
 * The embedded tsnet node is a userspace netstack: the system socket stack
 * cannot reach 100.x addresses, so every tailnet byte must travel through
 * [NetworkLayer].
 */
class TailnetPipe private constructor(
    private val job: Job,
    private val server: ServerSocket,
) {
    val localPort: Int get() = server.localPort

    fun close() {
        job.cancel()
        runCatching { server.close() }
    }

    companion object {
        private const val TAG = "MacRemote"
        private const val BUFFER = 64 * 1024

        /** Bind a loopback port that forwards its first connection to the tailnet target. */
        suspend fun open(net: NetworkLayer, host: String, port: Int): TailnetPipe? {
            val server = withContext(Dispatchers.IO) {
                try {
                    ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
                } catch (e: Exception) {
                    Log.w(TAG, "loopback bind failed: ${e.message}")
                    null
                }
            } ?: return null

            val job = CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
                try {
                    val local = server.accept()
                    val remote = net.dial("tcp", "$host:$port")
                    if (remote <= 0L) {
                        Log.w(TAG, "tailnet dial $host:$port failed")
                        local.close()
                        return@launch
                    }
                    pump(net, local, remote)
                } catch (e: Exception) {
                    Log.d(TAG, "pipe $host:$port closed: ${e.message}")
                } finally {
                    runCatching { server.close() }
                }
            }
            return TailnetPipe(job, server)
        }

        private suspend fun pump(net: NetworkLayer, local: Socket, remote: Long) {
            withContext(Dispatchers.IO) {
                try {
                    val up = launch {
                        try {
                            val input: InputStream = local.getInputStream()
                            val buf = ByteArray(BUFFER)
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                net.write(remote, buf.copyOf(n))
                            }
                        } catch (_: Exception) {
                        } finally {
                            runCatching { local.close() }
                        }
                    }
                    val down = launch {
                        try {
                            val output: OutputStream = local.getOutputStream()
                            while (true) {
                                val data = net.read(remote, BUFFER) ?: break
                                if (data.isEmpty()) break
                                output.write(data)
                                output.flush()
                            }
                        } catch (_: Exception) {
                        } finally {
                            runCatching { local.close() }
                        }
                    }
                    up.join()
                    down.cancel()
                } finally {
                    // Runs on cancellation too, so a closed pipe never leaks a
                    // tsnet connection.
                    net.closeConn(remote)
                }
            }
        }
    }
}
