// Safe wrapper around the libtsnapi.so NAPI module.
//
// When the native Tailscale .so is present (built from go/), the real
// implementation is used. When it is absent (e.g. local dev without the
// OpenHarmony NDK toolchain), a stub is returned so the app can still
// build and run in Direct LAN Mode.

import tsnapi from 'libtsnapi.so';

export interface TsnapiApi {
  start(authKey: string, stateDir: string, hostname: string): number;
  startAsync(authKey: string, stateDir: string, hostname: string): number;
  startState(): string;
  lastError(): string;
  isStarted(): number;
  getSelfInfo(): string;
  getPeers(): string;
  dial(network: string, addr: string): string;
  listen(network: string, addr: string): string;
  accept(listenerHandle: number): string;
  acceptStart(listenerHandle: number): number;
  acceptPoll(listenerHandle: number): string;
  forwardTcp(localPort: number, target: string): string;
  closeForward(handle: number): number;
  read(handle: number, maxLen: number): string;
  write(handle: number, data: ArrayBuffer): number;
  closeConn(handle: number): void;
  closeListener(handle: number): void;
  close(): void;
  probeChild(outPath: string): string;
  probeTls(): string;
  probeKeySlot(): string;
  // Surface-mode H.264 decoder (scrcpy mirror), implemented in video_decoder.cpp.
  vdInit(surfaceId: string, width: number, height: number): number;
  vdPush(data: ArrayBuffer, flags: number, ptsUs: number): number;
  vdRelease(): void;
}

class TsnapiStub implements TsnapiApi {
  start(authKey: string, stateDir: string, hostname: string): number {
    return -1;
  }

  startAsync(authKey: string, stateDir: string, hostname: string): number {
    return -1;
  }

  startState(): string {
    return '';
  }

  lastError(): string {
    return 'tailscale not available';
  }

  isStarted(): number {
    return 0;
  }

  getSelfInfo(): string {
    return '';
  }

  getPeers(): string {
    return '[]';
  }

  dial(network: string, addr: string): string {
    return '{"error":"tailscale not available"}';
  }

  listen(network: string, addr: string): string {
    return '{"error":"tailscale not available"}';
  }

  accept(listenerHandle: number): string {
    return '{"error":"tailscale not available"}';
  }

  acceptStart(listenerHandle: number): number {
    return -1;
  }

  acceptPoll(listenerHandle: number): string {
    return '{"error":"tailscale not available"}';
  }

  forwardTcp(localPort: number, target: string): string {
    return '{"error":"tailscale not available"}';
  }

  closeForward(handle: number): number {
    return -1;
  }

  read(handle: number, maxLen: number): string {
    return '{"data":"","err":"tailscale not available"}';
  }

  write(handle: number, data: ArrayBuffer): number {
    return -1;
  }

  closeConn(handle: number): void {
  }

  closeListener(handle: number): void {
  }

  close(): void {
  }

  probeChild(outPath: string): string {
    return '';
  }

  probeTls(): string {
    return '';
  }

  probeKeySlot(): string {
    return '';
  }

  vdInit(surfaceId: string, width: number, height: number): number {
    return -1;
  }

  vdPush(data: ArrayBuffer, flags: number, ptsUs: number): number {
    return -1;
  }

  vdRelease(): void {
  }
}

let cached: TsnapiApi | null = null;

export function getTsnapi(): TsnapiApi {
  if (cached !== null) {
    return cached;
  }
  // libtsnapi.so is bundled with the HAP. When it was built without
  // libtsnetbridge.so it returns failure sentinels and the caller falls
  // back to Direct LAN Mode. The stub is used only if the native module
  // does not expose the expected entry point.
  const mod: TsnapiApi = tsnapi as TsnapiApi;
  if (typeof mod.start === 'function') {
    cached = mod;
  } else {
    cached = new TsnapiStub();
  }
  return cached;
}
