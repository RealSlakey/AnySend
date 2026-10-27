package com.slakey.anysend.history

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.UUID

/** One completed file transfer, shown in the history tab. */
data class TransferRecord(
    val id: String,
    val direction: String, // "send" | "receive"
    val peer: String,
    val fileName: String,
    val size: Long,
    val time: Long,
    val path: String // local file path or content:// Uri
)

/** Disk usage plus how many records/files went stale. */
data class HistoryStats(
    val usedBytes: Long,
    val lostCount: Int,
    val orphanCount: Int,
    val orphanBytes: Long
)

data class CleanupResult(val removedRecords: Int, val removedFiles: Int)

/** Files in the receive folder that no record points at. */
private class OrphanScan(
    val paths: List<String>,
    val files: List<File>,
    val uris: List<Uri>,
    val bytes: Long
)

/**
 * SharedPreferences-backed transfer history, newest first and kept forever —
 * nothing is evicted behind the user's back, so every file this app wrote can
 * still be traced from the list.
 *
 * File ownership rules:
 *  - "receive" files live in Download/AnySend (public) or MediaStore downloads,
 *    both written by this app, so they are safe to delete on request.
 *  - "send" files are the copy this app made in its cache dir before uploading.
 *    A legacy send record may point at the sender's original content:// Uri —
 *    that one is never deleted.
 */
object TransferHistory {
    private const val TAG = "TransferHistory"
    private const val PREFS = "transfer_history"
    private const val KEY = "records"
    private val gson = Gson()

    /** Folder this app receives files into. */
    fun receiveDir(): File = File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        "AnySend"
    )

    @Synchronized
    fun add(
        context: Context,
        direction: String,
        peer: String,
        fileName: String,
        size: Long,
        path: String
    ) {
        val record = TransferRecord(
            id = UUID.randomUUID().toString(),
            direction = direction,
            peer = peer,
            fileName = fileName,
            size = size,
            time = System.currentTimeMillis(),
            path = path
        )
        val all = mutableListOf(record)
        all.addAll(all(context))
        prefs(context).edit().putString(KEY, gson.toJson(all)).apply()
    }

    @Synchronized
    fun all(context: Context): List<TransferRecord> {
        return try {
            val raw = prefs(context).getString(KEY, null) ?: return emptyList()
            val type = object : TypeToken<List<TransferRecord>>() {}.type
            gson.fromJson<List<TransferRecord>>(raw, type) ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** True when [r] backs onto a file this app wrote and may delete. */
    fun isDeletable(context: Context, r: TransferRecord): Boolean {
        val path = r.path
        if (path.startsWith("content://")) {
            // Only MediaStore rows this app inserted are ours to remove.
            val uri = Uri.parse(path)
            return r.direction == "receive" && uri.authority == MediaStore.AUTHORITY &&
                uri.path?.contains("downloads") == true
        }
        val cacheRoot = context.cacheDir.absolutePath + File.separator
        if (path.startsWith(cacheRoot)) {
            return r.direction == "send"
        }
        return r.direction == "receive" && File(path).parentFile?.absolutePath == receiveDir().absolutePath
    }

    /** Files already living in a user-visible folder need no export copy. */
    fun needsExport(context: Context, r: TransferRecord): Boolean {
        if (r.path.startsWith("content://")) return false
        return r.path.startsWith(context.cacheDir.absolutePath + File.separator)
    }

    /** Delete a set of records; [deleteFiles] also removes the app-owned files. */
    @Synchronized
    fun removeMany(context: Context, ids: Collection<String>, deleteFiles: Boolean) {
        val all = all(context)
        if (deleteFiles) {
            for (r in all) {
                if (ids.contains(r.id) && isDeletable(context, r)) deleteFile(context, r)
            }
        }
        val keep = all.filterNot { ids.contains(it.id) }
        prefs(context).edit().putString(KEY, gson.toJson(keep)).apply()
    }

    /** Drop every record; [deleteFiles] also removes the received files. */
    @Synchronized
    fun clear(context: Context, deleteFiles: Boolean) {
        if (deleteFiles) {
            for (r in all(context)) {
                if (isDeletable(context, r)) deleteFile(context, r)
            }
        }
        prefs(context).edit().remove(KEY).apply()
    }

    /** Space usage, plus how many records/files went stale. */
    fun stats(context: Context, records: List<TransferRecord>): HistoryStats {
        var used = 0L
        var lost = 0
        val referenced = HashSet<String>()
        for (r in records) {
            if (r.direction != "receive") {
                // Send records back onto the sender's own file: never probed,
                // never counted, never deleted.
                continue
            }
            referenced.add(r.path)
            if (exists(context, r.path)) used += r.size else lost++
        }
        val orphans = scanOrphans(context, referenced)
        return HistoryStats(used, lost, orphans.paths.size, orphans.bytes)
    }

    /** Drop stale records and delete files no record points at. */
    @Synchronized
    fun cleanup(context: Context): CleanupResult {
        val all = all(context)
        val referenced = HashSet<String>()
        val keep = mutableListOf<TransferRecord>()
        var removedRecords = 0
        for (r in all) {
            if (r.direction != "receive") {
                keep.add(r)
                continue
            }
            if (exists(context, r.path)) {
                referenced.add(r.path)
                keep.add(r)
            } else {
                removedRecords++
            }
        }
        if (removedRecords > 0) {
            prefs(context).edit().putString(KEY, gson.toJson(keep)).apply()
        }
        val orphans = scanOrphans(context, referenced)
        var removedFiles = 0
        for (f in orphans.files) {
            if (f.delete()) removedFiles++
        }
        for (u in orphans.uris) {
            val n = try {
                context.contentResolver.delete(u, null, null)
            } catch (e: Exception) {
                0
            }
            if (n > 0) removedFiles++
        }
        return CleanupResult(removedRecords, removedFiles)
    }

    /** Copy a file this app holds privately into Download/AnySend. */
    fun exportToDownloads(context: Context, r: TransferRecord): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        var created: Uri? = null
        return try {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, r.fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(r.fileName))
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/AnySend")
            }
            val uri = context.contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
            ) ?: return false
            created = uri
            val input = if (r.path.startsWith("content://")) {
                context.contentResolver.openInputStream(Uri.parse(r.path))
            } else {
                FileInputStream(File(r.path))
            } ?: throw IOException("source unreadable")
            input.use { ins ->
                val out = context.contentResolver.openOutputStream(uri)
                    ?: throw IOException("target unwritable")
                out.use { ins.copyTo(it, 64 * 1024) }
            }
            true
        } catch (e: Exception) {
            // Never leave a zero-byte row behind in Downloads.
            created?.let {
                try {
                    context.contentResolver.delete(it, null, null)
                } catch (_: Exception) {
                }
            }
            Log.w(TAG, "export failed for ${r.fileName}", e)
            false
        }
    }

    /** Best-effort mime type for a file name. */
    fun mimeOf(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        val fromExt = if (ext.isNotEmpty()) {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        } else null
        return fromExt ?: "*/*"
    }

    /** Pick a collision-free file in [dir] for [fileName]: "name (1).ext". */
    fun dedupeFile(dir: File, fileName: String): File {
        var candidate = File(dir, fileName)
        if (!candidate.exists()) return candidate
        val dot = fileName.lastIndexOf('.')
        val base = if (dot > 0) fileName.substring(0, dot) else fileName
        val ext = if (dot > 0) fileName.substring(dot) else ""
        var i = 1
        while (candidate.exists()) {
            candidate = File(dir, "$base ($i)$ext")
            i++
        }
        return candidate
    }

    private fun deleteFile(context: Context, r: TransferRecord) {
        try {
            if (r.path.startsWith("content://")) {
                context.contentResolver.delete(Uri.parse(r.path), null, null)
            } else {
                File(r.path).delete()
            }
        } catch (e: Exception) {
            // Best effort: the record is removed regardless.
        }
    }

    private fun exists(context: Context, path: String): Boolean {
        if (path.startsWith("content://")) {
            return try {
                context.contentResolver.query(
                    Uri.parse(path), arrayOf(MediaStore.MediaColumns._ID), null, null, null
                )?.use { it.count > 0 } ?: false
            } catch (e: Exception) {
                true // Unreadable: assume it is still there rather than drop the record.
            }
        }
        return File(path).exists()
    }

    /**
     * Files in the receive store that [referenced] does not account for.
     * Walks the raw folder (legacy storage) and the MediaStore rows this app
     * contributed (scoped storage), matching on the exact path/Uri we recorded.
     */
    private fun scanOrphans(context: Context, referenced: Set<String>): OrphanScan {
        val paths = mutableListOf<String>()
        val files = mutableListOf<File>()
        val uris = mutableListOf<Uri>()
        var bytes = 0L

        val listed = try {
            receiveDir().listFiles()
        } catch (e: Exception) {
            null
        }
        for (f in listed ?: emptyArray()) {
            if (!f.isFile || referenced.contains(f.absolutePath)) continue
            paths.add(f.absolutePath)
            files.add(f)
            bytes += f.length()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.SIZE
            )
            val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
            val args = arrayOf(Environment.DIRECTORY_DOWNLOADS + "/AnySend%")
            try {
                context.contentResolver.query(collection, projection, selection, args, null)
                    ?.use { c ->
                        while (c.moveToNext()) {
                            val uri = ContentUris.withAppendedId(collection, c.getLong(0))
                            if (referenced.contains(uri.toString())) continue
                            paths.add(uri.toString())
                            uris.add(uri)
                            bytes += c.getLong(1)
                        }
                    }
            } catch (e: Exception) {
                // No MediaStore access on this build: raw listing already ran.
            }
        }
        return OrphanScan(paths, files, uris, bytes)
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
