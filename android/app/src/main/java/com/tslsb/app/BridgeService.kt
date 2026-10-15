package com.tslsb.app

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.tslsb.app.protocol.DirectNetworkLayer
import com.tslsb.app.protocol.DeviceInfo
import com.tslsb.app.protocol.LocalSendConst
import com.tslsb.app.protocol.LocalSendServer
import com.tslsb.app.protocol.NetworkLayer
import com.tslsb.app.protocol.TailscaleNetworkLayer
import java.util.UUID

/**
 * Foreground service that keeps the LocalSend receiver server running while
 * the app is in the background. Supports both Tailscale mode and Direct LAN
 * mode (chosen via [EXTRA_NETWORK_MODE]).
 */
class BridgeService : Service() {

    private var server: LocalSendServer? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        startLocalSendServer(intent)
        return START_STICKY
    }

    private fun startLocalSendServer(intent: Intent?) {
        if (server != null) return
        val mode = intent?.getStringExtra(EXTRA_NETWORK_MODE) ?: MODE_TAILSCALE
        val network: NetworkLayer = if (mode == MODE_DIRECT) {
            DirectNetworkLayer()
        } else {
            TailscaleNetworkLayer()
        }
        val self = DeviceInfo(
            alias = Build.MODEL,
            deviceModel = Build.MODEL,
            deviceType = LocalSendConst.DEVICE_TYPE_MOBILE,
            fingerprint = UUID.randomUUID().toString()
        )
        server = LocalSendServer(this, self, network).apply { start() }
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
        server?.stop()
        server = null
        super.onDestroy()
    }

    companion object {
        private const val NOTIFICATION_ID = 1001
        const val EXTRA_NETWORK_MODE = "network_mode"
        const val MODE_TAILSCALE = "tailscale"
        const val MODE_DIRECT = "direct"
    }
}
