// 写短信页: pick a recipient, choose the SIM, write the body.
// On success jumps into the (possibly brand-new) thread.
// A NavDestination on the AppNav stack (was a router page).

import { promptAction } from '@kit.ArkUI';
import { SimCard, SmsMessage } from '../sms/SmsModels';
import { SmsStore } from '../sms/SmsStore';
import { Tokens } from '../common/DesignTokens';
import { AppNav } from '../common/AppNav';
import { defaultSendSubId, simBySubId } from '../sms/SmsUtil';

interface SimOption {
  subId: number;
  label: string;
}

/** Same shape as ArkUI SheetInfo minus the optional icon. */
interface MsgSheet {
  title: string;
  action: () => void;
}

@Component
export struct SmsComposePage {
  @State recipient: string = '';
  @State body: string = '';
  @State sims: SimCard[] = [];
  @State selectedSubId: number = 0;
  @State sending: boolean = false;
  private store: SmsStore = SmsStore.getInstance();

  aboutToAppear(): void {
    this.sims = this.store.sims;
    this.selectedSubId = defaultSendSubId(this.sims, -1);
    // Make sure we know the SIM list before the user picks one.
    if (this.sims.length === 0) {
      this.store.syncOnce().then(() => {
        this.sims = this.store.sims;
        this.selectedSubId = defaultSendSubId(this.sims, -1);
      });
    }
  }

  private simOptions(): SimOption[] {
    return this.sims.map((s: SimCard): SimOption => {
      return {
        subId: s.subscriptionId,
        label: `SIM${s.slotIndex} · ${s.displayName}（${s.carrierName}）`
      };
    });
  }

  private pickSim(): void {
    if (this.sims.length === 0) {
      promptAction.showToast({ message: '安卓设备未检测到 SIM 卡' });
      return;
    }
    const buttons: MsgSheet[] = this.simOptions().map((o: SimOption): MsgSheet => {
      return {
        title: o.label,
        action: () => {
          this.selectedSubId = o.subId;
        }
      };
    });
    this.getUIContext().showActionSheet({ title: '选择发送用的 SIM 卡', message: '', sheets: buttons });
  }

  build() {
    NavDestination() {
      Column() {
        // ---- Nav bar
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
            AppNav.stack.pop();
          })

          Text('新信息')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Blank()
        }
        .width('100%')
        .height(56)
        .padding({ left: 8, right: Tokens.SPACE_LG })
        .backgroundColor($r('app.color.card'))

        Scroll() {
          Column({ space: Tokens.SPACE_LG }) {
            // ---- Recipient
            Column({ space: 6 }) {
              Text('收件人')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_secondary'))
              TextInput({ placeholder: '输入手机号码', text: this.recipient })
                .type(InputType.PhoneNumber)
                .height(44)
                .borderRadius(Tokens.RADIUS_CTRL)
                .backgroundColor($r('app.color.field'))
                .placeholderColor($r('sys.color.font_tertiary'))
                .onChange((v: string) => {
                  this.recipient = v;
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // ---- SIM
            Column({ space: 6 }) {
              Text('使用的 SIM 卡')
                .fontSize(Tokens.FONT_CAPTION)
                .fontColor($r('sys.color.font_secondary'))
              Row({ space: 10 }) {
                ForEach(this.simOptions(), (o: SimOption) => {
                  Row({ space: 6 }) {
                    SymbolGlyph(o.subId === this.selectedSubId
                      ? $r('sys.symbol.checkmark_circle_fill')
                      : $r('sys.symbol.checkmark_circle'))
                      .fontSize(16)
                      .fontColor([o.subId === this.selectedSubId
                        ? $r('sys.color.brand')
                        : $r('sys.color.icon_tertiary')])
                    Text(o.label)
                      .fontSize(13)
                      .fontColor($r('sys.color.font_primary'))
                  }
                  .height(40)
                  .padding({ left: Tokens.SPACE_MD, right: Tokens.SPACE_MD })
                  .borderRadius(Tokens.RADIUS_CTRL)
                  .backgroundColor(o.subId === this.selectedSubId
                    ? $r('app.color.chip_bg')
                    : $r('app.color.field'))
                  .onClick(() => {
                    this.selectedSubId = o.subId;
                  })
                }, (o: SimOption) => `${o.subId}`)
                if (this.sims.length === 0) {
                  Text('未检测到 SIM 卡')
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                }
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // ---- Body
            Column({ space: 6 }) {
              Row() {
                Text('内容')
                  .fontSize(Tokens.FONT_CAPTION)
                  .fontColor($r('sys.color.font_secondary'))
                Blank()
                Text(`${this.body.length}/670`)
                  .fontSize(11)
                  .fontColor($r('sys.color.font_tertiary'))
              }
              .width('100%')
              TextArea({ placeholder: '输入短信内容…', text: this.body })
                .height(140)
                .borderRadius(Tokens.RADIUS_CTRL)
                .backgroundColor($r('app.color.field'))
                .placeholderColor($r('sys.color.font_tertiary'))
                .maxLength(670)
                .showCounter(false)
                .onChange((v: string) => {
                  this.body = v;
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            Button(this.sending ? '发送中…' : '发送')
              .width('100%')
              .height(46)
              .fontSize(Tokens.FONT_TITLE)
              .type(ButtonType.Capsule)
              .backgroundColor($r('sys.color.brand'))
              .opacity(!this.sending && this.recipient.trim().length > 0 && this.body.trim().length > 0 ? 1.0 : 0.4)
              .enabled(!this.sending && this.recipient.trim().length > 0 && this.body.trim().length > 0)
              .onClick(() => {
                this.send();
              })

            Text(this.hostHint())
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
          }
          .padding(Tokens.SPACE_LG)
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
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_bg'))
  }

  private hostHint(): string {
    const sim = simBySubId(this.selectedSubId, this.sims);
    const slot = sim !== null ? `${sim.slotIndex}` : '';
    return `将通过安卓设备「${this.store.hostName}」的 SIM${slot} 发送`;
  }

  private send(): void {
    const addr = this.recipient.trim();
    const body = this.body.trim();
    if (addr.length === 0 || body.length === 0 || this.sending) {
      return;
    }
    this.sending = true;
    this.store.sendMessage(addr, body, this.selectedSubId, -1)
      .then((sent: SmsMessage | null) => {
        this.sending = false;
        if (sent === null) {
          promptAction.showToast({ message: '发送失败：无法连接安卓设备' });
          return;
        }
        if (sent.clientStatus === 'failed') {
          // The host rejected the send (or was unreachable); show the real reason.
          promptAction.showToast({ message: sent.clientError ?? '发送失败' });
          return;
        }
        if (sent.threadId > 0) {
          const params: Record<string, Object> = {
            'threadId': sent.threadId,
            'address': addr,
            'contactName': ''
          };
          AppNav.stack.replacePathByName('SmsChatPage', params);
        } else {
          promptAction.showToast({ message: '发送失败' });
        }
      });
  }
}
