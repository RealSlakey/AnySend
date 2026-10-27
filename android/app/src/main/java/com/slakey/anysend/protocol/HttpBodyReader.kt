package com.slakey.anysend.protocol

import java.io.OutputStream

/**
 * Incremental HTTP request-body reader over the raw [NetworkLayer] socket.
 *
 * Memory footprint is one read buffer, regardless of body size — the previous
 * in-server implementation allocated `ByteArray(content-length)` up front, so
 * a single forged header (or just a legitimately huge file) could OOM-kill
 * the process. Supports both Content-Length and chunked framing; EOF-short
 * bodies are surfaced as a normal end-of-stream (the caller decides whether
 * that is acceptable, since the connection closes after the response anyway).
 *
 * Not Android-specific: unit-testable on the JVM.
 */
internal class BodyTooLargeException : Exception("request body exceeds limit")

internal class HttpBodyReader(
    private val net: NetworkLayer,
    private val conn: Long,
    leftover: ByteArray,
    private val contentLength: Long,
    private val chunked: Boolean,
    private val maxChunkBytes: Long = 1L shl 30
) {
    private var buf: ByteArray = leftover
    private var pos = 0
    private var served = 0L        // Content-Length mode: bytes returned
    private var chunkLeft = -1L    // chunked mode: bytes left in current chunk
    private var done = false

    /** Read up to b.size bytes; -1 at end of body. */
    suspend fun read(b: ByteArray): Int {
        if (done || !fill() || b.isEmpty()) return -1
        var want = b.size
        want = if (chunked) {
            minOf(want.toLong(), chunkLeft).toInt()
        } else {
            minOf(want.toLong(), contentLength - served).toInt()
        }
        if (want <= 0) {
            done = true
            return -1
        }
        val n = minOf(want, buf.size - pos)
        System.arraycopy(buf, pos, b, 0, n)
        pos += n
        served += n
        if (chunked) chunkLeft -= n
        return n
    }

    /** Read the entire body, refusing to buffer more than [maxBytes]. */
    suspend fun readFully(maxBytes: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(64 * 1024)
        val chunk = ByteArray(64 * 1024)
        var total = 0
        while (true) {
            val n = read(chunk)
            if (n < 0) break
            total += n
            if (total > maxBytes) throw BodyTooLargeException()
            out.write(chunk, 0, n)
        }
        return out.toByteArray()
    }

    /** Stream the body into [out]; returns the number of bytes written. */
    suspend fun copyTo(out: OutputStream, onProgress: (Long) -> Unit): Long {
        val chunk = ByteArray(256 * 1024)
        var total = 0L
        while (true) {
            val n = read(chunk)
            if (n < 0) break
            out.write(chunk, 0, n)
            total += n
            onProgress(total)
        }
        out.flush()
        return total
    }

    /** Guarantees at least one readable byte of payload, or sets [done]. */
    private suspend fun fill(): Boolean {
        while (true) {
            if (chunked) {
                if (chunkLeft == 0L) {
                    // The just-finished chunk's trailing CRLF comes before the
                    // next size line — consume it first.
                    while (buf.size - pos < 2) {
                        if (!compactAndRead()) return truncated()
                    }
                    if (buf[pos] != 13.toByte() || buf[pos + 1] != 10.toByte()) return truncated()
                    pos += 2
                    chunkLeft = -1L
                    continue
                }
                // Chunk boundary first: buffered bytes at this point belong to
                // the next size line, not to payload.
                if (chunkLeft < 0) {
                    val eol = findCrlf(buf, pos)
                    if (eol < 0) {
                        if (!compactAndRead()) return truncated()
                        continue
                    }
                    val line = String(buf, pos, eol - pos, Charsets.US_ASCII)
                    val size = line.substringBefore(';').trim().toLongOrNull(16)
                    if (size == null || size < 0 || size > maxChunkBytes) return truncated()
                    pos = eol + 2
                    if (size == 0L) {
                        done = true // final chunk; trailers ignored (conn closes)
                        return false
                    }
                    chunkLeft = size
                    continue
                }
                if (pos < buf.size) return true
                if (!compactAndRead()) return truncated()
            } else {
                if (served >= contentLength) {
                    done = true
                    return false
                }
                if (pos < buf.size) return true
                if (!compactAndRead()) return truncated()
            }
        }
    }

    /** Slide any unread tail to the front, then pull one more read. */
    private suspend fun compactAndRead(): Boolean {
        if (pos > 0) {
            buf = if (pos < buf.size) buf.copyOfRange(pos, buf.size) else ByteArray(0)
            pos = 0
        }
        val n = net.read(conn, 65536) ?: return false
        if (n.isEmpty()) return false
        buf = appendBytes(buf, n)
        return true
    }

    private fun truncated(): Boolean {
        // Peer vanished mid-body or sent malformed framing: treat as EOF.
        done = true
        return false
    }
}

/** Find the '\r\n' separator. Returns -1 when absent. */
internal fun findCrlf(data: ByteArray, from: Int): Int {
    var i = from
    while (i + 1 < data.size) {
        if (data[i] == 0x0d.toByte() && data[i + 1] == 0x0a.toByte()) return i
        i++
    }
    return -1
}

internal fun appendBytes(dst: ByteArray, src: ByteArray): ByteArray {
    val out = ByteArray(dst.size + src.size)
    dst.copyInto(out, 0)
    src.copyInto(out, dst.size)
    return out
}
