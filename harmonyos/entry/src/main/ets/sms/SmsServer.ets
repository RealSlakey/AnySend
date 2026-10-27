// Server half of the SMS relay on HarmonyOS: handles /api/sms/v1/push
// (Android -> HarmonyOS new-message notifications) served by the existing
// LocalSend HTTP listener.
//
// The body is decoded as UTF-8 here — message bodies are usually Chinese
// and would be mangled by the charCode-based decoder used for the file
// transfer routes.

import { utf8Decode } from './SmsClient';
import { PushEnvelope, SmsApiConst } from './SmsModels';
import { SmsStore } from './SmsStore';

export interface SmsRouteResponse {
  status: number;
  body: string;
}

function headerValue(headers: Record<string, string>, want: string): string {
  const keys = Object.keys(headers);
  for (const k of keys) {
    if (k.toLowerCase() === want) {
      return headers[k];
    }
  }
  return '';
}

/**
 * Returns null when [path] is not an SMS route (caller falls through to the
 * LocalSend routes).
 */
export function handleSmsServerRequest(
  method: string,
  path: string,
  headers: Record<string, string>,
  body: ArrayBuffer
): SmsRouteResponse | null {
  if (!path.startsWith(SmsApiConst.PREFIX)) {
    return null;
  }
  const store = SmsStore.getInstance();
  if (path === SmsApiConst.PATH_PUSH && method === 'POST') {
    if (store.token.length === 0 || headerValue(headers, 'x-relay-token') !== store.token) {
      const denied: SmsRouteResponse = { status: 401, body: '{"error":"token mismatch"}' };
      return denied;
    }
    try {
      const env = JSON.parse(utf8Decode(new Uint8Array(body))) as PushEnvelope;
      store.onPushEnvelope(env);
      const ok: SmsRouteResponse = { status: 200, body: '{"ok":true}' };
      return ok;
    } catch (e) {
      const bad: SmsRouteResponse = { status: 400, body: '{"error":"bad request"}' };
      return bad;
    }
  }
  const nf: SmsRouteResponse = { status: 404, body: '{"error":"not found"}' };
  return nf;
}
