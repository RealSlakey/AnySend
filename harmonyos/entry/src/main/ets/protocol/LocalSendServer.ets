// LocalSend receiver server for HarmonyOS. Listens on the provided
// NetworkLayer on TCP :53317 and serves the LocalSend v2 HTTP API.

import { NetworkLayer } from './NetworkLayer';
import {
  LocalSendConst,
  DeviceInfo,
  FileInfo,
  SendRequest,
  SendRequestResponse
} from './LocalSendModels';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

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

export class LocalSendServer {
  private selfInfo: DeviceInfo;
  private network: NetworkLayer;
  private listenerHandle: number = -1;
  private running: boolean = false;
  private decisions: Record<string, boolean> = {};
  private context: common.UIAbilityContext;

  onSendRequest: ((sender: DeviceInfo, files: Record<string, FileInfo>) => void) | null = null;

  constructor(context: common.UIAbilityContext, selfInfo: DeviceInfo, network: NetworkLayer) {
    this.context = context;
    this.selfInfo = selfInfo;
    this.network = network;
  }

  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.run();
  }

  stop(): void {
    this.running = false;
    if (this.listenerHandle > 0) {
      this.network.closeListener(this.listenerHandle);
      this.listenerHandle = -1;
    }
  }

  private async run(): Promise<void> {
    this.listenerHandle = await this.network.listen('tcp', `:${LocalSendConst.PORT}`);
    if (this.listenerHandle <= 0) {
      this.running = false;
      return;
    }
    while (this.running) {
      const conn = await this.network.accept(this.listenerHandle);
      if (conn > 0) {
        this.handleConnection(conn);
      }
    }
  }

  private async handleConnection(conn: number): Promise<void> {
    try {
      const request = await this.readHttpRequest(conn);
      if (!request) {
        return;
      }
      const response = this.route(request, conn);
      await this.writeHttpResponse(conn, response);
    } catch (e) {
      // ignore
    } finally {
      this.network.closeConn(conn);
    }
  }

  private async readHttpRequest(conn: number): Promise<HttpRequest | null> {
    let rawStr = '';
    let headerEnd = -1;
    while (headerEnd < 0) {
      const result = await this.network.read(conn, 8192);
      if (result.data.byteLength === 0) {
        break;
      }
      rawStr += arrayBufferToString(result.data);
      headerEnd = rawStr.indexOf('\r\n\r\n');
    }
    if (headerEnd < 0) {
      return null;
    }
    const headerSection = rawStr.substring(0, headerEnd);
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

    const contentLength = headers['content-length'] ? parseInt(headers['content-length'], 10) : 0;
    let bodyBytes = new Uint8Array(0);
    const already = rawStr.length - (headerEnd + 4);
    if (already > 0 && contentLength > 0) {
      const toCopy = Math.min(already, contentLength);
      bodyBytes = new Uint8Array(toCopy);
      const bodyStart = rawStr.substring(headerEnd + 4, headerEnd + 4 + toCopy);
      for (let i = 0; i < toCopy; i++) {
        bodyBytes[i] = bodyStart.charCodeAt(i);
      }
    }
    while (bodyBytes.length < contentLength) {
      const result = await this.network.read(conn, 8192);
      if (result.data.byteLength === 0) {
        break;
      }
      const chunk = new Uint8Array(result.data);
      const combined = new Uint8Array(bodyBytes.length + chunk.length);
      combined.set(bodyBytes, 0);
      combined.set(chunk, bodyBytes.length);
      bodyBytes = combined;
    }

    return { method, path: pathInfo.path, query: pathInfo.query, headers, body: bodyBytes.buffer };
  }

  private parsePath(fullPath: string): { path: string; query: Record<string, string> } {
    const qIdx = fullPath.indexOf('?');
    if (qIdx < 0) {
      return { path: fullPath, query: {} };
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
    return { path, query };
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
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_SEND) {
      return this.handleSend(req);
    }
    if (req.method === 'POST' && req.path === LocalSendConst.PATH_CANCEL) {
      return this.jsonResponse(200, {});
    }
    return { status: 404, contentType: 'text/plain', body: stringToArrayBuffer('Not Found') };
  }

  private handleSendRequest(req: HttpRequest): HttpResponse {
    let sendReq: SendRequest;
    try {
      sendReq = JSON.parse(arrayBufferToString(req.body)) as SendRequest;
    } catch (e) {
      return { status: 400, contentType: 'text/plain', body: stringToArrayBuffer('Bad Request') };
    }
    const sessionId = generateUUID();
    const accepted: Record<string, string> = {};
    for (const fileId of Object.keys(sendReq.files)) {
      accepted[fileId] = 'accept';
      this.decisions[fileId] = true;
    }
    if (this.onSendRequest) {
      this.onSendRequest(sendReq.info, sendReq.files);
    }
    const resp: SendRequestResponse = { sessionId, files: accepted };
    return this.jsonResponse(200, resp);
  }

  private handleSend(req: HttpRequest): HttpResponse {
    const sessionId = req.query['sessionId'];
    const fileId = req.query['fileId'];
    if (!sessionId || !fileId) {
      return { status: 400, contentType: 'text/plain', body: stringToArrayBuffer('missing sessionId or fileId') };
    }
    const fileName = `received_${fileId.substring(0, 8)}`;
    const savePath = `${this.context.filesDir}/${fileName}`;
    const file = fs.openSync(savePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    try {
      fs.writeSync(file.fd, new Uint8Array(req.body));
    } finally {
      fs.closeSync(file);
    }
    return this.jsonResponse(200, {});
  }

  private jsonResponse(status: number, obj: object): HttpResponse {
    const body = stringToArrayBuffer(JSON.stringify(obj));
    return { status, contentType: 'application/json', body };
  }

  private async writeHttpResponse(conn: number, resp: HttpResponse): Promise<void> {
    const statusText = resp.status === 200 ? 'OK' : resp.status === 400 ? 'Bad Request' : resp.status === 404 ? 'Not Found' : 'OK';
    const header = `HTTP/1.1 ${resp.status} ${statusText}\r\n` +
      `Content-Type: ${resp.contentType}\r\n` +
      `Content-Length: ${resp.body.byteLength}\r\n` +
      'Connection: close\r\n\r\n';
    await this.network.write(conn, stringToArrayBuffer(header));
    if (resp.body.byteLength > 0) {
      await this.network.write(conn, resp.body);
    }
  }
}

function stringToArrayBuffer(str: string): ArrayBuffer {
  const bytes = new Uint8Array(str.length);
  for (let i = 0; i < str.length; i++) {
    bytes[i] = str.charCodeAt(i);
  }
  return bytes.buffer;
}

function arrayBufferToString(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let str = '';
  for (let i = 0; i < bytes.length; i++) {
    str += String.fromCharCode(bytes[i]);
  }
  return str;
}

function generateUUID(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}
