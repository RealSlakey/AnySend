package com.slakey.anysend

import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import com.slakey.anysend.bridge.TailscaleManager
import kotlinx.coroutines.launch
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Shared connection actions used by the settings and transfer fragments. */
object AppActions {

    fun startBridge(context: Context, mode: String) {
        val intent = Intent(context, BridgeService::class.java)
        intent.putExtra(BridgeService.EXTRA_NETWORK_MODE, mode)
        ContextCompat.startForegroundService(context, intent)
    }

    /**
     * Login Tailscale and start the bridge service. Reports progress via
     * [onStatus]; invoked with the user-facing message.
     */
    fun loginTailscale(
        owner: LifecycleOwner,
        context: Context,
        authKey: String,
        onStatus: (String) -> Unit
    ) {
        if (authKey.isEmpty()) {
            Toast.makeText(context, "请输入 Tailscale Auth Key", Toast.LENGTH_SHORT).show()
            return
        }
        context.getSharedPreferences("tslsb", Context.MODE_PRIVATE)
            .edit().putString("auth_key", authKey).apply()

        owner.lifecycleScope.launch {
            onStatus("正在连接 Tailscale...")
            val ok = TailscaleManager.login(context, authKey)
            if (ok) {
                onStatus("Tailscale 已连接")
                startBridge(context, BridgeService.MODE_TAILSCALE)
            } else {
                val why = TailscaleManager.lastError()
                onStatus(
                    if (why.isNullOrEmpty()) "Tailscale 连接失败（可改用直连模式）"
                    else "Tailscale 连接失败：$why"
                )
            }
        }
    }

    /**
     * Write outgoing text as a UTF-8 .txt file in the private cache, named
     * 文字-yyyyMMdd-HHmmss.txt so receivers see a readable file name.
     */
    fun writeOutgoingText(context: Context, text: String): File? {
        return try {
            val dir = File(context.cacheDir, "outgoing").apply { mkdirs() }
            val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
            var file = File(dir, "文字-$stamp.txt")
            var suffix = 2
            while (file.exists()) {
                file = File(dir, "文字-$stamp-$suffix.txt")
                suffix++
            }
            file.writeText(text, Charsets.UTF_8)
            file
        } catch (e: Exception) {
            null
        }
    }

    /** Stable per-install LocalSend fingerprint (identifies this device). */
    fun deviceFingerprint(context: Context): String {
        val prefs = context.getSharedPreferences("tslsb", Context.MODE_PRIVATE)
        prefs.getString("fingerprint", null)?.let { return it }
        val fp = java.util.UUID.randomUUID().toString()
        prefs.edit().putString("fingerprint", fp).apply()
        return fp
    }

    /** The device's IPv4 on the Wi-Fi/Ethernet NIC (cellular excluded when present). */
    fun getLocalIpAddress(): String? {
        return try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            var fallback: String? = null
            for (intf in interfaces) {
                if (!intf.isUp || intf.isLoopback) continue
                var ip: String? = null
                for (addr in intf.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        ip = addr.hostAddress
                        break
                    }
                }
                if (ip == null) continue
                // With mobile data on, the rmnet NIC may enumerate first and
                // report the cellular address; prefer wlan/eth for LAN display.
                if (intf.name.startsWith("wlan") || intf.name.startsWith("eth")) {
                    return ip
                }
                if (fallback == null) {
                    fallback = ip
                }
            }
            fallback
        } catch (e: Exception) {
            null
        }
    }

    /** All local IPv4 addresses, used for subnet matching (never opens a socket). */
    fun getLocalIpAddresses(): List<String> {
        val result = ArrayList<String>()
        try {
            for (intf in NetworkInterface.getNetworkInterfaces()) {
                if (!intf.isUp || intf.isLoopback) continue
                for (addr in intf.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        val ip = addr.hostAddress ?: continue
                        if (!result.contains(ip)) {
                            result.add(ip)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            // keep whatever was collected
        }
        return result
    }
}
