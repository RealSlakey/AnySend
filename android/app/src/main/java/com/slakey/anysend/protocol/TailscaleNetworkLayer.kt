package com.slakey.anysend.protocol

import com.slakey.anysend.bridge.TailscaleManager

/**
 * NetworkLayer backed by the embedded Tailscale tsnet userspace netstack.
 * Used when the user has logged in to Tailscale.
 */
class TailscaleNetworkLayer : NetworkLayer {
    override suspend fun dial(network: String, addr: String): Long =
        TailscaleManager.dial(network, addr)

    override suspend fun listen(network: String, addr: String): Long =
        TailscaleManager.listen(network, addr)

    override suspend fun accept(listenerHandle: Long): Long =
        TailscaleManager.accept(listenerHandle)

    override suspend fun read(handle: Long, maxLen: Int): ByteArray? =
        TailscaleManager.read(handle, maxLen)

    override suspend fun write(handle: Long, data: ByteArray): Int =
        TailscaleManager.write(handle, data)

    override fun closeConn(handle: Long) = TailscaleManager.closeConn(handle)
    override fun closeListener(handle: Long) = TailscaleManager.closeListener(handle)
}
