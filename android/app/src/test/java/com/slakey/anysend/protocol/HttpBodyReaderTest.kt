package com.slakey.anysend.protocol

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayOutputStream

/**
 * JVM unit tests for the incremental HTTP body reader. These pin down the
 * framing edge cases that the streaming-upload refactor depends on: the
 * reader must never depend on body size for correctness.
 */
class HttpBodyReaderTest {

    /** Fake NetworkLayer that replays queued chunks, then EOFs. */
    private class FakeNet(var chunks: ArrayDeque<ByteArray>) : NetworkLayer {
        var reads = 0
        override suspend fun dial(network: String, addr: String) = -1L
        override suspend fun dialTls(network: String, addr: String) = -1L
        override suspend fun listen(network: String, addr: String) = -1L
        override suspend fun accept(listenerHandle: Long) = -1L
        override suspend fun read(handle: Long, maxLen: Int): ByteArray? {
            reads++
            return chunks.removeFirstOrNull()
        }
        override suspend fun write(handle: Long, data: ByteArray) = data.size
        override fun closeConn(handle: Long) {}
        override fun closeListener(handle: Long) {}
    }

    private fun readerOf(chunkSize: Int, net: FakeNet, leftover: ByteArray, len: Long, chunked: Boolean) =
        HttpBodyReader(net, 1L, leftover, len, chunked)

    private fun s(text: String) = text.toByteArray(Charsets.UTF_8)

    @Test
    fun `content-length body split across many reads`() = runBlocking {
        val payload = "0123456789".repeat(100) // 1000 bytes
        val net = FakeNet(ArrayDeque(listOf(s(payload.substring(0, 7)), s(payload.substring(7)))))
        val r = readerOf(64, net, ByteArray(0), payload.length.toLong(), chunked = false)
        val out = ByteArrayOutputStream()
        val got = r.copyTo(out) {}
        assertEquals(payload.length.toLong(), got)
        assertEquals(payload, out.toString("UTF-8"))
    }

    @Test
    fun `leftover bytes past header end are consumed first`() = runBlocking {
        val net = FakeNet(ArrayDeque(listOf(s("XY"))))
        val r = readerOf(64, net, s("HEAD-"), 7, chunked = false)
        assertEquals("HEAD-XY", r.readFully(1024).toString(Charsets.UTF_8))
    }

    @Test
    fun `short body (peer vanished) returns what arrived`() = runBlocking {
        val net = FakeNet(ArrayDeque(listOf(s("abc")))) // EOF after 3 of 10
        val r = readerOf(64, net, ByteArray(0), 10, chunked = false)
        assertEquals("abc", r.readFully(1024).toString(Charsets.UTF_8))
    }

    @Test
    fun `body is capped at content-length even if peer sends more`() = runBlocking {
        val net = FakeNet(ArrayDeque(listOf(s("AAAAAAAAAA"))))
        val r = readerOf(64, net, ByteArray(0), 4, chunked = false)
        assertEquals("AAAA", r.readFully(1024).toString(Charsets.UTF_8))
    }

    @Test
    fun `chunked body in several frames`() = runBlocking {
        // "hello world" as two chunks, size lines split across reads
        val net = FakeNet(ArrayDeque(listOf(s("5\r\nhell"), s("o\r\n6\r\n worl"), s("d\r\n0\r\n\r\n"))))
        val r = readerOf(64, net, ByteArray(0), 0, chunked = true)
        assertEquals("hello world", r.readFully(1024).toString(Charsets.UTF_8))
    }

    @Test
    fun `chunked with size-line extension is parsed`() = runBlocking {
        val net = FakeNet(ArrayDeque(listOf(s("3;ext=1\r\nabc\r\n0\r\n\r\n"))))
        val r = readerOf(64, net, ByteArray(0), 0, chunked = true)
        assertEquals("abc", r.readFully(1024).toString(Charsets.UTF_8))
    }

    @Test
    fun `readFully throws past the cap`() = runBlocking {
        val net = FakeNet(ArrayDeque(listOf(s("AAAAAAAAAA"))))
        val r = readerOf(64, net, ByteArray(0), 10, chunked = false)
        val thrown = assertThrows(BodyTooLargeException::class.java) { runBlocking { r.readFully(4) } }
        assertEquals("request body exceeds limit", thrown.message)
    }

    @Test
    fun `forged giant content-length does not allocate`() = runBlocking {
        // The old code did ByteArray(2_000_000_000) here. The reader must
        // simply return what actually arrives (nothing) and end.
        val net = FakeNet(ArrayDeque(emptyList()))
        val r = readerOf(64, net, ByteArray(0), 2_000_000_000L, chunked = false)
        assertEquals(0, r.readFully(8 * 1024 * 1024).size)
    }

    @Test
    fun `malformed chunk size ends the stream`() = runBlocking {
        val net = FakeNet(ArrayDeque(listOf(s("zzzz\r\n"))))
        val r = readerOf(64, net, ByteArray(0), 0, chunked = true)
        assertEquals(0, r.readFully(1024).size)
    }
}
