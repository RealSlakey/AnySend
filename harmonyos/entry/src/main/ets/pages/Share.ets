// Share sheet: pick a receiver for the files being sent, either direct IP or
// a Tailscale peer, with progress feedback.
//
// Two entry points:
//  - ShareAbility loads 'pages/Share' (system share sheet) — @Entry wrapper.
//  - In-app "分享文件至它" pushes 'SharePage' on the Nav stack, preselecting
//    the target device (AppStorage 'shareTargetIp').

import { TailscaleManager, PeerInfo } from '../bridge/TailscaleManager';
import { LocalSendSender, SendOutcomeKind, SendRequestResult } from '../protocol/LocalSendSender';
import { DirectNetworkLayer } from '../protocol/DirectNetworkLayer';
import { TailscaleNetworkLayer } from '../protocol/TailscaleNetworkLayer';
import { NetworkLayer } from '../protocol/NetworkLayer';
import { createDeviceInfo } from '../protocol/LocalSendModels';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import promptAction from '@ohos.promptAction';
import { Tokens } from '../common/DesignTokens';
import { CardContainer } from '../common/CardContainer';
import { DeviceProfile } from '../common/DeviceProfile';
import { DefaultTargets } from '../common/DefaultTargets';
import { AppNav } from '../common/AppNav';
import { HistoryStore } from '../common/HistoryStore';

/** In-app share destination (NavDestination on the main Nav stack). */
@Component
export struct SharePage {
  build() {
    NavDestination() {
      ShareView({ navMode: true })
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_bg'))
  }
}

/** System-share entry (ShareAbility loads this page directly). */
@Entry
@Component
struct Share {
  build() {
    Column() {
      ShareView()
    }
    .width('100%')
    .height('100%')
  }
}

@Component
struct ShareView {
  @Prop navMode: boolean = false;
  @State peers: PeerInfo[] = [];
  @State fileNames: string = '';
  @State progress: number = 0;
  @State progressText: string = '';
  @State sending: boolean = false;
  @State targetIp: string = '';
  @State targetName: string = '';
  /** 配对码：官方 LocalSend 开启 PIN 保护时才需要，留空即可。 */
  @State pin: string = '';
  // Share Kit resolves the shared records asynchronously, so stay bound to the
  // AppStorage entry instead of snapshotting it when the component is built.
  @StorageLink('sharedUris') @Watch('onSharedUrisChanged') sharedUris: string[] = [];

  build() {
    Column() {
      Text(this.navMode ? '发送至设备' : '选择接收设备')
        .fontSize(Tokens.FONT_H2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .margin({ top: Tokens.SPACE_LG })

      Text(`待发送：${this.fileNames}`)
        .fontSize(Tokens.FONT_BODY)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: Tokens.SPACE_SM })

      Scroll() {
        Column() {
          // ---- direct IP
          CardContainer() {
            Text('直连模式')
              .fontSize(Tokens.FONT_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text('输入接收方 IP，两台设备需在同一局域网')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_secondary'))
              .margin({ top: 2 })
            TextInput({ placeholder: '192.168.x.x', text: this.targetIp })
              .type(InputType.Normal)
              .height(44)
              .borderRadius(Tokens.RADIUS_CTRL)
              .backgroundColor($r('app.color.field'))
              .placeholderColor($r('sys.color.font_tertiary'))
              .width('100%')
              .margin({ top: 10 })
              .onChange((value: string) => {
                this.targetIp = value;
              })
            // 可选：官方 LocalSend 开了 PIN 保护时填写，AnySend 之间留空
            TextInput({ placeholder: '配对码 PIN（对方未开启可留空）', text: this.pin })
              .type(InputType.Normal)
              .height(44)
              .borderRadius(Tokens.RADIUS_CTRL)
              .backgroundColor($r('app.color.field'))
              .placeholderColor($r('sys.color.font_tertiary'))
              .width('100%')
              .margin({ top: 8 })
              .onChange((value: string) => {
                this.pin = value;
              })
            Button('发送到该 IP')
              .width('100%')
              .height(44)
              .backgroundColor($r('sys.color.brand'))
              .margin({ top: 10 })
              .onClick(() => {
                const ip = this.targetIp.trim();
                if (ip.length === 0) {
                  promptAction.showToast({ message: '请输入接收方 IP' });
                  return;
                }
                // Auto-pick the stack: 100.64.0.0/10 (100.x) routes through
                // Tailscale's userspace netstack, everything else is direct LAN.
                const net = ip.startsWith('100.') ? new TailscaleNetworkLayer() : new DirectNetworkLayer();
                const name = this.targetName.trim().length > 0 ? this.targetName.trim() : ip;
                this.sendToIp(ip, net, name);
              })
          }

          // ---- tailscale peers
          CardContainer() {
            Text('Tailscale 在线设备')
              .fontSize(Tokens.FONT_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            if (this.peers.length === 0) {
              Column({ space: Tokens.SPACE_SM }) {
                SymbolGlyph($r('sys.symbol.wifi_slash'))
                  .fontSize(28)
                  .fontColor([$r('sys.color.icon_tertiary')])
                Text('暂无在线设备（可使用上方直连模式）')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_tertiary'))
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 12, bottom: 4 })
            } else {
              ForEach(this.peers, (peer: PeerInfo) => {
                Row({ space: Tokens.SPACE_MD }) {
                  Text(peer.hostName.substring(0, 1).toUpperCase())
                    .fontSize(Tokens.FONT_TITLE)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(Color.White)
                    .width(36)
                    .height(36)
                    .textAlign(TextAlign.Center)
                    .borderRadius(18)
                    .backgroundColor($r('sys.color.brand'))
                  Column() {
                    Text(peer.hostName)
                      .fontSize(Tokens.FONT_BODY)
                      .fontColor($r('sys.color.font_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(peer.tailscaleIP)
                      .fontSize(Tokens.FONT_CAPTION)
                      .fontColor($r('sys.color.font_tertiary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .margin({ left: 10 })
                  SymbolGlyph($r('sys.symbol.paperplane_fill'))
                    .fontSize(18)
                    .fontColor([$r('sys.color.brand')])
                }
                .width('100%')
                .height(Tokens.TARGET_MIN + 12)
                .margin({ top: 6 })
                .onClick(() => {
                  this.sendToIp(peer.tailscaleIP, new TailscaleNetworkLayer(), peer.hostName);
                })
              }, (peer: PeerInfo) => peer.tailscaleIP)
            }
          }

          // ---- progress
          if (this.sending || this.progress > 0) {
            CardContainer() {
              Row() {
                Text(this.progressText)
                  .fontSize(Tokens.FONT_BODY)
                  .fontColor($r('sys.color.font_primary'))
                  .layoutWeight(1)
                if (this.progress > 0 && !this.sending) {
                  SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                    .fontSize(18)
                    .fontColor([$r('app.color.success')])
                }
              }
              .width('100%')
              Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
                .width('100%')
                .margin({ top: Tokens.SPACE_SM })
                .color($r('sys.color.brand'))
            }
          }
        }
        .width('100%')
        .padding({ top: Tokens.SPACE_MD })
        .constraintSize({ maxWidth: Tokens.CONTENT_MAX_WIDTH })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      Button('关闭')
        .width('100%')
        .height(44)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .margin({ bottom: Tokens.SPACE_LG })
        .onClick(() => {
          this.closeShare();
        })
    }
    .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  onSharedUrisChanged() {
    this.refreshFileNames();
  }

  refreshFileNames() {
    this.fileNames = this.sharedUris.map(uri => {
      const clean = uri.split('?')[0];
      const idx = clean.lastIndexOf('/');
      return idx >= 0 ? clean.substring(idx + 1) : clean;
    }).join(', ');
  }

  async aboutToAppear() {
    this.refreshFileNames();

    // Preselect target: explicit in-app pick first, then the saved default.
    const preset = AppStorage.get<string>('shareTargetIp') ?? '';
    AppStorage.setOrCreate('shareTargetIp', '');
    const presetName = AppStorage.get<string>('shareTargetName') ?? '';
    AppStorage.setOrCreate('shareTargetName', '');
    if (preset.length > 0) {
      this.targetIp = preset;
      this.targetName = presetName;
    } else {
      const context = getContext(this) as common.UIAbilityContext;
      await DefaultTargets.load(context);
      this.targetIp = DefaultTargets.shareIp();
      this.targetName = DefaultTargets.shareName();
    }

    // Refresh via the worker (no cgo on the UI thread), then read the cache.
    await TailscaleManager.refreshStatus();
    this.peers = TailscaleManager.getPeers().filter(p => p.online);
  }

  async sendToIp(ip: string, network: NetworkLayer, peerName: string) {
    if (this.sharedUris.length === 0) {
      return;
    }
    this.sending = true;
    this.progress = 0;
    this.progressText = `正在发送到 ${ip}...`;
    const self = createDeviceInfo(DeviceProfile.displayName(), 'HarmonyOS', DeviceProfile.fingerprint());
    const sender = new LocalSendSender(ip, self, network);
    // Release the HTTPS session on every exit path (rcp caps live sessions).
    const stop = (): void => {
      this.sending = false;
      sender.close();
    };

    const receiver = await sender.register();
    if (!receiver) {
      this.progressText = sender.peerNeedsTls
        ? '对方只接受 HTTPS（自签证书）；加密连接未能建立，请改用同一 Wi-Fi 直连后再试'
        : `无法连接到 ${ip}`;
      stop();
      return;
    }

    const outcome = await sender.sendRequest(this.sharedUris, this.pin);
    if (outcome.kind === SendOutcomeKind.NEED_PIN) {
      this.progressText = '对方需要配对码，请填写 PIN 后重试';
      stop();
      return;
    }
    if (outcome.kind === SendOutcomeKind.WRONG_PIN) {
      this.progressText = '配对码错误';
      stop();
      return;
    }
    if (outcome.kind !== SendOutcomeKind.ACCEPTED || !outcome.result) {
      this.progressText = outcome.status > 0
        ? `发送请求被拒绝（HTTP ${outcome.status}）`
        : '连接中断';
      stop();
      return;
    }
    const result = outcome.result as SendRequestResult;

    // v2 wire format: response.files maps fileId -> per-file upload token
    const accepted: string[] = Object.keys(result.response.files);
    if (accepted.length === 0) {
      this.progressText = '所有文件被拒绝';
      stop();
      return;
    }

    let totalBytes = 0;
    for (let i = 0; i < accepted.length; i++) {
      const path = result.fileIdToPath[accepted[i]];
      if (path) {
        try {
          const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
          const stat = fs.statSync(f.fd);
          totalBytes += stat.size;
          fs.closeSync(f);
        } catch (e) {
        }
      }
    }

    let sentBytes = 0;
    let allOk = true;
    for (let i = 0; i < accepted.length; i++) {
      const fileId = accepted[i];
      const filePath = result.fileIdToPath[fileId];
      if (!filePath) {
        continue;
      }
      const ok = await sender.sendFile(result.response.sessionId, fileId,
        result.response.files[fileId] ?? '', filePath, (sent, total) => {
        const overall = sentBytes + sent;
        this.progress = totalBytes > 0 ? Math.floor((overall / totalBytes) * 100) : 0;
        this.progressText = `发送中 ${Math.floor(overall / 1024)}/${Math.floor(totalBytes / 1024)} KB`;
      });
      if (!ok) {
        allOk = false;
        // Release the receiver's single session slot, otherwise the next send
        // is rejected with 409 until the receiving app is restarted.
        await sender.cancelSession(result.response.sessionId);
        break;
      }
      try {
        const f = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
        sentBytes += fs.statSync(f.fd).size;
        fs.closeSync(f);
      } catch (e) {
      }
    }

    if (allOk) {
      // Record every delivered file in the transfer history.
      const context = getContext(this) as common.UIAbilityContext;
      const peer = peerName && peerName.length > 0 ? peerName : ip;
      for (let i = 0; i < accepted.length; i++) {
        const filePath = result.fileIdToPath[accepted[i]];
        if (!filePath) {
          continue;
        }
        let size = 0;
        try {
          const f = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
          size = fs.statSync(f.fd).size;
          fs.closeSync(f);
        } catch (e) {
        }
        const name = filePath.substring(filePath.lastIndexOf('/') + 1);
        await HistoryStore.add(context, {
          id: this.generateUUID(),
          direction: 'send',
          peer: peer,
          fileName: name,
          size: size,
          time: Date.now(),
          path: filePath
        });
      }
      this.progressText = `发送完成（${accepted.length} 个文件）`;
      this.progress = 100;
      promptAction.showToast({ message: '发送完成' });
      if (this.navMode) {
        setTimeout(() => {
          AppNav.stack.pop();
        }, 800);
      }
    } else {
      this.progressText = '发送失败';
    }
    stop();
  }

  closeShare() {
    if (this.navMode) {
      AppNav.stack.pop();
      return;
    }
    (getContext() as common.UIAbilityContext).terminateSelf();
  }

  private generateUUID(): string {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }
}
