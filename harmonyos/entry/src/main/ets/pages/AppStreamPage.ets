// 应用推流页（Shizuku 虚拟显示桥 · 局域网直连）.
//
// 与"屏幕镜像"并列的另一件事：镜像把安卓整块屏幕搬过来；应用推流只把一个
// 指定的 app 跑在安卓端新建的虚拟显示上，安卓自己的屏幕不显示它 —— 相当于
// 把这个应用的画面"流转"到了鸿蒙这边。
//
// 流程：
//   list       - tailnet 拉取安卓端可启动应用清单（包名/名称/图标），宫格选择
//   connecting - 询问安卓端（带本机显示区域的宽高/DPI）→ 加入热点 → 建立直连
//   mirroring  - 满铺画面 + 悬浮球；触摸由 C++ 层直接注入，不经过本页
//                悬浮球是画面上唯一的 UI：单击给安卓端注入返回键，
//                长按停止推流回到应用列表；系统侧滑返回在推流期间被屏蔽
//   error      - 失败原因 + 重试 / 返回
//
// 虚拟显示尺寸取自本页画面容器的**实际可用内容区**（vp，已排除状态栏与导航条），
// 换算成 px 下发（MirrorAutoConnect.harmonyVdParams）。画面容器与视频流宽高比一致，
// 满铺无黑边，且 dp 画布与本机内容区相同，界面观感也与鸿蒙原生一致。

import { common } from '@kit.AbilityKit';
import { Tokens } from '../common/DesignTokens';
import { AppNav } from '../common/AppNav';
import { NativeStreamListener } from '../scrcpy/client/tools/NativeStreamClient';
import { DirectStreamClient } from '../scrcpy/client/tools/DirectStreamClient';
import { MirrorAutoConnect, MirrorBridgeTarget, AppEntry, VdParams } from '../adb/MirrorAutoConnect';

// Native context handed to the SURFACE XComponent onLoad callback.
interface NativeXComponentContext {
  registerNativeXComponent(): boolean;
}

interface StepDef {
  key: string;
  label: string;
}

type Phase = 'list' | 'connecting' | 'mirroring' | 'error';

const STEPS: StepDef[] = [
  { key: 'ask', label: '准备安卓端虚拟显示' },
  { key: 'hotspot', label: '加入安卓热点' },
  { key: 'stream', label: '建立直连并推流' }
];

const STEP_ASK: number = 0;
const STEP_HOTSPOT: number = 1;
const STEP_STREAM: number = 2;

const SURFACE_ID_NAME: string = 'appstream_video_surface';
const SURFACE_WAIT_MS: number = 3000;
const SURFACE_POLL_MS: number = 50;
const VIDEO_FRAME_RATE: number = 60;

/** 悬浮球直径（vp）、长按判定时长（ms）、拖动判定阈值（vp）、球心距边缘（vp） */
const BALL_SIZE: number = 52;
const BALL_LONG_PRESS_MS: number = 500;
const BALL_DRAG_MIN: number = 4;
const BALL_MARGIN: number = 12;

function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

/** onAreaChange 回调里的长度值转成 vp 数值（布局结果通常是数字）。 */
function lengthToVp(v: Length): number {
  if (typeof v === 'number') {
    return v;
  }
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

@Component
export struct AppStreamPage {
  @State view: Phase = 'list';
  @State apps: AppEntry[] = [];
  @State appsLoading: boolean = true;
  @State appsNote: string = '';
  @State statusText: string = '';
  @State stepIndex: number = -1;
  @State errTitle: string = '';
  @State errMsg: string = '';
  @State targetHost: string = '';
  @State targetLabel: string = '';
  @State guideOpen: boolean = false;
  /** 悬浮球球心在页面内的位置（vp），可拖动 */
  @State ballCX: number = 0;
  @State ballCY: number = 0;

  private context: common.UIAbilityContext | null = null;
  private surfaceId: string = '';
  /** 画面容器的实际可用内容区（vp），由 onAreaChange 量得；决定虚拟显示几何 */
  private contentW: number = 0;
  private contentH: number = 0;
  private dragBaseX: number = 0;
  private dragBaseY: number = 0;
  private sessionSeq: number = 0;
  private listSeq: number = 0;
  private client: DirectStreamClient | null = null;
  private xcController: XComponentController = new XComponentController();

  aboutToAppear(): void {
    this.context = getContext(this) as common.UIAbilityContext;
    this.loadApps();
  }

  aboutToDisappear(): void {
    this.stopSession();
  }

  // ---------- app list ----------

  private async loadApps(forceRefresh: boolean = false): Promise<void> {
    const seq = ++this.listSeq;
    this.appsLoading = true;
    this.appsNote = '正在读取安卓端应用列表…';
    const list = await MirrorAutoConnect.fetchApps((msg: string) => {
      if (seq === this.listSeq) {
        this.appsNote = msg;
      }
    }, forceRefresh);
    if (seq !== this.listSeq) {
      return;
    }
    this.apps = list;
    this.appsLoading = false;
    this.appsNote = list.length > 0 ? '' : '没能读取到安卓端应用列表，请确认两端 Tailscale 已连接';
  }

  // ---------- session ----------

  private async startStream(app: AppEntry): Promise<void> {
    if (this.view === 'connecting') {
      return;
    }
    if (this.context === null) {
      return;
    }
    this.stopSession();
    const seq = ++this.sessionSeq;
    this.targetHost = '';
    this.targetLabel = app.label;
    this.errTitle = '';
    this.errMsg = '';
    this.statusText = '正在准备虚拟显示…';
    this.stepIndex = STEP_ASK;
    this.view = 'connecting';

    // 本页切到 connecting 后画面容器才挂载，等它的 surface id 就绪
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

    // 画面容器的可用内容区（已排除系统栏）→ 虚拟显示几何。
    // 宽高比必须与容器一致，否则出黑边。
    const vd: VdParams = MirrorAutoConnect.harmonyVdParams(this.contentW, this.contentH);

    const target: MirrorBridgeTarget | null = await MirrorAutoConnect.resolveBridgeTarget(
      (msg: string) => {
        if (seq === this.sessionSeq) {
          this.statusText = msg;
          if (msg.indexOf('热点') >= 0) {
            this.stepIndex = STEP_HOTSPOT;
          }
        }
      }, true, vd);
    if (seq !== this.sessionSeq) {
      return;
    }
    if (target === null) {
      this.failWith(seq, '无法连接安卓设备',
        '未能让安卓端准备好虚拟显示。请确认：两端 AnySend 都在前台、Tailscale 已连接，且安卓端已授权 Shizuku。');
      return;
    }

    this.targetHost = target.host;
    this.stepIndex = STEP_STREAM;
    this.statusText = '建立直连并推流…';

    const client = new DirectStreamClient(this.buildListener(seq));
    this.client = client;
    try {
      await client.start(target.host, target.videoPort, target.controlPort, this.surfaceId,
        VIDEO_FRAME_RATE, app.pkg);
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
        this.statusText = '推流中…';
      },
      onFirstFrame: (): void => {
        if (seq !== this.sessionSeq) {
          return;
        }
        this.resetBallPosition();
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
          ? '安卓设备结束了推流会话。' : reason;
        this.failWith(seq, '推流已断开', msg);
      },
      onError: (error: string): void => {
        if (seq !== this.sessionSeq) {
          return;
        }
        this.failWith(seq, '推流出错', error);
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

  /** 回到应用宫格（XComponent 卸载后 surface 失效，需丢弃旧 id）。 */
  private backToList(): void {
    this.surfaceId = '';
    this.stopSession();
    this.view = 'list';
  }

  private leavePage(): void {
    this.stopSession();
    this.listSeq += 1;
    AppNav.stack.pop();
  }

  /** 悬浮球单击：把返回键注入安卓端（等同按安卓的返回键）。 */
  private sendAndroidBack(): void {
    const c = this.client;
    if (c !== null) {
      c.sendBackKey();
    }
  }

  // ---------- 悬浮球位置 ----------

  /** 进推流时把球放回右侧垂直居中（安卓悬浮球的默认位置）。 */
  private resetBallPosition(): void {
    this.ballCX = this.areaWidth() - BALL_SIZE / 2 - BALL_MARGIN;
    this.ballCY = this.areaHeight() / 2;
  }

  /** 球心拖动范围限制：把球始终留在内容区里，免得被拖出去找不回来。 */
  private clampBallX(v: number): number {
    const min = BALL_SIZE / 2 + BALL_MARGIN;
    const max = Math.max(min, this.areaWidth() - BALL_SIZE / 2 - BALL_MARGIN);
    return Math.min(Math.max(v, min), max);
  }

  private clampBallY(v: number): number {
    const min = BALL_SIZE / 2 + BALL_MARGIN;
    const max = Math.max(min, this.areaHeight() - BALL_SIZE / 2 - BALL_MARGIN);
    return Math.min(Math.max(v, min), max);
  }

  /** 内容区尺寸（vp）；未量到时退回一个够放球的最小值。 */
  private areaWidth(): number {
    return this.contentW > 0 ? this.contentW : BALL_SIZE * 4;
  }

  private areaHeight(): number {
    return this.contentH > 0 ? this.contentH : BALL_SIZE * 8;
  }

  // ---------- build ----------

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // ---- video layer (mounted from `connecting` onward)
        if (this.view === 'connecting' || this.view === 'mirroring') {
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

        // ---- 悬浮球：直接作为 Stack 的子节点，按绝对位置摆一处。
        //      绝不能套满屏容器：满屏的透明占位（哪怕标了 HitTestMode.None）
        //      会把整屏的触摸都吃掉，画面就再也点不动了。
        if (this.view === 'mirroring') {
          this.floatingBall()
        }

        // ---- state overlays
        if (this.view === 'list') {
          this.listView()
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
      // 量出本页实际可用内容区（已排除状态栏/导航条）：画面容器满铺它，
      // 虚拟显示几何也按它算，两边宽高比一致才不会出黑边。
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        this.contentW = lengthToVp(newArea.width);
        this.contentH = lengthToVp(newArea.height);
      })
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_bg'))
    // 推流期间屏蔽系统返回（含左右侧滑）：NavDestination.onBackPressed 返回 true
    // 即由本页接管返回事件 —— 这里就是什么都不做，画面上的侧滑手势才不会把
    // 推流页滑掉。退出推流走悬浮球。其余状态仍保留系统默认返回。
    .onBackPressed(() => {
      return this.view === 'mirroring';
    })
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
      // 满铺容器：虚拟显示的宽高比已按这个容器算好，缩放后正好 1:1 铺满，不留黑边
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Black)
  }

  /**
   * 悬浮球（推流画面上唯一的控件）。
   *
   * 单击 = 注入安卓返回键；长按 = 停止推流回应用列表；拖动可换位置。
   * 手势一律走 GestureGroup(Exclusive) 组合，不用 .onClick/.onLongPress：
   * 后两者并存时，长按抬手会连带触发一次点击，等于长按回列表还顺手给安卓
   * 多发一个返回键。Exclusive 模式只认第一个满足条件的手势。
   *
   * 位置用 .position() 绝对摆放（拖动时改球心坐标），绝不套满屏容器 ——
   * 满屏透明层会吃掉整屏触摸，画面就点不动了。
   */
  @Builder
  floatingBall() {
    Stack({ alignContent: Alignment.Center }) {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(20)
        .fontColor(['rgba(255,255,255,0.92)'])
    }
    .width(BALL_SIZE)
    .height(BALL_SIZE)
    // 用 backgroundColor + borderRadius 画圆：Circle 的 fill/stroke 都是 SDK 26
    // 的 API，本工程兼容 API 12，球体根本不会被填色。
    .borderRadius(BALL_SIZE / 2)
    .backgroundColor('rgba(16,16,16,0.55)')
    .position({ x: this.ballCX - BALL_SIZE / 2, y: this.ballCY - BALL_SIZE / 2 })
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        PanGesture({ fingers: 1, distance: BALL_DRAG_MIN })
          .onActionStart(() => {
            this.dragBaseX = this.ballCX;
            this.dragBaseY = this.ballCY;
          })
          .onActionUpdate((event: GestureEvent) => {
            this.ballCX = this.clampBallX(this.dragBaseX + event.offsetX);
            this.ballCY = this.clampBallY(this.dragBaseY + event.offsetY);
          }),
        LongPressGesture({ repeat: false, duration: BALL_LONG_PRESS_MS })
          .onAction(() => {
            this.backToList();
          }),
        TapGesture({ count: 1 })
          .onAction(() => {
            this.sendAndroidBack();
          })
      )
    )
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

      Text('应用推流')
        .fontSize(Tokens.FONT_H2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Blank()
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(22)
        .fontColor([$r('sys.color.icon_secondary')])
        .onClick(() => {
          if (!this.appsLoading) {
            this.loadApps(true);
          }
        })
    }
    .width('100%')
    .padding({ left: 12, right: Tokens.SPACE_LG, top: 12, bottom: 12 })
  }

  // ---------- app list view ----------

  @Builder
  listView() {
    Column() {
      this.navBar()
      Scroll() {
        Column({ space: Tokens.SPACE_MD }) {
          Column({ space: Tokens.SPACE_SM }) {
            SymbolGlyph($r('sys.symbol.rectangle_on_rectangle'))
              .fontSize(40)
              .fontColor([$r('sys.color.brand')])
            Text('把安卓应用推到本机')
              .fontSize(Tokens.FONT_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text('选一个应用：它只在鸿蒙这边显示，安卓手机自己的屏幕不受影响')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ top: Tokens.SPACE_MD, bottom: Tokens.SPACE_MD, left: Tokens.SPACE_LG, right: Tokens.SPACE_LG })

          if (this.appsLoading) {
            Column({ space: Tokens.SPACE_MD }) {
              LoadingProgress()
                .width(36)
                .height(36)
                .color($r('sys.color.brand'))
              Text(this.appsNote)
                .fontSize(Tokens.FONT_BODY)
                .fontColor($r('sys.color.font_tertiary'))
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .padding({ top: Tokens.SPACE_XL, bottom: Tokens.SPACE_XL })
          } else if (this.apps.length === 0) {
            Column({ space: Tokens.SPACE_MD }) {
              Text(this.appsNote.length > 0 ? this.appsNote : '没有可推流的应用')
                .fontSize(Tokens.FONT_BODY)
                .fontColor($r('sys.color.font_tertiary'))
                .textAlign(TextAlign.Center)
              Button('重新读取')
                .height(Tokens.TARGET_STD)
                .borderRadius(Tokens.RADIUS_CTRL)
                .fontSize(Tokens.FONT_TITLE)
                .backgroundColor($r('app.color.field'))
                .fontColor($r('sys.color.font_primary'))
                .onClick(() => {
                  this.loadApps();
                })
            }
            .width('100%')
            .padding({ top: Tokens.SPACE_XL, bottom: Tokens.SPACE_XL })
          } else {
            Grid() {
              ForEach(this.apps, (app: AppEntry) => {
                GridItem() {
                  this.appCell(app)
                }
              }, (app: AppEntry) => app.pkg)
            }
            .columnsTemplate('1fr 1fr 1fr 1fr')
            .columnsGap(Tokens.SPACE_MD)
            .rowsGap(Tokens.SPACE_MD)
            .width('100%')
          }

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
              this.guideRow('3', '点选应用：安卓端新建虚拟显示并把该应用启动上去')
              this.guideRow('4', '本机自动加入热点后直连推流，安卓屏幕不会显示该应用')
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
  appCell(app: AppEntry) {
    Column({ space: 6 }) {
      if (app.icon.length > 0) {
        Image(`data:image/png;base64,${app.icon}`)
          .width(48)
          .height(48)
          .borderRadius(12)
          .objectFit(ImageFit.Contain)
      } else {
        Stack() {
          SymbolGlyph($r('sys.symbol.square_grid_2x2'))
            .fontSize(26)
            .fontColor([$r('sys.color.icon_secondary')])
        }
        .width(48)
        .height(48)
        .borderRadius(12)
        .backgroundColor($r('app.color.field'))
      }
      Text(app.label)
        .fontSize(Tokens.FONT_CAPTION)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
    .padding({ top: Tokens.SPACE_MD, bottom: Tokens.SPACE_MD })
    .borderRadius(Tokens.RADIUS_CARD)
    .backgroundColor($r('app.color.card'))
    .onClick(() => {
      this.startStream(app);
    })
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
          Text(this.targetLabel.length > 0 ? `目标应用 ${this.targetLabel}` : '')
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
            this.backToList();
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
            this.backToList();
          })
        Button('返回')
          .width('100%')
          .height(Tokens.TARGET_STD)
          .borderRadius(Tokens.RADIUS_CTRL)
          .fontSize(Tokens.FONT_TITLE)
          .backgroundColor($r('app.color.field'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.leavePage();
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
