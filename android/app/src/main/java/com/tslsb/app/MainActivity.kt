package com.tslsb.app

import android.content.Intent
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.tslsb.app.bridge.TailscaleManager
import kotlinx.coroutines.launch
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : AppCompatActivity() {

    private lateinit var etAuthKey: EditText
    private lateinit var btnLogin: Button
    private lateinit var tvStatus: TextView
    private lateinit var tvPeers: TextView
    private lateinit var btnStartDirect: Button
    private lateinit var tvLocalIp: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        etAuthKey = findViewById(R.id.etAuthKey)
        btnLogin = findViewById(R.id.btnLogin)
        tvStatus = findViewById(R.id.tvStatus)
        tvPeers = findViewById(R.id.tvPeers)
        btnStartDirect = findViewById(R.id.btnStartDirect)
        tvLocalIp = findViewById(R.id.tvLocalIp)

        btnLogin.setOnClickListener {
            val key = etAuthKey.text.toString().trim()
            loginTailscale(key)
        }
        btnStartDirect.setOnClickListener {
            startDirectServer()
        }

        // Restore saved auth key
        val prefs = getSharedPreferences("tslsb", MODE_PRIVATE)
        etAuthKey.setText(prefs.getString("auth_key", ""))

        tvLocalIp.text = "本机 IP：${getLocalIpAddress() ?: "--"}"
        refreshStatus()
    }

    private fun loginTailscale(authKey: String) {
        if (authKey.isEmpty()) {
            Toast.makeText(this, "请输入 Tailscale Auth Key", Toast.LENGTH_SHORT).show()
            return
        }
        getSharedPreferences("tslsb", MODE_PRIVATE)
            .edit().putString("auth_key", authKey).apply()

        lifecycleScope.launch {
            tvStatus.text = "正在连接 Tailscale..."
            val ok = TailscaleManager.login(this@MainActivity, authKey)
            if (ok) {
                tvStatus.text = "Tailscale 已连接"
                refreshPeers()
                startBridgeService(BridgeService.MODE_TAILSCALE)
            } else {
                tvStatus.text = "Tailscale 连接失败（可改用直连模式）"
            }
        }
    }

    private fun startDirectServer() {
        val ip = getLocalIpAddress()
        if (ip == null) {
            Toast.makeText(this, "未检测到局域网 IP，请检查 Wi-Fi 连接", Toast.LENGTH_SHORT).show()
            return
        }
        startBridgeService(BridgeService.MODE_DIRECT)
        tvStatus.text = "直连模式已启动，监听 53317 端口"
        Toast.makeText(this, "接收服务已启动（直连模式）", Toast.LENGTH_SHORT).show()
    }

    private fun refreshStatus() {
        lifecycleScope.launch {
            if (TailscaleManager.isStarted()) {
                tvStatus.text = "Tailscale 已连接"
                refreshPeers()
            } else {
                tvStatus.text = "Tailscale 未连接"
            }
        }
    }

    private fun refreshPeers() {
        lifecycleScope.launch {
            val peers = TailscaleManager.getPeers()
            if (peers.isEmpty()) {
                tvPeers.text = "暂无在线设备"
            } else {
                tvPeers.text = peers.joinToString("\n") { "${it.hostName} (${it.tailscaleIP})" }
            }
        }
    }

    private fun startBridgeService(mode: String) {
        val intent = Intent(this, BridgeService::class.java)
        intent.putExtra(BridgeService.EXTRA_NETWORK_MODE, mode)
        startForegroundService(intent)
    }

    /** Get the device's non-loopback IPv4 address on the Wi-Fi/LAN. */
    private fun getLocalIpAddress(): String? {
        return try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            for (intf in interfaces) {
                if (!intf.isUp || intf.isLoopback) continue
                for (addr in intf.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        return addr.hostAddress
                    }
                }
            }
            null
        } catch (e: Exception) {
            null
        }
    }
}
