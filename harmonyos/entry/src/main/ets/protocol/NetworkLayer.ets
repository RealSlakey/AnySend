// Abstraction over the raw socket layer so the LocalSend protocol code can
// run either over the Tailscale userspace netstack or over the system
// network stack (Direct LAN mode).
//
// Methods are async because the HarmonyOS system socket API is
// promise-based. The Tailscale implementation resolves immediately since
// its native calls are blocking.

export interface NetworkLayer {
  /** Open a TCP connection to addr (host:port). Resolves to handle (>0) or -1. */
  dial(network: string, addr: string): Promise<number>;

  /** Listen on addr. Resolves to listener handle (>0) or -1. */
  listen(network: string, addr: string): Promise<number>;

  /** Accept one connection. Resolves to connection handle (>0) or -1. */
  accept(listenerHandle: number): Promise<number>;

  /** Read up to maxLen bytes. Resolves to { data, err }. */
  read(handle: number, maxLen: number): Promise<{ data: ArrayBuffer; err: string }>;

  /** Write data. Resolves to bytes written or -1. */
  write(handle: number, data: ArrayBuffer): Promise<number>;

  closeConn(handle: number): void;
  closeListener(handle: number): void;
}
