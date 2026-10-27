// 聊天页: message bubbles for one thread, with day dividers, per-message
// SIM chips, long-press copy/delete, history paging (scroll to top) and an
// input bar with a SIM selector + offline hint.
// A NavDestination on the AppNav stack (was a router page).

import { promptAction, UIContext } from '@kit.ArkUI';
import pasteboard from '@ohos.pasteboard';
import { SimCard, SmsMessage } from '../sms/SmsModels';
import { SmsStore } from '../sms/SmsStore';
import { Tokens } from '../common/DesignTokens';
import { AppNav } from '../common/AppNav';
import { ArrayDataSource } from '../common/ArrayDataSource';
import {
  avatarColor,
  avatarText,
  defaultSendSubId,
  displayNameOf,
  formatBubbleTime,
  formatDayDivider,
  simBySubId,
  simLabel
} from '../sms/SmsUtil';

interface ChatParams {
  threadId: number;
  address: string;
  contactName: string;
}

/** Same shape as ArkUI SheetInfo minus the optional icon. */
interface MsgSheet {
  title: string;
  action: () => void;
}

/** Flattened list row: history header, a day divider or a message bubble. */
interface ChatItem {
  key: string;
  kind: number; // 0=header 1=day 2=message
  label: string;
  msg: SmsMessage | null;
}

@Component
export struct SmsChatPage {
  @State sims: SimCard[] = [];
  @State selectedSubId: number = 0;
  @State inputText: string = '';
  @State contactName: string = '';
  @State address: string = '';
  @State threadId: number = -1;
  @State sending: boolean = false;
  @State online: boolean = false;
  private msgDs: ArrayDataSource<ChatItem> = new ArrayDataSource<ChatItem>();
  private store: SmsStore = SmsStore.getInstance();
  private scroller: Scroller = new Scroller();
  private itemCount: number = 0;
  private atBottom: boolean = true;
  private canLoadMore: boolean = false;
  private loadState: string = 'idle'; // idle | loading | done
  private preferSubId: number = -1;

  private threadCb: () => void = () => {
    this.rebuildMessages();
    // Only chase the bottom when the user is already there; never yank the
    // view while they are reading history.
    if (this.atBottom) {
      this.scrollToBottom();
    }
    // A message just arrived in the thread we are looking at: clear the
    // unread badge and sync the read state back to Android.
    this.store.markThreadRead(this.threadId);
  };

  private listCb: () => void = () => {
    this.sims = this.store.sims;
    this.online = this.store.online;
    if (simBySubId(this.selectedSubId, this.sims) === null) {
      this.selectedSubId = defaultSendSubId(this.sims, this.preferSubId);
    }
  };

  aboutToAppear(): void {
    // Param-dependent init happens in onReady once NavDestination provides them.
  }

  private onReady(ctx: NavDestinationContext): void {
    const raw: Object | undefined = ctx.pathInfo.param as Object | undefined;
    if (raw === undefined) {
      return;
    }
    const params = raw as ChatParams;
    this.threadId = params.threadId;
    this.address = params.address;
    this.contactName = params.contactName;
    this.sims = this.store.sims;
    this.online = this.store.online;
    // Prefer the SIM this conversation last used (latest message with one).
    const hist: SmsMessage[] = this.store.getThread(this.threadId);
    for (let i = hist.length - 1; i >= 0; i--) {
      if (hist[i].subId > 0) {
        this.preferSubId = hist[i].subId;
        break;
      }
    }
    this.selectedSubId = defaultSendSubId(this.sims, this.preferSubId);
    this.store.currentChatThreadId = this.threadId;
    this.store.onThreadChange(this.threadId, this.threadCb);
    this.store.onListChange(this.listCb);
    this.store.loadThread(this.threadId);
    this.store.markThreadRead(this.threadId);
    this.rebuildMessages();
    setTimeout(() => {
      this.scrollToBottom();
    }, 80);
    // Enable history paging only after the initial auto-scroll settles, so
    // the mount-time reach-start event doesn't trigger a fetch.
    setTimeout(() => {
      this.canLoadMore = true;
    }, 600);
  }

  aboutToDisappear(): void {
    this.store.currentChatThreadId = -1;
    this.store.offThreadChange(this.threadId, this.threadCb);
    this.store.offListChange(this.listCb);
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 30);
  }

  /** Flatten day-grouped messages into rows for LazyForEach. */
  private rebuildMessages(): void {
    const messages: SmsMessage[] = this.store.getThread(this.threadId).slice();
    const items: ChatItem[] = [];
    items.push({ key: 'chat_header', kind: 0, label: this.headerLabel(), msg: null });
    let label: string = '';
    for (const m of messages) {
      const day = formatDayDivider(m.date);
      if (day !== label) {
        label = day;
        items.push({ key: `day_${day}`, kind: 1, label: day, msg: null });
      }
      items.push({
        key: `${m.id}_${m.date}_${m.body.length}_${m.clientStatus ?? ''}`,
        kind: 2,
        label: '',
        msg: m
      });
    }
    this.itemCount = items.length;
    this.msgDs.setData(items);
  }

  private headerLabel(): string {
    if (this.loadState === 'loading') {
      return '加载更早的消息…';
    }
    if (this.loadState === 'done') {
      return '没有更早的消息了';
    }
    return '上滑加载更早的消息';
  }

  private onReachTop(): void {
    if (!this.canLoadMore || this.loadState !== 'idle' || this.itemCount <= 1) {
      return;
    }
    this.loadState = 'loading';
    this.rebuildMessages();
    const before: number = this.itemCount;
    this.store.loadMore(this.threadId).then((more: boolean) => {
      this.loadState = more ? 'idle' : 'done';
      this.rebuildMessages();
      const added: number = this.itemCount - before;
      if (added > 0) {
        // Keep the previously-top message anchored in view.
        this.scroller.scrollToIndex(added, false);
      }
    });
  }

  private copyText(text: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setPasteData(data);
    promptAction.showToast({ message: '已复制' });
  }

  private retryFailed(m: SmsMessage): void {
    if (m.clientStatus !== 'failed') {
      return;
    }
    this.store.removePlaceholder(this.threadId, m.id);
    this.store.sendMessage(this.address, m.body, m.subId, this.threadId)
      .then((sent: SmsMessage | null) => {
        if (sent !== null && sent.clientStatus === 'sent') {
          this.scrollToBottom();
        }
      });
  }

  private showMessageMenu(m: SmsMessage, ui: UIContext): void {
    const buttons: MsgSheet[] = [];
    if (m.clientStatus === 'failed') {
      buttons.push({
        title: '重试发送',
        action: () => {
          this.retryFailed(m);
        }
      });
    }
    buttons.push({
      title: '复制',
      action: () => {
        this.copyText(m.body);
      }
    });
    if (m.id > 0) {
      buttons.push({
        title: '删除',
        action: () => {
          this.store.deleteMessage(this.threadId, m.id);
        }
      });
    } else {
      // Client-side placeholder (sending/failed): just remove it locally.
      buttons.push({
        title: '删除',
        action: () => {
          this.store.removePlaceholder(this.threadId, m.id);
        }
      });
    }
    ui.showActionSheet({ title: '消息操作', message: '', sheets: buttons });
  }

  build() {
    NavDestination() {
      Column() {
        // ---- Nav bar (custom: avatar + name + SIM chip)
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

          Text(avatarText(displayNameOf(this.address, this.contactName)))
            .fontSize(Tokens.FONT_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .width(38)
            .height(38)
            .borderRadius(19)
            .backgroundColor(avatarColor(this.address))

          Column({ space: 2 }) {
            Text(displayNameOf(this.address, this.contactName))
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.address)
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(simLabel(this.selectedSubId, this.sims))
            .fontSize(11)
            .fontColor($r('sys.color.brand'))
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .visibility(simLabel(this.selectedSubId, this.sims).length > 0 ? Visibility.Visible : Visibility.None)
        }
        .width('100%')
        .height(56)
        .padding({ left: 8, right: Tokens.SPACE_LG })
        .backgroundColor($r('app.color.card'))

        // ---- Messages
        List({ space: 4, scroller: this.scroller }) {
          LazyForEach(this.msgDs, (item: ChatItem) => {
            ListItem() {
              if (item.kind === 0) {
                Text(item.label)
                  .fontSize(11)
                  .fontColor($r('sys.color.font_tertiary'))
                  .padding({ top: 8, bottom: 2 })
              } else if (item.kind === 1) {
                Text(item.label)
                  .fontSize(11)
                  .fontColor($r('sys.color.font_secondary'))
                  .backgroundColor($r('sys.color.comp_background_tertiary'))
                  .borderRadius(10)
                  .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                  .margin({ top: Tokens.SPACE_SM, bottom: 4 })
              } else {
                this.Bubble(item.msg as SmsMessage)
              }
            }
            .width('100%')
          }, (item: ChatItem) => item.key)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Tokens.SPACE_MD, right: Tokens.SPACE_MD })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(8)
        .backgroundColor($r('app.color.page_bg'))
        .onScrollIndex((start: number, end: number) => {
          this.atBottom = end >= this.itemCount - 2;
        })
        .onReachStart(() => {
          this.onReachTop();
        })

        // ---- Offline hint
        if (!this.online) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
              .fontSize(13)
              .fontColor([$r('app.color.danger')])
            Text('安卓设备未连接，消息可能发送失败')
              .fontSize(11)
              .fontColor($r('app.color.danger'))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 5, bottom: 5 })
          .backgroundColor($r('app.color.chip_bg'))
        }

        // ---- Input bar
        Row({ space: Tokens.SPACE_SM }) {
          // SIM selector
          Text(this.simButtonText())
            .fontSize(Tokens.FONT_CAPTION)
            .fontColor($r('sys.color.brand'))
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(14)
            .height(Tokens.TARGET_MIN)
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.pickSim();
            })

          TextArea({ text: this.inputText, placeholder: '输入短信…' })
            .layoutWeight(1)
            .constraintSize({ minHeight: 40, maxHeight: 120 })
            .borderRadius(20)
            .backgroundColor($r('app.color.card'))
            .placeholderColor($r('sys.color.font_tertiary'))
            .enterKeyType(EnterKeyType.Send)
            .onChange((v: string) => {
              this.inputText = v;
            })
            .onSubmit(() => {
              this.send();
            })

          Button() {
            SymbolGlyph($r('sys.symbol.paperplane_fill'))
              .fontSize(20)
              .fontColor([$r('sys.color.font_on_primary')])
          }
          .width(Tokens.TARGET_MIN)
          .height(Tokens.TARGET_MIN)
          .borderRadius(20)
          .backgroundColor($r('sys.color.brand'))
          .opacity(this.sending || this.inputText.trim().length === 0 ? 0.4 : 1.0)
          .enabled(!this.sending && this.inputText.trim().length > 0)
          .onClick(() => {
            this.send();
          })
        }
        .width('100%')
        .padding({ left: Tokens.SPACE_MD, right: Tokens.SPACE_MD, top: Tokens.SPACE_SM, bottom: Tokens.SPACE_MD })
        .backgroundColor($r('app.color.card'))
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.page_bg'))
    .onReady((ctx: NavDestinationContext) => {
      this.onReady(ctx);
    })
  }

  @Builder
  Bubble(m: SmsMessage) {
    Row() {
      if (this.isMine(m)) {
        Blank()
      }
      Column({ space: 2 }) {
        Text(m.body)
          .fontSize(Tokens.FONT_TITLE)
          .fontColor(this.isMine(m) ? $r('sys.color.font_on_primary') : $r('sys.color.font_primary'))
          .lineHeight(22)
        // meta line: time (+ status for mine)
        Row({ space: 6 }) {
          if (!this.isMine(m) && simLabel(m.subId, this.sims).length > 0) {
            Text(simLabel(m.subId, this.sims))
              .fontSize(10)
              .fontColor($r('sys.color.brand'))
          }
          Text(formatBubbleTime(m.date))
            .fontSize(10)
            .fontColor(this.isMine(m) ? $r('sys.color.font_on_primary') : $r('sys.color.font_tertiary'))
            .opacity(this.isMine(m) ? 0.7 : 1.0)
          if (this.isMine(m) && m.clientStatus === 'sending') {
            Text('发送中…')
              .fontSize(10)
              .fontColor($r('sys.color.font_on_primary'))
              .opacity(0.7)
          }
          if (this.isMine(m) && m.clientStatus === 'failed') {
            Text(m.clientError ?? '发送失败')
              .fontSize(10)
              .fontColor($r('sys.color.font_on_primary'))
              .opacity(0.9)
          }
        }
      }
      .alignItems(this.isMine(m) ? HorizontalAlign.End : HorizontalAlign.Start)
      .constraintSize({ maxWidth: '78%' })
      .padding({ left: Tokens.SPACE_MD, right: Tokens.SPACE_MD, top: Tokens.SPACE_SM, bottom: 6 })
      .borderRadius({
        topLeft: Tokens.RADIUS_CTRL,
        topRight: Tokens.RADIUS_CTRL,
        bottomLeft: this.isMine(m) ? Tokens.RADIUS_CTRL : 3,
        bottomRight: this.isMine(m) ? 3 : Tokens.RADIUS_CTRL
      })
      .backgroundColor(this.isMine(m)
        ? (m.clientStatus === 'failed' ? $r('app.color.danger') : $r('sys.color.brand'))
        : $r('app.color.card'))
      .opacity(m.clientStatus === 'sending' ? 0.65 : 1.0)
      .gesture(LongPressGesture().onAction(() => {
        this.showMessageMenu(m, this.getUIContext());
      }))
      .onClick(() => {
        // Tap only opens the menu for failed messages (retry is discoverable);
        // otherwise tap does nothing to avoid accidental menus.
        if (m.clientStatus === 'failed') {
          this.showMessageMenu(m, this.getUIContext());
        }
      })
      if (!this.isMine(m)) {
        Blank()
      }
    }
    .width('100%')
    .margin({ top: 4 })
  }

  private isMine(m: SmsMessage): boolean {
    return m.type === 2 || m.clientStatus !== undefined;
  }

  private simButtonText(): string {
    const sim = simBySubId(this.selectedSubId, this.sims);
    if (sim !== null) {
      return `SIM${sim.slotIndex}`;
    }
    return this.sims.length > 0 ? '选SIM' : '无SIM';
  }

  private pickSim(): void {
    if (this.sims.length === 0) {
      promptAction.showToast({ message: '安卓设备未检测到 SIM 卡' });
      return;
    }
    const buttons: MsgSheet[] = this.sims.map((s: SimCard): MsgSheet => {
      return {
        title: `SIM${s.slotIndex} · ${s.displayName}（${s.carrierName}）`,
        action: () => {
          this.selectedSubId = s.subscriptionId;
          this.preferSubId = s.subscriptionId;
        }
      };
    });
    this.getUIContext().showActionSheet({ title: '选择发送用的 SIM 卡', message: '', sheets: buttons });
  }

  private send(): void {
    const body = this.inputText.trim();
    if (body.length === 0 || this.sending) {
      return;
    }
    this.sending = true;
    this.store.sendMessage(this.address, body, this.selectedSubId, this.threadId)
      .then((sent: SmsMessage | null) => {
        this.sending = false;
        if (sent !== null && sent.clientStatus === 'sent') {
          this.scrollToBottom();
        }
        // Always clear: on failure the text lives in the failed bubble
        // (long-press -> 重试发送), so the input never keeps a stale copy.
        this.inputText = '';
      });
  }
}
