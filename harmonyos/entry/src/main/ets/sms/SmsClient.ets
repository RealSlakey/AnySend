// HTTP client for the SMS relay API (/api/sms/v1/*), speaking raw HTTP over
// the provided NetworkLayer — the same approach as LocalSendSender, because
// in Tailscale mode the system HTTP stack cannot reach the userspace
// netstack.
//
// Unlike LocalSendSender this client handles UTF-8 properly: SMS bodies are
// almost always Chinese, so raw bytes are accumulated and decoded once with
// util.TextDecoder instead of charCode-by-charCode.

import { util } from '@kit.ArkTS';
import { NetworkLayer } from '../protocol/NetworkLayer';
import { SmsApiConst } from './SmsModels';

interface RawResponse {
  status: number;
  body: Uint8Array;
}

export interface SmsHttpResult {
  status: number;
  bodyText: string;
}

const encoder = new util.TextEncoder();
const decoder = new util.TextDecoder('utf-8');

export function utf8Decode(bytes: Uint8Array): string {
  return decoder.decodeWithStream(bytes);
}

export function utf8Encode(str: string): ArrayBuffer {
  const u8: Uint8Array = encoder.encode(str);
  const ab = new ArrayBuffer(u8.length);
  new Uint8Array(ab).set(u8);
  return ab;
}

export class SmsClient {
  private host: string; // host:port
  private token: string;
  private network: NetworkLayer;

  constructor(host: string, token: string, network: NetworkLayer) {
    this.host = host;
    this.token = token;
    this.network = network;
  }

  private async request(method: string, path: string, body: string | null): Promise<SmsHttpResult> {
    const conn = await this.network.dial('tcp', this.host);
    if (conn <= 0) {
      const failed: SmsHttpResult = { status: 0, bodyText: '{"error":"dial failed"}' };
      return failed;
    }
    try {
      const bodyBytes: ArrayBuffer = body !== null ? utf8Encode(body) : new ArrayBuffer(0);
      const head: string = `${method} ${path} HTTP/1.1\r\n` +
        `Host: ${this.host}\r\n` +
        `X-Relay-Token: ${this.token}\r\n` +
        'Content-Type: application/json\r\n' +
        `Content-Length: ${bodyBytes.byteLength}\r\n` +
        'Connection: close\r\n\r\n';
      await this.network.write(conn, utf8Encode(head));
      if (bodyBytes.byteLength > 0) {
        await this.network.write(conn, bodyBytes);
      }
      const raw: RawResponse = await this.readResponse(conn);
      const result: SmsHttpResult = { status: raw.status, bodyText: utf8Decode(raw.body) };
      return result;
    } finally {
      this.network.closeConn(conn);
    }
  }

  /** Accumulate raw response bytes; decode the body once at the end. */
  private async readResponse(conn: number): Promise<RawResponse> {
    let chunks: Uint8Array[] = [];
    let total = 0;
    let headerEnd = -1; // index within the concatenated byte stream
    while (headerEnd < 0) {
      const result = await this.network.read(conn, 8192);
      if (result.data.byteLength === 0) {
        break;
      }
      const chunk = new Uint8Array(result.data);
      chunks.push(chunk);
      total += chunk.length;
      headerEnd = findHeaderEnd(chunks);
    }
    if (headerEnd < 0) {
      const empty: RawResponse = { status: 0, body: new Uint8Array(0) };
      return empty;
    }

    // Status line sits in the first bytes; headers are ASCII so decoding
    // them alone is safe.
    const headBytes = concatFrom(chunks, 0, headerEnd);
    const headStr = asciiDecode(headBytes);
    const statusLine = headStr.split('\r\n')[0].split(' ');
    const status = statusLine.length >= 2 ? parseInt(statusLine[1], 10) : 0;
    const contentLength = parseContentLength(headStr);

    const bodyStart = headerEnd + 4;
    let bodyBytes: Uint8Array = concatFrom(chunks, bodyStart, total);
    while (contentLength > 0 && bodyBytes.length < contentLength) {
      const result = await this.network.read(conn, 8192);
      if (result.data.byteLength === 0) {
        break;
      }
      const chunk = new Uint8Array(result.data);
      chunks.push(chunk);
      total += chunk.length;
      bodyBytes = concatFrom(chunks, bodyStart, total);
    }
    const resp: RawResponse = { status: status, body: bodyBytes };
    return resp;
  }

  // ----------------------------------------------------------- API calls

  async ping(): Promise<boolean> {
    const r = await this.request('GET', SmsApiConst.PATH_PING, null);
    return r.status === 200;
  }

  async sync(sinceId: number, callback: string, device: string): Promise<string> {
    const payload: string = JSON.stringify({ sinceId: sinceId, callback: callback, device: device });
    const r = await this.request('POST', SmsApiConst.PATH_SYNC, payload);
    if (r.status !== 200) {
      return '';
    }
    return r.bodyText;
  }

  async getMessages(threadId: number, beforeId: number, limit: number): Promise<string> {
    const path = `${SmsApiConst.PATH_MESSAGES}?threadId=${threadId}&beforeId=${beforeId}&limit=${limit}`;
    const r = await this.request('GET', path, null);
    if (r.status !== 200) {
      return '';
    }
    return r.bodyText;
  }

  async getConversations(): Promise<string> {
    const r = await this.request('GET', SmsApiConst.PATH_CONVERSATIONS, null);
    if (r.status !== 200) {
      return '';
    }
    return r.bodyText;
  }

  async getSims(): Promise<string> {
    const r = await this.request('GET', SmsApiConst.PATH_SIMS, null);
    if (r.status !== 200) {
      return '';
    }
    return r.bodyText;
  }

  async send(address: string, body: string, subscriptionId: number): Promise<string> {
    const payload: string = JSON.stringify({ address: address, body: body, subscriptionId: subscriptionId });
    const r = await this.request('POST', SmsApiConst.PATH_SEND, payload);
    if (r.status !== 200) {
      return '';
    }
    return r.bodyText;
  }

  async markRead(threadId: number): Promise<void> {
    const payload: string = JSON.stringify({ threadId: threadId });
    await this.request('POST', SmsApiConst.PATH_MARK_READ, payload);
  }

  async deleteMessage(id: number): Promise<void> {
    const payload: string = JSON.stringify({ id: id });
    await this.request('POST', SmsApiConst.PATH_DELETE, payload);
  }
}

// ------------------------------------------------------------ helpers

/** Locate \r\n\r\n across chunk boundaries. Returns absolute index or -1. */
function findHeaderEnd(chunks: Uint8Array[]): number {
  let offset = 0;
  let prevTail: Uint8Array = new Uint8Array(0);
  for (const chunk of chunks) {
    const merged = new Uint8Array(prevTail.length + chunk.length);
    merged.set(prevTail, 0);
    merged.set(chunk, prevTail.length);
    for (let i = 0; i + 3 < merged.length; i++) {
      if (merged[i] === 13 && merged[i + 1] === 10 && merged[i + 2] === 13 && merged[i + 3] === 10) {
        return offset - prevTail.length + i;
      }
    }
    // Keep the last 3 bytes to catch a boundary-straddling separator.
    const keep = Math.min(3, merged.length);
    prevTail = merged.slice(merged.length - keep);
    offset += chunk.length;
  }
  return -1;
}

/** Copy [from, from+count) out of the concatenated chunk stream. */
function concatFrom(chunks: Uint8Array[], from: number, count: number): Uint8Array {
  const end = Math.min(from + count, chunks.reduce((acc, c) => acc + c.length, 0));
  const size = Math.max(0, end - from);
  const out = new Uint8Array(size);
  let written = 0;
  let offset = 0;
  for (const chunk of chunks) {
    const chunkEnd = offset + chunk.length;
    const copyStart = Math.max(from, offset);
    const copyEnd = Math.min(end, chunkEnd);
    if (copyEnd > copyStart) {
      out.set(chunk.subarray(copyStart - offset, copyEnd - offset), written);
      written += copyEnd - copyStart;
    }
    offset = chunkEnd;
  }
  return out;
}

function asciiDecode(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    s += String.fromCharCode(bytes[i]);
  }
  return s;
}

function parseContentLength(headStr: string): number {
  const lines = headStr.split('\r\n');
  for (let i = 1; i < lines.length; i++) {
    const idx = lines[i].indexOf(':');
    if (idx > 0 && lines[i].substring(0, idx).trim().toLowerCase() === 'content-length') {
      return parseInt(lines[i].substring(idx + 1).trim(), 10) || 0;
    }
  }
  return 0;
}
