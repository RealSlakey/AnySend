package com.slakey.anysend.protocol

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * NetworkLayer backed by the system network stack (java.net sockets).
 * Used in "Direct LAN Mode" when Tailscale is not available — both
 * devices must be on the same Wi-Fi / reachable network.
 */
class DirectNetworkLayer : NetworkLayer {

    private val nextHandle = AtomicLong(1L)
    private val listeners = ConcurrentHashMap<Long, ServerSocket>()
    private val sockets = ConcurrentHashMap<Long, Socket>()

    override suspend fun dial(network: String, addr: String): Long = withContext(Dispatchers.IO) {
        try {
            val socket = Socket()
            socket.connect(InetSocketAddress(parseHost(addr), parsePort(addr)), 5000)
            val handle = nextHandle.getAndIncrement()
            sockets[handle] = socket
            handle
        } catch (e: Exception) {
            -1L
        }
    }

    /**
     * TLS dial for official LocalSend peers, whose default transport is HTTPS.
     *
     * The trust manager accepts any certificate on purpose: LocalSend mints a
     * self-signed cert per device, so there is no CA to chain to. The stream
     * is still encrypted; the peer is identified by the address the user chose.
     */
    override suspend fun dialTls(network: String, addr: String): Long = withContext(Dispatchers.IO) {
        try {
            val host = parseHost(addr)
            val port = parsePort(addr)
            val raw = Socket()
            raw.tcpNoDelay = true
            raw.connect(InetSocketAddress(host, port), 5000)
            val ssl = TRUST_ALL_CONTEXT.socketFactory
                .createSocket(raw, host, port, true) as SSLSocket
            ssl.useClientMode = true
            ssl.startHandshake()
            val handle = nextHandle.getAndIncrement()
            sockets[handle] = ssl
            handle
        } catch (e: Exception) {
            -1L
        }
    }

    override suspend fun listen(network: String, addr: String): Long = withContext(Dispatchers.IO) {
        try {
            val port = parsePort(addr)
            val server = ServerSocket()
            server.reuseAddress = true
            // Bind to all interfaces so LAN peers can reach us
            server.bind(InetSocketAddress(port))
            val handle = nextHandle.getAndIncrement()
            listeners[handle] = server
            handle
        } catch (e: Exception) {
            -1L
        }
    }

    override suspend fun accept(listenerHandle: Long): Long = withContext(Dispatchers.IO) {
        val server = listeners[listenerHandle] ?: return@withContext -1L
        try {
            val socket = server.accept()
            val handle = nextHandle.getAndIncrement()
            sockets[handle] = socket
            handle
        } catch (e: Exception) {
            -1L
        }
    }

    override suspend fun read(handle: Long, maxLen: Int): ByteArray? = withContext(Dispatchers.IO) {
        val socket = sockets[handle] ?: return@withContext null
        try {
            val buf = ByteArray(maxLen)
            val n = socket.getInputStream().read(buf)
            if (n <= 0) ByteArray(0) else buf.copyOf(n)
        } catch (e: Exception) {
            null
        }
    }

    override suspend fun write(handle: Long, data: ByteArray): Int = withContext(Dispatchers.IO) {
        val socket = sockets[handle] ?: return@withContext -1
        try {
            socket.getOutputStream().write(data)
            socket.getOutputStream().flush()
            data.size
        } catch (e: Exception) {
            -1
        }
    }

    override fun closeConn(handle: Long) {
        sockets.remove(handle)?.let {
            try { it.close() } catch (_: Exception) {}
        }
    }

    override fun closeListener(handle: Long) {
        listeners.remove(handle)?.let {
            try { it.close() } catch (_: Exception) {}
        }
    }

    private fun parseHost(addr: String): String {
        val idx = addr.lastIndexOf(':')
        return if (idx > 0) addr.substring(0, idx) else addr
    }

    private fun parsePort(addr: String): Int {
        val idx = addr.lastIndexOf(':')
        return if (idx >= 0 && idx < addr.length - 1) {
            addr.substring(idx + 1).toIntOrNull() ?: LocalSendConst.PORT
        } else {
            LocalSendConst.PORT
        }
    }

    private companion object {
        /**
         * Accepts any server certificate. LocalSend uses a self-signed cert
         * per device, so chain validation would always fail; the transport is
         * still encrypted, and peers are addressed explicitly by the user.
         */
        val TRUST_ALL_CONTEXT: SSLContext by lazy {
            SSLContext.getInstance("TLS").apply {
                init(
                    null,
                    arrayOf<TrustManager>(object : X509TrustManager {
                        override fun checkClientTrusted(
                            chain: Array<out X509Certificate>?,
                            authType: String?
                        ) = Unit

                        override fun checkServerTrusted(
                            chain: Array<out X509Certificate>?,
                            authType: String?
                        ) = Unit

                        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
                    }),
                    SecureRandom()
                )
            }
        }
    }
}
