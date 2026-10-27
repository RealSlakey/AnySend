// LocalSend receiver server for HarmonyOS. Listens on every provided
// NetworkLayer on TCP :53317 (Tailscale + direct LAN) and serves the
// LocalSend v2 HTTP API. A layer that fails to listen (e.g. Tailscale not
// connected yet) is skipped without affecting the others.

import { NetworkLayer } from './NetworkLayer';
import {
  LocalSendConst,
  DeviceInfo,
  FileInfo,
  SendRequest,
  SendRequestResponse
} from './LocalSendModels';
import { handleSmsServerRequest } from '../sms/SmsServer';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { HistoryStore } from '../common/HistoryStore';

interface HttpRequest {
  method: string;
  path: string;
  query: Record<string, string>;
  headers: Record<string, string>;
  body: ArrayBuffer;
}

interface HttpResponse {
  status: number;
  contentType: string;
  body: ArrayBuffer;
}

interface PathInfo {
  path: string;
  query: Record<string, string>;
}

/** Empty JSON body ({}) used by endpoints that return no payload. */
class EmptyBody {
}

export class LocalSendServer {
  private selfInfo: DeviceInfo;
  private networks: NetworkLayer[];
  private listenerHandles: number[] = [];
  private running: boolean = false;
  private decisions: Record<string, boolean> = {};
  private pendingFileNames: Map<string, string> = new Map();
  private pendingAliases: Map<string, string> = new Map();
  private context: common.UIAbilityContext;

  onSendRequest: ((sender: DeviceInfo, files: Record<string, FileInfo>) => void) | null = null;

  constructor(context: common.UIAbilityContext, selfInfo: DeviceInfo, networks: NetworkLayer[]) {
    this.context = context;
    this.selfInfo = selfInfo;
    this.networks = networks;
  }

  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    for (let i = 0; i < this.networks.length; i++) {
      this.runLayer(this.networks[i]);
    }
  }

  stop(): void {
    this.running = false;
    for (let i = 0; i < this.networks.length; i++) {
      this.networks[i].closeListener(this.listenerHandles[i] ?? -1);
    }
    this.listenerHandles = [];
  }

  private async runLayer(network: NetworkLayer): Promise<void> {
    const listenerHandle = await network.listen('tcp', `:${LocalSendConst.PORT}`);
    if (listenerHandle <= 0) {
      console.error(`LocalSendServer: listen on one network layer failed (running=${this.running})`);
      return;
    }
    const idx = this.networks.indexOf(network);
    if (idx >= 0) {
      this.listenerHandles[idx] = listenerHandle;
    }
    while (this.running) {
      const conn = await network.accept(listenerHandle);
      if (conn > 0) {
        this.handleConnection(network, conn);
      } else if (conn < 0) {
        // Listener failed or was closed (e.g. stop()) — do not hot-spin.
        break;
      }
    }
  }

  private async handleConnection(network: NetworkLayer, conn: number): Promise<void> {
    try {
      const request = await this.readHttpRequest(network, conn);
      if (!request) {
        return;
      }
      const response = this.route(request, conn);
      await this.writeHttpResponse(network, conn, response);
    } catch (e) {
      // ignore
    } finally {
      network.closeConn(conn);
    }
  }

  private async readHttpRequest(network: NetworkLayer, conn: number): Promise<HttpRequest | null> {
    // Byte-level buffering: the body must never pass through string
    // conversion (UTF-8 JSON and binary uploads would both corrupt).
    let rawBytes = new Uint8Array(0);
    let headerEnd = -1;
    while (headerEnd < 0) {
      const result = await network.read(conn, 8192);
      if (result.data.byteLength === 0) {
        break;
      }
      rawBytes = appendBytes(rawBytes, new Uint8Array(result.data));
      headerEnd = findHeaderEnd(rawBytes);
    }
    if (headerEnd < 0) {
      return null;
    }
    const headerSection = utf8Decode(rawBytes.subarray(0, headerEnd));
    const lines = headerSection.split('\r\n');
    const requestLine = lines[0].split(' ');
    if (requestLine.length < 2) {
      return null;
    }
    const method = requestLine[0];
    const fullPath = requestLine[1];
    const pathInfo = this.parsePath(fullPath);

    const headers: Record<string, string> = {};
    for (let i = 1; i < lines.length; i++) {
      const idx = lines[i].indexOf(':');
      if (idx > 0) {
        headers[lines[i].substring(0, idx).trim().toLowerCase()] = lines[i].substring(idx + 1).trim();
      }
    }

    // Large uploads from the official client arrive either with a
    // Content-Length or chunked (Transfer-Encoding: chunked, e.g. reqwest
    // streams). Both are handled here without quadratic re-copying.
    const chunked = (headers['transfer-encoding'] ?? '').toLowerCase().indexOf('chunked') >= 0;
    const contentLength = headers['content-length'] ? parseInt(headers['content-length'], 10) : 0;
    const bodyStart = headerEnd + 4;
    let body: Uint8Array;
    if (chunked) {
      body = await this.readChunkedBody(network, conn, rawBytes, bodyStart);
    } else {
      body = new Uint8Array(contentLength);
      let have = 0;
      if (rawBytes.length > bodyStart) {
        have = Math.min(rawBytes.length - bodyStart, contentLength);
        body.set(rawBytes.subarray(bodyStart, bodyStart + have), 0);
      }
      while (have < contentLength) {
        const result = await network.read(conn, 65536);
        if (result.data.byteLength === 0) {
          break;
        }
        const chunk = new Uint8Array(result.data);
        const copy = Math.min(chunk.length, contentLength - have);
        body.set(chunk.subarray(0, copy), have);
        have += copy;
      }
      if (have < contentLength) {
        // Sender closed early; keep the bytes that did arrive.
        body = body.subarray(0, have);
      }
    }

    // Avoid a second full copy when the array owns its exact buffer.
    let buffer: ArrayBuffer;
    if (body.byteOffset === 0 && body.byteLength === body.buffer.byteLength) {
      buffer = body.buffer as ArrayBuffer;
    } else {
      buffer = body.slice().buffer as ArrayBuffer;
    }
    const req: HttpRequest = {
      method: method,
      path: pathInfo.path,
      query: pathInfo.query,
      headers: headers,
      body: buffer
    };
    return req;
  }

  private findCrlf(data: Uint8Array, from: number): number {
    for (let i = from; i + 1 < data.length; i++) {
      if (data[i] === 0x0d && data[i + 1] === 0x0a) {
        return i;
      }
    }
    return -1;
  }

  private concatParts(parts: Uint8Array[], total: number): Uint8Array {
    const out = new Uint8Array(total);
    let off = 0;
    for (let i = 0; i < parts.length; i++) {
      out.set(parts[i], off);
      off += parts[i].length;
    }
    return out;
  }

  /** Decode a chunked transfer-encoded body, reading more data as needed. */
  private async readChunkedBody(network: NetworkLayer, conn: number, raw: Uint8Array, start: number): Promise<Uint8Array> {
    // `pending` holds only unconsumed bytes; consumed data is sliced off so
    // later appends stay cheap.
    let pending = raw.length > start ? raw.subarray(start) : new Uint8Array(0);
    let pos = 0;
    const parts: Uint8Array[] = [];
    let total = 0;
    while (true) {
      // 1. Read the chunk-size line (hex, optional extensions after ';').
      let eol = this.findCrlf(pending, pos);
      while (eol < 0) {
        const result = await network.read(conn, 65536);
        if (result.data.byteLength === 0) {
          return this.concatParts(parts, total);
        }
        pending = appendBytes(pending, new Uint8Array(result.data));
        eol = this.findCrlf(pending, pos);
      }
      const sizeLine = utf8Decode(pending.subarray(pos, eol));
      const chunkSize = parseInt(sizeLine.split(';')[0].trim(), 16);
      if (isNaN(chunkSize) || chunkSize < 0 || chunkSize > 1073741824) {
        return this.concatParts(parts, total);
      }
      const dataStart = eol + 2;
      // 2. Wait for the whole data chunk plus its trailing CRLF.
      while (pending.length < dataStart + chunkSize + 2) {
        const result = await network.read(conn, 65536);
        if (result.data.byteLength === 0) {
          const take = Math.min(Math.max(0, pending.length - dataStart), chunkSize);
          if (take > 0) {
            parts.push(pending.subarray(dataStart, dataStart + take));
            total += take;
          }
          return this.concatParts(parts, total);
        }
        pending = appendBytes(pending, new Uint8Array(result.data));
      }
      // 3. Consume the chunk; keep the tail bytes for the next round.
      parts.push(pending.subarray(dataStart, dataStart + chunkSize));
      total += chunkSize;
      const nextPending = pending.subarray(dataStart + chunkSize + 2);
      pending = nextPending;
      pos = 0;
      if (chunkSize === 0) {
        // Final chunk: what follows is optional trailers then CRLF; the
        // connection closes after the response anyway.
        break;
      }
    }
    return this.concatParts(parts, total);
  }

  private parsePath(fullPath: string): PathInfo {
    const qIdx = fullPath.indexOf('?');
    if (qIdx < 0) {
      const noQuery: PathInfo = { path: fullPath, query: {} };
      return noQuery;
    }
    const path = fullPath.substring(0, qIdx);
    const queryStr = fullPath.substring(qIdx + 1);
    const query: Record<string, string> = {};
    queryStr.split('&').forEach((pair) => {
      const eq = pair.indexOf('=');
      if (eq > 0) {
        query[pair.substring(0, eq)] = decodeURIComponent(pair.substring(eq + 1));
      } else {
        query[pair] = '';
      }
    });
    const result: PathInfo = { path: path, query: query };
    return result;
  }

  private route(req: HttpRequest, conn: number): HttpResponse {
    if (req.method === 'GET' && req.path === LocalSendConst.PATH_INFO) {
      return this.jsonResponse(200, this.selfInfo);
    }
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_REGISTER) {
      return this.jsonResponse(200, this.selfInfo);
    }
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_SEND_REQUEST) {
      return this.handleSendRequest(req);
    }
    // Official LocalSend app route: same handler and same response shape
    // (official v2 expects files: {fileId: token-string}).
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_PREPARE_UPLOAD) {
      return this.handleSendRequest(req);
    }
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_SEND) {
      return this.handleSend(req);
    }
    // Official upload route; the extra token query param is not validated
    // (auto-accept mode).
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_UPLOAD) {
      return this.handleSend(req);
    }
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_CANCEL) {
      return this.jsonResponse(200, new EmptyBody());
    }
    // SMS relay routes (Android -> HarmonyOS push). The body is passed raw;
    // SmsServer decodes it as UTF-8.
    if (req.path.startsWith('/api/sms/')) {
      const r = handleSmsServerRequest(req.method, req.path, req.headers, req.body);
      if (r !== null) {
        const respBody = stringToArrayBuffer(r.body);
        return { status: r.status, contentType: 'application/json', body: respBody };
      }
    }
    return { status: 404, contentType: 'text/plain', body: stringToArrayBuffer('Not Found') };
  }

  /** Accept all files and create a session (auto-accept). */
  private handleSendRequest(req: HttpRequest): HttpResponse {
    let sendReq: SendRequest;
    try {
      sendReq = JSON.parse(arrayBufferToString(req.body)) as SendRequest;
    } catch (e) {
      return { status: 400, contentType: 'text/plain', body: stringToArrayBuffer('Bad Request') };
    }
    const sessionId = generateUUID();
    const accepted: Record<string, string> = {};
    const senderAlias = sendReq.info.alias && sendReq.info.alias.length > 0 ? sendReq.info.alias : '未知设备';
    for (const fileId of Object.keys(sendReq.files)) {
      accepted[fileId] = 'accept';
      this.decisions[fileId] = true;
      if (sendReq.files[fileId] && sendReq.files[fileId].fileName) {
        this.pendingFileNames.set(fileId, sendReq.files[fileId].fileName);
      }
      this.pendingAliases.set(fileId, senderAlias);
    }
    if (this.onSendRequest) {
      this.onSendRequest(sendReq.info, sendReq.files);
    }
    const resp: SendRequestResponse = { sessionId: sessionId, files: accepted };
    return this.jsonResponse(200, resp);
  }

  private handleSend(req: HttpRequest): HttpResponse {
    const sessionId = req.query['sessionId'];
    const fileId = req.query['fileId'];
    if (!sessionId || !fileId) {
      return { status: 400, contentType: 'text/plain', body: stringToArrayBuffer('missing sessionId or fileId') };
    }
    // fs.writeSync on API 12 accepts ArrayBuffer|string only — pass req.body
    // directly (wrapping in Uint8Array throws and kills the transfer).
    // Keep the sender's original filename when available.
    let fileName = `received_${fileId.substring(0, 8)}`;
    const pending = this.pendingFileNames.get(fileId);
    this.pendingFileNames.delete(fileId);
    if (pending) {
      fileName = pending;
    }
    const safeName = fileName.replace(/[\/\\:*?"<>|]/g, '_');
    const dir = `${this.context.filesDir}/Received`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      // Fall through to openSync which reports the real error.
    }
    const savePath = HistoryStore.dedupePath(dir, safeName);
    const file = fs.openSync(savePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, req.body);
    } finally {
      fs.closeSync(file);
    }
    // Record in transfer history (receive direction). add() never rejects.
    HistoryStore.add(this.context, {
      id: generateUUID(),
      direction: 'receive',
      peer: this.pendingAliases.get(fileId) ?? '未知设备',
      fileName: safeName,
      size: req.body.byteLength,
      time: Date.now(),
      path: savePath
    });
    this.pendingAliases.delete(fileId);
    return this.jsonResponse(200, new EmptyBody());
  }

  private jsonResponse(status: number, obj: object): HttpResponse {
    const body = stringToArrayBuffer(JSON.stringify(obj));
    return { status, contentType: 'application/json', body };
  }

  private async writeHttpResponse(network: NetworkLayer, conn: number, resp: HttpResponse): Promise<void> {
    const statusText = resp.status === 200 ? 'OK' : resp.status === 400 ? 'Bad Request' : resp.status === 404 ? 'Not Found' : 'OK';
    const header = `HTTP/1.1 ${resp.status} ${statusText}\r\n` +
      `Content-Type: ${resp.contentType}\r\n` +
      `Content-Length: ${resp.body.byteLength}\r\n` +
      'Connection: close\r\n\r\n';
    await network.write(conn, stringToArrayBuffer(header));
    if (resp.body.byteLength > 0) {
      await network.write(conn, resp.body);
    }
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
