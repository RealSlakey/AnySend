package com.slakey.anysend

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID_FOREGROUND,
                "后台连接",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持 Tailscale 连接和文件接收服务运行"
            }
            val transferChannel = NotificationChannel(
                CHANNEL_ID_TRANSFER,
                "文件传输",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "文件传输进度与结果通知"
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
            nm.createNotificationChannel(transferChannel)
        }
    }

    companion object {
        const val CHANNEL_ID_FOREGROUND = "foreground"
        const val CHANNEL_ID_TRANSFER = "transfer"
    }
}
