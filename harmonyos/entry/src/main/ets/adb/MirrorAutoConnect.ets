// Mirror auto-connect: resolves the Android mirror-bridge endpoint without any
// manual IP entry and without adb. Flow (seamless bootstrap):
//   1. tailnet  – raw HTTP POST :53317/api/anysend/v1/mirror-prepare to the
//                 paired/online Android AnySend over tsnet; the peer starts its
//                 Wi-Fi hotspot (Shizuku), spawns scrcpy-server and reports its
//                 IPv4, the hotspot SSID/password and the two LAN stream ports
//   2. direct   – when the reported IPv4 is already reachable (same Wi-Fi), use
//                 it as-is, no hotspot needed
//   3. hotspot  – otherwise auto-join the reported hotspot and locate the peer
//                 (gateway guess / reported IP / re-ask over tailnet / sweep)
//
// The tailnet hop must NOT use @ohos.http — the system HTTP stack does not
// route through tsnet. Raw HTTP over TailscaleNetworkLayer is the only way to
// reach tailnet peers (same pattern as LocalSendSender). Plain TCP probes run
// on the system socket stack because the target IPs (192.168.x.x) are LAN
// addresses, not tailnet routes.
//
// Reachability is always probed on the LocalSend HTTP port (53317), never on a
// stream port: the bridge pairs its sockets in order and a stray connect to the
// video port would consume the video accept slot.

import socket from '@ohos.net.socket';
import wifiManager from '@ohos.wifiManager';
import { display } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { TailscaleManager } from '../bridge/TailscaleManager';
import { TailscaleNetworkLayer } from '../protocol/TailscaleNetworkLayer';
import { NetworkLayer, ReadResult } from '../protocol/NetworkLayer';
import { SmsStore } from '../sms/SmsStore';

const LOCALSEND_PORT = 53317;
const MIRROR_PREPARE_PATH = '/api/anysend/v1/mirror-prepare';
const APPS_PATH = '/api/anysend/v1/apps';
const TAILNET_HTTP_TIMEOUT_MS = 15000; // Android blocks ≤8 s raising the hotspot
const APPS_HTTP_TIMEOUT_MS = 45000; // ~120 base64 icons over the DERP relay
const TAILNET_PROBE_TIMEOUT_MS = 1500;
const CONFIRM_PROBE_TIMEOUT_MS = 1200;
const SCAN_PROBE_TIMEOUT_MS = 200;
const SCAN_CONCURRENCY = 12;
const JOIN_TOTAL_MS = 25000;
const JOIN_POLL_MS = 600;
const CONFIRM_TOTAL_MS = 45000;
const REASK_INTERVAL_MS = 5000;

/** Virtual-display geometry handed to the Android peer (px @ dpi). */
export interface VdParams {
  width: number;
  height: number;
  dpi: number;
}

/** One launcher entry reported by the Android peer. */
export interface AppEntry {
  pkg: string;
  label: string;
  icon: string; // base64 PNG (no data-uri prefix)
}

interface AppsResp {
  ok?: boolean;
  apps?: AppEntry[];
}

const VD_MAX_DIM = 2048; // matches the Android side's max_size

interface MirrorPrepareResp {
  ok?: boolean;
  ip?: string;
  port?: number;
  hotspotOn?: boolean;
  ssid?: string;
  password?: string;
  wirelessPort?: number;
  wirelessEnabled?: boolean;
  videoPort?: number;
  controlPort?: number;
  scid?: string;
}

interface MirrorPrepareInfo {
  ip: string;
  ssid: string;
  password: string;
  hotspotOn: boolean;
  videoPort: number;
  controlPort: number;
  scid: string;
}

/** LAN endpoint of the Android mirror bridge (video/control TCP ports). */
export interface MirrorBridgeTarget {
  host: string;
  videoPort: number;
  controlPort: number;
  scid: string;
  how: string; // 'lan' | 'hotspot'
}

interface HttpReply {
  status: number;
  body: string;
}

export class MirrorAutoConnect {
  /**
   * Resolve the Android mirror-bridge endpoint: ask the peer to prepare the
   * mirror (hotspot + scrcpy-server), then hand back the LAN host and the two
   * stream ports the HarmonyOS native layer connects to. Resolves null when no
   * peer answered or the bridge could not be started.
   *
   * `onNote` receives human-readable progress lines for the connecting UI.
   */
  static async resolveBridgeTarget(onNote?: (msg: string) => void,
    virtualDisplay: boolean = false,
    vd: VdParams | null = null): Promise<MirrorBridgeTarget | null> {
    onNote?.('正在询问已配对的安卓设备…');
    const tailnetIps = await MirrorAutoConnect.androidTailnetIps();
    if (tailnetIps.length === 0) {
      onNote?.('未找到安卓设备，请确认两端 Tailscale 已连接并已配对');
      return null;
    }

    let info: MirrorPrepareInfo | null = null;
    for (const ip of tailnetIps) {
      info = await MirrorAutoConnect.askMirrorPrepare(ip, virtualDisplay, vd);
      if (info.videoPort > 0 || info.ip.length > 0) {
        break;
      }
    }
    if (info === null || (info.videoPort <= 0 && info.ip.length === 0)) {
      onNote?.('安卓端未响应镜像准备请求');
      return null;
    }

    // Same Wi-Fi: the reported IPv4 already answers, no hotspot needed.
    const direct = await MirrorAutoConnect.firstReachableHost([info.ip]);
    if (direct.length > 0) {
      onNote?.('同一网络内直连…');
      return MirrorAutoConnect.accept(info, direct, 'lan');
    }

    // Different network: join the Android hotspot and locate the peer there.
    if (info.ssid.length > 0 && info.password.length > 0) {
      onNote?.('安卓热点已开启，正在加入热点网络…');
      const joined = await MirrorAutoConnect.joinHotspot(info.ssid, info.password);
      if (joined) {
        onNote?.('已加入热点，正在确认设备地址…');
        const confirmed = await MirrorAutoConnect.confirmHotspotHost(info, tailnetIps, virtualDisplay, vd);
        if (confirmed.length > 0) {
          return MirrorAutoConnect.accept(info, confirmed, 'hotspot');
        }
      }
    }

    onNote?.('未能连接到安卓端镜像服务');
    return null;
  }

  // ------------------------------------------------------------------ //

  private static accept(info: MirrorPrepareInfo, host: string, how: string): MirrorBridgeTarget {
    const target: MirrorBridgeTarget = {
      host: host,
      videoPort: info.videoPort,
      controlPort: info.controlPort,
      scid: info.scid,
      how: how
    };
    return target;
  }

  /** First candidate that answers on the LocalSend port ('' when none). */
  private static async firstReachableHost(candidates: string[]): Promise<string> {
    for (const candidate of candidates) {
      if (candidate.length === 0) {
        continue;
      }
      if (await MirrorAutoConnect.probeTcp(candidate, LOCALSEND_PORT, TAILNET_PROBE_TIMEOUT_MS)) {
        return candidate;
      }
    }
    return '';
  }

  /** Paired Android (SmsStore) first, then every online tailnet peer. */
  private static async androidTailnetIps(): Promise<string[]> {
    const ips: string[] = [];
    try {
      const store = SmsStore.getInstance();
      if (store.hostAddress.length > 0) {
        const ip = store.hostAddress.split(':')[0].trim();
        if (ip.length > 0) {
          ips.push(ip);
        }
      }
    } catch (e) {
      // store not initialized — fall through to peers
    }
    await TailscaleManager.refreshStatus();
    const peers = TailscaleManager.getPeers();
    for (const p of peers) {
      if (p.online && p.tailscaleIP.length > 0 && !ips.includes(p.tailscaleIP)) {
        ips.push(p.tailscaleIP);
      }
    }
    return ips;
  }

  /** Query string for the mirror-prepare request (`?vd=1[&w=&h=&dpi=]`). */
  private static vdQuery(vd: VdParams | null): string {
    if (vd === null || vd.width <= 0 || vd.height <= 0) {
      return '?vd=1';
    }
    const dpi = vd.dpi > 0 ? `&dpi=${Math.round(vd.dpi)}` : '';
    return `?vd=1&w=${Math.round(vd.width)}&h=${Math.round(vd.height)}${dpi}`;
  }

  /**
   * 虚拟显示几何（px @ dpi），由本机 app 的**可用内容区**换算。
   *
   * [areaWidthVp]/[areaHeightVp] 是本机页面里画面容器实际占据的大小（vp，
   * 已排除状态栏、导航条）：安卓端虚拟显示按这个尺寸运行，视频流的宽高比
   * 与画面容器完全一致，才能满铺、四周不留黑边。DPI 用本机原生值，
   * dp 画布也与内容区一致 —— 同一个 app 在本机看起来和鸿蒙原生应用同样大小。
   * 最长边超过 [VD_MAX_DIM] 时整体等比缩到 2048（scrcpy 的 max_size），避免解码压力。
   * 内容区尚未测得（<=0）时退回整屏尺寸。
   */
  static harmonyVdParams(areaWidthVp: number = 0, areaHeightVp: number = 0): VdParams {
    try {
      const d = display.getDefaultDisplaySync();
      const densityPx = d.densityPixels > 0 ? d.densityPixels : 1;
      const width = areaWidthVp > 0 ? areaWidthVp * densityPx : d.width;
      const height = areaHeightVp > 0 ? areaHeightVp * densityPx : d.height;
      const rawDpi = d.densityDPI > 0
        ? d.densityDPI
        : Math.round(densityPx * 160);
      const longest = Math.max(width, height);
      const k = longest > VD_MAX_DIM ? VD_MAX_DIM / longest : 1;
      const params: VdParams = {
        width: Math.round(width * k),
        height: Math.round(height * k),
        dpi: Math.round(rawDpi * k)
      };
      return params;
    } catch (e) {
      const fallback: VdParams = { width: 1080, height: 1920, dpi: 320 };
      return fallback;
    }
  }

  /**
   * 应用推流：向已配对的安卓端拉取可启动应用清单（包名 + 名称 + 图标）。
   * 走 tailnet 原始 HTTP（系统 http 栈不进 tsnet），不需要开启热点。
   * 失败时返回空数组，由调用方决定提示文案。
   */
  static async fetchApps(onNote?: (msg: string) => void,
    forceRefresh: boolean = false): Promise<AppEntry[]> {
    onNote?.('正在读取安卓端应用列表…');
    const tailnetIps = await MirrorAutoConnect.androidTailnetIps();
    if (tailnetIps.length === 0) {
      onNote?.('未找到安卓设备，请确认两端 Tailscale 已连接并已配对');
      return [];
    }
    for (const ip of tailnetIps) {
      const apps = await MirrorAutoConnect.getApps(ip, forceRefresh);
      if (apps !== null) {
        return apps;
      }
    }
    onNote?.('安卓端未返回应用列表');
    return [];
  }

  /** GET /api/anysend/v1/apps over tsnet; null when the peer did not answer. */
  private static async getApps(tailnetIp: string, forceRefresh: boolean): Promise<AppEntry[] | null> {
    const layer: NetworkLayer = new TailscaleNetworkLayer();
    const addr = `${tailnetIp}:${LOCALSEND_PORT}`;
    const conn = await layer.dial('tcp', addr);
    if (conn <= 0) {
      return null;
    }
    try {
      const path = forceRefresh ? `${APPS_PATH}?refresh=1` : APPS_PATH;
      const req = `GET ${path} HTTP/1.1\r\n` +
        `Host: ${addr}\r\n` +
        'Accept: application/json\r\n' +
        'Connection: close\r\n\r\n';
      const sent = await layer.write(conn, utf8Encode(req));
      if (sent <= 0) {
        return null;
      }
      const reply = await MirrorAutoConnect.readHttpReply(layer, conn, APPS_HTTP_TIMEOUT_MS);
      if (reply.status !== 200 || reply.body.length === 0) {
        return null;
      }
      try {
        const resp = JSON.parse(reply.body) as AppsResp;
        if (resp.ok === true && resp.apps !== undefined) {
          return resp.apps;
        }
      } catch (e) {
        // non-Android peer returned HTML/plain
      }
      return null;
    } finally {
      layer.closeConn(conn);
    }
  }

  /**
   * POST mirror-prepare over tsnet; resolves the peer's reply (LAN IPv4 +
   * hotspot AP credentials + bridge ports). Zero-length fields mean "not
   * provided". `virtualDisplay` adds ?vd=1 so the peer spawns scrcpy-server on
   * a fresh virtual display instead of its own screen; `vd` additionally sizes
   * that display to our own display area.
   */
  private static async askMirrorPrepare(tailnetIp: string,
    virtualDisplay: boolean,
    vd: VdParams | null): Promise<MirrorPrepareInfo> {
    const none: MirrorPrepareInfo = {
      ip: '',
      ssid: '',
      password: '',
      hotspotOn: false,
      videoPort: 0,
      controlPort: 0,
      scid: ''
    };
    const layer: NetworkLayer = new TailscaleNetworkLayer();
    const addr = `${tailnetIp}:${LOCALSEND_PORT}`;
    const conn = await layer.dial('tcp', addr);
    if (conn <= 0) {
      return none;
    }
    try {
      const path = virtualDisplay
        ? `${MIRROR_PREPARE_PATH}${MirrorAutoConnect.vdQuery(vd)}`
        : MIRROR_PREPARE_PATH;
      const req = `POST ${path} HTTP/1.1\r\n` +
        `Host: ${addr}\r\n` +
        'Content-Type: application/json\r\n' +
        'Content-Length: 0\r\n' +
        'Connection: close\r\n\r\n';
      const sent = await layer.write(conn, utf8Encode(req));
      if (sent <= 0) {
        return none;
      }
      const reply = await MirrorAutoConnect.readHttpReply(layer, conn, TAILNET_HTTP_TIMEOUT_MS);
      if (reply.status !== 200 || reply.body.length === 0) {
        return none;
      }
      try {
        const resp = JSON.parse(reply.body) as MirrorPrepareResp;
        const info: MirrorPrepareInfo = {
          ip: typeof resp.ip === 'string' ? resp.ip : '',
          ssid: typeof resp.ssid === 'string' ? resp.ssid : '',
          password: typeof resp.password === 'string' ? resp.password : '',
          hotspotOn: resp.hotspotOn === true,
          videoPort: typeof resp.videoPort === 'number' ? resp.videoPort : 0,
          controlPort: typeof resp.controlPort === 'number' ? resp.controlPort : 0,
          scid: typeof resp.scid === 'string' ? resp.scid : ''
        };
        if (resp.ok === true) {
          return info;
        }
      } catch (e) {
        // 404 HTML/plain from non-Android peers etc.
      }
      return none;
    } finally {
      layer.closeConn(conn);
    }
  }

  /**
   * Auto-join the Android hotspot with candidate-config APIs (needs only
   * SET_WIFI_INFO; the app must be foreground). Resolves true once the SSID
   * is linked and an IP is present.
   */
  private static async joinHotspot(ssid: string, password: string): Promise<boolean> {
    try {
      if (!wifiManager.isWifiActive()) {
        return false;
      }
      try {
        if (wifiManager.isConnected()) {
          const linked = await wifiManager.getLinkedInfo();
          if (linked.ssid === ssid) {
            return true;
          }
        }
      } catch (e) {
        // linked-info probes are best-effort
      }
      const cfg: wifiManager.WifiDeviceConfig = {
        ssid: ssid,
        preSharedKey: password,
        securityType: wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK
      };
      const netId = await wifiManager.addCandidateConfig(cfg);
      wifiManager.connectToCandidateConfig(netId); // sync; throws on denial
      const deadline = Date.now() + JOIN_TOTAL_MS;
      while (Date.now() < deadline) {
        await sleep(JOIN_POLL_MS);
        try {
          if (!wifiManager.isConnected()) {
            continue;
          }
          const linked = await wifiManager.getLinkedInfo();
          if (linked.ssid === ssid && MirrorAutoConnect.wifiIpString().length > 0) {
            return true;
          }
        } catch (e) {
          // retry until the deadline
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /**
   * After joining the hotspot, find the Android's LocalSend port. Candidates:
   * the peer-reported IP, the hotspot gateway from getIpInfo, and the classic
   * 192.168.x.1 guess derived from our own hotspot address. While waiting,
   * periodically re-ask via tailnet (the peer may answer again with its
   * post-hotspot IP) and sweep the current /24. Resolves '' on failure.
   */
  private static async confirmHotspotHost(info: MirrorPrepareInfo,
    tailnetIps: string[], virtualDisplay: boolean, vd: VdParams | null): Promise<string> {
    const deadline = Date.now() + CONFIRM_TOTAL_MS;
    let lastAsk = 0;
    let hintIp = info.ip;
    while (Date.now() < deadline) {
      const candidates: string[] = [];
      const push = (ip: string): void => {
        if (ip.length > 0 && !candidates.includes(ip)) {
          candidates.push(ip);
        }
      };
      push(MirrorAutoConnect.gatewayGuess());
      push(MirrorAutoConnect.wifiGatewayIp());
      push(hintIp);
      for (const c of candidates) {
        if (await MirrorAutoConnect.probeTcp(c, LOCALSEND_PORT, CONFIRM_PROBE_TIMEOUT_MS)) {
          return c;
        }
      }

      // periodic re-ask over tailnet (works when the peer kept a data path)
      if (Date.now() - lastAsk >= REASK_INTERVAL_MS) {
        lastAsk = Date.now();
        for (const ip of tailnetIps) {
          const again = await MirrorAutoConnect.askMirrorPrepare(ip, virtualDisplay, vd);
          if (again.ip.length > 0) {
            hintIp = again.ip;
            if (await MirrorAutoConnect.probeTcp(again.ip, LOCALSEND_PORT, TAILNET_PROBE_TIMEOUT_MS)) {
              return again.ip;
            }
          }
        }
      }

      // one /24 sweep round on the hotspot subnet
      const scanned = await MirrorAutoConnect.scanRound();
      if (scanned.length > 0) {
        return scanned;
      }
    }
    return '';
  }

  /** Current Wi-Fi IP as dotted string ('' when absent). */
  private static wifiIpString(): string {
    try {
      const info = wifiManager.getIpInfo();
      return u32ToIp(info.ipAddress >>> 0);
    } catch (e) {
      return '';
    }
  }

  /** Current Wi-Fi gateway as dotted string ('' when absent). */
  private static wifiGatewayIp(): string {
    try {
      const info = wifiManager.getIpInfo();
      return u32ToIp(info.gateway >>> 0);
    } catch (e) {
      return '';
    }
  }

  /** 192.168.x.1 guess from our own hotspot address. */
  private static gatewayGuess(): string {
    const self = MirrorAutoConnect.wifiIpString();
    const parts = self.split('.');
    if (parts.length !== 4) {
      return '';
    }
    return `${parts[0]}.${parts[1]}.${parts[2]}.1`;
  }

  /** Read one close-delimited HTTP reply, honoring an overall deadline. */
  private static async readHttpReply(layer: NetworkLayer, conn: number, timeoutMs: number): Promise<HttpReply> {
    let raw = new Uint8Array(0);
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const chunk = await MirrorAutoConnect.readChunk(layer, conn, deadline - Date.now());
      if (chunk.byteLength === 0) {
        break;
      }
      raw = appendBytes(raw, new Uint8Array(chunk));
      const headerEnd = findHeaderEnd(raw);
      if (headerEnd >= 0) {
        const contentLength = parseContentLength(raw, headerEnd);
        if (contentLength >= 0 && raw.length >= headerEnd + 4 + contentLength) {
          break;
        }
      }
    }
    const headerEnd = findHeaderEnd(raw);
    if (headerEnd < 0) {
      const fail: HttpReply = { status: 0, body: '' };
      return fail;
    }
    const headerText = utf8Decode(raw.subarray(0, headerEnd));
    const status = parseStatus(headerText);
    const ok: HttpReply = { status: status, body: utf8Decode(raw.subarray(headerEnd + 4)) };
    return ok;
  }

  private static readChunk(layer: NetworkLayer, conn: number, timeoutMs: number): Promise<ArrayBuffer> {
    return new Promise<ArrayBuffer>((resolve) => {
      let done = false;
      let timer = -1;
      const finish = (data: ArrayBuffer): void => {
        if (done) {
          return;
        }
        done = true;
        if (timer >= 0) {
          clearTimeout(timer);
        }
        resolve(data);
      };
      timer = setTimeout(() => {
        finish(new ArrayBuffer(0));
      }, Math.max(1, timeoutMs));
      layer.read(conn, 8192).then((r: ReadResult) => {
        finish(r.data);
      }).catch(() => {
        finish(new ArrayBuffer(0));
      });
    });
  }

  /** Plain TCP reachability probe on the system network stack. */
  private static probeTcp(host: string, port: number, timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let settled = false;
      let tcp: socket.TCPSocket | null = null;
      let timer = -1;
      const finish = (ok: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
        }
        if (tcp !== null) {
          try {
            tcp.close();
          } catch (e) {
            // already closed
          }
          tcp = null;
        }
        resolve(ok);
      };
      timer = setTimeout(() => {
        finish(false);
      }, timeoutMs);
      try {
        tcp = socket.constructTCPSocketInstance();
        const netAddr: socket.NetAddress = { address: host, port: port };
        const opts: socket.TCPConnectOptions = { address: netAddr, timeout: timeoutMs };
        tcp.connect(opts).then(() => {
          finish(true);
        }).catch(() => {
          finish(false);
        });
      } catch (e) {
        finish(false);
      }
    });
  }

  /** One /24 sweep round on the hotspot subnet ('' when nothing answered). */
  private static async scanRound(): Promise<string> {
    const selfIp = MirrorAutoConnect.wifiIpString();
    const parts = selfIp.split('.');
    if (parts.length !== 4) {
      return '';
    }
    const prefix = `${parts[0]}.${parts[1]}.${parts[2]}.`;
    let idx = 0;
    let found = '';
    const worker = async (): Promise<void> => {
      while (found.length === 0 && idx < 254) {
        const host = `${prefix}${idx + 1}`;
        idx = idx + 1;
        if (host === selfIp) {
          continue;
        }
        if (await MirrorAutoConnect.probeTcp(host, LOCALSEND_PORT, SCAN_PROBE_TIMEOUT_MS)) {
          found = host;
        }
      }
    };
    const runners: Promise<void>[] = [];
    for (let w = 0; w < SCAN_CONCURRENCY; w++) {
      runners.push(worker());
    }
    await Promise.all(runners);
    return found;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

/** HarmonyOS IpInfo integers are little-endian packed (0xC0A80164 → 192.168.1.100). */
function u32ToIp(v: number): string {
  if (v === 0) {
    return '';
  }
  const o1 = v & 0xFF;
  const o2 = (v >>> 8) & 0xFF;
  const o3 = (v >>> 16) & 0xFF;
  const o4 = (v >>> 24) & 0xFF;
  return `${o1}.${o2}.${o3}.${o4}`;
}

function utf8Encode(s: string): ArrayBuffer {
  return util.TextEncoder.create('utf-8').encodeInto(s).buffer as ArrayBuffer;
}

function utf8Decode(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

function appendBytes(dst: Uint8Array, src: Uint8Array): Uint8Array {
  const out = new Uint8Array(dst.length + src.length);
  out.set(dst, 0);
  out.set(src, dst.length);
  return out;
}

/** Find the '\r\n\r\n' header/body separator. Returns -1 when absent. */
function findHeaderEnd(bytes: Uint8Array): number {
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) {
      return i;
    }
  }
  return -1;
}

function parseStatus(headerText: string): number {
  const firstLineEnd = headerText.indexOf('\n');
  const line = firstLineEnd >= 0 ? headerText.substring(0, firstLineEnd) : headerText;
  const parts = line.split(' ');
  if (parts.length >= 2) {
    const code = parseInt(parts[1], 10);
    if (!isNaN(code)) {
      return code;
    }
  }
  return 0;
}

function parseContentLength(raw: Uint8Array, headerEnd: number): number {
  const headerText = utf8Decode(raw.subarray(0, headerEnd)).toLowerCase();
  const idx = headerText.indexOf('content-length:');
  if (idx < 0) {
    return -1;
  }
  const rest = headerText.substring(idx + 'content-length:'.length).trim();
  const lineEnd = rest.indexOf('\n');
  const line = lineEnd >= 0 ? rest.substring(0, lineEnd).trim() : rest;
  const value = parseInt(line, 10);
  return isNaN(value) ? -1 : value;
}
