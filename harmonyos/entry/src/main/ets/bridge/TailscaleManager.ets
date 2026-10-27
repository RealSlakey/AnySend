// Wraps the libtsnapi.so NAPI module (which itself wraps the Go tsnet
// c-shared library). Provides login, peer discovery, and raw socket
// I/O over the Tailscale network.
//
// Uses TsnapiLoader so the module is optional — if libtsnapi.so is
// absent, all methods return failure sentinels and the app falls back
// to Direct LAN Mode.

import { TsnapiClient } from './TsnapiClient';
import { ReadResult } from '../protocol/NetworkLayer';
import { common } from '@kit.AbilityKit';

/** Async-start progress reported by the Go side's StartState. */
interface TsnetStartState {
  phase: string;
  err: string;
}

export interface PeerInfo {
  hostName: string;
  tailscaleIP: string;
  online: boolean;
}

/** A tailnet endpoint exposed on 127.0.0.1 via ForwardTCP. */
export interface ForwardPort {
  handle: number;
  port: number;
}

export interface SelfInfo {
  hostName: string;
  tailscaleIP: string;
}

interface ParsedRead {
  data?: string;
  err?: string;
}

interface ParsedHandle {
  handle?: number;
}

export class TailscaleManager {
  private static started: boolean = false;

  /**
   * Start the embedded Tailscale node without blocking the UI thread.
   *
   * tsnet's full start (magicsock/DERP/control plane) can exceed HarmonyOS's
   * 6 s main-thread watchdog (THREAD_BLOCK_6S kills the process), so the Go
   * side runs Start on a background goroutine and this method only polls
   * the phase. The 500 ms poll interval itself is a quick in-memory read.
   *
   * @param authKey Tailscale auth key
   * @param context UIAbilityContext from the caller (the parameterless global
   *   getContext() may resolve to undefined when called from a static method,
   *   which would turn stateDir into the literal "undefined/tailscale-state").
   * @returns true on success
   */
  static async login(authKey: string, context: common.UIAbilityContext): Promise<boolean> {
    if (TailscaleManager.started) {
      return true;
    }
    if (!TsnapiClient.ensure()) {
      TailscaleManager.lastErr = 'native worker 不可用';
      return false;
    }
    const stateDir = context.filesDir + '/tailscale-state';
    const hostname = 'HarmonyOS-Device';
    console.info(`tsnet login: stateDir=${stateDir}`);
    // Every call below runs on the worker thread — the UI thread never
    // enters cgo, so a busy Go runtime can no longer freeze the UI.
    const rcRaw = await TsnapiClient.call('startAsync', [authKey, stateDir, hostname]);
    const rcErr = TsnapiClient.errorOf(rcRaw);
    if (rcErr !== '') {
      TailscaleManager.lastErr = rcErr;
      return false;
    }
    // tsnet can legitimately take a while on first login; 3 min mirrors the
    // Go-side Up() timeout (120 s) plus headroom for state persistence.
    const deadline = Date.now() + 180000;
    while (Date.now() < deadline) {
      await new Promise<void>(resolve => setTimeout(resolve, 500));
      const stateRaw = await TsnapiClient.call('startState', []);
      let st: TsnetStartState = { phase: 'starting', err: '' };
      try {
        st = JSON.parse(stateRaw) as TsnetStartState;
      } catch (e) {
        console.error(`tsnet startState parse error: ${stateRaw}`);
      }
      if (st.phase === 'running') {
        TailscaleManager.started = true;
        TailscaleManager.lastErr = '';
        await TailscaleManager.refreshStatus();
        return true;
      }
      if (st.phase === 'failed') {
        if (st.err !== '') {
          TailscaleManager.lastErr = st.err;
        } else {
          const errRaw = await TsnapiClient.call('lastError', []);
          TailscaleManager.lastErr = TsnapiClient.errorOf(errRaw) === '' ? errRaw : TsnapiClient.errorOf(errRaw);
        }
        console.error(`tsnet login failed: err=${TailscaleManager.lastErr}`);
        return false;
      }
    }
    TailscaleManager.lastErr = '连接超时，请重试';
    return false;
  }

  /** The Go-side message from the most recent failed start, '' when none. */
  static lastErr: string = '';

  /** Cached self/peers info, refreshed via the worker (refreshStatus). */
  private static selfCache: SelfInfo | null = null;
  private static peersCache: PeerInfo[] = [];

  static isStarted(): boolean {
    return TailscaleManager.started;
  }

  /**
   * Pull self + peers through the worker and refresh the sync caches.
   * UI code reads getSelfInfo()/getPeers() without ever touching cgo.
   */
  static async refreshStatus(): Promise<void> {
    if (!TailscaleManager.started) {
      return;
    }
    const selfJson = await TsnapiClient.call('getSelfInfo', []);
    if (TsnapiClient.errorOf(selfJson) === '' && selfJson.length > 0) {
      try {
        TailscaleManager.selfCache = JSON.parse(selfJson) as SelfInfo;
      } catch (e) {
        // keep previous cache
      }
    }
    const peersJson = await TsnapiClient.call('getPeers', []);
    if (TsnapiClient.errorOf(peersJson) === '') {
      try {
        TailscaleManager.peersCache = JSON.parse(peersJson) as PeerInfo[];
      } catch (e) {
        // keep previous cache
      }
    }
  }

  /** Cached self info; call refreshStatus() first for fresh data. */
  static getSelfInfo(): SelfInfo | null {
    return TailscaleManager.selfCache;
  }

  /** Cached peers; call refreshStatus() first for fresh data. */
  static getPeers(): PeerInfo[] {
    return TailscaleManager.peersCache;
  }

  /** Resolves to a connection handle (>0) or -1 on error. */
  static async dial(network: string, addr: string): Promise<number> {
    const json = await TsnapiClient.call('dial', [network, addr]);
    if (TsnapiClient.errorOf(json) !== '') {
      return -1;
    }
    return TailscaleManager.parseHandle(json);
  }

  /** Resolves to a listener handle (>0) or -1 on error. */
  static async listen(network: string, addr: string): Promise<number> {
    const json = await TsnapiClient.call('listen', [network, addr]);
    if (TsnapiClient.errorOf(json) !== '') {
      return -1;
    }
    return TailscaleManager.parseHandle(json);
  }

  /**
   * Expose a tailnet endpoint on 127.0.0.1.
   *
   * tsnet has no kernel TUN device, so the normal sockets used by the native
   * video/control channels cannot open 100.x addresses. The Go side listens on
   * loopback and relays through the tailnet instead.
   */
  static async forwardTcp(localPort: number, target: string): Promise<ForwardPort | null> {
    const json = await TsnapiClient.call('forwardTcp', [String(localPort), target]);
    if (TsnapiClient.errorOf(json) !== '') {
      return null;
    }
    try {
      const obj = JSON.parse(json) as ForwardPort;
      if (typeof obj.port === 'number' && obj.port > 0) {
        return obj;
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  static closeForward(handle: number): void {
    TsnapiClient.call('closeForward', [String(handle)]);
  }

  /**
   * Accept one connection. The blocking Accept runs on a Go goroutine
   * (acceptStart); we poll acceptPoll every 50 ms so the worker thread is
   * never stuck inside a blocking cgo call. Resolves -1 when the listener
   * fails or is closed.
   */
  static async accept(listenerHandle: number): Promise<number> {
    const h = String(listenerHandle);
    const startRaw = await TsnapiClient.call('acceptStart', [h]);
    if (TsnapiClient.errorOf(startRaw) !== '') {
      return -1;
    }
    const deadline = Date.now() + 3600000;
    while (Date.now() < deadline) {
      await new Promise<void>(resolve => setTimeout(resolve, 50));
      const raw = await TsnapiClient.call('acceptPoll', [h]);
      if (TsnapiClient.errorOf(raw) !== '') {
        return -1;
      }
      try {
        const obj = JSON.parse(raw) as ParsedHandle;
        if (typeof obj.handle === 'number' && obj.handle > 0) {
          return obj.handle;
        }
      } catch (e) {
        return -1;
      }
    }
    return -1;
  }

  /** Read from a connection. */
  static async read(handle: number, maxLen: number): Promise<ReadResult> {
    const json = await TsnapiClient.call('read', [String(handle), String(maxLen)]);
    try {
      const obj = JSON.parse(json) as ParsedRead;
      const dataStr: string = obj.data ?? '';
      const data = base64ToArrayBuffer(dataStr);
      const result: ReadResult = { data: data, err: obj.err ?? '' };
      return result;
    } catch (e) {
      const result: ReadResult = { data: new ArrayBuffer(0), err: String(e) };
      return result;
    }
  }

  static async write(handle: number, data: ArrayBuffer): Promise<number> {
    const raw = await TsnapiClient.call('write', [String(handle), arrayBufferToBase64(data)]);
    if (TsnapiClient.errorOf(raw) !== '') {
      return -1;
    }
    const n = Number(raw);
    return Number.isNaN(n) ? -1 : n;
  }

  static closeConn(handle: number): void {
    TsnapiClient.call('closeConn', [String(handle)]);
  }

  static closeListener(handle: number): void {
    TsnapiClient.call('closeListener', [String(handle)]);
  }

  static close(): void {
    TsnapiClient.call('close', []);
    TailscaleManager.started = false;
  }

  private static parseHandle(json: string): number {
    try {
      const obj = JSON.parse(json) as ParsedHandle;
      if (typeof obj.handle === 'number') {
        return obj.handle;
      }
      return -1;
    } catch (e) {
      return -1;
    }
  }
}

/** Decode a standard Base64 string into an ArrayBuffer. */
function base64ToArrayBuffer(base64: string): ArrayBuffer {
  const lookup: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let clean: string = '';
  for (let i = 0; i < base64.length; i++) {
    const c: string = base64.charAt(i);
    if (c !== '=' && lookup.indexOf(c) >= 0) {
      clean += c;
    }
  }
  const outLen: number = Math.floor(clean.length * 6 / 8);
  const out = new ArrayBuffer(outLen);
  const bytes = new Uint8Array(out);
  let buffer: number = 0;
  let bits: number = 0;
  let outIdx: number = 0;
  for (let i = 0; i < clean.length; i++) {
    buffer = (buffer << 6) | lookup.indexOf(clean.charAt(i));
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes[outIdx] = (buffer >> bits) & 0xff;
      outIdx += 1;
    }
  }
  return out;
}

/** Encode an ArrayBuffer into a standard Base64 string. */
function arrayBufferToBase64(buf: ArrayBuffer): string {
  const lookup: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const bytes = new Uint8Array(buf);
  let out: string = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0: number = bytes[i];
    const b1: number = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2: number = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += lookup[b0 >> 2];
    out += lookup[((b0 & 0x03) << 4) | (b1 >> 4)];
    out += i + 1 < bytes.length ? lookup[((b1 & 0x0f) << 2) | (b2 >> 6)] : '=';
    out += i + 2 < bytes.length ? lookup[b2 & 0x3f] : '=';
  }
  return out;
}
