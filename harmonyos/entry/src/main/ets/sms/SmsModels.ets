// SMS relay data models for HarmonyOS (ArkTS).
// Field names MUST match the Android implementation (sms/SmsModels.kt).

/** Route constants shared with the Android host. */
interface SmsApiConstType {
  PREFIX: string;
  PATH_PING: string;
  PATH_SIMS: string;
  PATH_CONVERSATIONS: string;
  PATH_MESSAGES: string;
  PATH_SYNC: string;
  PATH_SEND: string;
  PATH_PUSH: string;
  PATH_MARK_READ: string;
  PATH_DELETE: string;
}

export const SmsApiConst: SmsApiConstType = {
  PREFIX: '/api/sms/v1',
  PATH_PING: '/api/sms/v1/ping',
  PATH_SIMS: '/api/sms/v1/sims',
  PATH_CONVERSATIONS: '/api/sms/v1/conversations',
  PATH_MESSAGES: '/api/sms/v1/messages',
  PATH_SYNC: '/api/sms/v1/sync',
  PATH_SEND: '/api/sms/v1/send',
  PATH_PUSH: '/api/sms/v1/push',
  PATH_MARK_READ: '/api/sms/v1/mark-read',
  PATH_DELETE: '/api/sms/v1/delete'
};

/** Message type values, mirroring Android Telephony.Sms. */
export const MSG_TYPE_INBOX: number = 1;
export const MSG_TYPE_SENT: number = 2;

/** Client-side send status (negative-id messages only). */
export type SendStatus = 'sending' | 'sent' | 'failed';

/** One SMS, from either the inbox or the sent folder. */
export interface SmsMessage {
  id: number;
  threadId: number;
  address: string;
  contactName: string | null;
  body: string;
  /** Epoch millis: when the message arrived (inbox) or was stored (sent). */
  date: number;
  dateSent: number;
  /** 1=inbox, 2=sent, 3=draft, 4=outbox, 5=failed. */
  type: number;
  /** SIM subscription id, or -1 when unknown. */
  subId: number;
  read: boolean;
  /** Client-side only: set on optimistic placeholders, never from the wire. */
  clientStatus?: SendStatus;
  /** Client-side only: send failure reason for failed placeholders. */
  clientError?: string;
}

/** A conversation thread, one entry per counterpart. */
export interface Conversation {
  threadId: number;
  address: string;
  contactName: string | null;
  snippet: string;
  date: number;
  unread: number;
  subId: number;
  messageCount: number;
}

/** An active SIM subscription on the Android host. */
export interface SimCard {
  subscriptionId: number;
  slotIndex: number;
  displayName: string;
  carrierName: string;
  number: string;
}

export interface SyncRequest {
  sinceId: number;
  callback: string;
  device: string;
}

export interface SyncResponse {
  maxId: number;
  messages: SmsMessage[];
  conversations: Conversation[];
  sims: SimCard[];
}

export interface SendSmsRequest {
  address: string;
  body: string;
  subscriptionId: number;
}

export interface SendSmsResponse {
  ok: boolean;
  error?: string | null;
  message?: SmsMessage | null;
}

/** POST /push body: Android -> HarmonyOS notification of a new SMS. */
export interface PushEnvelope {
  kind: string;
  message: SmsMessage;
}

export interface MessagesResponse {
  messages: SmsMessage[];
}

export interface ConversationsResponse {
  conversations: Conversation[];
}

export interface SimsResponse {
  sims: SimCard[];
}

/** Generic OK envelope used by mark-read/delete. */
export interface OkResponse {
  ok: boolean;
}
