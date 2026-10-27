// Devices tab: connection status and Tailscale peers. Long-press a peer to
// share files to it or make it the default SMS / share target. Tailscale
// login and direct-LAN controls live in Settings > 连接.

import promptAction from '@ohos.promptAction';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import picker from '@ohos.file.picker';
import { TailscaleManager, PeerInfo } from '../bridge/TailscaleManager';
import { Tokens } from '../common/DesignTokens';
import { CardContainer } from '../common/CardContainer';
import { AutoConnect, ConnectPhase } from '../common/AutoConnect';
import { DeviceProfile } from '../common/DeviceProfile';
import { DefaultTargets } from '../common/DefaultTargets';
import { AppNav } from '../common/AppNav';
import { SmsStore } from '../sms/SmsStore';
import { LocalSendConst } from '../protocol/LocalSendModels';
import { LanDiscovery, LanDevice } from '../common/LanDiscovery';
import { TextShare } from '../common/TextShare';

// 镜像/推流入口卡片的固定高度：两者并排等宽，固定高度保证视觉齐平。
const TILE_HEIGHT: number = 124;

/** Multi-line input for the "文字" send entry. */
@CustomDialog
struct TextInputDialog {
  controller?: CustomDialogController;
  onConfirm: (text: string) => void = () => {
  };
  @State text: string = '';

  build() {
    Column({ space: Tokens.SPACE_MD }) {
      Text('发送文字')
        .fontSize(Tokens.FONT_H2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')

      TextArea({ placeholder: '输入要发送的文字…' })
        .height(180)
        .width('100%')
        .fontSize(Tokens.FONT_BODY)
        .backgroundColor($r('app.color.field'))
        .placeholderColor($r('sys.color.font_tertiary'))
        .borderRadius(Tokens.RADIUS_CTRL)
        .padding(10)
        .onChange((value: string) => {
          this.text = value;
        })

      Row({ space: Tokens.SPACE_MD }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.controller?.close();
          })
        Button('发送')
          .layoutWeight(1)
          .height(44)
          .backgroundColor($r('sys.color.brand'))
          .onClick(() => {
            const value = this.text;
            if (value.trim().length === 0) {
              promptAction.showToast({ message: '请输入要发送的文字' });
              return;
            }
            if (TextShare.isTooLong(value)) {
              promptAction.showToast({ message: '内容过长，请粘贴为文件' });
              return;
            }
            this.controller?.close();
            this.onConfirm(value);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(Tokens.SPACE_LG)
    .borderRadius(Tokens.RADIUS_CARD)
    .backgroundColor($r('app.color.card'))
  }
}

@Component
export struct TransferPage {
  @State statusText: string = '未连接';
  @State statusOk: boolean = false;
  @State peers: PeerInfo[] = [];
  @State lanDevices: LanDevice[] = [];
  @State lanScanning: boolean = false;
  @State localIp: string = '';
  @State selfName: string = '';
  @State serverRunning: boolean = false;
  private connectCb: () => void = () => {
    this.syncFromAutoConnect();
  };
  private textDialog: CustomDialogController = new CustomDialogController({
    builder: TextInputDialog({
      onConfirm: (text: string) => {
        this.addTextToSendList(text);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  aboutToAppear() {
    AutoConnect.onChange(this.connectCb);
    this.syncFromAutoConnect();
    this.refreshPeers();
    this.scanLan();
  }

  aboutToDisappear() {
    AutoConnect.offChange(this.connectCb);
  }

  /** Mirror AutoConnect's phase into the status card. */
  private syncFromAutoConnect(): void {
    this.serverRunning = AutoConnect.isServerRunning();
    const phase: ConnectPhase = AutoConnect.getPhase();
    if (phase === 'running') {
      this.statusText = 'Tailscale 已连接';
      this.statusOk = true;
    } else if (phase === 'connecting') {
      this.statusText = AutoConnect.getStatusText();
      this.statusOk = false;
    } else if (phase === 'failed') {
      this.statusText = AutoConnect.getStatusText();
      this.statusOk = false;
    } else if (this.serverRunning) {
      // direct LAN mode keeps the server up without Tailscale
      this.statusText = '直连模式运行中';
      this.statusOk = true;
    } else {
      this.statusText = '未连接';
      this.statusOk = false;
    }
    if (this.serverRunning) {
      this.localIp = AutoConnect.currentCallbackIp();
    }
    if (phase === 'running') {
      this.refreshPeers();
      const self = TailscaleManager.getSelfInfo();
      const custom = DeviceProfile.customName();
      this.selfName = custom.length > 0 ? custom : (self !== null ? self.hostName : '');
    }
  }

  build() {
    Column() {
      Text('设备')
        .fontSize(Tokens.FONT_H1)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, top: 14, bottom: Tokens.SPACE_SM })

      Scroll() {
        Column({ space: Tokens.SPACE_MD }) {
          // ---- status card
          CardContainer() {
            Row() {
              Circle({ width: 8, height: 8 })
                .fill(this.statusOk ? $r('app.color.success') : $r('sys.color.icon_tertiary'))
              Text(this.statusText)
                .fontSize(15)
                .fontColor($r('sys.color.font_primary'))
                .margin({ left: Tokens.SPACE_SM })
                .layoutWeight(1)
              Text(this.serverRunning ? '接收服务运行中' : '接收服务未启动')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor(this.serverRunning ? $r('sys.color.brand') : $r('sys.color.font_tertiary'))
                .backgroundColor(this.serverRunning ? $r('app.color.chip_bg') : $r('app.color.field'))
                .borderRadius(4)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            }
            .width('100%')

            if (this.localIp.length > 0) {
              Text(this.selfName.length > 0
                ? `本机设备：${this.selfName}（${this.localIp}）`
                : `本机地址：${this.localIp}`)
                .fontSize(13)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .margin({ top: Tokens.SPACE_SM })
            }
          }

          // ---- text send entries: typed text or clipboard -> cached .txt
          CardContainer() {
            Row() {
              Text('发送文字')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
              Text('输入文字，或粘贴剪贴板内容')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_tertiary'))
            }
            .width('100%')

            Row({ space: Tokens.SPACE_MD }) {
              Column({ space: Tokens.SPACE_XS }) {
                Text('文字')
                  .fontSize(Tokens.FONT_CAPTION)
                  .fontColor($r('sys.color.font_secondary'))
                Button('输入文字')
                  .width('100%')
                  .height(44)
                  .backgroundColor($r('app.color.field'))
                  .fontColor($r('sys.color.font_primary'))
                  .onClick(() => {
                    this.textDialog.open();
                  })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column({ space: Tokens.SPACE_XS }) {
                Text('剪贴板')
                  .fontSize(Tokens.FONT_CAPTION)
                  .fontColor($r('sys.color.font_secondary'))
                // Security component: only a real tap grants temporary clipboard
                // read permission for apps without the restricted READ_PASTEBOARD.
                PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
                  .width('100%')
                  .height(44)
                  .backgroundColor($r('app.color.field'))
                  .fontColor($r('sys.color.font_primary'))
                  .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                    if (result === PasteButtonOnClickResult.SUCCESS) {
                      this.shareClipboard();
                    } else {
                      promptAction.showToast({ message: '无法读取剪贴板' });
                    }
                  })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .margin({ top: Tokens.SPACE_MD })
          }

          // ---- mirror / app-stream entries（左右并排：左=应用推流，右=屏幕镜像）
          Row({ space: Tokens.SPACE_MD }) {
            Column() {
              SymbolGlyph($r('sys.symbol.rectangle_on_rectangle'))
                .fontSize(26)
                .fontColor([$r('sys.color.brand')])
              Text('应用推流')
                .fontSize(Tokens.FONT_BODY)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .margin({ top: Tokens.SPACE_XS })
              Text('把单个安卓应用推到本机运行')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_tertiary'))
                .maxLines(2)
                .margin({ top: Tokens.SPACE_XS })
            }
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Center)
            .layoutWeight(1)
            .height(TILE_HEIGHT)
            .padding(14)
            .borderRadius(Tokens.RADIUS_CARD)
            .backgroundColor($r('app.color.card'))
            .onClick(() => {
              AppNav.push('AppStreamPage', null);
            })

            Column() {
              SymbolGlyph($r('sys.symbol.screen_mirror'))
                .fontSize(26)
                .fontColor([$r('sys.color.brand')])
              Text('屏幕镜像')
                .fontSize(Tokens.FONT_BODY)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .margin({ top: Tokens.SPACE_XS })
              Text('实时查看安卓手机屏幕')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_tertiary'))
                .maxLines(2)
                .margin({ top: Tokens.SPACE_XS })
            }
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Center)
            .layoutWeight(1)
            .height(TILE_HEIGHT)
            .padding(14)
            .borderRadius(Tokens.RADIUS_CARD)
            .backgroundColor($r('app.color.card'))
            .onClick(() => {
              AppNav.push('MirrorPage', null);
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ bottom: Tokens.SPACE_MD })

          // ---- remote-control entry: drive a Mac from this phone
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.superdevice'))
                .fontSize(26)
                .fontColor([$r('sys.color.brand')])
              Column({ space: Tokens.SPACE_XS }) {
                Text('远程控制电脑')
                  .fontSize(Tokens.FONT_BODY)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                Text('折叠屏可当笔记本用：上半屏画面，下半屏键盘触控板')
                  .fontSize(Tokens.FONT_CAPTION)
                  .fontColor($r('sys.color.font_tertiary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: Tokens.SPACE_MD })
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(16)
                .fontColor([$r('sys.color.icon_tertiary')])
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding(14)
          .borderRadius(Tokens.RADIUS_CARD)
          .backgroundColor($r('app.color.card'))
          .margin({ bottom: Tokens.SPACE_MD })
          .onClick(() => {
            AppNav.push('MacRemotePage', null);
          })

          // ---- peers card
          CardContainer() {
            Row() {
              Text('在线设备')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
              Text('长按设备可操作')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_tertiary'))
            }
            .width('100%')
            .margin({ bottom: 6 })

            if (this.peers.length === 0) {
              Column({ space: Tokens.SPACE_SM }) {
                SymbolGlyph($r('sys.symbol.wifi_slash'))
                  .fontSize(28)
                  .fontColor([$r('sys.color.icon_tertiary')])
                Text('暂无在线设备')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_tertiary'))
                Text('可在「设置 › 连接」中登录 Tailscale 或启动直连模式')
                  .fontSize(Tokens.FONT_CAPTION)
                  .fontColor($r('sys.color.font_tertiary'))
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 8, bottom: 8 })
            } else {
              ForEach(this.peers, (p: PeerInfo, idx: number) => {
                Row() {
                  Text(p.hostName.substring(0, 1).toUpperCase())
                    .fontSize(Tokens.FONT_TITLE)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Color.White)
                    .width(36)
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .borderRadius(18)
                    .backgroundColor(this.peerColor(idx))

                  Column() {
                    Text(p.hostName)
                      .fontSize(Tokens.FONT_BODY)
                      .fontColor($r('sys.color.font_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(p.tailscaleIP)
                      .fontSize(Tokens.FONT_CAPTION)
                      .fontColor($r('sys.color.font_tertiary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .margin({ left: 10 })
                  .layoutWeight(1)

                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(14)
                    .fontColor([$r('sys.color.icon_tertiary')])
                }
                .width('100%')
                .height(Tokens.TARGET_MIN + 8)
                .padding({ top: 6, bottom: 6 })
                .onClick(() => {
                  this.shareTo(p.hostName, p.tailscaleIP);
                })
                .bindContextMenu(this.deviceMenu(p.hostName, p.tailscaleIP), ResponseType.LongPress)
              }, (p: PeerInfo) => p.tailscaleIP)
            }
          }

          // ---- LAN devices card (UDP auto-discovery)
          CardContainer() {
            Row() {
              Text('局域网设备')
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
              Text('同一 Wi-Fi 自动发现')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_tertiary'))
                .margin({ right: 10 })
              Text(this.lanScanning ? '扫描中…' : '重新扫描')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.brand'))
                .onClick(() => {
                  this.scanLan();
                })
            }
            .width('100%')
            .margin({ bottom: 6 })

            if (this.lanScanning && this.lanDevices.length === 0) {
              Column({ space: Tokens.SPACE_SM }) {
                SymbolGlyph($r('sys.symbol.wifi'))
                  .fontSize(28)
                  .fontColor([$r('sys.color.icon_tertiary')])
                Text('正在扫描局域网…')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_tertiary'))
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 8, bottom: 8 })
            } else if (this.lanDevices.length === 0) {
              Column({ space: Tokens.SPACE_SM }) {
                SymbolGlyph($r('sys.symbol.wifi_slash'))
                  .fontSize(28)
                  .fontColor([$r('sys.color.icon_tertiary')])
                Text('未发现局域网设备')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_tertiary'))
                Text('对端需打开 AnySend 并保持同一网络')
                  .fontSize(Tokens.FONT_CAPTION)
                  .fontColor($r('sys.color.font_tertiary'))
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 8, bottom: 8 })
            } else {
              ForEach(this.lanDevices, (d: LanDevice, idx: number) => {
                Row() {
                  Text(d.name.substring(0, 1).toUpperCase())
                    .fontSize(Tokens.FONT_TITLE)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Color.White)
                    .width(36)
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .borderRadius(18)
                    .backgroundColor(this.peerColor(idx))

                  Column() {
                    Text(d.name)
                      .fontSize(Tokens.FONT_BODY)
                      .fontColor($r('sys.color.font_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(d.ip)
                      .fontSize(Tokens.FONT_CAPTION)
                      .fontColor($r('sys.color.font_tertiary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .margin({ left: 10 })
                  .layoutWeight(1)

                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(14)
                    .fontColor([$r('sys.color.icon_tertiary')])
                }
                .width('100%')
                .height(Tokens.TARGET_MIN + 8)
                .padding({ top: 6, bottom: 6 })
                .onClick(() => {
                  this.shareTo(d.name, d.ip);
                })
                .bindContextMenu(this.deviceMenu(d.name, d.ip), ResponseType.LongPress)
              }, (d: LanDevice) => d.ip)
            }
          }
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
  deviceMenu(name: string, ip: string) {
    Menu() {
      MenuItem({ content: '分享文件至它' })
        .onClick(() => {
          this.shareTo(name, ip);
        })
      MenuItem({ content: '设为默认安卓短信设备' })
        .onClick(() => {
          this.setSmsHost(name, ip);
        })
      MenuItem({ content: '设为默认分享设备' })
        .onClick(() => {
          this.setDefaultShare(name, ip);
        })
    }
  }

  /** Read plain text from the clipboard and queue it as a cached .txt file. */
  private async shareClipboard(): Promise<void> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      const text = data.getPrimaryText();
      if (text.length === 0 || text.trim().length === 0) {
        promptAction.showToast({ message: '剪贴板没有文字' });
        return;
      }
      if (TextShare.isTooLong(text)) {
        promptAction.showToast({ message: '内容过长，请粘贴为文件' });
        return;
      }
      this.addTextToSendList(text);
    } catch (e) {
      promptAction.showToast({ message: '读取剪贴板失败' });
    }
  }

  /** Persist text as UTF-8 .txt in the cache dir, then open the send list. */
  private addTextToSendList(text: string): void {
    if (TextShare.isTooLong(text)) {
      promptAction.showToast({ message: '内容过长，请粘贴为文件' });
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    TextShare.writeToCache(context, text)
      .then((path: string) => {
        AppStorage.setOrCreate('sharedUris', [path]);
        AppStorage.setOrCreate('shareTargetIp', '');
        AppStorage.setOrCreate('shareTargetName', '');
        AppNav.push('SharePage', null);
      })
      .catch(() => {
        promptAction.showToast({ message: '写入文字失败' });
      });
  }

  /** Pick files, then open the share page with this peer preselected. */
  private async shareTo(name: string, ip: string): Promise<void> {
    try {
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 9;
      const docPicker = new picker.DocumentViewPicker();
      const uris: string[] = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      AppStorage.setOrCreate('sharedUris', uris);
      AppStorage.setOrCreate('shareTargetIp', ip);
      AppStorage.setOrCreate('shareTargetName', name);
      AppNav.push('SharePage', null);
    } catch (e) {
      promptAction.showToast({ message: '选择文件失败' });
    }
  }

  /** Point the SMS relay at this peer, reusing the saved pairing token. */
  private setSmsHost(name: string, ip: string): void {
    const store = SmsStore.getInstance();
    if (store.token.trim().length === 0) {
      promptAction.showToast({ message: '请先到「设置 › 配对码」填写安卓端配对码' });
      AppStorage.setOrCreate('smsTab', 2);
      return;
    }
    store.setHost(`${ip}:${LocalSendConst.PORT}`, name, store.token);
    store.startPolling();
    store.syncOnce();
    promptAction.showToast({ message: `已设为短信主机：${name}` });
  }

  private async setDefaultShare(name: string, ip: string): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    await DefaultTargets.saveShare(context, ip, name);
    promptAction.showToast({ message: `默认分享设备：${name}` });
  }

  private peerColor(idx: number): string {
    const palette: string[] = ['#0A59F1', '#34C759', '#FF9500', '#AF52DE', '#FF2D55', '#5AC8FA'];
    return palette[idx % palette.length];
  }

  async refreshPeers() {
    if (!TailscaleManager.isStarted()) {
      this.peers = [];
      return;
    }
    await TailscaleManager.refreshStatus();
    // Show only peers that are actually online; offline history stays out.
    this.peers = TailscaleManager.getPeers().filter((p: PeerInfo) => p.online);
  }

  /** UDP broadcast scan for AnySend instances on the same Wi-Fi. */
  private async scanLan(): Promise<void> {
    if (this.lanScanning) {
      return;
    }
    this.lanScanning = true;
    try {
      const list = await LanDiscovery.scan();
      // Hide our own responder answer.
      const selfIp = AutoConnect.queryLanIp();
      this.lanDevices = selfIp.length > 0
        ? list.filter((d: LanDevice) => d.ip !== selfIp)
        : list;
    } catch (e) {
      this.lanDevices = [];
    }
    this.lanScanning = false;
  }
}
