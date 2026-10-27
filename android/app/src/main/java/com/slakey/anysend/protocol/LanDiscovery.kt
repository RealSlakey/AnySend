package com.slakey.anysend.protocol

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.util.Log
import com.google.gson.Gson
import com.slakey.anysend.AppActions
import com.slakey.anysend.DeviceName
import java.net.DatagramPacket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * LocalSend protocol v2 discovery: devices announce themselves as JSON over
 * the 224.0.0.167:53317 multicast group.announce=false asks everyone to
 * announce; announce=true is the announcement. Wire-compatible with the
 * official LocalSend apps, which also answer our discovery requests.
 */
object LanDiscovery {
    private const val TAG = "LanScan"
    const val PORT = LocalSendConst.PORT
    const val MULTICAST_ADDR = "224.0.0.167"
    private const val ANNOUNCE_INTERVAL_MS = 5000L

    /** Min interval between discovery replies to the same source. Without it
     *  a peer that answers our announcements with fresh requests creates a
     *  multicast reply storm (observed with the official LocalSend app). */
    private const val REPLY_THROTTLE_MS = 2000L

    data class Device(val name: String, val ip: String, val fingerprint: String)

    private val gson = Gson()
    private val devices = ConcurrentHashMap<String, Device>() // ip -> device
    private val lastReplyAt = ConcurrentHashMap<String, Long>() // ip -> last reply ts
    private val executor = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "lan-discovery").apply { isDaemon = true }
    }

    @Volatile private var socket: MulticastSocket? = null
    @Volatile private var announceTask: java.util.concurrent.ScheduledFuture<*>? = null
    @Volatile private var selfInfo: DeviceInfo? = null

    /** Self DeviceInfo with a stable fingerprint and current alias. */
    fun selfDeviceInfo(context: Context): DeviceInfo = DeviceInfo(
        alias = DeviceName.get(context),
        deviceModel = android.os.Build.MODEL,
        deviceType = LocalSendConst.DEVICE_TYPE_MOBILE,
        fingerprint = AppActions.deviceFingerprint(context)
    )

    /** Start the resident responder: join the group, answer discovery
     *  requests and announce periodically. */
    fun start(context: Context) {
        if (socket != null) return
        val s = openSocket(context) ?: return
        selfInfo = selfDeviceInfo(context)
        socket = s
        // Receiver loop on its own thread — the scheduler is a single thread
        // and the blocking receive loop would starve the announce timer.
        Thread { receiveLoop(context, s) }.apply {
            isDaemon = true
            name = "lan-discovery-rx"
            start()
        }
        // Periodic announcement.
        announceTask = executor.scheduleWithFixedDelay({
            announce(context, s, true)
        }, 0, ANNOUNCE_INTERVAL_MS, TimeUnit.MILLISECONDS)
        Log.i(TAG, "responder started on $MULTICAST_ADDR:$PORT")
    }

    fun isRunning(): Boolean = socket != null

    /** Re-open the socket after the Wi-Fi network changed. A MulticastSocket
     *  stays bound to the interface it joined on, so switching networks
     *  (different subnet, hotspot, SSID change) silently kills discovery
     *  unless we drop the old socket and join again. */
    fun restart(context: Context) {
        stop()
        start(context)
    }

    fun stop() {
        announceTask?.cancel(false)
        announceTask = null
        socket?.close()
        socket = null
        devices.clear()
    }

    /** Broadcast announce=false and collect announcements for [timeoutMs]. */
    fun scan(context: Context, timeoutMs: Long = 2500): List<Device> {
        val own = AppActions.deviceFingerprint(context)
        var s = socket
        var temporary = false
        if (s == null) {
            s = openSocket(context) ?: return emptyList()
            temporary = true
        }
        try {
            announce(context, s, false)
            val deadline = System.currentTimeMillis() + timeoutMs
            val buf = ByteArray(4096)
            while (System.currentTimeMillis() < deadline) {
                val pkt = DatagramPacket(buf, buf.size)
                try {
                    s.soTimeout = 100
                    s.receive(pkt)
                } catch (e: java.net.SocketTimeoutException) {
                    continue
                } catch (e: Exception) {
                    break
                }
                handlePacket(context, s, pkt)
            }
        } catch (e: Exception) {
            Log.w(TAG, "scan failed", e)
        } finally {
            if (temporary) {
                s.close()
            }
        }
        return devices.values.filter { it.fingerprint != own }.toList()
    }

    /** Devices seen recently (used to render without a fresh scan). */
    fun knownDevices(context: Context): List<Device> {
        val own = AppActions.deviceFingerprint(context)
        return devices.values.filter { it.fingerprint != own }.toList()
    }

    // ------------------------------------------------------------------ //

    private fun openSocket(context: Context): MulticastSocket? {
        return try {
            val s = MulticastSocket(PORT)
            s.reuseAddress = true
            val ni = wifiInterface(context)
            Log.i(TAG, "wifiInterface=$ni")
            if (ni != null) {
                s.networkInterface = ni
                s.joinGroup(InetSocketAddress(InetAddress.getByName(MULTICAST_ADDR), PORT), ni)
            } else {
                s.joinGroup(InetAddress.getByName(MULTICAST_ADDR))
            }
            s
        } catch (e: Exception) {
            Log.w(TAG, "open socket failed", e)
            null
        }
    }

    private fun receiveLoop(context: Context, s: MulticastSocket) {
        val buf = ByteArray(4096)
        while (!s.isClosed) {
            val pkt = DatagramPacket(buf, buf.size)
            try {
                s.receive(pkt)
            } catch (e: Exception) {
                if (s.isClosed) return
                continue
            }
            handlePacket(context, s, pkt)
        }
    }

    /** Parse one announcement and record the sender; answer discovery
     *  requests (announce=false or legacy v2.0 messages) once. */
    private fun handlePacket(context: Context, s: MulticastSocket, pkt: DatagramPacket) {
        val msg = String(pkt.data, 0, pkt.length).trim()
        val ip = pkt.address?.hostAddress ?: return
        val parsed = try {
            gson.fromJson(msg, HashMap::class.java) as Map<*, *>
        } catch (e: Exception) {
            return
        }
        val alias = (parsed["alias"] as? String)?.takeIf { it.isNotEmpty() } ?: ip
        val fingerprint = parsed["fingerprint"] as? String ?: return
        val announce = parsed["announce"] as? Boolean ?: false
        devices[ip] = Device(alias, ip, fingerprint)
        Log.d(TAG, "discovered $alias from $ip (announce=$announce)")
        if (!announce) {
            // The sender is asking for announcements — reply with ours,
            // throttled per source to break reply-storm feedback loops.
            val now = System.currentTimeMillis()
            if (now - (lastReplyAt[ip] ?: 0L) >= REPLY_THROTTLE_MS) {
                lastReplyAt[ip] = now
                selfInfo = selfDeviceInfo(context)
                val reply = announceMessage(announce = true)
                try {
                    val data = reply.toByteArray()
                    s.send(DatagramPacket(data, data.size,
                        InetAddress.getByName(MULTICAST_ADDR), PORT))
                } catch (e: Exception) {
                    Log.w(TAG, "reply failed", e)
                }
            }
        }
    }

    private fun announce(context: Context, s: MulticastSocket, announce: Boolean) {
        try {
            selfInfo = selfDeviceInfo(context)
            val data = announceMessage(announce).toByteArray()
            s.send(DatagramPacket(data, data.size,
                InetAddress.getByName(MULTICAST_ADDR), PORT))
            Log.d(TAG, "announce($announce) sent via ${s.networkInterface?.name}")
        } catch (e: Exception) {
            Log.w(TAG, "announce failed", e)
        }
    }

    /** LocalSend v2 discovery message: DeviceInfo fields + announce flag. */
    private fun announceMessage(announce: Boolean): String {
        val info = selfInfo ?: return ""
        val map = LinkedHashMap<String, Any>()
        map["alias"] = info.alias
        map["version"] = info.version
        map["deviceModel"] = info.deviceModel
        map["deviceType"] = info.deviceType
        map["fingerprint"] = info.fingerprint
        map["port"] = info.port
        map["protocol"] = info.protocol
        map["download"] = info.download
        map["announce"] = announce
        return gson.toJson(map)
    }

    /**
     * The interface carrying the *station* Wi-Fi address.
     *
     * Uses the active Wi-Fi network's LinkProperties instead of guessing from
     * the first "wlan*" NIC: while the mirror feature has the hotspot up, that
     * guess can land on the AP interface and send our announcements out on a
     * network no peer is listening to.
     */
    private fun wifiInterface(context: Context): NetworkInterface? {
        return try {
            val cm = context.applicationContext
                .getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (cm != null) {
                for (n in cm.allNetworks) {
                    val caps = cm.getNetworkCapabilities(n) ?: continue
                    if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
                    val lp: LinkProperties = cm.getLinkProperties(n) ?: continue
                    for (la in lp.linkAddresses) {
                        val addr = la.address
                        if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                        val ni = NetworkInterface.getByInetAddress(addr) ?: continue
                        if (isHotspotInterface(ni.name)) continue
                        return ni
                    }
                }
            }
            NetworkInterface.getNetworkInterfaces().asSequence()
                .filter { it.isUp && !it.isLoopback && !isHotspotInterface(it.name) }
                .firstOrNull { it.name.startsWith("wlan") || it.name.startsWith("eth") }
        } catch (e: Exception) {
            null
        }
    }

    /** Hotspot/AP and Wi-Fi Direct NICs must never carry discovery traffic. */
    private fun isHotspotInterface(name: String): Boolean =
        name.startsWith("ap") || name.startsWith("softap") ||
            name.startsWith("swlan") || name.contains("p2p")
}
