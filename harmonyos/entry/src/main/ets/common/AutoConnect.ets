// Auto-connect bootstrap: after the first successful Tailscale login the
// auth key is persisted, and every subsequent app start reconnects by itself
// and brings the receive server up — the user never taps "login" again.
//
// All native work goes through TailscaleManager → TsnapiWorker, so the UI
// thread never enters cgo (THREAD_BLOCK_6S watchdog). EntryAbility.onCreate
// fire-and-forgets run(); the transfer page subscribes for status display.

import wifiManager from '@ohos.wifiManager';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { TailscaleManager } from '../bridge/TailscaleManager';
import { LocalSendServer } from '../protocol/LocalSendServer';
import { createDeviceInfo } from '../protocol/LocalSendModels';
import { TailscaleNetworkLayer } from '../protocol/TailscaleNetworkLayer';
import { DirectNetworkLayer } from '../protocol/DirectNetworkLayer';
import { NetworkLayer } from '../protocol/NetworkLayer';
import { SmsStore } from '../sms/SmsStore';
import { DeviceProfile } from './DeviceProfile';

export type ConnectPhase = 'idle' | 'connecting' | 'running' | 'failed';

const PREFS_NAME = 'ts_auth';
const KEY_AUTH = 'authKey';

export class AutoConnect {
  private static phase: ConnectPhase = 'idle';
  private static statusText: string = '未连接';
  private static gServer: LocalSendServer | null = null;
  private static listeners: (() => void)[] = [];
  private static cachedKey: string | null = null;

  static getPhase(): ConnectPhase {
    return AutoConnect.phase;
  }

  static getStatusText(): string {
    return AutoConnect.statusText;
  }

  static isServerRunning(): boolean {
    return AutoConnect.gServer !== null;
  }

  static onChange(cb: () => void): void {
    AutoConnect.listeners.push(cb);
  }

  static offChange(cb: () => void): void {
    const idx = AutoConnect.listeners.indexOf(cb);
    if (idx >= 0) {
      AutoConnect.listeners.splice(idx, 1);
    }
  }

  private static emit(): void {
    for (const l of AutoConnect.listeners) {
      l();
    }
  }

  static async loadAuthKey(context: common.UIAbilityContext): Promise<string> {
    if (AutoConnect.cachedKey !== null) {
      return AutoConnect.cachedKey;
    }
    try {
      const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
      AutoConnect.cachedKey = (await prefs.get(KEY_AUTH, '')) as string;
    } catch (e) {
      AutoConnect.cachedKey = '';
    }
    return AutoConnect.cachedKey;
  }

  static async saveAuthKey(context: common.UIAbilityContext, key: string): Promise<void> {
    AutoConnect.cachedKey = key;
    try {
      const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
      await prefs.put(KEY_AUTH, key);
      await prefs.flush();
    } catch (e) {
      console.error(`AutoConnect: save authKey failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * Auto login on app start. No-op when nothing is saved yet (first run) or
   * when a connection is already up/in progress. Safe to call repeatedly.
   */
  static async run(context: common.UIAbilityContext): Promise<void> {
    if (AutoConnect.phase === 'running' || AutoConnect.phase === 'connecting') {
      return;
    }
    const key = await AutoConnect.loadAuthKey(context);
    if (key.length === 0) {
      return; // first run: wait for a manual login
    }
    AutoConnect.phase = 'connecting';
    AutoConnect.statusText = '正在自动连接 Tailscale…';
    AutoConnect.emit();
    await AutoConnect.connect(key, context, false);
  }

  /** Manual login from the transfer page; persists the key on success. */
  static async manualLogin(authKey: string, context: common.UIAbilityContext): Promise<boolean> {
    AutoConnect.phase = 'connecting';
    AutoConnect.statusText = '正在连接 Tailscale...';
    AutoConnect.emit();
    return AutoConnect.connect(authKey, context, true);
  }

  private static async connect(key: string, context: common.UIAbilityContext, save: boolean): Promise<boolean> {
    const ok = await TailscaleManager.login(key, context);
    if (ok) {
      if (save) {
        await AutoConnect.saveAuthKey(context, key);
      }
      AutoConnect.phase = 'running';
      AutoConnect.statusText = 'Tailscale 已连接';
      AutoConnect.startServer(new TailscaleNetworkLayer(), context);
    } else {
      const err = TailscaleManager.lastErr;
      AutoConnect.phase = 'failed';
      AutoConnect.statusText = err !== '' ? `Tailscale 连接失败：${err}` : 'Tailscale 连接失败（可改用直连模式）';
    }
    AutoConnect.emit();
    return ok;
  }

  /** Start (or restart) the receive server on the given network layer. */
  static startServer(network: NetworkLayer, context: common.UIAbilityContext): void {
    if (AutoConnect.gServer !== null) {
      AutoConnect.gServer.stop();
    }
    const self = createDeviceInfo(DeviceProfile.displayName(), 'HarmonyOS', DeviceProfile.fingerprint());
    // Dual-stack: serve over both Tailscale and the direct LAN stack so
    // LAN-discovered peers can reach us too. A layer that fails to listen
    // (e.g. Tailscale not connected) is skipped by the server itself.
    const layers: NetworkLayer[] = network instanceof TailscaleNetworkLayer
      ? [network, new DirectNetworkLayer()]
      : [network];
    AutoConnect.gServer = new LocalSendServer(context, self, layers);
    AutoConnect.gServer.start();
    AutoConnect.wireSmsRelay();
    AutoConnect.emit();
  }

  /** Once our server listens, tell SmsStore where Android can push SMS. */
  private static wireSmsRelay(): void {
    const store = SmsStore.getInstance();
    const addr = AutoConnect.currentCallbackIp();
    if (addr.length === 0) {
      return;
    }
    store.setCallbackAddr(`${addr}:53317`);
    store.serverRunning = true;
    store.startPolling();
  }

  static currentCallbackIp(): string {
    if (TailscaleManager.isStarted()) {
      const self = TailscaleManager.getSelfInfo();
      if (self !== null && self.tailscaleIP.length > 0) {
        return self.tailscaleIP;
      }
    }
    return AutoConnect.queryLanIp();
  }

  /** Query the Wi-Fi LAN IPv4 (dotted), empty string when unavailable. */
  static queryLanIp(): string {
    try {
      const info = wifiManager.getIpInfo();
      const ip = info.ipAddress;
      if (ip === 0) {
        return '';
      }
      return `${ip & 0xFF}.${(ip >> 8) & 0xFF}.${(ip >> 16) & 0xFF}.${(ip >> 24) & 0xFF}`;
    } catch (e) {
      return '';
    }
  }

  private static generateUUID(): string {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }
}
