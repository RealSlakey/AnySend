package com.slakey.anysend

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import com.slakey.anysend.history.HistoryStats
import com.slakey.anysend.history.TransferHistory
import com.slakey.anysend.history.TransferRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * History tab: every completed transfer, with full local-file management.
 *
 *  - tap a row        -> open the file (in selection mode: toggle selection)
 *  - long-press a row -> open / save a copy / delete record / record + file
 *  - 选择              -> multi-select mode with batch delete
 *  - 清空              -> clear records only, or records + received files
 *  - stats row        -> disk usage, stale records, leftover files + cleanup
 *
 * Records are kept forever, so this list is the single source of truth for
 * everything the app has written to disk.
 */
class HistoryFragment : Fragment() {

    private var records: List<TransferRecord> = emptyList()
    private val selected = linkedSetOf<String>()
    private var selectionMode = false
    private val timeFmt = SimpleDateFormat("MM-dd HH:mm", Locale.getDefault())

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        return inflater.inflate(R.layout.fragment_history, container, false)
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        view.findViewById<TextView>(R.id.btnSelect).setOnClickListener { enterSelection() }
        view.findViewById<TextView>(R.id.btnCancel).setOnClickListener { exitSelection() }
        view.findViewById<TextView>(R.id.btnDelete).setOnClickListener { confirmDeleteSelected() }
        view.findViewById<TextView>(R.id.btnClear).setOnClickListener { confirmClear() }
        view.findViewById<TextView>(R.id.btnCleanup).setOnClickListener { runCleanup() }
        view.findViewById<ListView>(R.id.lvHistory).setOnItemClickListener { _, _, position, _ ->
            val r = records.getOrNull(position) ?: return@setOnItemClickListener
            if (selectionMode) toggleSelect(r.id) else openRecord(r)
        }
        view.findViewById<ListView>(R.id.lvHistory).setOnItemLongClickListener { _, _, position, _ ->
            val r = records.getOrNull(position) ?: return@setOnItemLongClickListener true
            if (selectionMode) toggleSelect(r.id) else confirmActions(r)
            true
        }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        val view = view ?: return
        records = TransferHistory.all(requireContext())
        // Keep only selections that still exist; drop the mode when empty.
        selected.retainAll(records.map { it.id }.toSet())
        if (records.isEmpty()) {
            selectionMode = false
            selected.clear()
        }
        view.findViewById<TextView>(R.id.tvEmpty).visibility =
            if (records.isEmpty()) View.VISIBLE else View.GONE
        view.findViewById<View>(R.id.layoutStats).visibility =
            if (records.isEmpty()) View.GONE else View.VISIBLE
        view.findViewById<ListView>(R.id.lvHistory).adapter = buildAdapter()
        applyHeader()
        refreshStats()
    }

    private fun buildAdapter(): ArrayAdapter<TransferRecord> {
        return object : ArrayAdapter<TransferRecord>(
            requireContext(), R.layout.history_row, R.id.tvName, records
        ) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val v = convertView ?: layoutInflater.inflate(R.layout.history_row, parent, false)
                val r = records[position]
                val receive = r.direction == "receive"
                val checked = selected.contains(r.id)
                val check = v.findViewById<TextView>(R.id.tvCheck)
                check.visibility = if (selectionMode) View.VISIBLE else View.GONE
                check.text = if (checked) "✓" else ""
                check.background = ContextCompat.getDrawable(
                    requireContext(), if (checked) R.drawable.bg_check_on else R.drawable.bg_check_off
                )
                val badge = v.findViewById<TextView>(R.id.tvBadge)
                badge.text = if (receive) "收" else "发"
                badge.background = ContextCompat.getDrawable(
                    requireContext(),
                    if (receive) R.drawable.bg_badge_receive else R.drawable.bg_badge_send
                )
                v.findViewById<TextView>(R.id.tvName).text = r.fileName
                v.findViewById<TextView>(R.id.tvMeta).text =
                    "${if (receive) "来自" else "发给"} ${r.peer} · ${formatSize(r.size)}"
                v.findViewById<TextView>(R.id.tvTime).text = timeFmt.format(Date(r.time))
                return v
            }
        }
    }

    // ---- selection mode -------------------------------------------------

    private fun enterSelection() {
        selectionMode = true
        selected.clear()
        applyHeader()
        (view?.findViewById<ListView>(R.id.lvHistory)?.adapter as? ArrayAdapter<*>)?.notifyDataSetChanged()
    }

    private fun exitSelection() {
        selectionMode = false
        selected.clear()
        applyHeader()
        (view?.findViewById<ListView>(R.id.lvHistory)?.adapter as? ArrayAdapter<*>)?.notifyDataSetChanged()
    }

    private fun toggleSelect(id: String) {
        if (!selected.remove(id)) selected.add(id)
        applyHeader()
        (view?.findViewById<ListView>(R.id.lvHistory)?.adapter as? ArrayAdapter<*>)?.notifyDataSetChanged()
    }

    private fun applyHeader() {
        val view = view ?: return
        view.findViewById<TextView>(R.id.tvTitle).text =
            if (selectionMode) "已选 ${selected.size} 项" else "历史"
        view.findViewById<TextView>(R.id.btnSelect).visibility =
            if (selectionMode) View.GONE else View.VISIBLE
        view.findViewById<TextView>(R.id.btnClear).visibility =
            if (selectionMode) View.GONE else View.VISIBLE
        view.findViewById<TextView>(R.id.btnCancel).visibility =
            if (selectionMode) View.VISIBLE else View.GONE
        val delete = view.findViewById<TextView>(R.id.btnDelete)
        delete.visibility = if (selectionMode) View.VISIBLE else View.GONE
        delete.alpha = if (selected.isEmpty()) 0.4f else 1f
    }

    // ---- stats ----------------------------------------------------------

    private fun refreshStats() {
        val view = view ?: return
        val snapshot = records
        if (snapshot.isEmpty()) return
        view.findViewById<TextView>(R.id.tvStats).text = "正在统计…"
        view.findViewById<TextView>(R.id.btnCleanup).visibility = View.GONE
        val ctx = requireContext().applicationContext
        viewLifecycleOwner.lifecycleScope.launch {
            val stats = withContext(Dispatchers.IO) { TransferHistory.stats(ctx, snapshot) }
            val v = view ?: return@launch
            v.findViewById<TextView>(R.id.tvStats).text = statsLine(stats)
            v.findViewById<TextView>(R.id.btnCleanup).visibility =
                if (stats.lostCount > 0 || stats.orphanCount > 0) View.VISIBLE else View.GONE
        }
    }

    private fun statsLine(s: HistoryStats): String {
        val sb = StringBuilder("已接收文件占用 ${formatSize(s.usedBytes)}")
        if (s.lostCount > 0) sb.append(" · ${s.lostCount} 条记录的文件已丢失")
        if (s.orphanCount > 0) sb.append(" · ${s.orphanCount} 个文件无记录")
        return sb.toString()
    }

    private fun runCleanup() {
        val ctx = requireContext().applicationContext
        viewLifecycleOwner.lifecycleScope.launch {
            val res = withContext(Dispatchers.IO) { TransferHistory.cleanup(ctx) }
            refresh()
            toast("已清理 ${res.removedRecords} 条失效记录、${res.removedFiles} 个无记录文件")
        }
    }

    // ---- per-row actions ------------------------------------------------

    private fun confirmActions(r: TransferRecord) {
        val hasFile = TransferHistory.isDeletable(requireContext(), r)
        val items = mutableListOf("打开")
        if (TransferHistory.needsExport(requireContext(), r)) items.add("保存到文件管理")
        items.add("删除记录")
        if (hasFile) items.add("删除记录并删除文件")
        AlertDialog.Builder(requireContext())
            .setTitle(r.fileName)
            .setItems(items.toTypedArray()) { _, which ->
                when (items[which]) {
                    "打开" -> openRecord(r)
                    "保存到文件管理" -> exportRecord(r)
                    "删除记录" -> {
                        TransferHistory.removeMany(requireContext(), listOf(r.id), false)
                        refresh()
                    }
                    else -> {
                        TransferHistory.removeMany(requireContext(), listOf(r.id), true)
                        refresh()
                    }
                }
            }
            .show()
    }

    private fun openRecord(r: TransferRecord) {
        try {
            val mime = TransferHistory.mimeOf(r.fileName)
            val uri: Uri = if (r.path.startsWith("content://")) {
                Uri.parse(r.path)
            } else {
                val file = File(r.path)
                if (!file.exists()) {
                    toast("文件已不存在")
                    return
                }
                FileProvider.getUriForFile(
                    requireContext(), "${requireContext().packageName}.fileprovider", file
                )
            }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
        } catch (e: Exception) {
            // FileProvider cannot expose the cache dir of a send record.
            toast("无法打开该文件")
        }
    }

    private fun exportRecord(r: TransferRecord) {
        val ctx = requireContext().applicationContext
        viewLifecycleOwner.lifecycleScope.launch {
            val ok = withContext(Dispatchers.IO) { TransferHistory.exportToDownloads(ctx, r) }
            toast(if (ok) "已保存到 Downloads/AnySend" else "保存失败")
        }
    }

    // ---- clearing -------------------------------------------------------

    private fun confirmDeleteSelected() {
        val count = selected.size
        if (count == 0) {
            toast("请先选择要删除的记录")
            return
        }
        val ctx = requireContext()
        val own = records.count { selected.contains(it.id) && TransferHistory.isDeletable(ctx, it) }
        val ids = selected.toList()
        val builder = AlertDialog.Builder(ctx)
            .setTitle("删除所选 $count 条记录")
            .setMessage(
                if (own > 0) "其中 $own 条对应本机文件，是否一并删除这些文件？"
                else "所选记录没有本机文件，仅删除记录。"
            )
        if (own > 0) {
            builder
                .setNegativeButton("仅删记录") { _, _ -> doDelete(ids, false) }
                .setPositiveButton("连文件一起删除") { _, _ -> doDelete(ids, true) }
        } else {
            builder
                .setNegativeButton("取消", null)
                .setPositiveButton("删除记录") { _, _ -> doDelete(ids, false) }
        }
        builder.show()
    }

    private fun doDelete(ids: List<String>, deleteFiles: Boolean) {
        TransferHistory.removeMany(requireContext(), ids, deleteFiles)
        exitSelection()
        refresh()
        toast(if (deleteFiles) "记录与文件已删除" else "记录已删除")
    }

    private fun confirmClear() {
        val ctx = requireContext()
        val own = records.count { TransferHistory.isDeletable(ctx, it) }
        val total = records.size
        val builder = AlertDialog.Builder(ctx)
            .setTitle("清空历史")
            .setMessage(
                if (own > 0) "共 $total 条记录，其中 $own 条对应本机文件。是否一并删除这些文件？"
                else "共 $total 条记录，没有本机文件，仅清空记录。"
            )
        if (own > 0) {
            builder
                .setNegativeButton("仅清记录") { _, _ -> doClear(false) }
                .setPositiveButton("连文件一起清空") { _, _ -> doClear(true) }
        } else {
            builder
                .setNegativeButton("取消", null)
                .setPositiveButton("清空记录") { _, _ -> doClear(false) }
        }
        builder.show()
    }

    private fun doClear(deleteFiles: Boolean) {
        TransferHistory.clear(requireContext(), deleteFiles)
        exitSelection()
        refresh()
        toast(if (deleteFiles) "记录与文件已清空" else "记录已清空")
    }

    private fun formatSize(bytes: Long): String = when {
        bytes >= 1024 * 1024 -> String.format(Locale.US, "%.1f MB", bytes / 1048576.0)
        bytes >= 1024 -> "${bytes / 1024} KB"
        else -> "$bytes B"
    }

    private fun toast(msg: String) {
        Toast.makeText(requireContext(), msg, Toast.LENGTH_SHORT).show()
    }
}
