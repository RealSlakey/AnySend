// NetworkLayer backed by the embedded Tailscale tsnet userspace netstack.
// TailscaleManager's native calls are blocking, so we wrap them in
// Promise.resolve to match the async NetworkLayer interface.

import { NetworkLayer } from './NetworkLayer';
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

  async read(handle: number, maxLen: number): Promise<{ data: ArrayBuffer; err: string }> {
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
