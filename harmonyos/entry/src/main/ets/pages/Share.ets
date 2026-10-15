import { TailscaleManager, PeerInfo } from '../bridge/TailscaleManager';
import { LocalSendSender } from '../protocol/LocalSendSender';
import { DirectNetworkLayer } from '../protocol/DirectNetworkLayer';
import { TailscaleNetworkLayer } from '../protocol/TailscaleNetworkLayer';
import { NetworkLayer } from '../protocol/NetworkLayer';
import { createDeviceInfo } from '../protocol/LocalSendModels';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import promptAction from '@ohos.promptAction';

@Entry
@Component
struct Share {
  @State peers: PeerInfo[] = [];
  @State fileNames: string = '';
  @State progress: number = 0;
  @State progressText: string = '';
  @State sending: boolean = false;
  @State targetIp: string = '';
  private sharedUris: string[] = AppStorage.get('sharedUris') ?? [];

  build() {
    Column() {
      Text('选择接收设备')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .margin({ top: 16 })

      Text(`待发送：${this.fileNames}`)
        .fontSize(14)
        .width('100%')
        .margin({ top: 8 })

      // Direct IP input
      Text('直连模式：输入接收方 IP')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .margin({ top: 12 })

      TextInput({ placeholder: '192.168.x.x', text: this.targetIp })
        .type(InputType.Normal)
        .width('100%')
        .margin({ top: 8 })
        .onChange((value: string) => {
          this.targetIp = value;
        })

      Button('发送到该 IP')
        .width('100%')
        .margin({ top: 8 })
        .onClick(() => {
          const ip = this.targetIp.trim();
          if (ip.length === 0) {
            promptAction.showToast({ message: '请输入接收方 IP' });
            return;
          }
          this.sendToIp(ip, new DirectNetworkLayer());
        })

      Text('或从 Tailscale 在线设备中选择')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .margin({ top: 16 })

      if (this.peers.length === 0) {
        Text('暂无在线设备（请使用上方直连模式）')
          .fontSize(14)
          .width('100%')
          .margin({ top: 16 })
      } else {
        List() {
          ForEach(this.peers, (peer: PeerInfo) => {
            ListItem() {
              Row() {
                Text(`${peer.hostName}`)
                  .fontSize(16)
                  .layoutWeight(1)
                Text(peer.tailscaleIP)
                  .fontSize(12)
                  .fontColor('#999')
              }
              .width('100%')
              .padding(16)
              .onClick(() => {
                this.sendToIp(peer.tailscaleIP, new TailscaleNetworkLayer());
              })
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
      }

      if (this.sending) {
        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .margin({ top: 16 })
        Text(this.progressText)
          .fontSize(14)
          .width('100%')
          .margin({ top: 8 })
      }

      Button('关闭')
        .width('100%')
        .margin({ top: 16 })
        .onClick(() => {
          this.closeShare();
        })
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }

  async aboutToAppear() {
    this.fileNames = this.sharedUris.map(uri => {
      const clean = uri.split('?')[0];
      const idx = clean.lastIndexOf('/');
      return idx >= 0 ? clean.substring(idx + 1) : clean;
    }).join(', ');

    this.peers = TailscaleManager.getPeers().filter(p => p.online);
  }

  async sendToIp(ip: string, network: NetworkLayer) {
    if (this.sharedUris.length === 0) {
      return;
    }
    this.sending = true;
    this.progressText = `正在发送到 ${ip}...`;
    const self = createDeviceInfo('HarmonyOS Device', 'HarmonyOS', this.generateUUID());
    const sender = new LocalSendSender(ip, self, network);

    const receiver = await sender.register();
    if (!receiver) {
      this.progressText = `无法连接到 ${ip}`;
      this.sending = false;
      return;
    }

    const result = await sender.sendRequest(this.sharedUris);
    if (!result) {
      this.progressText = '发送请求被拒绝';
      this.sending = false;
      return;
    }

    const accepted = Object.entries(result.response.files).filter(([, v]) => v === 'accept');
    if (accepted.length === 0) {
      this.progressText = '所有文件被拒绝';
      this.sending = false;
      return;
    }

    let totalBytes = 0;
    for (const [fileId] of accepted) {
      const path = result.fileIdToPath[fileId];
      if (path) {
        try {
          const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
          const stat = fs.fstatSync(f.fd);
          totalBytes += stat.size;
          fs.closeSync(f);
        } catch (e) {
        }
      }
    }

    let sentBytes = 0;
    let allOk = true;
    for (const [fileId] of accepted) {
      const filePath = result.fileIdToPath[fileId];
      if (!filePath) {
        continue;
      }
      const ok = await sender.sendFile(result.response.sessionId, fileId, filePath, (sent, total) => {
        const overall = sentBytes + sent;
        this.progress = totalBytes > 0 ? Math.floor((overall / totalBytes) * 100) : 0;
        this.progressText = `发送中 ${Math.floor(overall / 1024)}/${Math.floor(totalBytes / 1024)} KB`;
      });
      if (!ok) {
        allOk = false;
        break;
      }
      try {
        const f = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
        sentBytes += fs.fstatSync(f.fd).size;
        fs.closeSync(f);
      } catch (e) {
      }
    }

    if (allOk) {
      this.progressText = `发送完成（${accepted.length} 个文件）`;
      this.progress = 100;
      promptAction.showToast({ message: '发送完成' });
    } else {
      this.progressText = '发送失败';
    }
    this.sending = false;
  }

  closeShare() {
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
