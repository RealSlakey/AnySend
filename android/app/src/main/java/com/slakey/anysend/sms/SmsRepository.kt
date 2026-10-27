package com.slakey.anysend.sms

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Reads and writes the device SMS database (content://sms) and the SIM
 * subscription list. All operations degrade gracefully when the matching
 * runtime permission is missing: callers get an empty result or an error
 * message instead of a crash.
 */
class SmsRepository(private val context: Context) {

    /** number -> display name cache, refreshed per conversations listing. */
    private val contactCache = ConcurrentHashMap<String, String>()

    fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    fun canRead(): Boolean = hasPermission(Manifest.permission.READ_SMS)
    fun canSend(): Boolean = hasPermission(Manifest.permission.SEND_SMS)

    // ---------------------------------------------------------------- sims

    fun listSims(): List<SimCard> {
        if (!hasPermission(Manifest.permission.READ_PHONE_STATE)) return emptyList()
        return try {
            val sm = context.getSystemService(SubscriptionManager::class.java) ?: return emptyList()
            val subs = sm.activeSubscriptionInfoList ?: return emptyList()
            subs.map {
                SimCard(
                    subscriptionId = it.subscriptionId,
                    slotIndex = it.simSlotIndex + 1, // human 1-based
                    displayName = it.displayName?.toString() ?: "SIM",
                    carrierName = it.carrierName?.toString() ?: "",
                    number = it.number ?: ""
                )
            }.sortedBy { it.slotIndex }
        } catch (e: SecurityException) {
            emptyList()
        }
    }

    // ------------------------------------------------------- conversations

    /**
     * Most recent conversations, newest first. Derived from the sms table
     * rather than content://sms/conversations: several ROMs only expose
     * thread_id/snippet on that view (no date/message_count/read/address), so
     * the usual projection fails outright with "Invalid column date".
     */
    fun listConversations(limit: Int = 100): List<Conversation> {
        if (!canRead()) return emptyList()
        // Walk messages newest-first; the first hit of a thread is its latest
        // message, which gives address, SIM, snippet and sort key in one pass.
        val byThread = LinkedHashMap<Long, Conversation>()
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(
                Telephony.Sms.THREAD_ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.SUBSCRIPTION_ID
            ),
            null, null,
            "${Telephony.Sms.DATE} DESC"
        )?.use { c ->
            while (byThread.size < limit && c.moveToNext()) {
                val threadId = c.getLong(0)
                if (threadId <= 0 || byThread.containsKey(threadId)) continue
                val address = c.getString(1) ?: ""
                byThread[threadId] = Conversation(
                    threadId = threadId,
                    address = address,
                    contactName = resolveContact(address),
                    snippet = (c.getString(2) ?: "").replace('\n', ' '),
                    date = c.getLong(3),
                    unread = 0,
                    subId = c.getInt(4),
                    messageCount = 0
                )
            }
        }
        if (byThread.isEmpty()) return emptyList()

        // Unread counts for those threads, in a single pass over the inbox.
        val unread = HashMap<Long, Int>()
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms.THREAD_ID),
            "${Telephony.Sms.READ}=0 AND ${Telephony.Sms.TYPE}=${Telephony.Sms.MESSAGE_TYPE_INBOX}",
            null, null
        )?.use { c ->
            while (c.moveToNext()) {
                val threadId = c.getLong(0)
                if (byThread.containsKey(threadId)) unread[threadId] = (unread[threadId] ?: 0) + 1
            }
        }
        return byThread.map { (threadId, conv) ->
            if (unread.containsKey(threadId)) conv.copy(unread = unread.getValue(threadId)) else conv
        }
    }

    // ------------------------------------------------------------ messages

    /** One thread's messages, newest last. Paginates backwards via [beforeId]. */
    fun listMessages(threadId: Long, beforeId: Long, limit: Int): List<SmsMessage> {
        if (!canRead()) return emptyList()
        val selection: String
        val args: Array<String>
        if (beforeId > 0) {
            selection = "${Telephony.Sms.THREAD_ID}=? AND ${Telephony.Sms._ID}<?"
            args = arrayOf(threadId.toString(), beforeId.toString())
        } else {
            selection = "${Telephony.Sms.THREAD_ID}=?"
            args = arrayOf(threadId.toString())
        }
        return queryMessages(selection, args, "${Telephony.Sms.DATE} DESC, ${Telephony.Sms._ID} DESC", limit).reversed()
    }

    /** Messages newer than [sinceId] across all folders — the incremental sync. */
    fun syncSince(sinceId: Long, limit: Int = 300): Pair<Long, List<SmsMessage>> {
        if (!canRead()) return sinceId to emptyList()
        val msgs = queryMessages(
            "${Telephony.Sms._ID}>?",
            arrayOf(sinceId.toString()),
            "${Telephony.Sms._ID} ASC",
            limit
        )
        val max = msgs.lastOrNull()?.id ?: sinceId
        return max to msgs
    }

    private fun queryMessages(selection: String, args: Array<String>, order: String, limit: Int): List<SmsMessage> {
        val out = mutableListOf<SmsMessage>()
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(
                Telephony.Sms._ID,
                Telephony.Sms.THREAD_ID,
                Telephony.Sms.ADDRESS,
                Telephony.Sms.BODY,
                Telephony.Sms.DATE,
                Telephony.Sms.DATE_SENT,
                Telephony.Sms.TYPE,
                Telephony.Sms.SUBSCRIPTION_ID,
                Telephony.Sms.READ
            ),
            selection, args, order
        )?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                val address = c.getString(2) ?: ""
                out.add(
                    SmsMessage(
                        id = c.getLong(0),
                        threadId = c.getLong(1),
                        address = address,
                        contactName = resolveContact(address),
                        body = c.getString(3) ?: "",
                        date = c.getLong(4),
                        dateSent = c.getLong(5),
                        type = c.getInt(6),
                        subId = c.getInt(7),
                        read = c.getInt(8) != 0
                    )
                )
            }
        }
        return out
    }

    // ------------------------------------------------------------- actions

    /** Mark a whole thread read (called when the user opens a chat). */
    fun markThreadRead(threadId: Long): Boolean {
        if (!canRead()) return false
        // 非默认短信应用的 OP_WRITE_SMS 被系统置为 ignore，写入不抛异常也不生效
        // （影响行数 0）。这里通过 Shizuku 临时放行，写完立刻还原；放行不了就
        // 如实返回失败，不再静默吞掉。
        return SmsWriteAccessController.withSmsWriteAccess(context) {
            val values = android.content.ContentValues()
            values.put(Telephony.Sms.READ, 1)
            val n = context.contentResolver.update(
                Telephony.Sms.CONTENT_URI,
                values,
                "${Telephony.Sms.THREAD_ID}=? AND ${Telephony.Sms.READ}=0",
                arrayOf(threadId.toString())
            )
            n > 0
        }
    }

    fun deleteMessage(id: Long): Boolean {
        if (!canRead()) return false
        return SmsWriteAccessController.withSmsWriteAccess(context) {
            val n = context.contentResolver.delete(
                Telephony.Sms.CONTENT_URI,
                "${Telephony.Sms._ID}=?",
                arrayOf(id.toString())
            )
            n > 0
        }
    }

    /**
     * Send an SMS with a specific SIM and block until the telephony stack
     * reports the result (or 20s elapse). Returns the stored sent copy on
     * success — read back from the provider so ids/dates match reality.
     */
    suspend fun send(address: String, body: String, subscriptionId: Int): Pair<SmsMessage?, String?> =
        withContext(Dispatchers.IO) {
            if (!canSend()) return@withContext null to "缺少 SEND_SMS 权限"
            try {
                val sm: SmsManager = if (subscriptionId > 0) {
                    SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
                } else {
                    context.getSystemService(SmsManager::class.java)
                } ?: return@withContext null to "SmsManager 不可用"

                val sentAction = "com.slakey.anysend.SMS_SENT.${UUID.randomUUID()}"
                val latch = CountDownLatch(1)
                var error: String? = null
                val receiver = object : android.content.BroadcastReceiver() {
                    override fun onReceive(ctx: Context, intent: android.content.Intent) {
                        error = when (resultCode) {
                            android.app.Activity.RESULT_OK -> null
                            SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "发送失败（generic failure）"
                            SmsManager.RESULT_ERROR_RADIO_OFF -> "发送失败（无线电关闭）"
                            SmsManager.RESULT_ERROR_NULL_PDU -> "发送失败（PDU 为空）"
                            SmsManager.RESULT_ERROR_NO_SERVICE -> "发送失败（无服务）"
                            else -> "发送失败（code=$resultCode）"
                        }
                        latch.countDown()
                    }
                }
                ContextCompat.registerReceiver(
                    context, receiver, android.content.IntentFilter(sentAction),
                    ContextCompat.RECEIVER_EXPORTED
                )
                val pi = android.app.PendingIntent.getBroadcast(
                    context, 0, android.content.Intent(sentAction),
                    android.app.PendingIntent.FLAG_IMMUTABLE
                )
                try {
                    sm.sendTextMessage(address, null, body, pi, null)
                    latch.await(20, TimeUnit.SECONDS)
                } finally {
                    try {
                        context.unregisterReceiver(receiver)
                    } catch (_: IllegalArgumentException) {
                    }
                }

                if (error != null) return@withContext null to error

                // The sent copy is usually stored before the broadcast fires,
                // but give the provider a moment just in case.
                var stored: SmsMessage? = null
                repeat(5) {
                    stored = latestSentTo(address, body)
                    if (stored != null) return@repeat
                    Thread.sleep(200)
                }
                stored to null
            } catch (e: SecurityException) {
                null to "缺少 SEND_SMS 权限"
            } catch (e: Exception) {
                null to (e.message ?: "发送异常")
            }
        }

    private fun latestSentTo(address: String, body: String): SmsMessage? {
        return try {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(
                    Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS,
                    Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.DATE_SENT,
                    Telephony.Sms.TYPE, Telephony.Sms.SUBSCRIPTION_ID, Telephony.Sms.READ
                ),
                "${Telephony.Sms.ADDRESS}=? AND ${Telephony.Sms.BODY}=? AND ${Telephony.Sms.TYPE}=${Telephony.Sms.MESSAGE_TYPE_SENT}",
                arrayOf(address, body),
                "${Telephony.Sms.DATE} DESC"
            )?.use { c ->
                if (c.moveToFirst()) {
                    SmsMessage(
                        id = c.getLong(0),
                        threadId = c.getLong(1),
                        address = c.getString(2) ?: address,
                        contactName = resolveContact(c.getString(2) ?: address),
                        body = c.getString(3) ?: body,
                        date = c.getLong(4),
                        dateSent = c.getLong(5),
                        type = c.getInt(6),
                        subId = c.getInt(7),
                        read = true
                    )
                } else null
            }
        } catch (e: Exception) {
            null
        }
    }

    // ------------------------------------------------------------- contacts

    /** Resolve a phone number to a display name; null when unknown/no permission. */
    fun resolveContact(number: String): String? {
        if (number.isEmpty()) return null
        contactCache[number]?.let { return it.ifEmpty { null } }
        if (!hasPermission(Manifest.permission.READ_CONTACTS)) return null
        return try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null, null, null
            )?.use { c ->
                if (c.moveToFirst()) {
                    val name = c.getString(0) ?: ""
                    contactCache[number] = name
                    name.ifEmpty { null }
                } else {
                    contactCache[number] = ""
                    null
                }
            }
        } catch (e: SecurityException) {
            null
        }
    }
}
