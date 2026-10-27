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
import { HttpBodyReader, BodyTooLargeException, HeadTooLargeException } from './HttpBodyReader';

// Hard caps: request head 64 KB, JSON bodies 8 MB. Uploads are never
// buffered — they stream straight to disk via HttpBodyReader.copyToFile.
const MAX_HEADER_BYTES = 64 * 1024;
const MAX_META_BODY = 8 * 1024 * 1024;

interface HttpRequest {
  method: string;
  path: string;
  query: Record<string, string>;
  headers: Record<string, string>;
  body: HttpBodyReader;
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
      const response = await this.route(request);
      await this.writeHttpResponse(network, conn, response);
    } catch (e) {
      if (e instanceof HeadTooLargeException) {
        await this.writeHttpResponse(network, conn, {
          status: 431, contentType: 'text/plain', body: stringToArrayBuffer('Headers Too Large')
        });
      } else if (e instanceof BodyTooLargeException) {
        await this.writeHttpResponse(network, conn, {
          status: 413, contentType: 'text/plain', body: stringToArrayBuffer('Payload Too Large')
        });
      } else {
        // Broken connections are routine; anything else is worth a line.
        console.warn(`LocalSendServer: connection aborted: ${e}`);
      }
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
      if (rawBytes.length > MAX_HEADER_BYTES) {
        throw new HeadTooLargeException();
      }
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

    // Content-Length or chunked (Transfer-Encoding: chunked, e.g. reqwest
    // streams). A bogus length can no longer trigger an allocation: the
    // HttpBodyReader grows only as fast as bytes actually arrive.
    const chunked = (headers['transfer-encoding'] ?? '').toLowerCase().indexOf('chunked') >= 0;
    const contentLength = headers['content-length'] ? parseInt(headers['content-length'], 10) : 0;
    const bodyStart = headerEnd + 4;
    const leftover = rawBytes.length > bodyStart ? rawBytes.subarray(bodyStart) : new Uint8Array(0);
    const req: HttpRequest = {
      method: method,
      path: pathInfo.path,
      query: pathInfo.query,
      headers: headers,
      body: new HttpBodyReader(network, conn, leftover, contentLength, chunked)
    };
    return req;
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

  private async route(req: HttpRequest): Promise<HttpResponse> {
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
    // Official upload route. The body streams straight to disk; the session
    // and fileId from prepare-upload are validated before anything is written.
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_UPLOAD) {
      return this.handleSend(req);
    }
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_CANCEL) {
      return this.jsonResponse(200, new EmptyBody());
    }
    // SMS relay routes (Android -> HarmonyOS push). The body is passed raw;
    // SmsServer decodes it as UTF-8.
    if (req.path.startsWith('/api/sms/')) {
      const body = await req.body.readFully(MAX_META_BODY); // SMS payloads are small JSON
      const r = handleSmsServerRequest(req.method, req.path, req.headers, body.slice().buffer as ArrayBuffer);
      if (r !== null) {
        const respBody = stringToArrayBuffer(r.body);
        return { status: r.status, contentType: 'application/json', body: respBody };
      }
    }
    return { status: 404, contentType: 'text/plain', body: stringToArrayBuffer('Not Found') };
  }

  /** Accept all files and create a session (auto-accept). */
  private async handleSendRequest(req: HttpRequest): Promise<HttpResponse> {
    let sendReq: SendRequest;
    try {
      sendReq = JSON.parse(utf8Decode(await req.body.readFully(MAX_META_BODY))) as SendRequest;
    } catch (e) {
      if (e instanceof BodyTooLargeException) {
        throw e;
      }
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

  private async handleSend(req: HttpRequest): Promise<HttpResponse> {
    const sessionId = req.query['sessionId'];
    const fileId = req.query['fileId'];
    if (!sessionId || !fileId) {
      return { status: 400, contentType: 'text/plain', body: stringToArrayBuffer('missing sessionId or fileId') };
    }
    // The fileId must have been announced via prepare-upload. The old code
    // fell back to received_<fileId> and wrote anyway — that was an
    // unauthenticated arbitrary-file-write primitive.
    const pending = this.pendingFileNames.get(fileId);
    if (!pending) {
      return { status: 404, contentType: 'text/plain', body: stringToArrayBuffer('unknown fileId') };
    }
    this.pendingFileNames.delete(fileId);
    const safeName = pending.replace(/[\/\\:*?"<>|]/g, '_');
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
    let written = 0;
    try {
      // Socket -> 256 KB buffer -> disk. Nothing large is held in memory.
      written = await req.body.copyToFile(file.fd);
    } finally {
      fs.closeSync(file);
    }
    // Record in transfer history (receive direction). add() never rejects.
    HistoryStore.add(this.context, {
      id: generateUUID(),
      direction: 'receive',
      peer: this.pendingAliases.get(fileId) ?? '未知设备',
      fileName: safeName,
      size: written,
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
    const statusText = statusTextOf(resp.status);
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

function statusTextOf(status: number): string {
  if (status === 200) {
    return 'OK';
  }
  if (status === 400) {
    return 'Bad Request';
  }
  if (status === 404) {
    return 'Not Found';
  }
  if (status === 413) {
    return 'Payload Too Large';
  }
  if (status === 431) {
    return 'Headers Too Large';
  }
  if (status === 500) {
    return 'Internal Server Error';
  }
  return 'OK';
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
