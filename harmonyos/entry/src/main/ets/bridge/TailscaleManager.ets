// Wraps the libtsnapi.so NAPI module (which itself wraps the Go tsnet
// c-shared library). Provides login, peer discovery, and raw socket
// I/O over the Tailscale network.
//
// Uses TsnapiLoader so the module is optional — if libtsnapi.so is
// absent, all methods return failure sentinels and the app falls back
// to Direct LAN Mode.

import { getTsnapi } from './TsnapiLoader';

export interface PeerInfo {
  hostName: string;
  tailscaleIP: string;
  online: boolean;
}

export interface SelfInfo {
  hostName: string;
  tailscaleIP: string;
}

export class TailscaleManager {
  private static started: boolean = false;

  /**
   * Start the embedded Tailscale node.
   * @param authKey Tailscale auth key
   * @returns true on success
   */
  static async login(authKey: string): Promise<boolean> {
    if (this.started) {
      return true;
    }
    const tsnapi = getTsnapi();
    const stateDir = getContext().filesDir + '/tailscale-state';
    const hostname = 'HarmonyOS-Device';
    const rc: number = tsnapi.start(authKey, stateDir, hostname);
    this.started = (rc === 0);
    return this.started;
  }

  static isStarted(): boolean {
    if (!this.started) {
      return false;
    }
    return getTsnapi().isStarted() !== 0;
  }

  static getSelfInfo(): SelfInfo | null {
    const json: string = getTsnapi().getSelfInfo();
    if (!json) {
      return null;
    }
    try {
      return JSON.parse(json) as SelfInfo;
    } catch (e) {
      return null;
    }
  }

  static getPeers(): PeerInfo[] {
    const json: string = getTsnapi().getPeers();
    if (!json || json === '[]') {
      return [];
    }
    try {
      return JSON.parse(json) as PeerInfo[];
    } catch (e) {
      return [];
    }
  }

  /** Returns a connection handle (>0) or -1 on error. */
  static dial(network: string, addr: string): number {
    const json: string = getTsnapi().dial(network, addr);
    return this.parseHandle(json);
  }

  /** Returns a listener handle (>0) or -1 on error. */
  static listen(network: string, addr: string): number {
    const json: string = getTsnapi().listen(network, addr);
    return this.parseHandle(json);
  }

  static accept(listenerHandle: number): number {
    const json: string = getTsnapi().accept(listenerHandle);
    return this.parseHandle(json);
  }

  /**
   * Read from a connection. Returns { data: ArrayBuffer, err: string }.
   */
  static read(handle: number, maxLen: number): { data: ArrayBuffer; err: string } {
    const json: string = getTsnapi().read(handle, maxLen);
    try {
      const obj = JSON.parse(json);
      const dataStr: string = obj.data ?? '';
      const data = base64ToArrayBuffer(dataStr);
      return { data, err: obj.err ?? '' };
    } catch (e) {
      return { data: new ArrayBuffer(0), err: String(e) };
    }
  }

  static write(handle: number, data: ArrayBuffer): number {
    return getTsnapi().write(handle, data);
  }

  static closeConn(handle: number): void {
    getTsnapi().closeConn(handle);
  }

  static closeListener(handle: number): void {
    getTsnapi().closeListener(handle);
  }

  static close(): void {
    getTsnapi().close();
    this.started = false;
  }

  private static parseHandle(json: string): number {
    try {
      const obj = JSON.parse(json);
      if (typeof obj.handle === 'number') {
        return obj.handle;
      }
      return -1;
    } catch (e) {
      return -1;
    }
  }
}

function base64ToArrayBuffer(base64: string): ArrayBuffer {
  const binary = atob(base64);
  const len = binary.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}
