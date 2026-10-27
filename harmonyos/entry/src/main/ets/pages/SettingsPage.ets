// 设置 Tab: pair with the Android SMS host, request notifications, and show
// relay status (SIMs, connection state).

import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { TailscaleManager } from '../bridge/TailscaleManager';
import { SimCard } from '../sms/SmsModels';
import { SmsStore } from '../sms/SmsStore';
import { LocalSendConst } from '../protocol/LocalSendModels';
import { DirectNetworkLayer } from '../protocol/DirectNetworkLayer';
import { Tokens } from '../common/DesignTokens';
import { CardContainer } from '../common/CardContainer';
import { DeviceProfile } from '../common/DeviceProfile';
import { AutoConnect, ConnectPhase } from '../common/AutoConnect';

interface PeerRow {
  label: string;
  address: string;
  online: boolean;
}

@Component
export struct SettingsPage {
  @State hostAddress: string = '';
  @State hostName: string = '';
  @State token: string = '';
  @State manualHost: string = '';
  @State peers: PeerRow[] = [];
  @State online: boolean = false;
  @State sims: SimCard[] = [];
  @State testing: boolean = false;
  @State deviceName: string = '';
  // ---- connection card state (moved from the devices tab)
  @State authKey: string = '';
  @State connText: string = '未连接';
  @State connOk: boolean = false;
  @State serverRunning: boolean = false;
  @StorageLink('smsTab') @Watch('onTabShown') tabIdx: number = 0;
  private store: SmsStore = SmsStore.getInstance();
  private listCb: () => void = () => {
    this.pullState();
  };
  private connCb: () => void = () => {
    this.syncFromAutoConnect();
  };

  aboutToAppear(): void {
    this.hostAddress = this.store.hostAddress;
    this.hostName = this.store.hostName;
    this.token = this.store.token;
    this.deviceName = DeviceProfile.customName();
    this.pullState();
    this.store.onListChange(this.listCb);
    AutoConnect.onChange(this.connCb);
    this.syncFromAutoConnect();
    this.refreshPeers();
  }

  /** Re-discover peers when the user switches back to this tab. */
  private onTabShown(): void {
    if (this.tabIdx !== 2) {
      return;
    }
    // Re-read the SMS host too — it may have been changed from the devices
    // tab long-press menu while this page stayed alive.
    this.hostAddress = this.store.hostAddress;
    this.hostName = this.store.hostName;
    this.token = this.store.token;
    this.pullState();
    this.syncFromAutoConnect();
    this.refreshPeers();
  }

  aboutToDisappear(): void {
    this.store.offListChange(this.listCb);
    AutoConnect.offChange(this.connCb);
  }

  private pullState(): void {
    this.online = this.store.online;
    this.sims = this.store.sims;
  }

  /** Mirror AutoConnect's phase into the connection card. */
  private syncFromAutoConnect(): void {
    this.serverRunning = AutoConnect.isServerRunning();
    const phase: ConnectPhase = AutoConnect.getPhase();
    if (phase === 'running') {
      this.connText = 'Tailscale 已连接';
      this.connOk = true;
    } else if (phase === 'connecting') {
      this.connText = AutoConnect.getStatusText();
      this.connOk = false;
    } else if (phase === 'failed') {
      this.connText = AutoConnect.getStatusText();
      this.connOk = false;
    } else if (this.serverRunning) {
      this.connText = '直连模式运行中';
      this.connOk = true;
    } else {
      this.connText = '未连接';
      this.connOk = false;
    }
  }

  private async login(): Promise<void> {
    if (this.authKey.trim().length === 0) {
      promptAction.showToast({ message: '请输入 Tailscale Auth Key' });
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const ok = await AutoConnect.manualLogin(this.authKey.trim(), context);
    if (!ok) {
      promptAction.showToast({ message: AutoConnect.getStatusText() });
    }
    this.syncFromAutoConnect();
  }

  private startDirectServer(): void {
    const context = getContext(this) as common.UIAbilityContext;
    AutoConnect.startServer(new DirectNetworkLayer(), context);
    this.connText = '直连模式已启动';
    this.connOk = true;
    this.serverRunning = true;
    promptAction.showToast({ message: '接收服务已启动（直连模式）' });
  }

  private async refreshPeers(): Promise<void> {
    // Refresh via the worker (no cgo on the UI thread), then read the cache.
    // Show ALL tailnet peers (offline ones greyed out) — filtering by online
    // hid devices whenever the status cache was stale.
    await TailscaleManager.refreshStatus();
    const rows: PeerRow[] = [];
    const peers = TailscaleManager.getPeers();
    for (const p of peers) {
      rows.push({
        label: p.hostName,
        address: `${p.tailscaleIP}:${LocalSendConst.PORT}`,
        online: p.online
      });
    }
    this.peers = rows;
  }

  private saveHost(address: string, name: string): void {
    if (this.token.trim().length === 0) {
      promptAction.showToast({ message: '请先填写安卓端显示的配对码' });
      return;
    }
    this.store.setHost(address, name, this.token);
    this.hostAddress = address;
    this.hostName = name;
    promptAction.showToast({ message: '已保存，正在连接…' });
    this.store.startPolling();
    this.store.syncOnce();
  }

  private testConnection(): void {
    if (this.hostAddress.length === 0 || this.token.length === 0) {
      promptAction.showToast({ message: '请先完成配对配置' });
      return;
    }
    const client = this.store.client();
    if (client === null) {
      promptAction.showToast({ message: '配置不完整' });
      return;
    }
    this.testing = true;
    client.ping()
      .then((ok: boolean) => {
        this.testing = false;
        if (ok) {
          promptAction.showToast({ message: '连接成功' });
          this.store.startPolling();
          this.store.syncOnce();
        } else {
          promptAction.showToast({ message: '连接失败：检查 IP、接收服务和配对码' });
        }
      });
  }

  build() {
    Column() {
      Text('设置')
        .fontSize(Tokens.FONT_H1)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, top: 14, bottom: Tokens.SPACE_SM })

      Scroll() {
        Column({ space: Tokens.SPACE_MD }) {
          // ---- 连接（原「传输」页的 Tailscale / 直连设置）
          CardContainer() {
            Row() {
              Text('连接')
                .fontSize(Tokens.FONT_TITLE)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
              Row({ space: 6 }) {
                Circle({ width: 8, height: 8 })
                  .fill(this.connOk ? $r('app.color.success') : $r('sys.color.icon_tertiary'))
                Text(this.connText)
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(1)
              }
            }
            .width('100%')

            Text('Tailscale：跨网段安全连接，无需同一局域网')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .margin({ top: 10 })

            TextInput({ placeholder: 'tskey-auth-...', text: this.authKey })
              .type(InputType.Normal)
              .height(44)
              .borderRadius(Tokens.RADIUS_CTRL)
              .backgroundColor($r('app.color.field'))
              .placeholderColor($r('sys.color.font_tertiary'))
              .width('100%')
              .margin({ top: 10 })
              .onChange((value: string) => {
                this.authKey = value;
              })

            Button('登录 Tailscale 并启动接收')
              .width('100%')
              .height(44)
              .backgroundColor($r('sys.color.brand'))
              .margin({ top: 10 })
              .onClick(() => {
                this.login();
              })

            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ top: 12, bottom: 10 })

            Text('直连局域网：两台设备连接同一 Wi-Fi 即可')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')

            Button(this.serverRunning ? '接收服务已启动' : '启动接收服务（直连模式）')
              .width('100%')
              .height(44)
              .margin({ top: 10 })
              .enabled(!this.serverRunning)
              .backgroundColor(this.serverRunning
                ? $r('sys.color.comp_background_tertiary')
                : $r('sys.color.brand'))
              .fontColor(this.serverRunning ? $r('sys.color.font_tertiary') : $r('sys.color.font_on_primary'))
              .onClick(() => {
                this.startDirectServer();
              })
          }

          // ---- 本机设备名
          CardContainer() {
            Text('本机设备名')
              .fontSize(Tokens.FONT_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')

            Text('其他设备在收发文件时看到的名字，留空则显示默认名「HarmonyOS Device」')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .margin({ top: 2 })

            Row({ space: Tokens.SPACE_SM }) {
              TextInput({ placeholder: '例如：我的鸿蒙手机', text: this.deviceName })
                .height(44)
                .layoutWeight(1)
                .borderRadius(Tokens.RADIUS_CTRL)
                .backgroundColor($r('app.color.field'))
                .placeholderColor($r('sys.color.font_tertiary'))
                .maxLength(30)
                .onChange((v: string) => {
                  this.deviceName = v;
                })
              Button('保存')
                .height(44)
                .backgroundColor($r('sys.color.brand'))
                .onClick(() => {
                  const context = getContext(this) as common.UIAbilityContext;
                  DeviceProfile.saveName(context, this.deviceName);
                  promptAction.showToast({ message: '已保存' });
                })
            }
            .width('100%')
            .margin({ top: 10 })
            .alignItems(VerticalAlign.Center)
          }

          // ---- 安卓短信设备
          CardContainer() {
            Row() {
              Text('安卓短信设备')
                .fontSize(Tokens.FONT_TITLE)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
              Text('刷新')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.brand'))
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .onClick(() => {
                  this.refreshPeers();
                })
            }
            .width('100%')

            if (this.peers.length > 0) {
              Text('通过 Tailscale 发现的全部设备（灰色为离线，点击选用）')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .margin({ top: 10 })
              ForEach(this.peers, (p: PeerRow) => {
                Row({ space: Tokens.SPACE_SM }) {
                  Circle({ width: 8, height: 8 })
                    .fill(p.online ? $r('app.color.success') : $r('sys.color.icon_tertiary'))
                  Text(p.label)
                    .fontSize(Tokens.FONT_BODY)
                    .fontColor(p.online ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(p.address)
                    .fontSize(11)
                    .fontColor($r('sys.color.font_tertiary'))
                  SymbolGlyph(p.address === this.hostAddress
                    ? $r('sys.symbol.checkmark_circle_fill')
                    : $r('sys.symbol.chevron_right'))
                    .fontSize(16)
                    .fontColor([p.address === this.hostAddress
                      ? $r('sys.color.brand')
                      : $r('sys.color.icon_tertiary')])
                }
                .width('100%')
                .height(Tokens.TARGET_MIN + 8)
                .padding({ left: Tokens.SPACE_MD, right: Tokens.SPACE_MD })
                .borderRadius(Tokens.RADIUS_CTRL)
                .backgroundColor(p.address === this.hostAddress
                  ? $r('app.color.chip_bg')
                  : $r('app.color.field'))
                .margin({ top: 6 })
                .onClick(() => {
                  if (!p.online) {
                    promptAction.showToast({ message: '该设备当前离线' });
                    return;
                  }
                  this.saveHost(p.address, p.label);
                })
              }, (p: PeerRow) => p.address)
            }

            Text(this.peers.length > 0 ? '或手动输入地址（直连局域网模式）' : '手动输入安卓设备地址（直连局域网模式）')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .margin({ top: 10 })
            TextInput({ placeholder: '例如 192.168.5.108:53317', text: this.manualHost })
              .height(44)
              .borderRadius(Tokens.RADIUS_CTRL)
              .backgroundColor($r('app.color.field'))
              .placeholderColor($r('sys.color.font_tertiary'))
              .type(InputType.Normal)
              .onChange((v: string) => {
                this.manualHost = v;
              })
            Button('使用该地址')
              .width('100%')
              .height(44)
              .margin({ top: 10 })
              .backgroundColor($r('sys.color.brand'))
              .onClick(() => {
                const addr = this.manualHost.trim();
                if (addr.length === 0) {
                  promptAction.showToast({ message: '请输入地址' });
                  return;
                }
                this.saveHost(addr, addr.split(':')[0]);
              })

            if (this.hostAddress.length > 0) {
              Row({ space: Tokens.SPACE_SM }) {
                Circle({ width: 8, height: 8 })
                  .fill(this.online ? $r('app.color.success') : $r('app.color.danger'))
                Text(`当前：${this.hostName}（${this.online ? '已连接' : '未连接'}）`)
                  .fontSize(13)
                  .fontColor($r('sys.color.font_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .margin({ top: 10 })
            }
          }

          // ---- 配对码
          CardContainer() {
            Text('配对码')
              .fontSize(Tokens.FONT_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
            Text('在安卓端主界面「短信中继」区域查看配对码，填到这里。配对码用于验证身份，防止局域网内其他设备读取你的短信。')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_secondary'))
              .lineHeight(18)
              .width('100%')
              .margin({ top: 6 })
            TextInput({ placeholder: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx', text: this.token })
              .height(44)
              .borderRadius(Tokens.RADIUS_CTRL)
              .backgroundColor($r('app.color.field'))
              .placeholderColor($r('sys.color.font_tertiary'))
              .type(InputType.Normal)
              .margin({ top: 10 })
              .onChange((v: string) => {
                this.token = v;
              })
            Row({ space: 10 }) {
              Button('保存并连接')
                .layoutWeight(1)
                .height(44)
                .backgroundColor($r('sys.color.brand'))
                .onClick(() => {
                  if (this.hostAddress.length === 0) {
                    promptAction.showToast({ message: '请先选择或输入设备地址' });
                    return;
                  }
                  this.saveHost(this.hostAddress, this.hostName);
                })
              Button(this.testing ? '测试中…' : '测试连接')
                .layoutWeight(1)
                .height(44)
                .backgroundColor($r('sys.color.comp_background_emphasize'))
                .fontColor($r('sys.color.font_on_primary'))
                .enabled(!this.testing)
                .opacity(this.testing ? 0.5 : 1.0)
                .onClick(() => {
                  this.testConnection();
                })
            }
            .width('100%')
            .margin({ top: 10 })
          }

          // ---- 通知与状态
          CardContainer() {
            Text('新短信通知')
              .fontSize(Tokens.FONT_TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
            Text('允许通知后，安卓收到新短信会实时推送到本机并弹通知。')
              .fontSize(Tokens.FONT_CAPTION)
              .fontColor($r('sys.color.font_secondary'))
              .lineHeight(18)
              .width('100%')
              .margin({ top: 6 })
            Button('开启通知权限')
              .width('100%')
              .height(44)
              .margin({ top: 10 })
              .backgroundColor($r('sys.color.brand'))
              .onClick(() => {
                this.requestNotifications();
              })

            if (this.sims.length > 0) {
              Divider()
                .color($r('sys.color.comp_divider'))
                .margin({ top: 12, bottom: 8 })
              Text('安卓端 SIM 卡')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
              ForEach(this.sims, (s: SimCard) => {
                Row({ space: 6 }) {
                  SymbolGlyph(s.slotIndex === 0
                    ? $r('sys.symbol.simcard_1')
                    : $r('sys.symbol.simcard_2'))
                    .fontSize(16)
                    .fontColor([$r('sys.color.icon_secondary')])
                  Text(`SIM${s.slotIndex}：${s.displayName}（${s.carrierName}）`)
                    .fontSize(Tokens.FONT_CAPTION)
                    .fontColor($r('sys.color.font_secondary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
              }, (s: SimCard) => `${s.subscriptionId}`)
            }
          }
        }
        .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, bottom: Tokens.SPACE_XL })
        .width('100%')
        .constraintSize({ maxWidth: Tokens.CONTENT_MAX_WIDTH })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  private requestNotifications(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.store.requestNotification(context)
      .then(() => {
        promptAction.showToast({ message: '已请求通知权限' });
      });
  }
}
