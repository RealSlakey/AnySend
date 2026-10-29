// HTTPS transport for talking to stock LocalSend peers.
//
// Why this exists: stock LocalSend always serves HTTPS with a per-device
// self-signed certificate. Those certs are not issued by any system CA, and
// @ohos.net.socket's TLSSocket only accepts a CA chain -- there is no
// skip-verify switch, so the low-level socket path can never complete the
// handshake with a LocalSend peer.
//
// RemoteCommunicationKit (rcp) is the supported escape hatch:
//   SecurityConfiguration.remoteValidation = 'skip'   (since API 11)
// which makes the networking stack accept the peer's own certificate.
// This is exactly the trust model LocalSend itself uses (trust on first
// contact + optional PIN), so no protection is lost compared to the desktop
// apps. The one thing we do keep is the PIN: it still has to be correct.
//
// Uploads stay streamed: MultipartForm fields accept a GetDataCallback, so we
// hand rcp 64 KiB slices straight off the file descriptor and report progress
// while doing it -- a 2 GB video never lands in memory.

import { rcp } from '@kit.RemoteCommunicationKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DeviceIdentity } from '../common/DeviceIdentity';

export interface RcpHttpResponse {
  status: number;
  body: string;
}

/** 64 KiB matches the read size used by the plaintext sender. */
const CHUNK: number = 64 * 1024;

export class RcpTransport {
  private host: string;
  private port: number;
  private session: rcp.Session | null = null;
  private inFlight: rcp.Request | null = null;

  /**
   * transferMs default is 60 s *for the whole transfer*, which would kill any
   * big upload. Raise it out of the way and let inactivityMs catch stalls.
   *
   * `remoteValidation: 'skip'` accepts the peer's self-signed certificate;
   * `certificate` presents ours, because stock LocalSend asks for a client
   * certificate and aborts the handshake with `certificate_required` without
   * one (mutual TLS is how peers prove their device identity).
   */
  private config(): rcp.Configuration {
    const security: rcp.SecurityConfiguration = { remoteValidation: 'skip' };
    const certPath: string = DeviceIdentity.certPath();
    const keyPath: string = DeviceIdentity.keyPath();
    if (certPath.length > 0 && keyPath.length > 0) {
      security.certificate = { type: 'PEM', filePath: certPath, key: keyPath };
    }
    const config: rcp.Configuration = {
      security: security,
      transfer: {
        timeout: { connectMs: 5000, transferMs: 24 * 60 * 60 * 1000, inactivityMs: 60000 }
      }
    };
    return config;
  }

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }

  private ensureSession(): rcp.Session {
    if (this.session === null) {
      this.session = rcp.createSession({ requestConfiguration: this.config() });
    }
    return this.session;
  }

  private baseUrl(): string {
    return `https://${this.host}:${this.port}`;
  }

  /** POST a JSON body and return the status plus the raw response text. */
  async postJson(path: string, json: string): Promise<RcpHttpResponse> {
    const headers: rcp.RequestHeaders = { 'content-type': 'application/json' };
    try {
      const req = new rcp.Request(`${this.baseUrl()}${path}`, 'POST', headers, json);
      this.inFlight = req;
      const resp = await this.ensureSession().fetch(req);
      const text: string = resp.toString() ?? '';
      return { status: resp.statusCode, body: text };
    } catch (e) {
      const err = e as BusinessError;
      console.error(`ANYSEND rcp post failed path=${path} code=${err.code} msg=${err.message}`);
      return { status: -1, body: '' };
    } finally {
      this.inFlight = null;
    }
  }

  /**
   * POST the file's bytes as the request body (the LocalSend v2 /upload shape
   * used by this project: the receiver streams the body straight to disk and
   * checks the byte count against the announced size, so no multipart
   * envelope is expected).
   * Returns the HTTP status, or -1 when the file could not be opened or the
   * request failed at the transport layer.
   */
  async postFile(path: string, filePath: string, mime: string,
    total: number, progress: (sent: number, total: number) => void): Promise<number> {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`ANYSEND open failed (tls send) uri=${filePath} code=${err.code} msg=${err.message}`);
      return -1;
    }
    const fd: number = file.fd;
    const size: number = total > 0 ? total : statSize(fd);
    let offset: number = 0;
    let finished: boolean = false;

    // rcp pulls bytes on its own network thread; we only translate "give me up
    // to maxSize bytes" into one positioned read off the file descriptor.
    const pull: rcp.GetDataCallback = (maxSize: number): ArrayBuffer => {
      const remain: number = size - offset;
      if (finished || remain <= 0) {
        return new ArrayBuffer(0);
      }
      const want: number = Math.min(maxSize > 0 ? maxSize : CHUNK, remain);
      const buf = new ArrayBuffer(want);
      let n: number = 0;
      try {
        n = fs.readSync(fd, buf, { offset: offset, length: want });
      } catch (e) {
        const err = e as BusinessError;
        console.error(`ANYSEND read failed (tls send) offset=${offset} code=${err.code} msg=${err.message}`);
        finished = true;
        return new ArrayBuffer(0);
      }
      if (n <= 0) {
        finished = true;
        return new ArrayBuffer(0);
      }
      offset += n;
      progress(offset, size);
      return n === want ? buf : buf.slice(0, n);
    };

    const headers: rcp.RequestHeaders = { 'content-type': mime };
    try {
      // A bare GetDataCallback is the request body itself; rcp pulls on demand,
      // so the transfer stays chunked and memory stays flat.
      const req = new rcp.Request(`${this.baseUrl()}${path}`, 'POST', headers, pull);
      this.inFlight = req;
      const resp = await this.ensureSession().fetch(req);
      return resp.statusCode;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`ANYSEND rcp upload failed path=${path} code=${err.code} msg=${err.message}`);
      return -1;
    } finally {
      this.inFlight = null;
      finished = true;
      try {
        fs.closeSync(fd);
      } catch (e) {
        // already closed
      }
    }
  }

  /** Abort the request in flight (user cancelled, or the UI was torn down). */
  cancel(): void {
    if (this.session !== null) {
      try {
        if (this.inFlight !== null) {
          this.session.cancel(this.inFlight);
        } else {
          this.session.cancel();
        }
      } catch (e) {
        // session already closed
      }
    }
  }

  close(): void {
    if (this.session !== null) {
      try {
        this.session.close();
      } catch (e) {
        // ignore
      }
      this.session = null;
    }
  }
}

function statSize(fd: number): number {
  try {
    return fs.statSync(fd).size;
  } catch (e) {
    return 0;
  }
}
