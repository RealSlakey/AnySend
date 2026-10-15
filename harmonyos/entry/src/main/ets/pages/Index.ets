import promptAction from '@ohos.promptAction';
import { TailscaleManager } from '../bridge/TailscaleManager';
import { LocalSendServer } from '../protocol/LocalSendServer';
import { createDeviceInfo } from '../protocol/LocalSendModels';
import { DirectNetworkLayer } from '../protocol/DirectNetworkLayer';
import { TailscaleNetworkLayer } from '../protocol/TailscaleNetworkLayer';
import { NetworkLayer } from '../protocol/NetworkLayer';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct Index {
  @State authKey: string = '';
  @State statusText: string = '未连接';
  @State peersText: string = '暂无在线设备';
  @State localIp: string = '--';
  @State serverRunning: boolean = false;
  private server: LocalSendServer | null = null;

  build() {
    Scroll() {
      Column() {
        // Tailscale mode
        Text('Tailscale Auth Key')
          .fontSize(14)
          .width('100%')
          .margin({ top: 16 })

        TextInput({ placeholder: 'tskey-auth-...', text: this.authKey })
          .type(InputType.Normal)
          .width('100%')
          .margin({ top: 8 })
          .onChange((value: string) => {
            this.authKey = value;
          })

        Button('登录 Tailscale 并启动接收')
          .width('100%')
          .margin({ top: 8 })
          .onClick(() => {
            this.login();
          })

        Text(`状态：${this.statusText}`)
          .fontSize(16)
          .width('100%')
          .margin({ top: 16 })

        Text('在线设备')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .margin({ top: 16 })

        Text(this.peersText)
          .fontSize(14)
          .width('100%')
          .margin({ top: 8 })

        Divider()
          .width('100%')
          .margin({ top: 24, bottom: 16 })

        // Direct LAN mode
        Text('直连局域网模式（无需 Tailscale）')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .width('100%')

        Button(this.serverRunning ? '接收服务已启动' : '启动接收服务（直连模式）')
          .width('100%')
          .margin({ top: 8 })
          .enabled(!this.serverRunning)
          .onClick(() => {
            this.startDirectServer();
          })

        Text(`本机 IP：${this.localIp}`)
          .fontSize(14)
          .width('100%')
          .margin({ top: 8 })

        Text('提示：两台设备连同一 Wi-Fi，发送端在分享时输入此 IP')
          .fontSize(12)
          .fontColor('#888888')
          .width('100%')
          .margin({ top: 4 })
      }
      .padding(16)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  async login() {
    if (this.authKey.length === 0) {
      promptAction.showToast({ message: '请输入 Tailscale Auth Key' });
      return;
    }
    this.statusText = '正在连接 Tailscale...';
    const ok = await TailscaleManager.login(this.authKey);
    if (ok) {
      this.statusText = 'Tailscale 已连接';
      await this.refreshPeers();
      this.startServer(new TailscaleNetworkLayer());
    } else {
      this.statusText = 'Tailscale 连接失败（可改用直连模式）';
    }
  }

  async refreshPeers() {
    const peers = await TailscaleManager.getPeers();
    if (peers.length === 0) {
      this.peersText = '暂无在线设备';
    } else {
      this.peersText = peers.map(p => `${p.hostName} (${p.tailscaleIP})`).join('\n');
    }
  }

  startDirectServer() {
    const ip = this.getLocalIpAddress();
    if (!ip) {
      promptAction.showToast({ message: '未检测到局域网 IP，请检查 Wi-Fi 连接' });
      return;
    }
    this.localIp = ip;
    this.startServer(new DirectNetworkLayer());
    this.statusText = '直连模式已启动，监听 53317 端口';
    promptAction.showToast({ message: '接收服务已启动（直连模式）' });
  }

  private startServer(network: NetworkLayer) {
    if (this.server) {
      this.server.stop();
    }
    const self = createDeviceInfo('HarmonyOS Device', 'HarmonyOS', this.generateUUID());
    const context = getContext() as common.UIAbilityContext;
    this.server = new LocalSendServer(context, self, network);
    this.server.start();
    this.serverRunning = true;
  }

  private getLocalIpAddress(): string {
    // HarmonyOS does not expose a simple API to enumerate network
    // interfaces. Return a placeholder; the user can look up their IP
    // in Wi-Fi settings. In practice the device's LAN IP is shown by
    // the system Wi-Fi status.
    return '请在 Wi-Fi 设置中查看本机 IP';
  }

  private generateUUID(): string {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }

  aboutToAppear() {
    this.refreshPeers();
  }

  aboutToDisappear() {
    if (this.server) {
      this.server.stop();
      this.server = null;
    }
  }
}
