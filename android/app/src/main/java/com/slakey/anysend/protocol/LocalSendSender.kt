package com.slakey.anysend.protocol

import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.util.UUID

/**
 * LocalSend sender. Routes all traffic through the provided [NetworkLayer]
 * (either Tailscale userspace netstack or system sockets in Direct LAN mode).
 *
 * Flow: register -> send-request -> send (per accepted file).
 */
class LocalSendSender(
    private val receiverIp: String,
    private val selfInfo: DeviceInfo,
    private val network: NetworkLayer
) {
    private val gson = Gson()

    private suspend fun openConn(): Long {
        return network.dial("tcp", "$receiverIp:${LocalSendConst.PORT}")
    }

    /** Send a raw HTTP request and return the parsed response. */
    private suspend fun httpRequest(
        method: String,
        path: String,
        contentType: String?,
        body: ByteArray?
    ): HttpResponse = withContext(Dispatchers.IO) {
        val conn = openConn()
        if (conn <= 0) return@withContext HttpResponse(0, emptyMap(), ByteArray(0))

        try {
            val reqBuilder = StringBuilder()
            reqBuilder.append("$method $path HTTP/1.1\r\n")
            reqBuilder.append("Host: $receiverIp:${LocalSendConst.PORT}\r\n")
            reqBuilder.append("Connection: close\r\n")
            if (contentType != null) {
                reqBuilder.append("Content-Type: $contentType\r\n")
            }
            if (body != null) {
                reqBuilder.append("Content-Length: ${body.size}\r\n")
            } else {
                reqBuilder.append("Content-Length: 0\r\n")
            }
            reqBuilder.append("\r\n")
            network.write(conn, reqBuilder.toString().toByteArray())
            if (body != null && body.isNotEmpty()) {
                network.write(conn, body)
            }
            return@withContext readHttpResponse(conn)
        } finally {
            network.closeConn(conn)
        }
    }

    private suspend fun readHttpResponse(conn: Long): HttpResponse {
        // Byte-level buffering: the body must never pass through String
        // conversion (UTF-8 JSON aliases and binary payloads would corrupt).
        var rawBytes = ByteArray(0)
        var headerEnd = -1
        while (headerEnd < 0) {
            val n = network.read(conn, 8192) ?: break
            if (n.isEmpty()) break
            rawBytes = appendBytes(rawBytes, n)
            headerEnd = findHeaderEnd(rawBytes)
        }
        if (headerEnd < 0) return HttpResponse(0, emptyMap(), ByteArray(0))

        val headerSection = String(rawBytes, 0, headerEnd, Charsets.UTF_8)
        val lines = headerSection.split("\r\n")
        val statusLine = lines[0].split(" ")
        val status = if (statusLine.size >= 2) statusLine[1].toIntOrNull() ?: 0 else 0

        val headers = mutableMapOf<String, String>()
        for (i in 1 until lines.size) {
            val idx = lines[i].indexOf(':')
            if (idx > 0) {
                headers[lines[i].substring(0, idx).trim().lowercase()] =
                    lines[i].substring(idx + 1).trim()
            }
        }

        val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
        val bodyStart = headerEnd + 4
        var body = if (rawBytes.size > bodyStart) rawBytes.copyOfRange(bodyStart, rawBytes.size) else ByteArray(0)
        while (body.size < contentLength) {
            val n = network.read(conn, 8192) ?: break
            if (n.isEmpty()) break
            body = appendBytes(body, n)
        }
        val finalBody = if (contentLength > 0 && body.size > contentLength) body.copyOf(contentLength) else body
        return HttpResponse(status, headers, finalBody)
    }

    private fun appendBytes(dst: ByteArray, src: ByteArray): ByteArray {
        val out = ByteArray(dst.size + src.size)
        dst.copyInto(out, 0)
        src.copyInto(out, dst.size)
        return out
    }

    /** Find the '\r\n\r\n' header/body separator. Returns -1 when absent. */
    private fun findHeaderEnd(bytes: ByteArray): Int {
        for (i in 0 until bytes.size - 3) {
            if (bytes[i] == 13.toByte() && bytes[i + 1] == 10.toByte() &&
                bytes[i + 2] == 13.toByte() && bytes[i + 3] == 10.toByte()
            ) {
                return i
            }
        }
        return -1
    }

    private data class HttpResponse(
        val status: Int,
        val headers: Map<String, String>,
        val body: ByteArray
    )

    /** Step 1: register. Returns receiver's DeviceInfo or null. */
    suspend fun register(): DeviceInfo? {
        val body = gson.toJson(selfInfo).toByteArray()
        val resp = httpRequest("POST", LocalSendConst.PATH_REGISTER, "application/json", body)
        if (resp.status != 200) return null
        return try {
            gson.fromJson(String(resp.body), DeviceInfo::class.java)
        } catch (e: Exception) {
            null
        }
    }

    /** Step 2: send file metadata. Returns response + fileId->File map, or null if rejected. */
    suspend fun sendRequest(files: List<File>): SendRequestResult? {
        val fileIdToFile = mutableMapOf<String, File>()
        val fileMap = files.associate { f ->
            val id = UUID.randomUUID().toString()
            fileIdToFile[id] = f
            id to FileInfo(
                id = id,
                fileName = f.name,
                size = f.length(),
                fileType = guessMime(f.name)
            )
        }
        val sendReq = SendRequest(info = selfInfo, files = fileMap)
        val body = gson.toJson(sendReq).toByteArray()
        val resp = httpRequest("POST", LocalSendConst.PATH_SEND_REQUEST, "application/json", body)
        if (resp.status != 200) return null
        return try {
            val response = gson.fromJson(String(resp.body), SendRequestResponse::class.java)
            SendRequestResult(response, fileIdToFile)
        } catch (e: Exception) {
            null
        }
    }

    /** Bundles the send-request response with the mapping of fileId -> local File. */
    data class SendRequestResult(
        val response: SendRequestResponse,
        val fileIdToFile: Map<String, File>
    )

    /**
     * Step 3: upload a single file with progress reporting.
     *
     * [fileToken] is the per-file token from the send-request response
     * (v2 wire format); the receiver rejects uploads without it.
     */
    suspend fun sendFile(
        sessionId: String,
        fileId: String,
        fileToken: String,
        file: File,
        progress: (Long, Long) -> Unit
    ): Boolean = withContext(Dispatchers.IO) {
        val conn = openConn()
        if (conn <= 0) return@withContext false
        try {
            val mime = guessMime(file.name)
            val uploadType = if (mime.startsWith("text/")) "$mime; charset=utf-8" else mime
            val total = file.length()
            val path = "${LocalSendConst.PATH_UPLOAD}?sessionId=$sessionId&fileId=$fileId&token=$fileToken"
            val header = StringBuilder()
                .append("POST $path HTTP/1.1\r\n")
                .append("Host: $receiverIp:${LocalSendConst.PORT}\r\n")
                .append("Connection: close\r\n")
                .append("Content-Type: $uploadType\r\n")
                .append("Content-Length: $total\r\n")
                .append("\r\n")
                .toString()
            network.write(conn, header.toByteArray())

            // Stream file in chunks
            val fis = FileInputStream(file)
            val buf = ByteArray(64 * 1024)
            var sent = 0L
            var n: Int
            while (fis.read(buf).also { n = it } != -1) {
                network.write(conn, buf.copyOf(n))
                sent += n
                progress(sent, total)
            }
            fis.close()

            val resp = readHttpResponse(conn)
            return@withContext resp.status == 200
        } finally {
            network.closeConn(conn)
        }
    }

    private fun guessMime(fileName: String): String {
        return when {
            fileName.endsWith(".jpg", true) || fileName.endsWith(".jpeg", true) -> "image/jpeg"
            fileName.endsWith(".png", true) -> "image/png"
            fileName.endsWith(".gif", true) -> "image/gif"
            fileName.endsWith(".mp4", true) -> "video/mp4"
            fileName.endsWith(".mp3", true) -> "audio/mpeg"
            fileName.endsWith(".pdf", true) -> "application/pdf"
            fileName.endsWith(".zip", true) -> "application/zip"
            fileName.endsWith(".txt", true) || fileName.endsWith(".log", true) -> "text/plain"
            fileName.endsWith(".md", true) -> "text/markdown"
            fileName.endsWith(".json", true) -> "application/json"
            else -> "application/octet-stream"
        }
    }
}
