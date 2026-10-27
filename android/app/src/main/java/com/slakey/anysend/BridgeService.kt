package com.slakey.anysend

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.slakey.anysend.bridge.TailscaleManager
import com.slakey.anysend.protocol.DirectNetworkLayer
import com.slakey.anysend.protocol.DeviceInfo
import com.slakey.anysend.protocol.LanDiscovery
import com.slakey.anysend.protocol.LocalSendConst
import com.slakey.anysend.protocol.LocalSendServer
import com.slakey.anysend.protocol.NetworkLayer
import com.slakey.anysend.protocol.TailscaleNetworkLayer
import com.slakey.anysend.sms.SmsReceiver
import com.slakey.anysend.sms.SmsRelay
import com.slakey.anysend.sms.SmsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Foreground service that keeps the LocalSend receiver server running while
 * the app is in the background. Supports both Tailscale mode and Direct LAN
 * mode (chosen via [EXTRA_NETWORK_MODE]). When SMS permissions are granted,
 * it also enables the SMS relay (HTTP API + incoming-SMS push).
 *
 * Also answers UDP LAN-discovery broadcasts on port 53317 so peers can list
 * this device in their devices tab.
 */
class BridgeService : Service() {

    private var server: LocalSendServer? = null
    private var smsRelay: SmsRelay? = null
    private var smsReceiver: SmsReceiver? = null
    private var currentMode: String? = null
    private var discoveryStarted: Boolean = false
    private var multicastLock: WifiManager.MulticastLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    /** Debounced: one Wi-Fi switch fires several capability callbacks. */
    private val discoveryRestart = Runnable { restartDiscovery() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        startLocalSendServer(intent)
        startDiscovery()
        // START_STICKY: when the system restarts this service after a process
        // death the intent is null; mode persistence below restores whichever
        // mode the user last chose.
        return START_STICKY
    }

    /**
     * LAN discovery responder. Broadcast replies need a multicast lock on
     * many Wi-Fi drivers, otherwise the broadcast frames are filtered out.
     */
    private fun startDiscovery() {
        if (!LanDiscovery.isRunning()) {
            try {
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                multicastLock = wifi.createMulticastLock("anysend").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (_: Exception) {
                // No Wi-Fi service (e.g. Ethernet only) — discovery may still work.
            }
        }
        LanDiscovery.start(this)
        watchNetworkChanges()
    }

    /**
     * Re-join the multicast group whenever the Wi-Fi network changes: a
     * MulticastSocket keeps the interface from the moment it joined, so after
     * a network switch (or hotspot on/off) discovery would stay dead until the
     * app restarted.
     */
    private fun watchNetworkChanges() {
        if (networkCallback != null) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = scheduleDiscoveryRestart()
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) =
                scheduleDiscoveryRestart()
            override fun onLost(network: Network) = scheduleDiscoveryRestart()
        }
        try {
            cm.registerNetworkCallback(request, cb)
            networkCallback = cb
        } catch (e: Exception) {
            Log.w(TAG, "registerNetworkCallback failed", e)
        }
    }

    private fun scheduleDiscoveryRestart() {
        mainHandler.removeCallbacks(discoveryRestart)
        mainHandler.postDelayed(discoveryRestart, 800)
    }

    private fun restartDiscovery() {
        Log.i(TAG, "Wi-Fi changed, re-joining discovery group")
        LanDiscovery.stop()
        try {
            multicastLock?.release()
        } catch (_: Exception) {}
        multicastLock = null
        startDiscovery()
    }

    private fun startLocalSendServer(intent: Intent?) {
        val prefs = getSharedPreferences("tslsb", MODE_PRIVATE)
        val requested = intent?.getStringExtra(EXTRA_NETWORK_MODE)
            ?: prefs.getString(KEY_MODE, null)
            ?: MODE_TAILSCALE
        if (server != null && currentMode == requested) return
        // Mode switch (or fresh start): drop any previous server first.
        server?.stop()
        server = null
        currentMode = requested
        prefs.edit().putString(KEY_MODE, requested).apply()

        scope.launch {
            val layers = mutableListOf<NetworkLayer>()
            // Tailscale layer when tsnet can be brought up. A restarted
            // process has no tsnet: re-login with the saved key first.
            if (requested != MODE_DIRECT) {
                val key = prefs.getString("auth_key", "").orEmpty()
                if (!TailscaleManager.isStarted() && key.isNotEmpty()) {
                    TailscaleManager.login(this@BridgeService, key)
                }
                if (TailscaleManager.isStarted()) layers.add(TailscaleNetworkLayer())
            }
            // LAN layer always — LAN-discovered peers reach us over Wi-Fi.
            layers.add(DirectNetworkLayer())
            val self = DeviceInfo(
                alias = DeviceName.get(this@BridgeService),
                deviceModel = Build.MODEL,
                deviceType = LocalSendConst.DEVICE_TYPE_MOBILE,
                fingerprint = AppActions.deviceFingerprint(this@BridgeService)
            )
            val srv = LocalSendServer(this@BridgeService, self, layers)
            server = srv
            setupSmsRelay()
            srv.start()
        }
    }

    /** Enable the SMS relay when the user has granted the SMS permissions. */
    private fun setupSmsRelay() {
        val srv = server ?: return
        val repo = SmsRepository(this)
        if (!repo.canRead() && !repo.canSend()) return
        if (smsRelay == null) {
            smsRelay = SmsRelay(this)
            smsReceiver = SmsReceiver { msg -> smsRelay?.pushNewMessage(msg) }
            ContextCompat.registerReceiver(
                this, smsReceiver!!,
                IntentFilter(android.provider.Telephony.Sms.Intents.SMS_RECEIVED_ACTION),
                ContextCompat.RECEIVER_EXPORTED
            )
        }
        srv.smsRelay = smsRelay
    }

    private fun buildNotification(): Notification {
        val pi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, App.CHANNEL_ID_FOREGROUND)
            .setContentTitle("TS LocalSend")
            .setContentText("正在等待接收文件")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        scope.cancel()
        mainHandler.removeCallbacks(discoveryRestart)
        networkCallback?.let {
            try {
                (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
                    ?.unregisterNetworkCallback(it)
            } catch (_: Exception) {}
        }
        networkCallback = null
        LanDiscovery.stop()
        try {
            multicastLock?.release()
        } catch (_: Exception) {}
        multicastLock = null
        smsReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        smsReceiver = null
        smsRelay = null
        server?.stop()
        server = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "BridgeService"
        private const val NOTIFICATION_ID = 1001
        const val EXTRA_NETWORK_MODE = "network_mode"
        const val MODE_TAILSCALE = "tailscale"
        const val MODE_DIRECT = "direct"
        const val KEY_MODE = "network_mode"
    }
}
