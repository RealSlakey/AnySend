package com.slakey.anysend.sms

/**
 * SMS relay data models. Field names are serialized as-is by Gson and must
 * stay in sync with the HarmonyOS client (sms/SmsModels.ets).
 */

/** One SMS, from either the inbox or the sent folder. */
data class SmsMessage(
    val id: Long,
    val threadId: Long,
    val address: String,
    val contactName: String?,
    val body: String,
    /** Epoch millis: when the message arrived (inbox) or was stored (sent). */
    val date: Long,
    /** Epoch millis: when the sender originally sent it (SMSC timestamp). */
    val dateSent: Long,
    /** Telephony.Sms.MESSAGE_TYPE_*: 1=inbox, 2=sent, 3=draft, 4=outbox, 5=failed. */
    val type: Int,
    /** Subscription (SIM) id, or -1 when unknown. */
    val subId: Int,
    val read: Boolean
)

/** A conversation thread, one entry per counterpart. */
data class Conversation(
    val threadId: Long,
    val address: String,
    val contactName: String?,
    val snippet: String,
    val date: Long,
    val unread: Int,
    val subId: Int,
    val messageCount: Int
)

/** An active SIM subscription. */
data class SimCard(
    val subscriptionId: Int,
    val slotIndex: Int,
    val displayName: String,
    val carrierName: String,
    val number: String
)

/** POST /api/sms/v1/sync body. */
data class SyncRequest(
    val sinceId: Long = 0,
    /** Reachable address (host:port) of the caller, used to push new messages. */
    val callback: String? = null,
    val device: String? = null
)

/** POST /api/sms/v1/sync response: everything the client needs in one roundtrip. */
data class SyncResponse(
    val maxId: Long,
    val messages: List<SmsMessage>,
    val conversations: List<Conversation>,
    val sims: List<SimCard>
)

/** POST /api/sms/v1/send body. */
data class SendSmsRequest(
    val address: String,
    val body: String,
    /** SIM subscription to send with; <=0 means the default subscription. */
    val subscriptionId: Int = 0
)

/** POST /api/sms/v1/send response. */
data class SendSmsResponse(
    val ok: Boolean,
    val error: String? = null,
    /** The stored copy of the sent message (null on failure). */
    val message: SmsMessage? = null
)

/** POST /api/sms/v1/push body: Android -> HarmonyOS notification of a new SMS. */
data class PushEnvelope(
    val kind: String, // "new-message"
    val message: SmsMessage
)

/** POST /api/sms/v1/mark-read body. */
data class MarkReadRequest(
    val threadId: Long
)

/** POST /api/sms/v1/delete body. */
data class DeleteMessageRequest(
    val id: Long
)
