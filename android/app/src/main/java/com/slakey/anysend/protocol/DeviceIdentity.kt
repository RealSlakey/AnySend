package com.slakey.anysend.protocol

import android.content.Context
import android.util.Log
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import javax.security.auth.x500.X500Principal

/**
 * Per-install device identity for HTTPS peers.
 *
 * Stock LocalSend runs **mutual** TLS: the server asks for a client certificate
 * and aborts the handshake with `certificate_required` when none is presented.
 * The certificate is the device identity — peers know each other by its SHA-256
 * fingerprint — so accepting the peer's self-signed certificate is only half of
 * the handshake.
 *
 * The identity mirrors what LocalSend mints with rcgen: RSA-2048, CN=LocalSend
 * User, self-signed, valid for 20 years. Android has no public certificate
 * builder, so the minimal X.509 DER is assembled by hand and kept in a PKCS#12
 * keystore inside the app sandbox; the private key never leaves the app.
 */
object DeviceIdentity {
    private const val TAG = "AnySendIdentity"
    private const val STORE_FILE = "identity.p12"
    private const val ALIAS = "identity"
    private const val PREFS = "device_identity"
    private const val PREF_PASSWORD = "password"

    @Volatile
    private var ssl: SSLContext? = null

    @Volatile
    private var fingerprintHex: String = ""

    /** Loads the identity, generating it on first run. Safe to call repeatedly. */
    @Synchronized
    fun init(context: Context) {
        if (ssl != null) return
        try {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val password = prefs.getString(PREF_PASSWORD, null) ?: randomPassword().also {
                prefs.edit().putString(PREF_PASSWORD, it).apply()
            }
            load(context.filesDir, password)
            Log.i(TAG, "identity ready fingerprint=$fingerprintHex")
        } catch (e: Exception) {
            Log.w(TAG, "identity init failed", e)
        }
    }

    /**
     * Loads or creates the keystore in [dir]. Kept separate from [init] so the
     * JVM test can run the exact same code without an Android context.
     */
    @Synchronized
    fun load(dir: File, password: String) {
        val file = File(dir, STORE_FILE)
        val store = if (file.exists()) readStore(file, password) else createStore(file, password)
        val cert = store.getCertificate(ALIAS) as X509Certificate
        fingerprintHex = sha256Hex(cert.encoded)
        ssl = buildContext(store, password)
    }

    /** TLS context that trusts any server certificate and presents ours. */
    fun sslContext(): SSLContext? = ssl

    /** SHA-256 of the certificate DER, uppercase hex (LocalSend fingerprint). */
    fun fingerprint(): String = fingerprintHex

    private fun readStore(file: File, password: String): KeyStore =
        KeyStore.getInstance("PKCS12").apply { file.inputStream().use { load(it, password.toCharArray()) } }

    private fun createStore(file: File, password: String): KeyStore {
        val generator = KeyPairGenerator.getInstance("RSA")
        generator.initialize(2048, SecureRandom())
        val keyPair = generator.generateKeyPair()

        val certDer = buildSelfSignedCertificate(keyPair.private.encoded, keyPair.public.encoded)
        val cert = CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(certDer)) as X509Certificate

        val store = KeyStore.getInstance("PKCS12")
        store.load(null, password.toCharArray())
        store.setKeyEntry(ALIAS, keyPair.private, password.toCharArray(), arrayOf(cert))
        dirOf(file).mkdirs()
        FileOutputStream(file).use { store.store(it, password.toCharArray()) }
        return store
    }

    private fun buildContext(store: KeyStore, password: String): SSLContext {
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(store, password.toCharArray())
        val trustAll = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        return SSLContext.getInstance("TLS").apply {
            init(kmf.keyManagers, arrayOf<TrustManager>(trustAll), SecureRandom())
        }
    }

    private fun dirOf(file: File): File = file.parentFile ?: file

    private fun randomPassword(): String {
        val bytes = ByteArray(24)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun sha256Hex(data: ByteArray): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(data)
        return digest.joinToString("") { "%02X".format(it) }
    }

    /** Minimal X.509 v3, self-signed with SHA256withRSA. */
    private fun buildSelfSignedCertificate(pkcs8: ByteArray, spki: ByteArray): ByteArray {
        val signatureAlg = derSeq(
            derOid(byteArrayOf(0x2a, 0x86.toByte(), 0x48, 0x86.toByte(), 0xf7.toByte(), 0x0d, 0x01, 0x01, 0x0b)),
            tlv(0x05, ByteArray(0)) // NULL
        )
        val name = X500Principal("CN=LocalSend User").encoded
        val now = System.currentTimeMillis()
        val validity = derSeq(
            utcTime(Date(now - 24 * 60 * 60 * 1000L)),
            utcTime(Date(now + 20L * 365 * 24 * 60 * 60 * 1000))
        )
        val serial = BigInteger(128, SecureRandom()).abs().add(BigInteger.ONE)

        val tbs = derSeq(
            tlv(0xa0, derInt(byteArrayOf(2))), // [0] version = v3
            derInt(serial.toByteArray()),
            signatureAlg,
            name, // issuer
            validity,
            name, // subject (self-signed)
            spki
        )

        val signer = Signature.getInstance("SHA256withRSA")
        signer.initSign(
            java.security.KeyFactory.getInstance("RSA")
                .generatePrivate(java.security.spec.PKCS8EncodedKeySpec(pkcs8))
        )
        signer.update(tbs)
        val signature = signer.sign()
        return derSeq(tbs, signatureAlg, tlv(0x03, byteArrayOf(0x00) + signature))
    }

    // ---------- minimal DER encoder ----------

    private fun tlv(tag: Int, body: ByteArray): ByteArray =
        byteArrayOf(tag.toByte()) + derLength(body.size) + body

    private fun derLength(len: Int): ByteArray {
        if (len < 0x80) return byteArrayOf(len.toByte())
        var value = len
        val bytes = ByteArrayOutputStream()
        while (value > 0) {
            bytes.write(value and 0xff)
            value = value shr 8
        }
        val raw = bytes.toByteArray().reversedArray()
        return byteArrayOf((0x80 or raw.size).toByte()) + raw
    }

    private fun derSeq(vararg parts: ByteArray): ByteArray {
        val body = ByteArrayOutputStream()
        parts.forEach { body.write(it) }
        return tlv(0x30, body.toByteArray())
    }

    private fun derInt(bytes: ByteArray): ByteArray {
        var value = bytes.dropWhile { it == 0.toByte() }.toByteArray()
        if (value.isEmpty()) value = byteArrayOf(0)
        if (value[0].toInt() and 0x80 != 0) value = byteArrayOf(0) + value
        return tlv(0x02, value)
    }

    private fun derOid(content: ByteArray): ByteArray = tlv(0x06, content)

    private fun utcTime(date: Date): ByteArray {
        val format = SimpleDateFormat("yyMMddHHmmss'Z'", Locale.US)
        format.timeZone = TimeZone.getTimeZone("UTC")
        return tlv(0x17, format.format(date).toByteArray(Charsets.US_ASCII))
    }
}
