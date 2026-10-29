// LocalSend sender for HarmonyOS. Routes all traffic through the provided
// NetworkLayer (either Tailscale userspace netstack or system sockets in
// Direct LAN mode).

import { NetworkLayer } from './NetworkLayer';
import {
  LocalSendConst,
  DeviceInfo,
  FileInfo,
  SendRequest,
  SendRequestResponse,
  createDeviceInfo,
  guessMime
} from './LocalSendModels';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import util from '@ohos.util';

interface HttpResponse {
  status: number;
  headers: Record<string, string>;
  body: ArrayBuffer;
}

export interface SendRequestResult {
  response: SendRequestResponse;
  fileIdToPath: Record<string, string>;
}

/** prepare-upload 的四种结局。 */
export enum SendOutcomeKind {
  ACCEPTED = 0,
  /** 接收端要求配对码，但我们还没填。 */
  NEED_PIN = 1,
  /** 填了配对码，但被拒。 */
  WRONG_PIN = 2,
  /** 其它失败，status 为 HTTP 码（负数表示传输层失败）。 */
  REJECTED = 3
}

export interface SendOutcome {
  kind: SendOutcomeKind;
  result: SendRequestResult | null;
  status: number;
}

export class LocalSendSender {
  private receiverIp: string;
  private selfInfo: DeviceInfo;
  private network: NetworkLayer;

  /**
   * 明文请求连上了却拿不到任何 HTTP 响应 —— 说明对端只讲 HTTPS。
   * 鸿蒙的 TLSSocket 只信任系统 CA，无法接受 LocalSend 的自签证书，
   * 调用方据此给出明确提示，而不是笼统的“连接失败”。
   */
  peerNeedsTls: boolean = false;

  constructor(receiverIp: string, selfInfo: DeviceInfo, network: NetworkLayer) {
    this.receiverIp = receiverIp;
    this.selfInfo = selfInfo;
    this.network = network;
  }

  private async openConn(): Promise<number> {
    return this.network.dial('tcp', `${this.receiverIp}:${LocalSendConst.PORT}`);
  }

  /** Send a raw HTTP request over the network layer socket. */
  private async httpRequest(method: string, path: string, contentType: string | null, body: ArrayBuffer | null): Promise<HttpResponse> {
    const conn = await this.openConn();
    if (conn <= 0) {
      // -1：套接字都没打开，不存在“对端讲什么协议”这一信息。
      return { status: -1, headers: {}, body: new ArrayBuffer(0) };
    }
    try {
      const headerLines: string[] = [];
      headerLines.push(`${method} ${path} HTTP/1.1`);
      headerLines.push(`Host: ${this.receiverIp}:${LocalSendConst.PORT}`);
      headerLines.push('Connection: close');
      if (contentType) {
        headerLines.push(`Content-Type: ${contentType}`);
      }
      const bodyLen = body ? body.byteLength : 0;
      headerLines.push(`Content-Length: ${bodyLen}`);
      const headerStr = headerLines.join('\r\n') + '\r\n\r\n';
      await this.network.write(conn, stringToArrayBuffer(headerStr));
      if (body && body.byteLength > 0) {
        await this.network.write(conn, body);
      }
      return await this.readHttpResponse(conn);
    } finally {
      this.network.closeConn(conn);
    }
  }

  private async readHttpResponse(conn: number): Promise<HttpResponse> {
    // Byte-level buffering: the body must never pass through string
    // conversion (UTF-8 text and binary payloads would both corrupt).
    let rawBytes = new Uint8Array(0);
    let headerEnd = -1;
    while (headerEnd < 0) {
      const result = await this.network.read(conn, 8192);
      if (result.data.byteLength === 0) {
        break;
      }
      rawBytes = appendBytes(rawBytes, new Uint8Array(result.data));
      headerEnd = findHeaderEnd(rawBytes);
    }
    if (headerEnd < 0) {
      return { status: 0, headers: {}, body: new ArrayBuffer(0) };
    }
    const headerSection = utf8Decode(rawBytes.subarray(0, headerEnd));
    const lines = headerSection.split('\r\n');
    const statusParts = lines[0].split(' ');
    const status = statusParts.length >= 2 ? parseInt(statusParts[1], 10) : 0;

    const headers: Record<string, string> = {};
    for (let i = 1; i < lines.length; i++) {
      const idx = lines[i].indexOf(':');
      if (idx > 0) {
        const key = lines[i].substring(0, idx).trim().toLowerCase();
        const value = lines[i].substring(idx + 1).trim();
        headers[key] = value;
      }
    }

    const contentLength = headers['content-length'] ? parseInt(headers['content-length'], 10) : 0;
    const bodyStart = headerEnd + 4;
    let body = rawBytes.length > bodyStart ? rawBytes.subarray(bodyStart) : new Uint8Array(0);
    while (body.length < contentLength) {
      const result = await this.network.read(conn, 8192);
      if (result.data.byteLength === 0) {
        break;
      }
      body = appendBytes(body, new Uint8Array(result.data));
    }
    const finalBytes = contentLength > 0 && body.length > contentLength ? body.subarray(0, contentLength) : body;
    return { status: status, headers: headers, body: finalBytes.slice().buffer as ArrayBuffer };
  }

  /**
   * Step 1: register. Returns receiver's DeviceInfo or null.
   *
   * 顺带识别传输协议：明文连上却读不到 HTTP 响应（status 0）说明对端只
   * 提供 HTTPS，置位 [peerNeedsTls] 让界面给出准确提示。
   */
  async register(): Promise<DeviceInfo | null> {
    const body = stringToArrayBuffer(JSON.stringify(this.selfInfo));
    const resp = await this.httpRequest('POST', LocalSendConst.PATH_REGISTER, 'application/json', body);
    if (resp.status === 0) {
      this.peerNeedsTls = true;
      return null;
    }
    if (resp.status !== 200) {
      return null;
    }
    try {
      return JSON.parse(arrayBufferToString(resp.body)) as DeviceInfo;
    } catch (e) {
      return null;
    }
  }

  /**
   * Step 2: announce the files and collect per-file upload tokens.
   *
   * [pin] 只在接收端要求时携带；401 表示需要配对码（或配对码错误）。
   */
  async sendRequest(filePaths: string[], pin?: string): Promise<SendOutcome> {
    const fileIdToPath: Record<string, string> = {};
    const files: Record<string, FileInfo> = {};
    for (const path of filePaths) {
      const fileName = extractFileName(path);
      const size = getFileSize(path);
      const id = generateUUID();
      fileIdToPath[id] = path;
      files[id] = {
        id: id,
        fileName: fileName,
        size: size,
        fileType: guessMime(fileName)
      };
    }
    const trimmedPin: string = pin ? pin.trim() : '';
    const sendReq: SendRequest = { info: this.selfInfo, files };
    if (trimmedPin.length > 0) {
      sendReq.pin = trimmedPin;
    }
    const body = stringToArrayBuffer(JSON.stringify(sendReq));
    // Official LocalSend v2 receivers (e.g. the macOS app) only expose
    // /prepare-upload; the legacy AnySend route is kept for old builds.
    let resp = await this.httpRequest('POST', LocalSendConst.PATH_PREPARE_UPLOAD, 'application/json', body);
    if (resp.status === 404) {
      resp = await this.httpRequest('POST', LocalSendConst.PATH_SEND_REQUEST, 'application/json', body);
    }
    if (resp.status === 401) {
      return {
        kind: trimmedPin.length > 0 ? SendOutcomeKind.WRONG_PIN : SendOutcomeKind.NEED_PIN,
        result: null,
        status: 401
      };
    }
    if (resp.status !== 200) {
      return { kind: SendOutcomeKind.REJECTED, result: null, status: resp.status };
    }
    try {
      const response = JSON.parse(arrayBufferToString(resp.body)) as SendRequestResponse;
      return {
        kind: SendOutcomeKind.ACCEPTED,
        result: { response, fileIdToPath },
        status: 200
      };
    } catch (e) {
      return { kind: SendOutcomeKind.REJECTED, result: null, status: -2 };
    }
  }

  /**
   * Step 3: upload a single file with progress callback.
   * filePath can be a file path or a content:// URI.
   * progress(sentBytes, totalBytes)
   * fileToken: per-file token from the send-request response (v2 spec);
   * the receiver rejects uploads without it.
   */
  async sendFile(sessionId: string, fileId: string, fileToken: string, filePath: string, progress: (sent: number, total: number) => void): Promise<boolean> {
    const conn = await this.openConn();
    if (conn <= 0) {
      return false;
    }
    try {
      const total = getFileSize(filePath);
      const fileName = extractFileName(filePath);
      const mime = guessMime(fileName);
      // Text uploads carry their charset; the metadata fileType stays text/plain.
      const contentType = mime.startsWith('text/') ? `${mime}; charset=utf-8` : mime;
      const path = `${LocalSendConst.PATH_UPLOAD}?sessionId=${sessionId}&fileId=${fileId}&token=${fileToken}`;
      const headerLines: string[] = [
        `POST ${path} HTTP/1.1`,
        `Host: ${this.receiverIp}:${LocalSendConst.PORT}`,
        'Connection: close',
        `Content-Type: ${contentType}`,
        `Content-Length: ${total}`,
        ''
      ];
      const headerStr = headerLines.join('\r\n') + '\r\n';
      await this.network.write(conn, stringToArrayBuffer(headerStr));

      // Open the file (works with both file paths and content:// URIs)
      let file: fs.File;
      try {
        file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      } catch (e) {
        const err = e as BusinessError;
        console.error(`ANYSEND open failed (send) uri=${filePath} code=${err.code} msg=${err.message}`);
        return false;
      }
      const buf = new ArrayBuffer(64 * 1024);
      let sent = 0;
      let n = 0;
      try {
        // ReadOptions.offset is the absolute position inside the file, so it has
        // to advance; leaving it at 0 re-reads the head forever and the upload
        // never ends (the receiver then gets a truncated, unopenable file).
        while (sent < total) {
          const want = Math.min(buf.byteLength, total - sent);
          n = fs.readSync(file.fd, buf, { offset: sent, length: want });
          if (n <= 0) {
            break;
          }
          const chunk = buf.slice(0, n);
          await this.network.write(conn, chunk);
          sent += n;
          progress(sent, total);
        }
      } finally {
        fs.closeSync(file);
      }

      const resp = await this.readHttpResponse(conn);
      return resp.status === 200;
    } finally {
      this.network.closeConn(conn);
    }
  }

  /**
   * Cancel an in-flight session. Receivers such as the macOS app allow only
   * one session at a time, so a failed/aborted transfer must release it or
   * every later send is rejected as "blocked by another session".
   */
  async cancelSession(sessionId: string): Promise<void> {
    try {
      await this.httpRequest('POST', `${LocalSendConst.PATH_CANCEL}?sessionId=${sessionId}`, null, null);
    } catch (e) {
    }
  }
}

/** Extract file name from a path or URI. */
function extractFileName(pathOrUri: string): string {
  const clean = pathOrUri.split('?')[0];
  const idx = clean.lastIndexOf('/');
  const raw = idx >= 0 ? clean.substring(idx + 1) : clean;
  // Share Kit hands over percent-encoded URIs; the receiver needs the real name.
  try {
    return decodeURIComponent(raw);
  } catch (e) {
    return raw;
  }
}

/** Get file size. Handles both file paths and content:// URIs. */
function getFileSize(pathOrUri: string): number {
  try {
    const file = fs.openSync(pathOrUri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      return stat.size;
    } finally {
      fs.closeSync(file);
    }
  } catch (e) {
    const err = e as BusinessError;
    console.error(`ANYSEND open failed (size) uri=${pathOrUri} code=${err.code} msg=${err.message}`);
    return 0;
  }
}

function stringToArrayBuffer(str: string): ArrayBuffer {
  return util.TextEncoder.create('utf-8').encodeInto(str).buffer as ArrayBuffer;
}

function arrayBufferToString(buf: ArrayBuffer): string {
  return utf8Decode(new Uint8Array(buf));
}

function utf8Decode(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

function appendBytes(dst: Uint8Array, src: Uint8Array): Uint8Array {
  const combined = new Uint8Array(dst.length + src.length);
  combined.set(dst, 0);
  combined.set(src, dst.length);
  return combined;
}

/** Find the '\r\n\r\n' header/body separator. Returns -1 when absent. */
function findHeaderEnd(bytes: Uint8Array): number {
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) {
      return i;
    }
  }
  return -1;
}

function generateUUID(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}
