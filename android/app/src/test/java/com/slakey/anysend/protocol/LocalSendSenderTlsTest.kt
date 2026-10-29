package com.slakey.anysend.protocol

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.ServerSocket
import java.nio.file.Files
import java.net.Socket
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Interop tests for the official LocalSend transport.
 *
 * Official receivers serve HTTPS with a self-signed certificate and may
 * require a pairing PIN, while AnySend receivers serve plain HTTP. These
 * tests pin down both paths end to end over a real socket, not a mock:
 * register -> prepare-upload (PIN) -> upload, asserting the received bytes.
 */
class LocalSendSenderTlsTest {

    private val servers = mutableListOf<V2TestServer>()
    private val tempFiles = mutableListOf<File>()

    @After
    fun tearDown() {
        servers.forEach { it.close() }
        tempFiles.forEach { it.delete() }
    }

    /** Official LocalSend: HTTPS only, accepts any PIN-free client. */
    @Test
    fun sendsOverHttpsWhenPeerOnlySpeaksTls() = runBlocking {
        val server = startServer(tls = true)
        val payload = "hello-over-tls".toByteArray()

        val sender = senderFor(server.port)
        assertNotNull("register should discover the TLS transport", sender.register())

        val outcome = sender.sendRequest(listOf(fileWith(payload)))
        assertTrue("expected Accepted, got $outcome", outcome is LocalSendSender.SendOutcome.Accepted)
        val accepted = outcome as LocalSendSender.SendOutcome.Accepted
        val fileId = accepted.result.response.files.keys.first()

        val ok = sender.sendFile(
            accepted.result.response.sessionId,
            fileId,
            accepted.result.response.files.getValue(fileId),
            accepted.result.fileIdToFile.getValue(fileId)
        ) { _, _ -> }

        assertTrue("upload over TLS should succeed", ok)
        assertArrayEquals(payload, server.lastUpload)
    }

    /** Official LocalSend with PIN protection: 401 first, then accept. */
    @Test
    fun asksForPinThenAcceptsWithIt() = runBlocking {
        val server = startServer(tls = true, requiredPin = "1234")
        val payload = "pin-protected".toByteArray()
        val sender = senderFor(server.port)
        assertNotNull(sender.register())

        assertEquals(
            LocalSendSender.SendOutcome.NeedPin,
            sender.sendRequest(listOf(fileWith(payload)))
        )

        val retry = sender.sendRequest(listOf(fileWith(payload)), pin = "1234")
        assertTrue("expected Accepted, got $retry", retry is LocalSendSender.SendOutcome.Accepted)
        assertEquals("1234", server.lastPin)
    }

    /** Wrong PIN must not be mistaken for a transport failure. */
    @Test
    fun reportsWrongPin() = runBlocking {
        val server = startServer(tls = true, requiredPin = "1234")
        val sender = senderFor(server.port)
        assertNotNull(sender.register())

        assertEquals(
            LocalSendSender.SendOutcome.WrongPin,
            sender.sendRequest(listOf(fileWith("x".toByteArray())), pin = "9999")
        )
    }

    /** AnySend peers stay on plain HTTP; the probe must not break them. */
    @Test
    fun stillSendsToPlainHttpPeer() = runBlocking {
        val server = startServer(tls = false)
        val payload = "plain-http".toByteArray()
        val sender = senderFor(server.port)
        assertNotNull(sender.register())

        val outcome = sender.sendRequest(listOf(fileWith(payload)))
        assertTrue("expected Accepted, got $outcome", outcome is LocalSendSender.SendOutcome.Accepted)
        val accepted = outcome as LocalSendSender.SendOutcome.Accepted
        val fileId = accepted.result.response.files.keys.first()
        val ok = sender.sendFile(
            accepted.result.response.sessionId,
            fileId,
            accepted.result.response.files.getValue(fileId),
            accepted.result.fileIdToFile.getValue(fileId)
        ) { _, _ -> }

        assertTrue(ok)
        assertArrayEquals(payload, server.lastUpload)
    }

    private fun senderFor(port: Int) = LocalSendSender(
        receiverIp = "127.0.0.1",
        selfInfo = DeviceInfo(
            alias = "test",
            deviceModel = "jvm",
            deviceType = LocalSendConst.DEVICE_TYPE_MOBILE,
            fingerprint = "test-fingerprint"
        ),
        network = DirectNetworkLayer(),
        port = port
    )

    private fun fileWith(bytes: ByteArray): File {
        val f = File.createTempFile("anysend-test", ".bin")
        f.writeBytes(bytes)
        tempFiles.add(f)
        return f
    }

    private fun startServer(
        tls: Boolean,
        requiredPin: String? = null,
        requireClientCert: Boolean = false
    ): V2TestServer = V2TestServer(tls, requiredPin, requireClientCert).also { servers.add(it) }

    /**
     * Stock LocalSend asks for a client certificate and fails the handshake
     * without one, so the sender has to offer its device certificate.
     */
    @Test
    fun presentsClientCertificateWhenPeerRequiresIt() = runBlocking {
        val dir = Files.createTempDirectory("identity").toFile().also { tempFiles.add(it) }
        DeviceIdentity.load(dir, "test-password")

        val server = startServer(tls = true, requireClientCert = true)
        val payload = "mutual-tls".toByteArray()
        val sender = senderFor(server.port)

        assertNotNull("register should survive client-auth TLS", sender.register())
        val outcome = sender.sendRequest(listOf(fileWith(payload)))
        assertTrue("expected Accepted, got $outcome", outcome is LocalSendSender.SendOutcome.Accepted)
        val accepted = outcome as LocalSendSender.SendOutcome.Accepted
        val fileId = accepted.result.response.files.keys.first()

        val ok = sender.sendFile(
            accepted.result.response.sessionId,
            fileId,
            accepted.result.response.files.getValue(fileId),
            accepted.result.fileIdToFile.getValue(fileId)
        ) { _, _ -> }

        assertTrue("upload over mutual TLS should succeed", ok)
        assertArrayEquals(payload, server.lastUpload)
    }

    /** The generated certificate must look like the one LocalSend mints. */
    @Test
    fun generatedIdentityIsALocalSendCertificate() {
        val dir = Files.createTempDirectory("identity-shape").toFile().also { tempFiles.add(it) }
        DeviceIdentity.load(dir, "test-password")

        val ks = KeyStore.getInstance("PKCS12")
        File(dir, "identity.p12").inputStream().use { ks.load(it, "test-password".toCharArray()) }
        val cert = ks.getCertificate("identity") as X509Certificate
        // Parsing it back is half the test: a malformed DER would throw here.
        CertificateFactory.getInstance("X.509").generateCertificate(cert.encoded.inputStream())

        assertEquals("CN=LocalSend User", cert.subjectX500Principal.name)
        assertEquals(cert.subjectX500Principal, cert.issuerX500Principal)
        assertEquals(64, DeviceIdentity.fingerprint().length)
    }
}

/**
 * Minimal LocalSend v2 receiver: just enough of the wire format to exercise
 * the sender (register / prepare-upload / upload). Handles one connection at
 * a time, like the real server's single session slot.
 */
private class V2TestServer(
    tls: Boolean,
    private val requiredPin: String?,
    private val requireClientCert: Boolean = false
) {

    @Volatile
    var lastUpload: ByteArray? = null

    @Volatile
    var lastPin: String? = null

    private val socket: ServerSocket = if (tls) tlsServerSocket() else ServerSocket(0)
    private val thread = Thread { acceptLoop() }.apply {
        isDaemon = true
        start()
    }

    val port: Int get() = socket.localPort

    fun close() {
        try {
            socket.close()
        } catch (_: Exception) {
        }
    }

    private fun tlsServerSocket(): ServerSocket {
        val ks = KeyStore.getInstance("PKCS12")
        javaClass.classLoader!!.getResourceAsStream("test-tls.p12")!!.use {
            ks.load(it, "testpass".toCharArray())
        }
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(ks, "testpass".toCharArray())
        val trustAnyClient = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) = Unit
            override fun checkServerTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) = Unit
            override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = emptyArray()
        }
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(
            kmf.keyManagers,
            if (requireClientCert) arrayOf<TrustManager>(trustAnyClient) else null,
            null
        )
        val server = ctx.serverSocketFactory.createServerSocket(0) as SSLServerSocket
        server.needClientAuth = requireClientCert
        return server
    }

    private fun acceptLoop() {
        while (!socket.isClosed) {
            val client = try {
                socket.accept()
            } catch (e: Exception) {
                return
            }
            try {
                handle(client)
            } catch (_: Exception) {
                // A plaintext probe against the TLS listener lands here; the
                // real client then retries over TLS.
            } finally {
                try {
                    client.close()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun handle(client: Socket) {
        val input = client.getInputStream()
        val head = StringBuilder()
        var tail = 0
        while (tail != 0x0D0A0D0A) {
            val b = input.read()
            if (b < 0) return
            head.append(b.toChar())
            tail = (tail shl 8) or b
        }

        val lines = head.toString().split("\r\n")
        val requestLine = lines[0].split(" ")
        val path = requestLine.getOrElse(1) { "/" }

        var contentLength = 0
        for (line in lines.drop(1)) {
            val idx = line.indexOf(':')
            if (idx > 0 && line.substring(0, idx).equals("Content-Length", ignoreCase = true)) {
                contentLength = line.substring(idx + 1).trim().toIntOrNull() ?: 0
            }
        }
        val body = ByteArray(contentLength)
        var off = 0
        while (off < contentLength) {
            val n = input.read(body, off, contentLength - off)
            if (n <= 0) break
            off += n
        }

        when {
            path.endsWith("/register") -> respond(client, 200, infoJson())
            path.contains("/prepare-upload") -> {
                val root = JsonParser.parseString(String(body)).asJsonObject
                val pin = root.get("pin")?.asString
                lastPin = pin
                if (requiredPin != null && pin != requiredPin) {
                    respond(client, 401, """{"message":"PIN required"}""")
                    return
                }
                val files = root.getAsJsonObject("files")
                val tokens = JsonObject()
                files.keySet().forEach { tokens.addProperty(it, "tok-$it") }
                val resp = JsonObject().apply {
                    addProperty("sessionId", "sess-1")
                    add("files", tokens)
                }
                respond(client, 200, resp.toString())
            }
            path.contains("/upload") -> {
                lastUpload = body
                respond(client, 200, "{}")
            }
            else -> respond(client, 404, "{}")
        }
    }

    private fun respond(client: Socket, status: Int, json: String) {
        val body = json.toByteArray()
        val head = buildString {
            append("HTTP/1.1 $status X\r\n")
            append("Content-Type: application/json\r\n")
            append("Content-Length: ${body.size}\r\n")
            append("Connection: close\r\n\r\n")
        }
        val out = client.getOutputStream()
        out.write(head.toByteArray())
        out.write(body)
        out.flush()
    }

    private fun infoJson(): String = """
        {"alias":"jvm-test","version":"2.1","deviceModel":"jvm","deviceType":"desktop",
         "fingerprint":"jvm-test","port":${socket.localPort},"protocol":"http","download":true}
    """.trimIndent()
}
