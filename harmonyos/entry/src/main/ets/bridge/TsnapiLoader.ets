// Safe wrapper around the libtsnapi.so NAPI module.
//
// When the native Tailscale .so is present (built from go/), the real
// implementation is used. When it is absent (e.g. local dev without the
// OpenHarmony NDK toolchain), a stub is returned so the app can still
// build and run in Direct LAN Mode.

export interface TsnapiApi {
  start(authKey: string, stateDir: string, hostname: string): number;
  isStarted(): number;
  getSelfInfo(): string;
  getPeers(): string;
  dial(network: string, addr: string): string;
  listen(network: string, addr: string): string;
  accept(listenerHandle: number): string;
  read(handle: number, maxLen: number): string;
  write(handle: number, data: ArrayBuffer): number;
  closeConn(handle: number): void;
  closeListener(handle: number): void;
  close(): void;
}

const stub: TsnapiApi = {
  start(): number { return -1; },
  isStarted(): number { return 0; },
  getSelfInfo(): string { return ''; },
  getPeers(): string { return '[]'; },
  dial(): string { return '{"error":"tailscale not available"}'; },
  listen(): string { return '{"error":"tailscale not available"}'; },
  accept(): string { return '{"error":"tailscale not available"}'; },
  read(): string { return '{"data":"","err":"tailscale not available"}'; },
  write(): number { return -1; },
  closeConn(): void { /* no-op */ },
  closeListener(): void { /* no-op */ },
  close(): void { /* no-op */ }
};

let cached: TsnapiApi | null = null;

export function getTsnapi(): TsnapiApi {
  if (cached !== null) {
    return cached;
  }
  try {
    // Try the full .so filename first, then the bare module name.
    const candidates = ['libtsnapi.so', 'tsnapi'];
    for (const name of candidates) {
      try {
        const mod = requireNapi(name);
        if (mod && typeof mod.start === 'function') {
          cached = mod as TsnapiApi;
          return cached;
        }
      } catch (inner) {
        // try next candidate
      }
    }
  } catch (e) {
    // Native module not available — fall back to stub.
  }
  cached = stub;
  return cached;
}
