package com.slakey.anysend

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.ListView
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.slakey.anysend.bridge.TailscaleManager
import com.slakey.anysend.history.TransferHistory
import com.slakey.anysend.protocol.DeviceInfo
import com.slakey.anysend.protocol.DirectNetworkLayer
import com.slakey.anysend.protocol.LanDiscovery
import com.slakey.anysend.protocol.LocalSendConst
import com.slakey.anysend.protocol.LocalSendSender
import com.slakey.anysend.protocol.NetworkLayer
import com.slakey.anysend.protocol.TailscaleNetworkLayer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * Launched when the user shares a file to this app. Supports two ways to
 * pick a receiver:
 *  - Direct IP input (Direct LAN mode, no Tailscale needed)
 *  - Selecting an online Tailscale peer
 */
class ShareActivity : AppCompatActivity() {

    private lateinit var tvFile: TextView
    private lateinit var etTargetIp: EditText
    private lateinit var btnSendDirect: Button
    private lateinit var lvPeers: ListView
    private lateinit var btnCancel: Button
    private lateinit var progressBar: ProgressBar
    private lateinit var tvProgress: TextView

    private var sharedFiles: List<File> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_share)

        tvFile = findViewById(R.id.tvFile)
        etTargetIp = findViewById(R.id.etTargetIp)
        btnSendDirect = findViewById(R.id.btnSendDirect)
        lvPeers = findViewById(R.id.lvPeers)
        btnCancel = findViewById(R.id.btnCancel)
        progressBar = findViewById(R.id.progressBar)
        tvProgress = findViewById(R.id.tvProgress)

        btnCancel.setOnClickListener { finish() }
        btnSendDirect.setOnClickListener {
            val ip = etTargetIp.text.toString().trim()
            if (ip.isEmpty()) {
                Toast.makeText(this, "请输入接收方 IP", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            sendToIp(ip, DirectNetworkLayer(), ip)
        }

        // Extract shared files from the intent
        sharedFiles = resolveSharedFiles(intent)
        if (sharedFiles.isEmpty()) {
            Toast.makeText(this, "未找到可分享的文件", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        renderFiles()

        loadPeers()
    }

    /** A second share while open should replace the pending payload. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val files = resolveSharedFiles(intent)
        if (files.isEmpty()) return
        sharedFiles = files
        renderFiles()
        progressBar.progress = 0
        progressBar.visibility = android.view.View.GONE
        tvProgress.text = ""
        btnCancel.text = "取消"
        btnCancel.setOnClickListener { finish() }
        loadPeers()
    }

    /**
     * Files from EXTRA_STREAM, or plain text from EXTRA_TEXT written to a
     * UTF-8 .txt so text and files share the same upload path.
     */
    private fun resolveSharedFiles(intent: Intent?): List<File> {
        if (intent == null) return emptyList()
        val files = extractFiles(intent).toMutableList()
        if (files.isEmpty()) {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            if (!text.isNullOrBlank()) {
                AppActions.writeOutgoingText(this, text)?.let { files.add(it) }
            }
        }
        return files
    }

    private fun renderFiles() {
        tvFile.text =
            "待发送：${sharedFiles.joinToString { it.name }} (${sharedFiles.sumOf { it.length() / 1024 }} KB)"
    }

    private fun extractFiles(intent: Intent): List<File> {
        val files = mutableListOf<File>()
        val action = intent.action
        val type = intent.type

        if (action == Intent.ACTION_SEND) {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uri ->
                copyToCache(uri)?.let { files.add(it) }
            }
        } else if (action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.forEach { uri ->
                copyToCache(uri)?.let { files.add(it) }
            }
        }
        return files
    }

    private fun copyToCache(uri: Uri): File? {
        return try {
            val input = contentResolver.openInputStream(uri) ?: return null
            val name = queryName(uri) ?: "shared_${UUID.randomUUID()}"
            val outFile = File(cacheDir, name)
            FileOutputStream(outFile).use { fos ->
                input.copyTo(fos)
            }
            input.close()
            outFile
        } catch (e: Exception) {
            null
        }
    }

    private fun queryName(uri: Uri): String? {
        return contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) cursor.getString(idx) else null
            } else null
        }
    }

    /** A selectable share destination: Tailscale peer or LAN device. */
    private data class Target(val name: String, val ip: String, val isTailscale: Boolean)

    private fun loadPeers() {
        lifecycleScope.launch {
            val tsPeers = TailscaleManager.getPeers().filter { it.online }.map {
                Target(it.hostName, it.tailscaleIP, isTailscale = true)
            }
            val lanPeers = withContext(Dispatchers.IO) {
                LanDiscovery.scan(applicationContext).map {
                    Target(it.name, it.ip, isTailscale = false)
                }
            }
            val targets = tsPeers + lanPeers
            if (targets.isEmpty()) {
                // Still show a hint that direct IP is available
                val adapter = ArrayAdapter(
                    this@ShareActivity,
                    android.R.layout.simple_list_item_1,
                    listOf("（未发现设备，可使用上方直连模式输入 IP）")
                )
                lvPeers.adapter = adapter
                return@launch
            }
            val adapter = ArrayAdapter(
                this@ShareActivity,
                android.R.layout.simple_list_item_1,
                targets.map { if (it.isTailscale) "${it.name} (${it.ip})" else "${it.name} (${it.ip} · 局域网)" }
            )
            lvPeers.adapter = adapter
            lvPeers.setOnItemClickListener { _, _, position, _ ->
                val t = targets[position]
                val network = if (t.isTailscale || t.ip.startsWith("100.")) {
                    TailscaleNetworkLayer()
                } else {
                    DirectNetworkLayer()
                }
                sendToIp(t.ip, network, t.name)
            }
        }
    }

    private fun sendToIp(ip: String, network: NetworkLayer, peerName: String) {
        val self = DeviceInfo(
            alias = DeviceName.get(this),
            deviceModel = android.os.Build.MODEL,
            deviceType = LocalSendConst.DEVICE_TYPE_MOBILE,
            fingerprint = AppActions.deviceFingerprint(this)
        )
        lifecycleScope.launch {
            progressBar.visibility = android.view.View.VISIBLE
            tvProgress.text = "正在发送到 $ip..."
            val sender = LocalSendSender(ip, self, network)
            val receiver = withContext(Dispatchers.IO) { sender.register() }
            if (receiver == null) {
                tvProgress.text = "无法连接到 $ip"
                return@launch
            }
            val resp = withContext(Dispatchers.IO) { sender.sendRequest(sharedFiles) }
            if (resp == null) {
                tvProgress.text = "发送请求被拒绝"
                return@launch
            }
            val acceptedFiles = resp.response.files.filter { it.value == "accept" }
            if (acceptedFiles.isEmpty()) {
                tvProgress.text = "所有文件被拒绝"
                return@launch
            }
            val totalBytes = acceptedFiles.keys.sumOf { fileId ->
                resp.fileIdToFile[fileId]?.length() ?: 0L
            }
            var sentBytes = 0L
            var allOk = true
            for ((fileId, _) in acceptedFiles) {
                val file = resp.fileIdToFile[fileId] ?: continue
                val ok = withContext(Dispatchers.IO) {
                    sender.sendFile(resp.response.sessionId, fileId, file) { sent, total ->
                        runOnUiThread {
                            val overall = sentBytes + sent
                            progressBar.progress = if (totalBytes > 0) (overall * 100 / totalBytes).toInt() else 0
                            tvProgress.text = "发送中 ${overall / 1024}/${totalBytes / 1024} KB"
                        }
                    }
                }
                if (!ok) {
                    allOk = false
                    break
                }
                sentBytes += file.length()
            }
            if (allOk) {
                // Record every delivered file in the transfer history.
                acceptedFiles.keys.forEach { fileId ->
                    val file = resp.fileIdToFile[fileId] ?: return@forEach
                    TransferHistory.add(
                        this@ShareActivity, "send",
                        peerName.ifBlank { ip },
                        file.name, file.length(), file.absolutePath
                    )
                }
                tvProgress.text = "发送完成（${acceptedFiles.size} 个文件）"
                Toast.makeText(this@ShareActivity, "发送完成", Toast.LENGTH_SHORT).show()
            } else {
                tvProgress.text = "发送失败"
            }
            btnCancel.text = "关闭"
            btnCancel.setOnClickListener { finish() }
        }
    }
}
