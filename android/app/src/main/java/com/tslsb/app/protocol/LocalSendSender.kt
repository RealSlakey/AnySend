package com.tslsb.app.protocol

import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
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
        val buf = ByteArray(8192)
        val raw = StringBuilder()
        var headerEnd = -1
        while (headerEnd < 0) {
            val n = network.read(conn, buf.size) ?: break
            if (n.isEmpty()) break
            raw.append(String(n))
            headerEnd = raw.indexOf("\r\n\r\n")
        }
        if (headerEnd < 0) return HttpResponse(0, emptyMap(), ByteArray(0))

        val headerSection = raw.substring(0, headerEnd)
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
        val body = ByteArrayOutputStream()
        // body already in raw buffer?
        val already = raw.length - (headerEnd + 4)
        if (already > 0 && contentLength > 0) {
            val toCopy = minOf(already, contentLength)
            body.write(raw.substring(headerEnd + 4, headerEnd + 4 + toCopy).toByteArray())
        }
        while (body.size() < contentLength) {
            val n = network.read(conn, buf.size) ?: break
            if (n.isEmpty()) break
            body.write(n)
        }
        return HttpResponse(status, headers, body.toByteArray())
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
     */
    suspend fun sendFile(
        sessionId: String,
        fileId: String,
        file: File,
        progress: (Long, Long) -> Unit
    ): Boolean = withContext(Dispatchers.IO) {
        val conn = openConn()
        if (conn <= 0) return@withContext false
        try {
            val mime = guessMime(file.name)
            val total = file.length()
            val path = "${LocalSendConst.PATH_SEND}?sessionId=$sessionId&fileId=$fileId"
            val header = StringBuilder()
                .append("POST $path HTTP/1.1\r\n")
                .append("Host: $receiverIp:${LocalSendConst.PORT}\r\n")
                .append("Connection: close\r\n")
                .append("Content-Type: $mime\r\n")
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
            else -> "application/octet-stream"
        }
    }
}
