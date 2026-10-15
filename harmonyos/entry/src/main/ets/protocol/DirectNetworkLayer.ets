// NetworkLayer backed by the HarmonyOS system network stack (@ohos.net.socket).
// Used in "Direct LAN Mode" when Tailscale is not available — both devices
// must be on the same Wi-Fi / reachable network.
//
// The HarmonyOS socket API is event-based, so we bridge incoming 'message'
// events into a buffer queue that read() drains.

import socket from '@ohos.net.socket';
import { NetworkLayer } from './NetworkLayer';

interface PendingRead {
  resolve: (value: { data: ArrayBuffer; err: string }) => void;
}

class ConnState {
  sock: socket.TCPSocket | null = null;
  queue: ArrayBuffer[] = [];
  pending: PendingRead | null = null;
  eof: boolean = false;
  totalRead: number = 0;

  push(data: ArrayBuffer): void {
    if (this.pending) {
      const p = this.pending;
      this.pending = null;
      p.resolve({ data, err: '' });
    } else {
      this.queue.push(data);
    }
  }

  close(): void {
    this.eof = true;
    if (this.pending) {
      const p = this.pending;
      this.pending = null;
      p.resolve({ data: new ArrayBuffer(0), err: 'closed' });
    }
  }
}

export class DirectNetworkLayer implements NetworkLayer {
  private nextHandle: number = 1;
  private listeners: Map<number, socket.TCPServerSocket> = new Map();
  private conns: Map<number, ConnState> = new Map();
  private acceptQueue: number[] = [];
  private acceptPending: ((handle: number) => void) | null = null;

  async dial(network: string, addr: string): Promise<number> {
    try {
      const { host, port } = this.parseAddr(addr);
      const tcp = socket.constructTCPSocketInstance();
      await tcp.connect({ address: { address: host, port: port }, timeout: 5000 });
      const handle = this.nextHandle++;
      const state = new ConnState();
      state.sock = tcp;
      this.conns.set(handle, state);
      tcp.on('message', (value: { message: ArrayBuffer }) => {
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
      const port = this.parsePort(addr);
      const server = socket.constructTCPServerSocketInstance();
      await server.listen({ address: '0.0.0.0', port: port });
      const handle = this.nextHandle++;
      this.listeners.set(handle, server);
      server.on('connect', (client: socket.TCPSocket) => {
        const connHandle = this.nextHandle++;
        const state = new ConnState();
        state.sock = client;
        this.conns.set(connHandle, state);
        client.on('message', (value: { message: ArrayBuffer }) => {
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

  async read(handle: number, maxLen: number): Promise<{ data: ArrayBuffer; err: string }> {
    const state = this.conns.get(handle);
    if (!state) {
      return { data: new ArrayBuffer(0), err: 'invalid handle' };
    }
    if (state.queue.length > 0) {
      const buf = state.queue.shift()!;
      if (buf.byteLength <= maxLen) {
        state.totalRead += buf.byteLength;
        return { data: buf, err: '' };
      }
      // Split: return first maxLen, keep the rest
      const view = new Uint8Array(buf);
      const first = view.slice(0, maxLen).buffer;
      const rest = view.slice(maxLen).buffer;
      state.queue.unshift(rest);
      state.totalRead += maxLen;
      return { data: first, err: '' };
    }
    if (state.eof) {
      return { data: new ArrayBuffer(0), err: '' };
    }
    return new Promise<{ data: ArrayBuffer; err: string }>((resolve) => {
      state.pending = { resolve };
    });
  }

  async write(handle: number, data: ArrayBuffer): Promise<number> {
    const state = this.conns.get(handle);
    if (!state || !state.sock) {
      return -1;
    }
    try {
      await state.sock.send({ data: data });
      return data.byteLength;
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
        state.sock?.close();
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

  private parseAddr(addr: string): { host: string; port: number } {
    const idx = addr.lastIndexOf(':');
    if (idx < 0) {
      return { host: addr, port: 53317 };
    }
    const host = addr.substring(0, idx);
    const port = parseInt(addr.substring(idx + 1), 10) || 53317;
    return { host, port };
  }

  private parsePort(addr: string): number {
    const idx = addr.lastIndexOf(':');
    if (idx < 0) {
      return 53317;
    }
    return parseInt(addr.substring(idx + 1), 10) || 53317;
  }
}
