package com.slakey.anysend.sms

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.telephony.SubscriptionManager

/**
 * Receives incoming SMS broadcasts (registered dynamically by BridgeService
 * while the relay is running) and forwards each message to SmsRelay for
 * push delivery to the paired HarmonyOS device.
 *
 * Note: the message also lands in content://sms asynchronously; the client
 * deduplicates by (type, date, body) when the later /sync returns the stored
 * row.
 */
class SmsReceiver(private val onMessage: (SmsMessage) -> Unit) : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        // Flat array: one entry per PDU segment (multipart SMS = several).
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val subId = intent.getIntExtra("subscription", SubscriptionManager.INVALID_SUBSCRIPTION_ID)

        // Concatenate segments grouped by originating address so a long SMS
        // arrives as one body; different senders in one broadcast stay apart.
        val bySender = LinkedHashMap<String, StringBuilder>()
        var firstDate = Long.MAX_VALUE
        var sentDate = 0L
        for (m in messages) {
            val key = m?.originatingAddress ?: ""
            bySender.getOrPut(key) { StringBuilder() }.append(m?.displayMessageBody ?: "")
            val ts = m?.timestampMillis ?: 0L
            if (ts > 0) {
                firstDate = minOf(firstDate, ts)
                sentDate = maxOf(sentDate, ts)
            }
        }
        for ((address, body) in bySender) {
            val now = System.currentTimeMillis()
            val date = if (firstDate == Long.MAX_VALUE) now else firstDate
            onMessage(
                SmsMessage(
                    id = -1, // not yet in the provider
                    threadId = -1,
                    address = address,
                    contactName = null, // filled by the client via conversations refresh
                    body = body.toString(),
                    date = date,
                    dateSent = if (sentDate > 0) sentDate else date,
                    type = Telephony.Sms.MESSAGE_TYPE_INBOX,
                    subId = if (subId != SubscriptionManager.INVALID_SUBSCRIPTION_ID) subId else -1,
                    read = false
                )
            )
        }
    }
}
