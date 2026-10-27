// Remote control of a Mac from the phone — the receiving end of AnySend's
// “Mac 被控端” (RemoteHostController.swift).
//
// The Mac listens with the same scrcpy v2 wire protocol the Android mirror
// bridge uses, so this page reuses DirectStreamClient / the native H.264
// pipeline and only adds:
//   * endpoint discovery (manual IP + Tailscale peers, fixed ports
//     27042 video / 27043 control)
//   * an optional PIN prefix on both sockets (Mac side: RemoteHostController)
//   * phone-side input: a floating toolbar, and in laptop mode a trackpad +
//     virtual keyboard laid out for foldables (Pura X Max style: video on the
//     upper half, keyboard and trackpad on the lower half)

import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { Tokens } from '../common/DesignTokens';
import { AppNav } from '../common/AppNav';
import { NativeStreamListener } from '../scrcpy/client/tools/NativeStreamClient';
import { DirectStreamClient } from '../scrcpy/client/tools/DirectStreamClient';
import { ControlPacket, KeyCode, KeyAction, TouchAction } from '../scrcpy/client/tools/ControlPacket';
import { TailscaleManager, PeerInfo, ForwardPort } from '../bridge/TailscaleManager';
import { LanDiscovery, LanDevice } from '../common/LanDiscovery';

const MAC_VIDEO_PORT = 27042;
const MAC_CONTROL_PORT = 27043;
const VIDEO_FRAME_RATE = 30;
const SURFACE_ID_NAME = 'MacRemoteSurface';
const SURFACE_WAIT_MS = 3000;
const SURFACE_POLL_MS = 100;
const KEY_ROW_HEIGHT = 40;

interface NativeXComponentContext {
  registerNativeXComponent(): boolean;
}

type Phase = 'idle' | 'connecting' | 'mirroring' | 'error';

/** Meta-state bit sent along with a keycode (Android convention). */
const META_SHIFT = 0x01;
const META_ALT = 0x02;
const META_CTRL = 0x1000;
const META_CMD = 0x10000;

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * True for addresses that only exist inside the tailnet: IPv4 100.64.0.0/10
 * and Tailscale's IPv6 range fd7a:115c:a1e0::/48.
 *
 * tsnet runs in userspace without a kernel TUN device, so the native TCP stack
 * cannot open these directly; they must go through a loopback forward.
 */
function isTailnetAddress(host: string): boolean {
  if (host.startsWith('100.')) {
    const second = Number(host.split('.')[1]);
    return second >= 64 && second <= 127;
  }
  return host.toLowerCase().startsWith('fd7a:115c:a1e0:');
}

/** Android keycodes for the characters the on-screen keyboard emits. */
function androidKeycodeFor(char: string): number {
  const lower = char.toLowerCase();
  if (lower >= 'a' && lower <= 'z') {
    return 29 + (lower.charCodeAt(0) - 97);
  }
  if (char >= '0' && char <= '9') {
    return 7 + (char.charCodeAt(0) - 48);
  }
  switch (char) {
    case ' ': return 62;
    case '.': return 56;
    case ',': return 55;
    case '-': return 69;
    case '=': return 70;
    case '/': return 76;
    case ';': return 74;
    case "'": return 75;
    case '[': return 71;
    case ']': return 72;
    case '\\': return 73;
    case '`': return 68;
    default: return 0;
  }
}

@Component
export struct MacRemotePage {
  @State view: Phase = 'idle';
  @State statusText: string = '';
  @State note: string = '';
  @State errTitle: string = '';
  @State errMsg: string = '';
  @State peers: PeerInfo[] = [];
  // LocalSend multicast neighbours, listed first because they connect directly.
  // Tailscale peers are equally usable: their 100.x endpoint is bridged onto
  // 127.0.0.1 by the embedded Go tsnet forwarder.
  @State lanHosts: LanDevice[] = [];
  @State host: string = '';
  @State pin: string = '';
  @State videoAR: number = 16 / 10;
  @State laptopMode: boolean = false;
  @State halfFolded: boolean = false;
  @State symbols: boolean = false;
  @State shift: boolean = false;
  @State modCmd: boolean = false;
  @State modCtrl: boolean = false;
  @State modAlt: boolean = false;

  private context: common.UIAbilityContext | null = null;
  private surfaceId: string = '';
  private sessionSeq: number = 0;
  private client: DirectStreamClient | null = null;
  private xcController: XComponentController = new XComponentController();
  private videoW: number = 1920;
  private videoH: number = 1200;
  // Actual pixel size of the video rect, reported by the overlay that captures
  // touches. It differs from the phone screen because the surface is letter- or
  // pillar-boxed by the video aspect ratio.
  @State videoPxW: number = 0;
  @State videoPxH: number = 0;
  // Measured size of the area the picture may occupy, and the letterboxed size
  // derived from it. The XComponent is sized explicitly instead of with
  // aspectRatio+100%, because there the surface either overflows the container
  // (and gets clipped, cropping the picture) or is measured as 0x0 before the
  // parent has a height — which makes OH_VideoDecoder_SetSurface fail.
  @State boxPxW: number = 0;
  @State boxPxH: number = 0;
  @State fitPxW: number = 0;
  @State fitPxH: number = 0;
  // Picture zoom. ArkUI reports local touch coordinates in the untransformed
  // component space, so scaling and panning the surface never distorts the
  // mapping between a finger and the Mac pixel underneath it.
  @State zoom: number = 1;
  @State panVpX: number = 0;
  @State panVpY: number = 0;

  // trackpad state
  private cursorX: number = 0.5;
  private cursorY: number = 0.5;
  private padLastX: number = 0;
  private padLastY: number = 0;
  private padStartX: number = 0;
  private padStartY: number = 0;
  private padDownAt: number = 0;
  private padDragging: boolean = false;
  private padTouching: boolean = false;
  private padScrollAcc: number = 0;
  private padHoldTimer: number = -1;
  private padMoved: boolean = false;
  private foldListener: ((status: display.FoldStatus) => void) | null = null;
  private waitTimer: number = -1;
  /** Loopback forward handles opened for the current tailnet session. */
  private forwardHandles: number[] = [];

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    // Seed the letterboxed size from the display so the XComponent is never
    // 0x0 before the first layout pass: a zero-sized surface is never created,
    // which leaves the native decoder without a target to render into.
    try {
      const d = display.getDefaultDisplaySync();
      this.refit(d.width, d.height);
    } catch (e) {
      this.refit(1080, 675);
    }
    this.detectFold();
    this.watchFold();
    this.loadPeers();
  }

  aboutToDisappear(): void {
    this.stopSession();
    this.unwatchFold();
  }

  private detectFold(): void {
    try {
      // FoldStatus.HALF_FOLDED === 3
      this.halfFolded = (display.getFoldStatus() as number) === 3;
      this.laptopMode = this.halfFolded;
    } catch (e) {
      this.halfFolded = false;
    }
  }

  /** Folding / unfolding while the session runs switches the deck live. */
  private watchFold(): void {
    this.foldListener = (status: display.FoldStatus): void => {
      // FoldStatus.HALF_FOLDED === 3
      this.halfFolded = (status as number) === 3;
      this.laptopMode = this.halfFolded;
    };
    try {
      display.on('foldStatusChange', this.foldListener);
    } catch (e) {
      this.foldListener = null;
    }
  }

  private unwatchFold(): void {
    const listener = this.foldListener;
    if (listener === null) {
      return;
    }
    this.foldListener = null;
    try {
      display.off('foldStatusChange', listener);
    } catch (e) {
      // already gone
    }
  }

  private async loadPeers(): Promise<void> {
    try {
      await TailscaleManager.refreshStatus();
      const all: PeerInfo[] = TailscaleManager.getPeers();
      this.peers = all.filter((p: PeerInfo) => p.online && p.tailscaleIP.length > 0);
    } catch (e) {
      this.peers = [];
    }

    // LAN entries come first only as a convenience default; Tailscale peers work
    // too, just through the loopback forward set up in startRemote().
    try {
      const lan: LanDevice[] = await LanDiscovery.scan(1200);
      this.lanHosts = lan;
    } catch (e) {
      this.lanHosts = [];
    }

    if (this.host.length > 0) {
      return;
    }
    if (this.lanHosts.length > 0) {
      this.host = this.lanHosts[0].ip;
    } else if (this.peers.length > 0) {
      this.host = this.peers[0].tailscaleIP;
    }
  }

  // ---------- session ----------

  private refit(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    this.boxPxW = w;
    this.boxPxH = h;
    const ar = this.videoAR > 0 ? this.videoAR : 16 / 10;
    let fw = w;
    let fh = w / ar;
    if (fh > h) {
      fh = h;
      fw = h * ar;
    }
    this.fitPxW = Math.max(1, Math.floor(fw));
    this.fitPxH = Math.max(1, Math.floor(fh));
    this.videoPxW = this.fitPxW;
    this.videoPxH = this.fitPxH;
    this.clampPan();
  }

  private setZoom(next: number): void {
    const z = Math.max(1, Math.min(4, next));
    this.zoom = z;
    if (z <= 1) {
      this.panVpX = 0;
      this.panVpY = 0;
    }
    this.clampPan();
  }

  /** Keep the picture edge glued to the container edge while zoomed in. */
  private clampPan(): void {
    const maxX = (this.zoom - 1) / 2 * px2vp(this.fitPxW);
    const maxY = (this.zoom - 1) / 2 * px2vp(this.fitPxH);
    this.panVpX = Math.max(-maxX, Math.min(maxX, this.panVpX));
    this.panVpY = Math.max(-maxY, Math.min(maxY, this.panVpY));
  }

  private async startRemote(): Promise<void> {
    if (this.view === 'connecting') {
      return;
    }
    const host = this.host.trim();
    if (host.length === 0) {
      this.errTitle = '请选择 Mac 设备';
      this.errMsg = '输入 Mac 的 Tailscale IP 或局域网 IP，或在列表中选择在线设备。';
      this.view = 'error';
      return;
    }
    this.stopSession();
    const seq = ++this.sessionSeq;
    this.errTitle = '';
    this.errMsg = '';
    this.note = '';
    this.statusText = '正在连接 Mac…';
    this.view = 'connecting';

    let waited = 0;
    while ((this.surfaceId.length === 0 || this.fitPxW <= 0 || this.fitPxH <= 0) && waited < SURFACE_WAIT_MS) {
      await sleepMs(SURFACE_POLL_MS);
      waited += SURFACE_POLL_MS;
    }
    if (seq !== this.sessionSeq) {
      return;
    }
    if (this.surfaceId.length === 0 || this.fitPxW <= 0 || this.fitPxH <= 0) {
      this.failWith(seq, '画面组件未就绪', '页面渲染组件未能创建渲染表面，请返回后重试。');
      return;
    }

    const client = new DirectStreamClient(this.buildListener(seq));
    this.client = client;

    // Tailnet addresses live in tsnet's userspace netstack, so the native TCP
    // stack cannot open them. Forward both ports onto 127.0.0.1 and let the
    // native channels connect there instead.
    let targetHost = host;
    let videoPort = MAC_VIDEO_PORT;
    let controlPort = MAC_CONTROL_PORT;
    if (isTailnetAddress(host)) {
      // AutoConnect logs in on app start and can still be finishing here, so
      // waiting briefly is normal rather than an error.
      console.info(`[MacRemote] tailnet target ${host}, started=${TailscaleManager.isStarted()}`);
      for (let i = 0; i < 40 && !TailscaleManager.isStarted(); i++) {
        this.statusText = '正在连接 Tailscale…';
        await sleepMs(300);
        if (seq !== this.sessionSeq) {
          return;
        }
      }
      if (!TailscaleManager.isStarted()) {
        const why = TailscaleManager.lastErr;
        console.info(`[MacRemote] tailnet not started, lastErr=${why}`);
        this.failWith(seq, 'Tailscale 未连接',
          why.length > 0
            ? `内嵌 Tailscale 未能启动：${why}`
            : '请先在 AnySend 设置页登录 Tailscale（需要 tskey-auth- 开头的密钥），再使用 100.x 地址。');
        return;
      }
      this.statusText = '正在通过 Tailscale 建立通道…';
      const videoTarget = `${host}:${MAC_VIDEO_PORT}`;
      const controlTarget = `${host}:${MAC_CONTROL_PORT}`;
      const fwds = await this.openForwards(videoTarget, controlTarget);
      if (seq !== this.sessionSeq) {
        this.closeForwards(fwds[0], fwds[1]);
        return;
      }
      const fwdVideo = fwds[0];
      const fwdControl = fwds[1];
      if (fwdVideo === null || fwdControl === null) {
        this.closeForwards(fwdVideo, fwdControl);
        this.failWith(seq, 'Tailscale 通道建立失败',
          `无法通过 Tailscale 连到 ${host}，请确认该地址是 Mac 的 tailnet IP 且 Mac 上的 AnySend 正在运行。`);
        return;
      }
      this.forwardHandles.push(fwdVideo.handle, fwdControl.handle);
      targetHost = '127.0.0.1';
      videoPort = fwdVideo.port;
      controlPort = fwdControl.port;
    }

    try {
      await client.start(targetHost, videoPort, controlPort, this.surfaceId,
        VIDEO_FRAME_RATE, '', this.pin, false);
      if (seq !== this.sessionSeq) {
        return;
      }
      this.statusText = '等待画面…';
      // A wrong/blank PIN makes the Mac wait for its prefix instead of sending
      // the handshake, so surface a timeout instead of hanging on "connecting".
      this.waitTimer = setTimeout(() => {
        this.waitTimer = -1;
        if (seq === this.sessionSeq && this.view === 'connecting') {
          this.failWith(seq, '连接超时',
            '请确认 Mac 已开启“远程控制（被控端）”，并检查 PIN 是否正确。');
        }
      }, 12000);
    } catch (err) {
      if (seq !== this.sessionSeq) {
        return;
      }
      const msg = err instanceof Error ? err.message : String(err);
      this.failWith(seq, '连接失败', msg);
    }
  }

  private buildListener(seq: number): NativeStreamListener {
    const listener: NativeStreamListener = {
      onVideoConfig: (width: number, height: number): void => {
        if (seq !== this.sessionSeq) {
          return;
        }
        if (width > 0 && height > 0) {
          this.videoW = width;
          this.videoH = height;
          this.videoAR = width / height;
          // The real aspect ratio only arrives with the handshake, so the
          // letterboxed surface is re-measured once it is known.
          this.refit(this.boxPxW, this.boxPxH);
        }
      },
      onFirstFrame: (): void => {
        if (seq !== this.sessionSeq) {
          return;
        }
        this.clearWaitTimer();
        this.view = 'mirroring';
        this.statusText = '';
      },
      onClipboard: (_text: string): void => {},
      onDisconnect: (reason: string): void => {
        if (seq !== this.sessionSeq) {
          return;
        }
        const msg = reason.length > 0 ? reason : 'Mac 结束了远控会话。';
        this.failWith(seq, '远控已断开', msg);
      },
      onError: (error: string): void => {
        if (seq !== this.sessionSeq) {
          return;
        }
        this.failWith(seq, '远控出错', error);
      }
    };
    return listener;
  }

  /**
   * Open both loopback forwards, retrying a few times.
   *
   * The Go side refuses to bind while tsnet is still settling right after a
   * login, so a single failed attempt does not mean the target is unreachable.
   */
  private async openForwards(videoTarget: string,
    controlTarget: string): Promise<(ForwardPort | null)[]> {
    let video: ForwardPort | null = null;
    let control: ForwardPort | null = null;
    for (let attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) {
        await sleepMs(400);
      }
      if (video === null) {
        video = await TailscaleManager.forwardTcp(0, videoTarget);
      }
      if (control === null) {
        control = await TailscaleManager.forwardTcp(0, controlTarget);
      }
      if (video !== null && control !== null) {
        break;
      }
    }
    console.info(`[MacRemote] forward video=${video === null ? 'fail' : video.port} ` +
      `control=${control === null ? 'fail' : control.port}`);
    return [video, control];
  }

  private stopSession(): void {
    this.sessionSeq += 1;
    this.clearWaitTimer();
    this.closeForwards(null, null);
    const c = this.client;
    this.client = null;
    if (c !== null) {
      c.stop();
    }
  }

  /** Stop the loopback forwards opened for a tailnet session. */
  private closeForwards(video: ForwardPort | null, control: ForwardPort | null): void {
    if (video !== null) {
      this.forwardHandles.push(video.handle);
    }
    if (control !== null) {
      this.forwardHandles.push(control.handle);
    }
    for (const handle of this.forwardHandles) {
      TailscaleManager.closeForward(handle);
    }
    this.forwardHandles = [];
  }

  private clearWaitTimer(): void {
    if (this.waitTimer !== -1) {
      clearTimeout(this.waitTimer);
      this.waitTimer = -1;
    }
  }

  private failWith(seq: number, title: string, msg: string): void {
    if (seq !== this.sessionSeq) {
      return;
    }
    this.errTitle = title;
    this.errMsg = msg;
    this.view = 'error';
    this.stopSession();
  }

  private leavePage(): void {
    this.stopSession();
    AppNav.stack.pop();
  }

  private reopen(): void {
    this.surfaceId = '';
    this.stopSession();
    this.view = 'idle';
  }

  // ---------- input helpers ----------

  private send(packet: ArrayBuffer): void {
    const c = this.client;
    if (c === null) {
      console.info('[MacRemote] send skipped: no client');
      return;
    }
    if (!c.sendControlPacket(packet)) {
      console.info('[MacRemote] send rejected: native control not ready');
    }
  }

  private sendKeyPair(code: number): void {
    for (const packet of ControlPacket.createKeyEventPair(code, this.metaState())) {
      this.send(packet);
    }
  }

  private metaState(): number {
    let meta = 0;
    if (this.shift) {
      meta |= META_SHIFT;
    }
    if (this.modCmd) {
      meta |= META_CMD;
    }
    if (this.modCtrl) {
      meta |= META_CTRL;
    }
    if (this.modAlt) {
      meta |= META_ALT;
    }
    return meta;
  }

  private clearModifiers(): void {
    this.modCmd = false;
    this.modCtrl = false;
    this.modAlt = false;
    this.shift = false;
  }

  /** Tap on a character key. */
  private typeChar(raw: string): void {
    const hasCommandModifier = this.modCmd || this.modCtrl || this.modAlt;
    if (!hasCommandModifier) {
      // Plain typing (with or without shift) goes out as text — macOS turns
      // the uppercase character into the right key combination itself.
      this.send(ControlPacket.createInjectText(this.shift ? raw.toUpperCase() : raw));
      this.shift = false;
      return;
    }
    const code = androidKeycodeFor(raw);
    if (code === 0) {
      this.send(ControlPacket.createInjectText(raw));
      this.clearModifiers();
      return;
    }
    this.sendKeyPair(code);
    this.clearModifiers();
  }

  // ---------- direct touch on the video ----------
  //
  // Without this the picture is receive-only: taps must map straight onto the
  // Mac screen coordinates, one finger drags the pointer, and two fingers
  // scroll. This is the only way to drive the Mac while the phone is unfolded
  // and the laptop deck is hidden.

  private tapDownAt: number = 0;
  private tapStartX: number = 0;
  private tapStartY: number = 0;
  private tapMoved: boolean = false;
  private tapActive: boolean = false;

  /** Map a touch inside the video rect to Mac screen coordinates. */
  private videoPoint(x: number, y: number): number[] {
    // TouchEvent coordinates are local vp, the picture rect is in physical px.
    // Mixing the two put every tap at the bottom-right corner of the Mac.
    const w = this.videoPxW > 0 ? px2vp(this.videoPxW) : 1;
    const h = this.videoPxH > 0 ? px2vp(this.videoPxH) : 1;
    const nx = Math.max(0, Math.min(1, x / w));
    const ny = Math.max(0, Math.min(1, y / h));
    return [Math.round(nx * this.videoW), Math.round(ny * this.videoH), nx, ny];
  }

  private tapDown(x: number, y: number): void {
    this.tapActive = true;
    this.tapMoved = false;
    this.tapDownAt = Date.now();
    this.tapStartX = x;
    this.tapStartY = y;
    const p = this.videoPoint(x, y);
    this.cursorX = p[2];
    this.cursorY = p[3];
    // Hover first so the Mac shows the pointer before the click lands.
    this.send(this.padPoint(this.cursorX, this.cursorY));
  }

  private tapMove(x: number, y: number): void {
    if (!this.tapActive) {
      return;
    }
    const wasMoved = this.tapMoved;
    if (Math.abs(x - this.tapStartX) + Math.abs(y - this.tapStartY) > 12) {
      this.tapMoved = true;
    }
    const p = this.videoPoint(x, y);
    this.cursorX = p[2];
    this.cursorY = p[3];
    if (this.tapMoved && !wasMoved) {
      // Crossing the drag threshold presses the button first, otherwise the Mac
      // receives dragged events with no preceding mouse-down.
      this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_DOWN, 0n, p[0], p[1],
        this.videoW, this.videoH, 1.0));
    }
    this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_MOVE, 0n, p[0], p[1],
      this.videoW, this.videoH, this.tapMoved ? 1.0 : 0.0));
  }

  private tapUp(): void {
    if (!this.tapActive) {
      return;
    }
    this.tapActive = false;
    const px = Math.round(this.cursorX * this.videoW);
    const py = Math.round(this.cursorY * this.videoH);
    if (this.tapMoved) {
      // Drag: the button was pressed while moving, so release it here.
      this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_UP, 0n, px, py,
        this.videoW, this.videoH, 0.0));
      return;
    }
    if (Date.now() - this.tapDownAt < 600) {
      // Short, still touch = left click at the touched point.
      this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_DOWN, 0n, px, py,
        this.videoW, this.videoH, 1.0));
      this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_UP, 0n, px, py,
        this.videoW, this.videoH, 0.0));
    } else {
      // Long press without movement = right click.
      this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_DOWN, 0n, px, py,
        this.videoW, this.videoH, 1.0, 2));
      this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_UP, 0n, px, py,
        this.videoW, this.videoH, 0.0, 2));
    }
  }

  private tapTwoFinger(x: number, y: number): void {
    if (this.tapTwoX < 0) {
      this.tapTwoX = x;
      this.tapTwoY = y;
      return;
    }
    if (this.zoom > 1) {
      // Zoomed in: two fingers drag the picture around instead of scrolling.
      this.panVpX += x - this.tapTwoX;
      this.panVpY += y - this.tapTwoY;
      this.clampPan();
    } else {
      this.padScroll(y - this.tapTwoY);
    }
    this.tapTwoX = x;
    this.tapTwoY = y;
  }

  private tapTwoX: number = -1;
  private tapTwoY: number = -1;

  /** A second finger arrived: drop the pending click without emitting one. */
  private tapCancel(): void {
    this.tapTwoX = -1;
    this.tapTwoY = -1;
    if (!this.tapActive) {
      return;
    }
    this.tapActive = false;
    if (this.tapMoved) {
      const px = Math.round(this.cursorX * this.videoW);
      const py = Math.round(this.cursorY * this.videoH);
      this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_UP, 0n, px, py,
        this.videoW, this.videoH, 0.0));
    }
    this.tapMoved = false;
  }

  private onVideoTouch(event: TouchEvent): void {
    const touches = event.touches;
    console.info(`[MacRemote] touch type=${event.type} n=${touches.length} x=${touches.length > 0 ? touches[0].x : -1} y=${touches.length > 0 ? touches[0].y : -1} px=${this.videoPxW}x${this.videoPxH}`);
    if (event.type === TouchType.Down) {
      if (touches.length >= 2) {
        this.tapCancel();
        this.tapTwoX = (touches[0].x + touches[1].x) / 2;
        this.tapTwoY = (touches[0].y + touches[1].y) / 2;
        return;
      }
      const t = touches[0];
      if (t === undefined) {
        return;
      }
      this.tapDown(t.x, t.y);
      return;
    }
    if (event.type === TouchType.Move) {
      if (touches.length >= 2) {
        const cx = (touches[0].x + touches[1].x) / 2;
        const cy = (touches[0].y + touches[1].y) / 2;
        if (this.tapActive) {
          this.tapCancel();
        }
        this.tapTwoFinger(cx, cy);
        return;
      }
      const t = touches[0];
      if (t === undefined) {
        return;
      }
      this.tapMove(t.x, t.y);
      return;
    }
    // Lift off: tapUp decides between click, drag release and right click.
    this.tapUp();
  }

  // ---------- trackpad ----------

  private padPoint(nx: number, ny: number): ArrayBuffer {
    const x = Math.round(Math.max(0, Math.min(1, nx)) * this.videoW);
    const y = Math.round(Math.max(0, Math.min(1, ny)) * this.videoH);
    return ControlPacket.createInjectTouchEvent(TouchAction.ACTION_MOVE, 0n, x, y,
      this.videoW, this.videoH, 0.0);
  }

  private padClick(): void {
    const x = Math.round(Math.max(0, Math.min(1, this.cursorX)) * this.videoW);
    const y = Math.round(Math.max(0, Math.min(1, this.cursorY)) * this.videoH);
    this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_DOWN, 0n, x, y,
      this.videoW, this.videoH, 1.0));
    this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_UP, 0n, x, y,
      this.videoW, this.videoH, 0.0));
  }

  private padDown(x: number, y: number): void {
    this.padTouching = true;
    this.padMoved = false;
    this.padDragging = false;
    this.padLastX = x;
    this.padLastY = y;
    this.padStartX = x;
    this.padStartY = y;
    this.padDownAt = Date.now();
    this.padHoldTimer = setTimeout(() => {
      // Holding still arms drag: press the button where the cursor is.
      if (this.padTouching && !this.padMoved && !this.padDragging) {
        const px = Math.round(Math.max(0, Math.min(1, this.cursorX)) * this.videoW);
        const py = Math.round(Math.max(0, Math.min(1, this.cursorY)) * this.videoH);
        this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_DOWN, 0n, px, py,
          this.videoW, this.videoH, 1.0));
        this.padDragging = true;
      }
    }, 420);
  }

  private padMove(x: number, y: number, padW: number, padH: number): void {
    if (!this.padTouching || padW <= 0 || padH <= 0) {
      return;
    }
    const dx = (x - this.padLastX) / padW;
    const dy = (y - this.padLastY) / padH;
    this.padLastX = x;
    this.padLastY = y;
    if (Math.abs(x - this.padStartX) + Math.abs(y - this.padStartY) > 8) {
      this.padMoved = true;
    }
    this.cursorX = Math.max(0, Math.min(1, this.cursorX + dx * 1.6));
    this.cursorY = Math.max(0, Math.min(1, this.cursorY + dy * 1.6));
    if (this.padDragging) {
      const px = Math.round(this.cursorX * this.videoW);
      const py = Math.round(this.cursorY * this.videoH);
      this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_MOVE, 0n, px, py,
        this.videoW, this.videoH, 1.0));
    } else {
      this.send(this.padPoint(this.cursorX, this.cursorY));
    }
  }

  private padUp(): void {
    if (this.padHoldTimer !== -1) {
      clearTimeout(this.padHoldTimer);
      this.padHoldTimer = -1;
    }
    if (!this.padTouching) {
      return;
    }
    this.padTouching = false;
    if (this.padDragging) {
      const px = Math.round(this.cursorX * this.videoW);
      const py = Math.round(this.cursorY * this.videoH);
      this.send(ControlPacket.createInjectTouchEvent(TouchAction.ACTION_UP, 0n, px, py,
        this.videoW, this.videoH, 0.0));
      this.padDragging = false;
    } else if (!this.padMoved && Date.now() - this.padDownAt < 400) {
      this.padClick();
    }
  }

  private padScroll(dy: number): void {
    this.padScrollAcc += dy;
    if (Math.abs(this.padScrollAcc) < 6) {
      return;
    }
    // Mac host 的滚动值按像素增量解析（第 8 个参数 rawPixels）。
    // 手指上滑（dy<0）→ 正增量 = 内容向下滚动，与自然滚动一致。
    const vertical = Math.max(-160, Math.min(160, -this.padScrollAcc * 2));
    this.padScrollAcc = 0;
    const px = Math.round(this.cursorX * this.videoW);
    const py = Math.round(this.cursorY * this.videoH);
    this.send(ControlPacket.createInjectScrollEvent(px, py, this.videoW, this.videoH, 0, vertical, 0, true));
  }

  // ---------- build ----------

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // The surface must exist while still connecting: the native starter
        // needs a surface id before it opens the sockets, and this page polls
        // for it at the very start of the session.
        if (this.view !== 'idle') {
          this.videoLayer()
        }
        if (this.view === 'idle') {
          this.idleView()
        }
        if (this.view === 'connecting') {
          this.connectingView()
        }
        if (this.view === 'error') {
          this.errorView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_bg'))
  }

  // ---------- idle ----------

  @Builder
  navBar() {
    Row({ space: 8 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('sys.color.icon_primary')])
      }
      .width(Tokens.TARGET_MIN)
      .height(Tokens.TARGET_MIN)
      .borderRadius(Tokens.TARGET_MIN / 2)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.leavePage();
      })

      Text('远程控制电脑')
        .fontSize(Tokens.FONT_H2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: Tokens.SPACE_LG, top: 12, bottom: 12 })
  }

  @Builder
  idleView() {
    Column() {
      this.navBar()
      Scroll() {
        Column({ space: Tokens.SPACE_MD }) {
          Column({ space: Tokens.SPACE_SM }) {
            SymbolGlyph($r('sys.symbol.superdevice'))
              .fontSize(40)
              .fontColor([$r('sys.color.brand')])
            Text('把 Mac 装进这台手机')
              .fontSize(Tokens.FONT_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text(this.halfFolded
              ? '半折叠状态下自动进入笔记本模式：上半屏看画面，下半屏当键盘和触控板'
              : '连接后在 Mac 端设置页开启「远程控制（被控端）」即可'
            )
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ top: Tokens.SPACE_LG, bottom: Tokens.SPACE_LG })

          // ---- device picker
          Column({ space: Tokens.SPACE_SM }) {
            Row() {
              Text('目标 Mac')
                .fontSize(Tokens.FONT_BODY)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
              Blank()
              Text('刷新')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.brand'))
                .onClick(() => {
                  this.loadPeers();
                })
            }
            .width('100%')

            TextInput({ text: this.host, placeholder: 'Tailscale IP 或局域网 IP' })
              .onChange((value: string) => {
                this.host = value;
              })
              .height(Tokens.TARGET_MIN)
              .fontSize(Tokens.FONT_BODY)

            if (this.lanHosts.length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.lanHosts, (d: LanDevice) => {
                  Text(`${d.name} · ${d.ip}`)
                    .fontSize(Tokens.FONT_CAPTION)
                    .fontColor(this.host === d.ip
                      ? Color.White : $r('sys.color.font_secondary'))
                    .backgroundColor(this.host === d.ip
                      ? $r('sys.color.brand') : $r('app.color.card'))
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .borderRadius(Tokens.RADIUS_PILL)
                    .margin({ right: 6, bottom: 6 })
                    .onClick(() => {
                      this.host = d.ip;
                    })
                }, (d: LanDevice) => d.ip)
              }
              .width('100%')
            }
            if (this.peers.length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.peers, (p: PeerInfo) => {
                  Text(`Tailscale · ${p.hostName} · ${p.tailscaleIP}`)
                    .fontSize(Tokens.FONT_CAPTION)
                    .fontColor(this.host === p.tailscaleIP
                      ? Color.White : $r('sys.color.font_secondary'))
                    .backgroundColor(this.host === p.tailscaleIP
                      ? $r('sys.color.brand') : $r('app.color.card'))
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .borderRadius(Tokens.RADIUS_PILL)
                    .margin({ right: 6, bottom: 6 })
                    .onClick(() => {
                      this.host = p.tailscaleIP;
                    })
                }, (p: PeerInfo) => p.tailscaleIP)
              }
              .width('100%')
            }
            if (this.lanHosts.length === 0 && this.peers.length === 0) {
              Text('暂未发现在线设备，可直接输入 Mac 的局域网 IP')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_tertiary'))
                .width('100%')
            }
            Text('同一 Wi-Fi 直连延迟最低；不在同一网络时用 Tailscale 的 100.x 地址，会自动经内嵌 Tailscale 走加密通道')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_tertiary'))
              .width('100%')
          }
          .width('100%')
          .padding(Tokens.SPACE_LG)
          .borderRadius(Tokens.RADIUS_CARD)
          .backgroundColor($r('app.color.card'))

          // ---- PIN + mode
          Column({ space: Tokens.SPACE_SM }) {
            Row() {
              Text('访问 PIN')
                .fontSize(Tokens.FONT_BODY)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
              Blank()
              Text('可留空')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_tertiary'))
            }
            .width('100%')

            TextInput({ text: this.pin, placeholder: '与 Mac 设置页中的 PIN 一致' })
              .type(InputType.Password)
              .onChange((value: string) => {
                this.pin = value;
              })
              .height(Tokens.TARGET_MIN)
              .fontSize(Tokens.FONT_BODY)

            Row() {
              Text('笔记本模式')
                .fontSize(Tokens.FONT_BODY)
                .fontColor($r('sys.color.font_primary'))
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.laptopMode })
                .onChange((on: boolean) => {
                  this.laptopMode = on;
                })
            }
            .width('100%')

            Text('笔记本模式：上半屏显示画面，下半屏为触控板与虚拟键盘，适合半折叠的折叠屏。')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_tertiary'))
              .width('100%')
          }
          .width('100%')
          .padding(Tokens.SPACE_LG)
          .borderRadius(Tokens.RADIUS_CARD)
          .backgroundColor($r('app.color.card'))

          Button('开始远控')
            .width('100%')
            .height(Tokens.TARGET_STD)
            .borderRadius(Tokens.RADIUS_CTRL)
            .fontSize(Tokens.FONT_TITLE)
            .backgroundColor($r('sys.color.brand'))
            .onClick(() => {
              this.startRemote();
            })
        }
        .width('100%')
        .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, bottom: Tokens.SPACE_XL })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  // ---------- session ----------

  /**
   * Video layer, mounted for every non-idle state.
   *
   * The XComponent is deliberately the first child of a Stack that never gets
   * torn down when the fold state changes: remounting it would hand the native
   * renderer a stale surface id and the picture would stay black. The deck is
   * therefore only appended below (or omitted) instead of moving the surface.
   */
  @Builder
  videoLayer() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        this.videoSurface()
        this.touchOverlay()
        this.videoOverlay()
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(Color.Black)
      .clip(true)
      .onAreaChange((_old: Area, now: Area) => {
        // Area reports vp while refit() computes in physical pixels, which is
        // also what the native decoder and the touch mapping use. Handing vp
        // straight to refit() made the picture a third of its intended size.
        this.refit(vp2px(Number(now.width)), vp2px(Number(now.height)));
      })

      if (this.laptopMode) {
        this.laptopDeck()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }

  @Builder
  connectingView() {
    Column({ space: Tokens.SPACE_SM }) {
      LoadingProgress()
        .width(40)
        .height(40)
        .color($r('sys.color.brand'))
      Text(this.statusText.length > 0 ? this.statusText : '正在连接…')
        .fontSize(Tokens.FONT_BODY)
        .fontColor($r('sys.color.font_secondary'))
      Text('连接 Mac 的 27042 / 27043 端口')
        .fontSize(Tokens.FONT_CAPTION)
        .fontColor($r('sys.color.font_tertiary'))
      Button('取消')
        .margin({ top: Tokens.SPACE_SM })
        .backgroundColor($r('app.color.card'))
        .fontColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.reopen();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.55)')
  }

  @Builder
  videoOverlay() {
    Row() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(16)
          .fontColor([Color.White])
      }
      .width(32)
      .height(32)
      .borderRadius(16)
      .backgroundColor('rgba(0,0,0,0.35)')
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.leavePage();
      })
      Blank()
      this.overlayButton('−', () => {
        this.setZoom(this.zoom - 0.5);
      })
      Text(`${Math.round(this.zoom * 100)}%`)
        .fontSize(Tokens.FONT_CAPTION)
        .fontColor(Color.White)
        .width(46)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.setZoom(1);
        })
      this.overlayButton('＋', () => {
        this.setZoom(this.zoom + 0.5);
      })
      this.overlayButton('适应', () => {
        this.setZoom(1);
      })
      if (!this.laptopMode) {
        this.overlayButton('键盘', () => {
          this.laptopMode = true;
        })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12 })
    .position({ x: 0, y: 0 })
  }

  @Builder
  overlayButton(label: string, action: () => void) {
    Text(label)
      .fontSize(Tokens.FONT_CAPTION)
      .fontColor(Color.White)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(Tokens.RADIUS_PILL)
      .backgroundColor('rgba(0,0,0,0.35)')
      .onClick(action)
  }

  @Builder
  videoSurface() {
    XComponent({
      id: SURFACE_ID_NAME,
      type: XComponentType.SURFACE,
      controller: this.xcController,
      libraryname: 'scrcpy_native'
    })
      .onLoad((nativeContext: object) => {
        (nativeContext as NativeXComponentContext).registerNativeXComponent();
        this.surfaceId = this.xcController.getXComponentSurfaceId();
      })
      .width(px2vp(this.fitPxW))
      .height(px2vp(this.fitPxH))
      .backgroundColor(Color.Black)
      .scale({ x: this.zoom, y: this.zoom })
      .translate({ x: this.panVpX, y: this.panVpY })
  }

  /**
   * Touch target for the picture.
   *
   * The XComponent registers a native DispatchTouchEvent callback, and while
   * that is bound ArkUI routes touches to the native handler without ever
   * calling the ArkTS onTouch of the same node — hence “the picture cannot be
   * clicked”. A sibling on top of the surface receives the touches instead;
   * it has to be sized in the same px/vp space as the surface and block hit
   * testing, otherwise ArkUI skips it.
   */
  @Builder
  touchOverlay() {
    Column()
      .width(px2vp(this.fitPxW))
      .height(px2vp(this.fitPxH))
      .backgroundColor(Color.Transparent)
      .hitTestBehavior(HitTestMode.Block)
      .onTouch((event: TouchEvent) => this.onVideoTouch(event))
      .scale({ x: this.zoom, y: this.zoom })
      .translate({ x: this.panVpX, y: this.panVpY })
  }

  // ---------- laptop deck ----------

  @Builder
  laptopDeck() {
    Column({ space: Tokens.SPACE_SM }) {
      // ---- trackpad
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(Tokens.RADIUS_CARD)
          .backgroundColor($r('app.color.card'))

        // cursor indicator follows the virtual cursor
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor($r('sys.color.brand'))
          .position({
            x: this.cursorX * this.padPxW - 4,
            y: this.cursorY * this.padPxH - 4
          })
      }
      .width('100%')
      .height(96)
      .onAreaChange((_old: Area, now: Area) => {
        this.padPxW = Number(now.width);
        this.padPxH = Number(now.height);
      })
      .onTouch((event: TouchEvent) => {
        if (event.touches.length === 0) {
          this.padUp();
          return;
        }
        if (event.touches.length >= 2) {
          // two-finger: scroll with the average vertical delta
          const avgY = (event.touches[0].y + event.touches[1].y) / 2;
          if (event.type === TouchType.Move) {
            this.padScroll(avgY - this.padLastY);
          }
          this.padLastY = avgY;
          return;
        }
        const t = event.touches[0];
        if (event.type === TouchType.Down) {
          this.padDown(t.x, t.y);
        } else if (event.type === TouchType.Move) {
          this.padMove(t.x, t.y, this.padPxW, this.padPxH);
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.padUp();
        }
      })

      // ---- keyboard
      this.keyboard()
    }
    .width('100%')
    // Tall enough for all five key rows: a shorter deck silently clips the
    // lower rows, which looked like the keyboard only had the digit row.
    .height(96 + Tokens.SPACE_SM + KEY_ROW_HEIGHT * 5 + 16 + 24)
    .padding({ left: Tokens.SPACE_SM, right: Tokens.SPACE_SM, top: Tokens.SPACE_SM, bottom: Tokens.SPACE_SM })
    .backgroundColor($r('app.color.page_bg'))
  }

  @State padPxW: number = 360;
  @State padPxH: number = 96;

  @Builder
  keyboard() {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        ForEach(this.rowKeys('1234567890'), (k: string) => {
          this.keyCap(k, () => this.typeChar(k), 1)
        }, (k: string) => k)
      }
      .width('100%')
      .height(KEY_ROW_HEIGHT)

      Row({ space: 4 }) {
        ForEach(this.rowKeys(this.symbols ? '@#¥&*()' : 'qwertyuiop'), (k: string) => {
          this.keyCap(k, () => this.typeChar(k), 1)
        }, (k: string) => k)
      }
      .width('100%')
      .height(KEY_ROW_HEIGHT)

      Row({ space: 4 }) {
        ForEach(this.rowKeys(this.symbols ? '~-_=+[]{}' : 'asdfghjkl'), (k: string) => {
          this.keyCap(k, () => this.typeChar(k), 1)
        }, (k: string) => k)
      }
      .width('100%')
      .height(KEY_ROW_HEIGHT)

      Row({ space: 4 }) {
        this.fnKey(this.shift ? '⇧' : '⇧', this.shift, () => {
          this.shift = !this.shift;
        })
        ForEach(this.rowKeys(this.symbols ? ':,.;/?!' : 'zxcvbnm,.'), (k: string) => {
          this.keyCap(k, () => this.typeChar(this.shift && !this.symbols ? k.toUpperCase() : k), 1)
        }, (k: string) => k)
        this.fnKey('⌫', false, () => {
          this.sendKeyPair(KeyCode.KEYCODE_DEL);
        })
      }
      .width('100%')
      .height(KEY_ROW_HEIGHT)

      Row({ space: 4 }) {
        this.fnKey('⌘', this.modCmd, () => {
          this.modCmd = !this.modCmd;
        })
        this.fnKey('⌃', this.modCtrl, () => {
          this.modCtrl = !this.modCtrl;
        })
        this.fnKey('⌥', this.modAlt, () => {
          this.modAlt = !this.modAlt;
        })
        this.keyCap('空格', () => this.typeChar(' '), 4)
        this.fnKey('↵', false, () => {
          this.sendKeyPair(KeyCode.KEYCODE_ENTER);
        })
        this.fnKey('esc', false, () => {
          const packet = ControlPacket.createInjectKeycode(KeyAction.ACTION_DOWN, 111, 0, 0);
          this.send(packet);
          const up = ControlPacket.createInjectKeycode(KeyAction.ACTION_UP, 111, 0, 0);
          this.send(up);
        })
        this.fnKey(this.symbols ? 'ABC' : '?123', this.symbols, () => {
          this.symbols = !this.symbols;
        })
      }
      .width('100%')
      .height(KEY_ROW_HEIGHT)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.SpaceBetween)
  }

  private rowKeys(chars: string): string[] {
    const out: string[] = [];
    for (let i = 0; i < chars.length; i++) {
      out.push(chars.charAt(i));
    }
    return out;
  }

  @Builder
  keyCap(label: string, action: () => void, weight: number) {
    Text(label)
      .fontSize(Tokens.FONT_BODY)
      .fontColor($r('sys.color.font_primary'))
      .textAlign(TextAlign.Center)
      .height('100%')
      .layoutWeight(weight)
      .borderRadius(6)
      .backgroundColor($r('app.color.card'))
      .onClick(action)
  }

  @Builder
  fnKey(label: string, active: boolean, action: () => void) {
    Text(label)
      .fontSize(Tokens.FONT_CAPTION)
      .fontColor(active ? Color.White : $r('sys.color.font_secondary'))
      .textAlign(TextAlign.Center)
      .height('100%')
      .layoutWeight(1)
      .borderRadius(6)
      .backgroundColor(active ? $r('sys.color.brand') : $r('app.color.card'))
      .onClick(action)
  }

  // ---------- error ----------

  @Builder
  errorView() {
    Column() {
      this.navBar()
      Column({ space: Tokens.SPACE_MD }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(36)
          .fontColor([$r('sys.color.font_secondary')])
        Text(this.errTitle)
          .fontSize(Tokens.FONT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text(this.errMsg)
          .fontSize(Tokens.FONT_CAPTION)
          .fontColor($r('sys.color.font_secondary'))
          .textAlign(TextAlign.Center)
        Button('返回')
          .width(160)
          .height(Tokens.TARGET_STD)
          .backgroundColor($r('sys.color.brand'))
          .onClick(() => {
            this.reopen();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding(Tokens.SPACE_LG)
    }
    .width('100%')
    .height('100%')
  }
}
