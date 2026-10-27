// NetworkLayer backed by the embedded Tailscale tsnet userspace netstack.
// All native calls run on the dedicated worker thread (see TsnapiWorker):
// a cgo call from the UI thread can stall the Go runtime and trip the 6 s
// main-thread watchdog, so every call here is async via TsnapiClient.

import { NetworkLayer, ReadResult } from './NetworkLayer';
import { TailscaleManager } from '../bridge/TailscaleManager';

export class TailscaleNetworkLayer implements NetworkLayer {
  async dial(network: string, addr: string): Promise<number> {
    return TailscaleManager.dial(network, addr);
  }

  async listen(network: string, addr: string): Promise<number> {
    return TailscaleManager.listen(network, addr);
  }

  async accept(listenerHandle: number): Promise<number> {
    return TailscaleManager.accept(listenerHandle);
  }

  async read(handle: number, maxLen: number): Promise<ReadResult> {
    return TailscaleManager.read(handle, maxLen);
  }

  async write(handle: number, data: ArrayBuffer): Promise<number> {
    return TailscaleManager.write(handle, data);
  }

  closeConn(handle: number): void {
    TailscaleManager.closeConn(handle);
  }

  closeListener(handle: number): void {
    TailscaleManager.closeListener(handle);
  }
}
