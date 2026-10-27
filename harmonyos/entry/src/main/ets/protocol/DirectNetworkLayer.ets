// NetworkLayer backed by the HarmonyOS system network stack (@ohos.net.socket).
// Used in "Direct LAN Mode" when Tailscale is not available — both devices
// must be on the same Wi-Fi / reachable network.
//
// The HarmonyOS socket API is event-based, so we bridge incoming 'message'
// events into a buffer queue that read() drains.

import socket from '@ohos.net.socket';
import { NetworkLayer, ReadResult } from './NetworkLayer';

interface PendingRead {
  resolve: (value: ReadResult) => void;
}

interface HostPort {
  host: string;
  port: number;
}

class ConnState {
  // Set when this connection was opened via dial().
  sock: socket.TCPSocket | null = null;
  // Set when this connection was accepted from a listening server.
  conn: socket.TCPSocketConnection | null = null;
  queue: ArrayBuffer[] = [];
  pending: PendingRead | null = null;
  eof: boolean = false;
  totalRead: number = 0;

  push(data: ArrayBuffer): void {
    if (this.pending) {
      const p = this.pending;
      this.pending = null;
      const result: ReadResult = { data: data, err: '' };
      p.resolve(result);
    } else {
      this.queue.push(data);
    }
  }

  close(): void {
    this.eof = true;
    if (this.pending) {
      const p = this.pending;
      this.pending = null;
      const result: ReadResult = { data: new ArrayBuffer(0), err: 'closed' };
      p.resolve(result);
    }
  }
}

export class DirectNetworkLayer implements NetworkLayer {
  private nextHandle: number = 1;
  private listeners: Map<number, socket.TCPSocketServer> = new Map();
  private conns: Map<number, ConnState> = new Map();
  private acceptQueue: number[] = [];
  private acceptPending: ((handle: number) => void) | null = null;

  async dial(network: string, addr: string): Promise<number> {
    try {
      const hp: HostPort = this.parseAddr(addr);
      const tcp = socket.constructTCPSocketInstance();
      const netAddr: socket.NetAddress = { address: hp.host, port: hp.port };
      const options: socket.TCPConnectOptions = { address: netAddr, timeout: 5000 };
      await tcp.connect(options);
      const handle = this.nextHandle++;
      const state = new ConnState();
      state.sock = tcp;
      this.conns.set(handle, state);
      tcp.on('message', (value: socket.SocketMessageInfo) => {
        state.push(value.message);
      });
      tcp.on('close', () => {
        state.close();
      });
      tcp.on('error', () => {
        state.close();
      });
      return handle;
    } catch (e) {
      return -1;
    }
  }

  async listen(network: string, addr: string): Promise<number> {
    try {
      const port: number = this.parsePort(addr);
      const server = socket.constructTCPSocketServerInstance();
      const bindAddr: socket.NetAddress = { address: '0.0.0.0', port: port };
      await server.listen(bindAddr);
      const handle = this.nextHandle++;
      this.listeners.set(handle, server);
      server.on('connect', (client: socket.TCPSocketConnection) => {
        const connHandle = this.nextHandle++;
        const state = new ConnState();
        state.conn = client;
        this.conns.set(connHandle, state);
        client.on('message', (value: socket.SocketMessageInfo) => {
          state.push(value.message);
        });
        client.on('close', () => {
          state.close();
        });
        client.on('error', () => {
          state.close();
        });
        if (this.acceptPending) {
          const p = this.acceptPending;
          this.acceptPending = null;
          p(connHandle);
        } else {
          this.acceptQueue.push(connHandle);
        }
      });
      return handle;
    } catch (e) {
      return -1;
    }
  }

  async accept(listenerHandle: number): Promise<number> {
    if (this.acceptQueue.length > 0) {
      return this.acceptQueue.shift()!;
    }
    return new Promise<number>((resolve) => {
      this.acceptPending = resolve;
    });
  }

  async read(handle: number, maxLen: number): Promise<ReadResult> {
    const state = this.conns.get(handle);
    if (!state) {
      const missing: ReadResult = { data: new ArrayBuffer(0), err: 'invalid handle' };
      return missing;
    }
    if (state.queue.length > 0) {
      const buf = state.queue.shift()!;
      if (buf.byteLength <= maxLen) {
        state.totalRead += buf.byteLength;
        const whole: ReadResult = { data: buf, err: '' };
        return whole;
      }
      // Split: return first maxLen, keep the rest
      const view = new Uint8Array(buf);
      const first = new ArrayBuffer(maxLen);
      new Uint8Array(first).set(view.subarray(0, maxLen));
      const restLen = view.length - maxLen;
      const rest = new ArrayBuffer(restLen);
      new Uint8Array(rest).set(view.subarray(maxLen));
      state.queue.unshift(rest);
      state.totalRead += maxLen;
      const firstPart: ReadResult = { data: first, err: '' };
      return firstPart;
    }
    if (state.eof) {
      const closed: ReadResult = { data: new ArrayBuffer(0), err: '' };
      return closed;
    }
    return new Promise<ReadResult>((resolve) => {
      const pending: PendingRead = { resolve: resolve };
      state.pending = pending;
    });
  }

  async write(handle: number, data: ArrayBuffer): Promise<number> {
    const state = this.conns.get(handle);
    if (!state) {
      return -1;
    }
    const options: socket.TCPSendOptions = { data: data };
    try {
      if (state.conn) {
        await state.conn.send(options);
        return data.byteLength;
      }
      if (state.sock) {
        await state.sock.send(options);
        return data.byteLength;
      }
      return -1;
    } catch (e) {
      return -1;
    }
  }

  closeConn(handle: number): void {
    const state = this.conns.get(handle);
    if (state) {
      this.conns.delete(handle);
      state.close();
      try {
        if (state.conn) {
          state.conn.close();
        }
        if (state.sock) {
          state.sock.close();
        }
      } catch (e) {
        // ignore
      }
    }
  }

  closeListener(handle: number): void {
    const server = this.listeners.get(handle);
    if (server) {
      this.listeners.delete(handle);
      try {
        server.close();
      } catch (e) {
        // ignore
      }
    }
  }

  private parseAddr(addr: string): HostPort {
    const idx = addr.lastIndexOf(':');
    if (idx < 0) {
      const fallback: HostPort = { host: addr, port: 53317 };
      return fallback;
    }
    const host = addr.substring(0, idx);
    const port = parseInt(addr.substring(idx + 1), 10) || 53317;
    const result: HostPort = { host: host, port: port };
    return result;
  }

  private parsePort(addr: string): number {
    const idx = addr.lastIndexOf(':');
    if (idx < 0) {
      return 53317;
    }
    return parseInt(addr.substring(idx + 1), 10) || 53317;
  }
}
