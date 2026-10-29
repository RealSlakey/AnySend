package com.slakey.anysend.protocol

/**
 * Abstraction over the raw socket layer so the LocalSend protocol code can
 * run either over the Tailscale userspace netstack or over the system
 * network stack (Direct LAN mode).
 *
 * Handles are opaque Longs (>0 means valid, <=0 means error).
 */
interface NetworkLayer {
    /** Open a TCP connection to addr (host:port). Returns handle or -1. */
    suspend fun dial(network: String, addr: String): Long

    /**
     * Open a TLS connection to addr (host:port). Returns handle or -1.
     *
     * Official LocalSend peers serve HTTPS with a per-device self-signed
     * certificate, so the chain is intentionally not verified: the stream is
     * still encrypted, and the peer's identity is pinned by the LAN/tailnet
     * context rather than by a CA.
     */
    suspend fun dialTls(network: String, addr: String): Long

    /** Listen on addr. Returns listener handle or -1. */
    suspend fun listen(network: String, addr: String): Long

    /** Accept one connection. Returns connection handle or -1. */
    suspend fun accept(listenerHandle: Long): Long

    /** Read up to maxLen bytes. Returns bytes (empty on EOF) or null on error. */
    suspend fun read(handle: Long, maxLen: Int): ByteArray?

    /** Write data. Returns bytes written or -1 on error. */
    suspend fun write(handle: Long, data: ByteArray): Int

    fun closeConn(handle: Long)
    fun closeListener(handle: Long)
}
