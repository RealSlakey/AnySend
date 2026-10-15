package com.tslsb.app.protocol

import android.content.Context
import android.os.Environment
import com.google.gson.Gson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * LocalSend receiver. Listens on the provided [NetworkLayer] on TCP :53317
 * and serves the LocalSend v2 HTTP API. File acceptance is delegated to a
 * callback so the UI can prompt the user.
 */
class LocalSendServer(
    private val context: Context,
    private val selfInfo: DeviceInfo,
    private val network: NetworkLayer
) {
    private val gson = Gson()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var listenerHandle = -1L
    private var running = false

    /** Pending session decisions: fileId -> accept(true)/reject(false) */
    private val decisions = ConcurrentHashMap<String, Boolean>()

    /** Callback invoked when a send-request arrives. UI should prompt user. */
    var onSendRequest: ((sender: DeviceInfo, files: Map<String, FileInfo>) -> Unit)? = null

    /** Set the decision for a session (called by UI after user chooses). */
    fun setSessionDecision(sessionId: String, acceptedFileIds: Set<String>) {
        acceptedFileIds.forEach { decisions[it] = true }
    }

    fun start() {
        if (running) return
        running = true
        scope.launch {
            listenerHandle = network.listen("tcp", ":${LocalSendConst.PORT}")
            if (listenerHandle <= 0) {
                running = false
                return@launch
            }
            while (running) {
                val conn = network.accept(listenerHandle)
                if (conn > 0) {
                    scope.launch { handleConnection(conn) }
                }
            }
        }
    }

    fun stop() {
        running = false
        if (listenerHandle > 0) {
            network.closeListener(listenerHandle)
            listenerHandle = -1L
        }
    }

    private suspend fun handleConnection(conn: Long) {
        try {
            val request = readHttpRequest(conn) ?: return
            val response = route(request, conn)
            writeHttpResponse(conn, response)
        } catch (e: Exception) {
            // ignore broken connections
        } finally {
            network.closeConn(conn)
        }
    }

    private data class HttpRequest(
        val method: String,
        val path: String,
        val query: Map<String, String>,
        val headers: Map<String, String>,
        val body: ByteArray
    )

    private suspend fun readHttpRequest(conn: Long): HttpRequest? {
        val raw = StringBuilder()
        val buf = ByteArray(8192)
        var headerEnd = -1
        // Read until we see \r\n\r\n
        while (headerEnd < 0) {
            val n = network.read(conn, buf.size) ?: break
            if (n.isEmpty()) break
            raw.append(String(n))
            headerEnd = raw.indexOf("\r\n\r\n")
        }
        if (headerEnd < 0) return null

        val headerSection = raw.substring(0, headerEnd)
        val lines = headerSection.split("\r\n")
        val requestLine = lines[0].split(" ")
        if (requestLine.size < 2) return null
        val method = requestLine[0]
        val fullPath = requestLine[1]
        val (path, query) = parsePath(fullPath)

        val headers = mutableMapOf<String, String>()
        for (i in 1 until lines.size) {
            val idx = lines[i].indexOf(':')
            if (idx > 0) {
                headers[lines[i].substring(0, idx).trim().lowercase()] =
                    lines[i].substring(idx + 1).trim()
            }
        }

        val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
        val body = ByteArray(contentLength)
        if (contentLength > 0) {
            var read = headerEnd + 4
            var bodyOffset = 0
            // body may already be partially in `raw`
            val already = raw.length - (headerEnd + 4)
            if (already > 0) {
                val toCopy = minOf(already, contentLength)
                raw.substring(headerEnd + 4, headerEnd + 4 + toCopy).toByteArray().copyInto(body, 0)
                bodyOffset = toCopy
            }
            while (bodyOffset < contentLength) {
                val n = network.read(conn, buf.size) ?: break
                if (n.isEmpty()) break
                val toCopy = minOf(n.size, contentLength - bodyOffset)
                n.copyInto(body, bodyOffset, 0, toCopy)
                bodyOffset += toCopy
            }
        }

        return HttpRequest(method, path, query, headers, body)
    }

    private fun parsePath(fullPath: String): Pair<String, Map<String, String>> {
        val qIdx = fullPath.indexOf('?')
        return if (qIdx < 0) {
            fullPath to emptyMap()
        } else {
            val path = fullPath.substring(0, qIdx)
            val query = fullPath.substring(qIdx + 1).split("&")
                .associate {
                    val eq = it.indexOf('=')
                    if (eq > 0) it.substring(0, eq) to it.substring(eq + 1)
                    else it to ""
                }
            path to query
        }
    }

    private fun route(req: HttpRequest, conn: Long): HttpResponse {
        return when {
            req.method == "GET" && req.path == LocalSendConst.PATH_INFO ->
                HttpResponse(200, "application/json", gson.toJson(selfInfo).toByteArray())

            req.method == "POST" && req.path == LocalSendConst.PATH_REGISTER -> {
                // Sender registers; we respond with our info.
                HttpResponse(200, "application/json", gson.toJson(selfInfo).toByteArray())
            }

            req.method == "POST" && req.path == LocalSendConst.PATH_SEND_REQUEST -> {
                handleSendRequest(req)
            }

            req.method == "POST" && req.path == LocalSendConst.PATH_SEND -> {
                handleSend(req, conn)
            }

            req.method == "POST" && req.path == LocalSendConst.PATH_CANCEL -> {
                HttpResponse(200, "application/json", "{}".toByteArray())
            }

            else -> HttpResponse(404, "text/plain", "Not Found".toByteArray())
        }
    }

    private fun handleSendRequest(req: HttpRequest): HttpResponse {
        val sendReq = try {
            gson.fromJson(String(req.body), SendRequest::class.java)
        } catch (e: Exception) {
            return HttpResponse(400, "text/plain", "Bad Request".toByteArray())
        }
        val sessionId = UUID.randomUUID().toString()
        // Notify UI; in this minimal impl we auto-accept all (configurable).
        onSendRequest?.invoke(sendReq.info, sendReq.files)
        // Auto-accept by default
        sendReq.files.keys.forEach { decisions[it] = true }
        val accepted = sendReq.files.mapValues { "accept" }
        val resp = SendRequestResponse(sessionId = sessionId, files = accepted)
        return HttpResponse(200, "application/json", gson.toJson(resp).toByteArray())
    }

    private fun handleSend(req: HttpRequest, conn: Long): HttpResponse {
        val sessionId = req.query["sessionId"] ?: return HttpResponse(400, "text/plain", "missing sessionId".toByteArray())
        val fileId = req.query["fileId"] ?: return HttpResponse(400, "text/plain", "missing fileId".toByteArray())
        // Save body to downloads
        val fileName = "received_${fileId.take(8)}"
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        downloads.mkdirs()
        val outFile = File(downloads, fileName)
        FileOutputStream(outFile).use { fos ->
            fos.write(req.body)
        }
        return HttpResponse(200, "application/json", "{}".toByteArray())
    }

    private suspend fun writeHttpResponse(conn: Long, resp: HttpResponse) {
        val header = "HTTP/1.1 ${resp.status} ${resp.statusText}\r\n" +
                "Content-Type: ${resp.contentType}\r\n" +
                "Content-Length: ${resp.body.size}\r\n" +
                "Connection: close\r\n\r\n"
        network.write(conn, header.toByteArray())
        if (resp.body.isNotEmpty()) {
            network.write(conn, resp.body)
        }
    }

    private data class HttpResponse(
        val status: Int,
        val contentType: String,
        val body: ByteArray,
        val statusText: String = when (status) {
            200 -> "OK"
            400 -> "Bad Request"
            403 -> "Forbidden"
            404 -> "Not Found"
            else -> "OK"
        }
    )
}
