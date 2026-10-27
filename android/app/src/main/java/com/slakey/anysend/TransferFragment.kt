package com.slakey.anysend

import android.app.AlertDialog
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import com.slakey.anysend.bridge.TailscaleManager
import com.slakey.anysend.remote.RemoteMacActivity
import kotlinx.coroutines.launch
import java.io.File

/** Transfer tab: LocalSend-style send hero + receive status. Peers live in the devices tab. */
class TransferFragment : Fragment() {

    private lateinit var tvStatus: TextView
    private lateinit var tvLocalIp: TextView

    private val pickFile =
        registerForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
            uri ?: return@registerForActivityResult
            val type = requireContext().contentResolver.getType(uri) ?: "*/*"
            val send = Intent(requireContext(), ShareActivity::class.java).apply {
                action = Intent.ACTION_SEND
                setType(type)
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(send)
        }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        return inflater.inflate(R.layout.fragment_transfer, container, false)
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        tvStatus = view.findViewById(R.id.tvStatus)
        tvLocalIp = view.findViewById(R.id.tvLocalIp)

        view.findViewById<View>(R.id.btnSendFile).setOnClickListener {
            pickFile.launch("*/*")
        }
        view.findViewById<View>(R.id.btnSendText).setOnClickListener {
            showTextDialog()
        }
        view.findViewById<View>(R.id.btnSendClipboard).setOnClickListener {
            sendClipboard()
        }
        view.findViewById<View>(R.id.btnRemoteMac).setOnClickListener {
            showRemoteMacDialog()
        }
    }

    /** Multi-line text input; the text becomes a UTF-8 .txt in the send flow. */
    private fun showTextDialog() {
        val context = requireContext()
        val input = EditText(context).apply {
            hint = "输入要发送的文字"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            gravity = Gravity.TOP or Gravity.START
            minLines = 6
            maxLines = 12
            setPadding(48, 24, 48, 24)
        }
        val scroll = ScrollView(context).apply { addView(input) }

        val dialog = AlertDialog.Builder(context)
            .setTitle("发送文字")
            .setView(scroll)
            .setNegativeButton("取消", null)
            .setPositiveButton("发送", null)
            .create()

        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val text = input.text.toString()
                if (text.isBlank()) {
                    Toast.makeText(context, "请输入文字内容", Toast.LENGTH_SHORT).show()
                    return@setOnClickListener
                }
                val file = AppActions.writeOutgoingText(context, text)
                if (file == null) {
                    Toast.makeText(context, "写入临时文件失败", Toast.LENGTH_SHORT).show()
                    return@setOnClickListener
                }
                dialog.dismiss()
                startSendFile(file)
            }
        }
        dialog.show()
    }

    /** Send the system clipboard as a .txt file (guarded against huge payloads). */
    private fun sendClipboard() {
        val context = requireContext()
        val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = manager.primaryClip
        val text = if (clip != null && clip.itemCount > 0) {
            clip.getItemAt(0).coerceToText(context).toString()
        } else {
            ""
        }
        if (text.isBlank()) {
            Toast.makeText(context, "剪贴板为空", Toast.LENGTH_SHORT).show()
            return
        }
        if (text.toByteArray(Charsets.UTF_8).size > MAX_CLIP_BYTES) {
            Toast.makeText(context, "内容过长，请粘贴为文件", Toast.LENGTH_SHORT).show()
            return
        }
        val file = AppActions.writeOutgoingText(context, text)
        if (file == null) {
            Toast.makeText(context, "写入临时文件失败", Toast.LENGTH_SHORT).show()
            return
        }
        startSendFile(file)
    }

    /** Hand a local .txt to the existing share/receiver-picking flow. */
    private fun startSendFile(file: File) {
        val context = requireContext()
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file
        )
        val send = Intent(context, ShareActivity::class.java).apply {
            action = Intent.ACTION_SEND
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(send)
    }

    /** Host + PIN dialog; online Tailscale peers can be picked with one tap. */
    private fun showRemoteMacDialog() {
        val context = requireContext()
        val prefs = context.getSharedPreferences("remote_mac", android.content.Context.MODE_PRIVATE)
        val density = resources.displayMetrics.density
        fun dp(value: Int): Int = (value * density).toInt()

        val host = EditText(context).apply {
            hint = "Mac 的 IP 或 Tailscale 地址"
            inputType = InputType.TYPE_CLASS_TEXT
            setText(prefs.getString("host", ""))
            setSingleLine()
        }
        val pin = EditText(context).apply {
            hint = "访问 PIN（Mac 端未设置可留空）"
            inputType = InputType.TYPE_CLASS_TEXT
            setText(prefs.getString("pin", ""))
            setSingleLine()
        }
        val peerPicker = TextView(context).apply {
            text = "从在线设备中选择"
            setTextColor(context.getColor(R.color.brand_primary))
            setPadding(0, dp(12), 0, 0)
        }

        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), dp(4))
            addView(host)
            addView(pin)
            addView(peerPicker)
        }
        val scroll = ScrollView(context).apply { addView(column) }

        val dialog = AlertDialog.Builder(context)
            .setTitle("远程控制电脑")
            .setView(scroll)
            .setNegativeButton("取消", null)
            .setPositiveButton("连接") { _, _ ->
                val target = host.text.toString().trim()
                if (target.isEmpty()) {
                    Toast.makeText(context, "请填写 Mac 地址", Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                val code = pin.text.toString()
                prefs.edit().putString("host", target).putString("pin", code).apply()
                startActivity(RemoteMacActivity.intent(context, target, code))
            }
            .create()

        peerPicker.setOnClickListener {
            viewLifecycleOwner.lifecycleScope.launch {
                val peers = runCatching { TailscaleManager.getPeers() }.getOrDefault(emptyList())
                if (peers.isEmpty()) {
                    Toast.makeText(context, "Tailscale 未连接或没有在线设备", Toast.LENGTH_SHORT).show()
                    return@launch
                }
                val online = peers.filter { it.online }
                val labels = online.map { "${it.hostName}  ·  ${it.tailscaleIP}" }.toTypedArray()
                AlertDialog.Builder(context)
                    .setTitle("选择设备")
                    .setItems(labels) { _, index ->
                        host.setText(online[index].tailscaleIP)
                    }
                    .show()
            }
        }

        dialog.show()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        tvLocalIp.text = "本机 IP：${AppActions.getLocalIpAddress() ?: "--"} · 端口 53317"
        viewLifecycleOwner.lifecycleScope.launch {
            tvStatus.text = if (TailscaleManager.isStarted()) "Tailscale 已连接，可跨网段接收"
            else "局域网接收就绪"
        }
    }

    private companion object {
        const val MAX_CLIP_BYTES = 32 * 1024
    }
}
