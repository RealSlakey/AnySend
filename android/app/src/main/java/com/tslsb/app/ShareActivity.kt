package com.tslsb.app

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
import com.tslsb.app.bridge.TailscaleManager
import com.tslsb.app.protocol.DeviceInfo
import com.tslsb.app.protocol.DirectNetworkLayer
import com.tslsb.app.protocol.LocalSendConst
import com.tslsb.app.protocol.LocalSendSender
import com.tslsb.app.protocol.NetworkLayer
import com.tslsb.app.protocol.TailscaleNetworkLayer
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
    private var selectedPeer: TailscaleManager.PeerInfo? = null

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
            sendToIp(ip, DirectNetworkLayer())
        }

        // Extract shared files from the intent
        sharedFiles = extractFiles(intent)
        if (sharedFiles.isEmpty()) {
            Toast.makeText(this, "未找到可分享的文件", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        tvFile.text = "待发送：${sharedFiles.joinToString { it.name }} (${sharedFiles.sumOf { it.length() / 1024 }} KB)"

        loadPeers()
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

    private fun loadPeers() {
        lifecycleScope.launch {
            val peers = TailscaleManager.getPeers().filter { it.online }
            if (peers.isEmpty()) {
                // Still show a hint that direct IP is available
                val adapter = ArrayAdapter(
                    this@ShareActivity,
                    android.R.layout.simple_list_item_1,
                    listOf("（请使用上方直连模式输入 IP）")
                )
                lvPeers.adapter = adapter
                return@launch
            }
            val adapter = ArrayAdapter(
                this@ShareActivity,
                android.R.layout.simple_list_item_1,
                peers.map { "${it.hostName} (${it.tailscaleIP})" }
            )
            lvPeers.adapter = adapter
            lvPeers.setOnItemClickListener { _, _, position, _ ->
                selectedPeer = peers[position]
                sendToIp(peers[position].tailscaleIP, TailscaleNetworkLayer())
            }
        }
    }

    private fun sendToIp(ip: String, network: NetworkLayer) {
        val self = DeviceInfo(
            alias = android.os.Build.MODEL,
            deviceModel = android.os.Build.MODEL,
            deviceType = LocalSendConst.DEVICE_TYPE_MOBILE,
            fingerprint = UUID.randomUUID().toString()
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
