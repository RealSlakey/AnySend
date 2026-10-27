// Screen mirror page (Shizuku 镜像桥 · 局域网直连).
//
// No adb, no wireless debugging, no pairing: the Android peer is asked over
// Tailscale to prepare the mirror (it raises its hotspot via Shizuku and spawns
// scrcpy-server), then this page joins the hotspot and connects straight to the
// bridge's video/control TCP ports.
//   bootstrap : MirrorAutoConnect.resolveBridgeTarget()
//   session   : DirectStreamClient -> native direct-mode decoder/renderer
//   input     : handled entirely in C++ through the XComponent callbacks, so
//               this page never injects touch events itself.
//
// Visual states driven by `view`:
//   idle       - entry card with the one-tap "开始镜像" button
//   connecting - progress checklist (询问安卓 / 加入热点 / 建立直连)
//   mirroring  - full-bleed surface + back button (top-left)
//   error      - failure reason + retry / back

import { common } from '@kit.AbilityKit';
import { Tokens } from '../common/DesignTokens';
import { AppNav } from '../common/AppNav';
import { NativeStreamListener } from '../scrcpy/client/tools/NativeStreamClient';
import { DirectStreamClient } from '../scrcpy/client/tools/DirectStreamClient';
import { MirrorAutoConnect, MirrorBridgeTarget } from '../adb/MirrorAutoConnect';

// Native context handed to the SURFACE XComponent onLoad callback.
interface NativeXComponentContext {
  registerNativeXComponent(): boolean;
}

interface StepDef {
  key: string;
  label: string;
}

type Phase = 'idle' | 'connecting' | 'mirroring' | 'error';

const STEPS: StepDef[] = [
  { key: 'ask', label: '询问安卓端准备镜像' },
  { key: 'hotspot', label: '加入安卓热点' },
  { key: 'stream', label: '建立直连并推流' }
];

const STEP_ASK: number = 0;
const STEP_HOTSPOT: number = 1;
const STEP_STREAM: number = 2;

const SURFACE_ID_NAME: string = 'mirror_video_surface';
const SURFACE_WAIT_MS: number = 3000;
const SURFACE_POLL_MS: number = 50;
const VIDEO_FRAME_RATE: number = 60;

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

@Component
export struct MirrorPage {
  @State view: Phase = 'idle';
  @State statusText: string = '';
  @State note: string = '';
  @State stepIndex: number = -1;
  @State errTitle: string = '';
  @State errMsg: string = '';
  @State targetHost: string = '';
  @State videoAR: number = 9 / 19.5;
  @State guideOpen: boolean = false;

  private context: common.UIAbilityContext | null = null;
  private surfaceId: string = '';
  private sessionSeq: number = 0;
  private client: DirectStreamClient | null = null;
  private xcController: XComponentController = new XComponentController();

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
  }

  aboutToDisappear(): void {
    this.stopSession();
  }

  // ---------- session ----------

  private async startMirror(): Promise<void> {
    if (this.view === 'connecting') {
      return;
    }
    if (this.context === null) {
      return;
    }
    this.stopSession();
    const seq = ++this.sessionSeq;
    this.targetHost = '';
    this.note = '';
    this.errTitle = '';
    this.errMsg = '';
    this.statusText = '正在询问安卓端…';
    this.stepIndex = STEP_ASK;
    this.view = 'connecting';

    // the XComponent mounts with this state; wait for its surface id
    let waited = 0;
    while (this.surfaceId.length === 0 && waited < SURFACE_WAIT_MS) {
      await sleepMs(SURFACE_POLL_MS);
      waited += SURFACE_POLL_MS;
    }
    if (seq !== this.sessionSeq) {
      return;
    }
    if (this.surfaceId.length === 0) {
      this.failWith(seq, '视频组件未就绪', '页面渲染组件未能创建渲染表面，请返回后重试。');
      return;
    }

    const target: MirrorBridgeTarget | null = await MirrorAutoConnect.resolveBridgeTarget((msg: string) => {
      if (seq === this.sessionSeq) {
        this.statusText = msg;
        if (msg.indexOf('热点') >= 0) {
          this.stepIndex = STEP_HOTSPOT;
        }
      }
    });
    if (seq !== this.sessionSeq) {
      return;
    }
    if (target === null) {
      this.failWith(seq, '无法连接安卓设备',
        '未能让安卓端准备好镜像服务。请确认：两端 AnySend 都在前台、Tailscale 已连接，且安卓端已授权 Shizuku。');
      return;
    }

    this.targetHost = target.host;
    this.stepIndex = STEP_STREAM;
    this.statusText = '建立直连并推流…';

    const client = new DirectStreamClient(this.buildListener(seq));
    this.client = client;
    try {
      await client.start(target.host, target.videoPort, target.controlPort, this.surfaceId,
        VIDEO_FRAME_RATE);
      if (seq !== this.sessionSeq) {
        return;
      }
      this.statusText = '推流中…';
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
          this.videoAR = width / height;
        }
        this.statusText = '推流中…';
      },
      onFirstFrame: (): void => {
        if (seq !== this.sessionSeq) {
          return;
        }
        this.view = 'mirroring';
        this.statusText = '';
      },
      // 剪贴板内容不在画面上展示，避免遮挡视野
      onClipboard: (_text: string): void => {},
      onDisconnect: (reason: string): void => {
        if (seq !== this.sessionSeq) {
          return;
        }
        const msg = reason === 'Server Disconnected' || reason.length === 0
          ? '安卓设备结束了镜像会话。' : reason;
        this.failWith(seq, '投屏已断开', msg);
      },
      onError: (error: string): void => {
        if (seq !== this.sessionSeq) {
          return;
        }
        this.failWith(seq, '镜像出错', error);
      }
    };
    return listener;
  }

  private stopSession(): void {
    this.sessionSeq += 1;
    const c = this.client;
    this.client = null;
    if (c !== null) {
      c.stop();
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

  private backToIdle(): void {
    // unmounting the XComponent invalidates the surface; drop the stale id so
    // the next connect waits for a fresh onLoad
    this.surfaceId = '';
    this.stopSession();
    this.view = 'idle';
  }

  private leavePage(): void {
    this.stopSession();
    AppNav.stack.pop();
  }

  // ---------- build ----------

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // ---- video layer (mounted from `connecting` onward)
        if (this.view !== 'idle') {
          Stack({ alignContent: Alignment.Center }) {
            Column() {
              this.videoSurface()
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Color.Black)
          }
          .width('100%')
          .height('100%')
          .clip(true)
        }

        // ---- floating controls over the video (touch on the video itself is
        //      forwarded to the device natively by the C++ layer)
        if (this.view === 'mirroring') {
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

          }
          .width('100%')
          .padding({ top: 12, left: Tokens.SPACE_LG, right: Tokens.SPACE_LG })
        }

        // ---- state overlays
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

  @Builder
  videoSurface() {
    XComponent({
      id: SURFACE_ID_NAME,
      type: XComponentType.SURFACE,
      controller: this.xcController,
      libraryname: 'scrcpy_native'
    })
      .onLoad((nativeContext: object) => {
        // Registration failure is surfaced by the native start call itself
        // (code -3), so this stays fire-and-forget.
        (nativeContext as NativeXComponentContext).registerNativeXComponent();
        this.surfaceId = this.xcController.getXComponentSurfaceId();
      })
      .aspectRatio(this.videoAR)
      .height('100%')
      .backgroundColor(Color.Black)
  }

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

      Text('屏幕镜像')
        .fontSize(Tokens.FONT_H2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Blank()
    }
    .width('100%')
    .padding({ left: 12, right: Tokens.SPACE_LG, top: 12, bottom: 12 })
  }

  // ---------- idle view ----------

  @Builder
  idleView() {
    Column() {
      this.navBar()
      Scroll() {
        Column({ space: Tokens.SPACE_MD }) {
          Column({ space: Tokens.SPACE_SM }) {
            SymbolGlyph($r('sys.symbol.screen_mirror'))
              .fontSize(40)
              .fontColor([$r('sys.color.brand')])
            Text('安卓屏幕实时镜像')
              .fontSize(Tokens.FONT_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text('无需数据线、无需配对码：一键让安卓端开启热点并直连投屏')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ top: Tokens.SPACE_LG, bottom: Tokens.SPACE_LG, left: Tokens.SPACE_LG, right: Tokens.SPACE_LG })

          Button('开始镜像')
            .width('100%')
            .height(Tokens.TARGET_STD)
            .borderRadius(Tokens.RADIUS_CTRL)
            .fontSize(Tokens.FONT_TITLE)
            .backgroundColor($r('sys.color.brand'))
            .onClick(() => {
              this.startMirror();
            })

          Column({ space: Tokens.SPACE_SM }) {
            Row({ space: Tokens.SPACE_SM }) {
              Text('使用说明')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
              SymbolGlyph(this.guideOpen ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                .fontSize(16)
                .fontColor([$r('sys.color.icon_tertiary')])
            }
            .width('100%')
            .height(40)
            .onClick(() => {
              this.guideOpen = !this.guideOpen;
            })

            if (this.guideOpen) {
              this.guideRow('1', '两端 AnySend 保持前台，Tailscale 已连接')
              this.guideRow('2', '安卓端需运行 Shizuku 并已授权（首次会弹一次允许框）')
              this.guideRow('3', '点「开始镜像」：安卓端自动开启热点并启动镜像服务')
              this.guideRow('4', '本机自动加入热点后直连推流，无需手动配置地址')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(Tokens.SPACE_MD)
          .borderRadius(Tokens.RADIUS_CARD)
          .backgroundColor($r('app.color.card'))
        }
        .width('100%')
        .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, bottom: Tokens.SPACE_XL })
        .constraintSize({ maxWidth: Tokens.CONTENT_MAX_WIDTH })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  guideRow(no: string, text: string) {
    Row({ space: Tokens.SPACE_SM }) {
      Text(no)
        .fontSize(Tokens.FONT_CAPTION)
        .fontColor($r('sys.color.brand'))
        .width(22)
        .height(22)
        .textAlign(TextAlign.Center)
        .borderRadius(11)
        .backgroundColor($r('app.color.chip_bg'))
      Text(text)
        .fontSize(Tokens.FONT_BODY)
        .fontColor($r('sys.color.font_secondary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  // ---------- connecting view ----------

  @Builder
  connectingView() {
    Column() {
      this.navBar()
      Column({ space: Tokens.SPACE_XL }) {
        Column({ space: Tokens.SPACE_MD }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color($r('sys.color.brand'))
          Text(this.statusText.length > 0 ? this.statusText : '连接中…')
            .fontSize(Tokens.FONT_H2)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          Text(this.targetHost.length > 0 ? `目标 ${this.targetHost}` : '')
            .fontSize(Tokens.FONT_BODY)
            .fontColor($r('sys.color.font_tertiary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: Tokens.SPACE_XL })

        Column({ space: 0 }) {
          ForEach(STEPS, (s: StepDef, idx: number) => {
            this.stepRow(s, idx)
          }, (s: StepDef) => s.key)
        }
        .width('100%')

        Button('取消')
          .width('100%')
          .height(Tokens.TARGET_STD)
          .borderRadius(Tokens.RADIUS_CTRL)
          .fontSize(Tokens.FONT_TITLE)
          .backgroundColor($r('app.color.field'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.backToIdle();
          })
      }
      .width('100%')
      .padding({ left: Tokens.SPACE_XL, right: Tokens.SPACE_XL, bottom: Tokens.SPACE_XL })
      .constraintSize({ maxWidth: Tokens.CONTENT_MAX_WIDTH })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  stepRow(s: StepDef, idx: number) {
    Row({ space: Tokens.SPACE_MD }) {
      if (idx < this.stepIndex) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(22)
          .fontColor([$r('app.color.success')])
      } else if (idx === this.stepIndex) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color($r('sys.color.brand'))
      } else {
        SymbolGlyph($r('sys.symbol.circle'))
          .fontSize(20)
          .fontColor([$r('sys.color.icon_tertiary')])
      }

      Text(s.label)
        .fontSize(Tokens.FONT_BODY)
        .fontColor(idx <= this.stepIndex ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
        .layoutWeight(1)

      if (idx < this.stepIndex) {
        Text('完成')
          .fontSize(Tokens.FONT_CAPTION)
          .fontColor($r('app.color.success'))
      } else if (idx === this.stepIndex) {
        Text('进行中…')
          .fontSize(Tokens.FONT_CAPTION)
          .fontColor($r('sys.color.brand'))
      }
    }
    .width('100%')
    .height(48)
  }

  // ---------- error view ----------

  @Builder
  errorView() {
    Column() {
      this.navBar()
      Column({ space: Tokens.SPACE_LG }) {
        Column({ space: Tokens.SPACE_MD }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(36)
            .fontColor([$r('sys.color.warning')])
          Text(this.errTitle)
            .fontSize(Tokens.FONT_H2)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: Tokens.SPACE_XL })

        Scroll() {
          Text(this.errMsg)
            .fontSize(Tokens.FONT_BODY)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
        }
        .scrollBar(BarState.Auto)
        .width('100%')
        .constraintSize({ minHeight: 80, maxHeight: 220 })
        .backgroundColor($r('app.color.field'))
        .borderRadius(Tokens.RADIUS_CTRL)
        .padding(Tokens.SPACE_MD)

        Button('重试')
          .width('100%')
          .height(Tokens.TARGET_STD)
          .borderRadius(Tokens.RADIUS_CTRL)
          .fontSize(Tokens.FONT_TITLE)
          .backgroundColor($r('sys.color.brand'))
          .onClick(() => {
            this.startMirror();
          })
        Button('返回')
          .width('100%')
          .height(Tokens.TARGET_STD)
          .borderRadius(Tokens.RADIUS_CTRL)
          .fontSize(Tokens.FONT_TITLE)
          .backgroundColor($r('app.color.field'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.backToIdle();
          })
      }
      .width('100%')
      .padding({ left: Tokens.SPACE_XL, right: Tokens.SPACE_XL, bottom: Tokens.SPACE_XL })
      .constraintSize({ maxWidth: Tokens.CONTENT_MAX_WIDTH })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
