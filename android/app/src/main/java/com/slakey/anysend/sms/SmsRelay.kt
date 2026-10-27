package com.slakey.anysend.sms

import android.content.Context
import com.google.gson.Gson
import com.slakey.anysend.protocol.DirectNetworkLayer
import com.slakey.anysend.protocol.LocalSendConst
import com.slakey.anysend.protocol.NetworkLayer
import com.slakey.anysend.protocol.TailscaleNetworkLayer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * The server half of the SMS relay: serves the /api/sms/v1 routes on the
 * existing LocalSend HTTP listener and pushes new incoming messages to the
 * registered HarmonyOS clients (the "callbacks" they hand us in /sync).
 *
 * Every route requires the X-Relay-Token header to match the pairing token
 * generated here and shown on the Android UI — the tailnet/LAN may contain
 * devices that should not read the user's text messages.
 */
class SmsRelay(private val context: Context) {

    private val gson = Gson()
    private val repo = SmsRepository(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** device label -> reachable host:port used to push new messages. */
    private val callbacks = ConcurrentHashMap<String, String>()

    /** Resolved lazily so the token survives without restarting the service. */
    val token: String by lazy {
        val prefs = context.getSharedPreferences("sms_relay", Context.MODE_PRIVATE)
        prefs.getString("token", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("token", it).apply()
        }
    }

    // ------------------------------------------------------------- routing

    data class RelayResponse(val status: Int, val json: String)

    /**
     * Handle one SMS API request. Returns null when [path] is not an SMS
     * route (so the caller can fall through to the LocalSend routes).
     */
    suspend fun handle(
        method: String,
        path: String,
        query: Map<String, String>,
        headers: Map<String, String>,
        body: ByteArray
    ): RelayResponse? {
        if (!path.startsWith(SmsApiConst.PREFIX)) return null

        val sentToken = headers.entries
            .firstOrNull { it.key.equals("x-relay-token", ignoreCase = true) }?.value ?: ""
        if (sentToken != token) {
            return RelayResponse(401, """{"error":"token mismatch"}""")
        }

        return try {
            when {
                method == "GET" && path == SmsApiConst.PATH_PING ->
                    RelayResponse(200, """{"ok":true,"device":"android"}""")

                method == "GET" && path == SmsApiConst.PATH_SIMS ->
                    RelayResponse(200, gson.toJson(SimsResponse(repo.listSims())))

                method == "GET" && path == SmsApiConst.PATH_CONVERSATIONS ->
                    RelayResponse(200, gson.toJson(ConversationsResponse(repo.listConversations())))

                method == "GET" && path == SmsApiConst.PATH_MESSAGES -> {
                    val threadId = query["threadId"]?.toLongOrNull()
                        ?: return RelayResponse(400, """{"error":"threadId required"}""")
                    val beforeId = query["beforeId"]?.toLongOrNull() ?: 0L
                    val limit = (query["limit"]?.toIntOrNull() ?: 50).coerceIn(1, 500)
                    val msgs = repo.listMessages(threadId, beforeId, limit)
                    RelayResponse(200, gson.toJson(MessagesResponse(msgs)))
                }

                method == "POST" && path == SmsApiConst.PATH_SYNC -> {
                    val req = parseJson<SyncRequest>(body)
                    if (req != null && !req.callback.isNullOrBlank() && req.device != null) {
                        callbacks[req.device] = req.callback.trim()
                    }
                    val since = req?.sinceId ?: 0L
                    val (maxId, msgs) = repo.syncSince(since)
                    RelayResponse(
                        200,
                        gson.toJson(
                            SyncResponse(
                                maxId = maxId,
                                messages = msgs,
                                conversations = repo.listConversations(),
                                sims = repo.listSims()
                            )
                        )
                    )
                }

                method == "POST" && path == SmsApiConst.PATH_SEND -> {
                    val req = parseJson<SendSmsRequest>(body)
                        ?: return RelayResponse(400, """{"error":"bad request"}""")
                    val (msg, err) = repo.send(req.address, req.body, req.subscriptionId)
                    if (err != null) {
                        RelayResponse(200, gson.toJson(SendSmsResponse(ok = false, error = err)))
                    } else {
                        RelayResponse(200, gson.toJson(SendSmsResponse(ok = true, message = msg)))
                    }
                }

                method == "POST" && path == SmsApiConst.PATH_MARK_READ -> {
                    val req = parseJson<MarkReadRequest>(body)
                        ?: return RelayResponse(400, """{"error":"bad request"}""")
                    val ok = repo.markThreadRead(req.threadId)
                    RelayResponse(200, """{"ok":$ok}""")
                }

                method == "POST" && path == SmsApiConst.PATH_DELETE -> {
                    val req = parseJson<DeleteMessageRequest>(body)
                        ?: return RelayResponse(400, """{"error":"bad request"}""")
                    val ok = repo.deleteMessage(req.id)
                    RelayResponse(200, """{"ok":$ok}""")
                }

                else -> RelayResponse(404, """{"error":"not found"}""")
            }
        } catch (e: SecurityException) {
            RelayResponse(403, """{"error":"${e.message ?: "permission denied"}"}""")
        } catch (e: Exception) {
            RelayResponse(500, """{"error":"${e.message ?: "internal error"}"}""")
        }
    }

    // --------------------------------------------------------------- push

    /** Called by SmsReceiver for every incoming SMS. */
    fun pushNewMessage(message: SmsMessage) {
        if (callbacks.isEmpty()) return
        scope.launch {
            val envelope = gson.toJson(PushEnvelope(kind = "new-message", message = message))
            for ((device, addr) in callbacks) {
                pushTo(device, addr, SmsApiConst.PATH_PUSH, envelope)
            }
        }
    }

    private suspend fun pushTo(device: String, addr: String, path: String, json: String) =
        withContext(Dispatchers.IO) {
            val network: NetworkLayer = networkFor(addr)
            val conn = network.dial("tcp", "$addr:${LocalSendConst.PORT}")
            if (conn <= 0) return@withContext
            try {
                val payload = json.toByteArray()
                val req = "POST $path HTTP/1.1\r\n" +
                        "Host: $addr:${LocalSendConst.PORT}\r\n" +
                        "X-Relay-Token: $token\r\n" +
                        "Content-Type: application/json\r\n" +
                        "Content-Length: ${payload.size}\r\n" +
                        "Connection: close\r\n\r\n"
                network.write(conn, req.toByteArray())
                network.write(conn, payload)
                // Drain the response so the peer sees a clean close.
                val buf = ByteArray(4096)
                var read = 0
                while (read < 4) {
                    val n = network.read(conn, buf.size) ?: break
                    if (n.isEmpty()) break
                    read++
                }
            } catch (e: Exception) {
                // Push is best-effort; polling on the client covers outages.
                callbacks.remove(device)
            } finally {
                network.closeConn(conn)
            }
        }

    /** Tailscale addresses live in 100.64.0.0/10 (RFC 6598). */
    private fun networkFor(addr: String): NetworkLayer {
        val host = addr.substringBefore(':')
        val parts = host.split('.').mapNotNull { it.toIntOrNull() }
        return if (parts.size == 4 && parts[0] == 100 && parts[1] in 64..127) {
            TailscaleNetworkLayer()
        } else {
            DirectNetworkLayer()
        }
    }

    private inline fun <reified T> parseJson(body: ByteArray): T? = try {
        gson.fromJson(String(body), T::class.java)
    } catch (e: Exception) {
        null
    }
}

private data class SimsResponse(val sims: List<SimCard>)
private data class ConversationsResponse(val conversations: List<Conversation>)
private data class MessagesResponse(val messages: List<SmsMessage>)

/** Route constants shared with the HarmonyOS client. */
object SmsApiConst {
    const val PREFIX = "/api/sms/v1"
    const val PATH_PING = "$PREFIX/ping"
    const val PATH_SIMS = "$PREFIX/sims"
    const val PATH_CONVERSATIONS = "$PREFIX/conversations"
    const val PATH_MESSAGES = "$PREFIX/messages"
    const val PATH_SYNC = "$PREFIX/sync"
    const val PATH_SEND = "$PREFIX/send"
    const val PATH_PUSH = "$PREFIX/push"
    const val PATH_MARK_READ = "$PREFIX/mark-read"
    const val PATH_DELETE = "$PREFIX/delete"
}
