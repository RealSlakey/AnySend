// LocalSend protocol v2 discovery: devices announce themselves as JSON over
// the 224.0.0.167:53317 multicast group. announce=false asks everyone to
// announce; announce=true is the announcement. Wire-compatible with the
// official LocalSend apps.

import socket from '@ohos.net.socket';
import util from '@ohos.util';
import { DeviceProfile } from './DeviceProfile';
import { LocalSendConst } from '../protocol/LocalSendModels';

export interface LanDevice {
  name: string;
  ip: string;
  fingerprint: string;
}

const MULTICAST_ADDR = '224.0.0.167';
const ANNOUNCE_INTERVAL_MS = 5000;
// Min interval between discovery replies to the same source. Without it a
// peer that answers our announcements with fresh requests creates a
// multicast reply storm (observed with the official LocalSend app).
const REPLY_THROTTLE_MS = 2000;

interface DiscoveryMsg {
  alias?: string;
  version?: string;
  deviceModel?: string;
  deviceType?: string;
  fingerprint?: string;
  port?: number;
  protocol?: string;
  download?: boolean;
  announce?: boolean;
}

export class LanDiscovery {
  private static socket: socket.UDPSocket | null = null;
  private static announceTimer: number = -1;
  private static started: boolean = false;
  private static retryTimer: number = -1;
  private static retryCount: number = 0;
  private static devices: Map<string, LanDevice> = new Map(); // ip -> device
  private static lastReplyAt: Map<string, number> = new Map(); // ip -> last reply ts

  static isRunning(): boolean {
    return LanDiscovery.started;
  }

  /** Start the resident responder: join the group, answer discovery
   *  requests and announce periodically. */
  static start(): void {
    if (LanDiscovery.started) {
      return;
    }
    LanDiscovery.started = true;
    LanDiscovery.responderLoop();
  }

  static stop(): void {
    LanDiscovery.started = false;
    if (LanDiscovery.announceTimer >= 0) {
      clearInterval(LanDiscovery.announceTimer);
      LanDiscovery.announceTimer = -1;
    }
    if (LanDiscovery.retryTimer >= 0) {
      clearTimeout(LanDiscovery.retryTimer);
      LanDiscovery.retryTimer = -1;
    }
    LanDiscovery.retryCount = 0;
    if (LanDiscovery.socket !== null) {
      try {
        LanDiscovery.socket.close();
      } catch (e) {
        // ignore
      }
      LanDiscovery.socket = null;
    }
    LanDiscovery.devices.clear();
  }

  /** Broadcast announce=false and collect announcements for timeoutMs. */
  static async scan(timeoutMs: number = 2500): Promise<LanDevice[]> {
    if (!LanDiscovery.started) {
      LanDiscovery.start();
    }
    // Give the resident socket a moment to be bound.
    await LanDiscovery.sleep(300);
    await LanDiscovery.sendAnnounce(false);
    await LanDiscovery.sleep(timeoutMs);
    const own = DeviceProfile.fingerprint();
    const list: LanDevice[] = [];
    LanDiscovery.devices.forEach((d: LanDevice) => {
      if (d.fingerprint !== own) {
        list.push(d);
      }
    });
    return list;
  }

  // ------------------------------------------------------------------ //

  private static async responderLoop(): Promise<void> {
    // Per the official guide: do NOT bind explicitly — addMembership binds
    // the socket internally using the port in its NetAddress. Binding first
    // and then joining with port=0 makes the internal re-bind fail EINVAL.
    let srv: socket.MulticastSocket;
    try {
      srv = socket.constructMulticastSocketInstance();
      // SO_REUSEADDR must be set before the internal bind happens in
      // addMembership. broadcast:true is invalid here (EINVAL), omit it.
      try {
        await srv.setExtraOptions({ reuseAddress: true });
        console.info('LanDiscovery: extraOptions ok');
      } catch (e) {
        console.warn(`LanDiscovery: extraOptions skipped: ${JSON.stringify(e)}`);
      }
      await srv.addMembership({ address: MULTICAST_ADDR, port: LocalSendConst.PORT, family: 1 });
      console.info('LanDiscovery: join ok');
    } catch (e) {
      console.error(`LanDiscovery: init failed: ${JSON.stringify(e)}`);
      LanDiscovery.started = false;
      LanDiscovery.scheduleRetry();
      return;
    }
    LanDiscovery.retryCount = 0;
    srv.on('message', (value: socket.SocketMessageInfo) => {
      LanDiscovery.handlePacket(value);
    });
    LanDiscovery.socket = srv;
    console.info('LanDiscovery: responder joined 224.0.0.167:53317');
    // Periodic announcement so others find us.
    LanDiscovery.sendAnnounce(true);
    LanDiscovery.announceTimer = setInterval(() => {
      LanDiscovery.sendAnnounce(true);
    }, ANNOUNCE_INTERVAL_MS);
  }

  /** Port 53317 is not released the moment close() returns, so re-joining
   *  right after a network change can fail with "Address in use". Retry. */
  private static scheduleRetry(): void {
    if (LanDiscovery.retryCount >= 5) {
      LanDiscovery.retryCount = 0;
      return;
    }
    LanDiscovery.retryCount++;
    if (LanDiscovery.retryTimer >= 0) {
      clearTimeout(LanDiscovery.retryTimer);
    }
    LanDiscovery.retryTimer = setTimeout(() => {
      LanDiscovery.retryTimer = -1;
      LanDiscovery.start();
    }, 700);
  }

  private static handlePacket(value: socket.SocketMessageInfo): void {
    const text = LanDiscovery.decode(value.message);
    let msg: DiscoveryMsg;
    try {
      msg = JSON.parse(text) as DiscoveryMsg;
    } catch (e) {
      return;
    }
    if (!msg || typeof msg.fingerprint !== 'string' || msg.fingerprint.length === 0) {
      return;
    }
    const ip = value.remoteInfo.address;
    const name = (msg.alias !== undefined && msg.alias.length > 0) ? msg.alias : ip;
    LanDiscovery.devices.set(ip, {
      name: name,
      ip: ip,
      fingerprint: msg.fingerprint
    });
    if (msg.announce !== true) {
      // The sender is asking for announcements — reply with ours,
      // throttled per source to break reply-storm feedback loops.
      const now = Date.now();
      if (now - (LanDiscovery.lastReplyAt.get(ip) ?? 0) >= REPLY_THROTTLE_MS) {
        LanDiscovery.lastReplyAt.set(ip, now);
        LanDiscovery.sendAnnounce(true);
      }
    }
  }

  /** LocalSend v2 discovery message: DeviceInfo fields + announce flag. */
  private static async sendAnnounce(announce: boolean): Promise<void> {
    const s = LanDiscovery.socket;
    if (s === null) {
      return;
    }
    const msg: Record<string, Object> = {
      'alias': DeviceProfile.displayName(),
      'version': LocalSendConst.PROTOCOL_VERSION,
      'deviceModel': 'HarmonyOS',
      'deviceType': 'mobile',
      'fingerprint': DeviceProfile.fingerprint(),
      'port': LocalSendConst.PORT,
      'protocol': 'http',
      'download': true,
      'announce': announce
    };
    try {
      await s.send({
        data: JSON.stringify(msg),
        address: { address: MULTICAST_ADDR, port: LocalSendConst.PORT }
      });
      console.info(`LanDiscovery: announce(${announce}) sent`);
    } catch (e) {
      console.error(`LanDiscovery: announce failed: ${JSON.stringify(e)}`);
    }
  }

  private static decode(buf: ArrayBuffer): string {
    // Aliases are UTF-8 (Chinese names are multi-byte); decode properly.
    try {
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    } catch (e) {
      return '';
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }
}
