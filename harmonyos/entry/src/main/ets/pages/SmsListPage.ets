// 短信 Tab: conversation list backed by SmsStore.
// Distinguishes connecting / disconnected / failed states, supports
// pull-to-refresh, unread badges and a floating "new message" action that
// doesn't cover the last row. Conversations are grouped by SmsClassifier
// into verification-code / known-contact / unknown-contact categories.

import { promptAction } from '@kit.ArkUI';
import pasteboard from '@ohos.pasteboard';
import { Conversation } from '../sms/SmsModels';
import { SmsStore } from '../sms/SmsStore';
import { SmsCategory, classifyConversation, extractOtp } from '../sms/SmsClassifier';
import { Tokens } from '../common/DesignTokens';
import { AppNav } from '../common/AppNav';
import { ArrayDataSource } from '../common/ArrayDataSource';
import {
  avatarColor,
  avatarText,
  displayNameOf,
  formatListTime,
  simLabel
} from '../sms/SmsUtil';

@Component
export struct SmsListPage {
  @StorageLink('smsTab') @Watch('onTabShown') tabIdx: number = 0;
  @State online: boolean = false;
  @State everOnline: boolean = false; // synced successfully at least once
  @State hostName: string = '';
  @State hasHost: boolean = false;
  @State isEmpty: boolean = true;
  @State refreshing: boolean = false;
  @State activeCat: SmsCategory = SmsCategory.ALL;
  @State catEmpty: boolean = false;
  @State cntAll: number = 0;
  @State cntCode: number = 0;
  @State cntKnown: number = 0;
  @State cntUnknown: number = 0;
  private convDs: ArrayDataSource<Conversation> = new ArrayDataSource<Conversation>();
  private store: SmsStore = SmsStore.getInstance();
  private listCb: () => void = () => {
    this.refreshFromStore();
  };

  private refreshFromStore(): void {
    const rows: Conversation[] = this.store.conversations.slice();
    this.cntAll = rows.length;
    this.cntCode = 0;
    this.cntKnown = 0;
    this.cntUnknown = 0;
    for (let i = 0; i < rows.length; i++) {
      const cat = classifyConversation(rows[i]);
      if (cat === SmsCategory.CODE) {
        this.cntCode++;
      } else if (cat === SmsCategory.KNOWN) {
        this.cntKnown++;
      } else {
        this.cntUnknown++;
      }
    }
    this.isEmpty = rows.length === 0;
    this.applyFilter(rows);
    this.online = this.store.online;
    if (this.online) {
      this.everOnline = true;
    }
  }

  private applyFilter(rows?: Conversation[]): void {
    const src = rows ?? this.store.conversations.slice();
    let filtered: Conversation[] = src;
    if (this.activeCat !== SmsCategory.ALL) {
      filtered = src.filter((c: Conversation) => classifyConversation(c) === this.activeCat);
    }
    this.catEmpty = filtered.length === 0 && !this.isEmpty;
    this.convDs.setData(filtered);
  }

  aboutToAppear(): void {
    this.refreshFromStore();
    this.hostName = this.store.hostName;
    this.hasHost = this.store.hasHost();
    this.store.onListChange(this.listCb);
    if (this.hasHost) {
      this.store.startPolling();
    }
  }

  /** Re-read host state when the user switches back to this tab, so a
   * pairing done in Settings reflects immediately. */
  private onTabShown(): void {
    if (this.tabIdx !== 0) {
      return;
    }
    this.hostName = this.store.hostName;
    this.hasHost = this.store.hasHost();
    if (this.hasHost) {
      this.store.startPolling();
    }
  }

  aboutToDisappear(): void {
    this.store.offListChange(this.listCb);
  }

  build() {
    Column() {
      // ---- Header
      Row() {
        Text('短信')
          .fontSize(Tokens.FONT_H1)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Blank()
        Row({ space: 6 }) {
          Circle({ width: 8, height: 8 })
            .fill(this.online ? $r('app.color.success') : $r('sys.color.icon_tertiary'))
          Text(this.hostName.length > 0 ? this.hostName : (this.hasHost ? '已配置' : '未配置安卓设备'))
            .fontSize(Tokens.FONT_CAPTION)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .maxFontSize(Tokens.FONT_CAPTION)
            .minFontSize(10)
        }
      }
      .width('100%')
      .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, top: 14, bottom: Tokens.SPACE_SM })

      // ---- Category chips
      if (this.hasHost && !this.isEmpty) {
        this.CategoryChips()
      }

      // ---- Empty / unpaired states
      if (!this.hasHost) {
        Column({ space: Tokens.SPACE_MD }) {
          SymbolGlyph($r('sys.symbol.envelope'))
            .fontSize(44)
            .fontColor([$r('sys.color.icon_tertiary')])
          Text('还没有连接安卓设备')
            .fontSize(Tokens.FONT_TITLE)
            .fontColor($r('sys.color.font_primary'))
          Text('在安卓手机上打开本应用，开启短信权限后，\n把「配对码」填到鸿蒙端设置里完成配对。')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
          Button('去设置')
            .backgroundColor($r('sys.color.brand'))
            .onClick(() => {
              AppStorage.setOrCreate('smsTab', 2);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.isEmpty) {
        this.EmptyState()
      } else if (this.catEmpty) {
        Column({ space: Tokens.SPACE_SM }) {
          Text('该分类暂无会话')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // ---- Conversation list (pull to refresh)
        // $$ two-way binding is required: without it the component never
        // sees `refreshing = false` and the spinner spins forever.
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 2 }) {
            LazyForEach(this.convDs, (conv: Conversation) => {
              ListItem() {
                this.ConversationRow(conv)
              }
            }, (conv: Conversation) => `${conv.threadId}_${conv.date}_${conv.unread}`)
            // Bottom spacer: keeps the last row clear of the floating action
            // button without padding (padding would clip the last row).
            ListItem()
              .width('100%')
              .height(84)
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(8)
          // White panel: no bare page-bg slab below short content.
          .backgroundColor($r('app.color.card'))
          .divider({
            strokeWidth: 0.5,
            color: $r('sys.color.comp_divider'),
            startMargin: 78,
            endMargin: Tokens.SPACE_LG
          })
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing(() => {
          this.store.syncOnce().finally(() => {
            this.refreshing = false;
          });
          // Failsafe: if the request hangs (peer never replies), retract
          // the spinner anyway. Setting it again later is harmless.
          setTimeout(() => {
            this.refreshing = false;
          }, 12000);
        })
      }

      // hint when the host was reachable but the connection dropped
      if (this.hasHost && this.everOnline && !this.online && !this.isEmpty) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(14)
            .fontColor([$r('app.color.danger')])
          Text('无法连接安卓设备：请确认接收服务已启动、配对码正确')
            .fontSize(11)
            .fontColor($r('app.color.danger'))
        }
        .width('100%')
        .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, bottom: 6 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .overlay(this.NewMessageFab(), { align: Alignment.BottomEnd, offset: { x: -20, y: -24 } })
  }

  /** Category filter chips with per-category counts. */
  @Builder
  CategoryChips() {
    Row({ space: 8 }) {
      this.Chip(SmsCategory.ALL, '全部', this.cntAll)
      this.Chip(SmsCategory.CODE, '验证码', this.cntCode)
      this.Chip(SmsCategory.KNOWN, '已知联系人', this.cntKnown)
      this.Chip(SmsCategory.UNKNOWN, '未知联系人', this.cntUnknown)
    }
    .width('100%')
    .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, bottom: Tokens.SPACE_SM })
  }

  @Builder
  Chip(cat: SmsCategory, label: string, count: number) {
    Row({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontWeight(this.activeCat === cat ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeCat === cat ? Color.White : $r('sys.color.font_secondary'))
      Text(`${count}`)
        .fontSize(10)
        .fontColor(this.activeCat === cat ? '#E6EEFF' : $r('sys.color.font_tertiary'))
        .visibility(count > 0 ? Visibility.Visible : Visibility.None)
    }
    .height(28)
    .borderRadius(14)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.activeCat === cat ? $r('sys.color.brand') : $r('app.color.chip_bg'))
    .onClick(() => {
      if (this.activeCat !== cat) {
        this.activeCat = cat;
        this.applyFilter();
      }
    })
  }

  /** Empty-list state: connecting (spinner) vs failed (retry). */
  @Builder
  EmptyState() {
    Column({ space: Tokens.SPACE_MD }) {
      if (this.online) {
        SymbolGlyph($r('sys.symbol.envelope'))
          .fontSize(44)
          .fontColor([$r('sys.color.icon_tertiary')])
        Text('暂无会话')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      } else if (!this.everOnline) {
        LoadingProgress()
          .width(36)
          .height(36)
          .color($r('sys.color.brand'))
        Text('正在连接安卓设备…')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      } else {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize(44)
          .fontColor([$r('app.color.danger')])
        Text('连接安卓设备失败')
          .fontSize(Tokens.FONT_TITLE)
          .fontColor($r('sys.color.font_primary'))
        Text('请确认安卓端应用已启动、地址可达')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        Button('重试')
          .backgroundColor($r('sys.color.brand'))
          .onClick(() => {
            this.store.startPolling();
            this.store.syncOnce();
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ConversationRow(conv: Conversation) {
    Row({ space: Tokens.SPACE_MD }) {
      // Left block opens the chat. Kept separate from the right column so
      // the verification-code chip can own its tap without stopPropagation
      // (ClickEvent has no stopPropagation in ArkTS).
      Row({ space: Tokens.SPACE_MD }) {
        // Avatar
        Text(avatarText(displayNameOf(conv.address, conv.contactName)))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .width(46)
          .height(46)
          .borderRadius(23)
          .backgroundColor(avatarColor(conv.address))

        // Name + snippet
        Column({ space: 3 }) {
          Text(displayNameOf(conv.address, conv.contactName))
            .fontSize(Tokens.FONT_TITLE)
            .fontWeight(conv.unread > 0 ? FontWeight.Bold : FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(conv.snippet)
            .fontSize(13)
            .fontWeight(conv.unread > 0 ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(conv.unread > 0 ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .onClick(() => {
        this.openChat(conv);
      })

      // Time / unread / verification code / sim
      Column({ space: 4 }) {
        Text(formatListTime(conv.date))
          .fontSize(11)
          .fontColor(conv.unread > 0 ? $r('sys.color.brand') : $r('sys.color.font_tertiary'))
        if (extractOtp(conv.snippet ?? '') !== '') {
          // Verification-code conversation: show the code, tap to copy.
          Text(extractOtp(conv.snippet ?? ''))
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.brand'))
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(6)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .onClick((e: ClickEvent) => {
              this.copyOtp(extractOtp(conv.snippet ?? ''));
            })
        } else if (conv.unread > 0) {
          Text(`${conv.unread}`)
            .fontSize(11)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .constraintSize({ minWidth: 18 })
            .height(18)
            .borderRadius(9)
            .padding({ left: 5, right: 5 })
            .backgroundColor($r('app.color.danger'))
        } else {
          Text(simLabel(conv.subId, this.store.sims))
            .fontSize(10)
            .fontColor($r('sys.color.brand'))
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(4)
            .padding({ left: 4, right: 4 })
            .visibility(simLabel(conv.subId, this.store.sims).length > 0 ? Visibility.Visible : Visibility.None)
        }
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.card'))
  }

  private openChat(conv: Conversation): void {
    const params: Record<string, Object> = {
      'threadId': conv.threadId,
      'address': conv.address,
      'contactName': conv.contactName ?? ''
    };
    AppNav.push('SmsChatPage', params);
  }

  private copyOtp(code: string): void {
    const data = pasteboard.createData('text/plain', code);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: `验证码 ${code} 已复制` });
    }).catch(() => {
      promptAction.showToast({ message: '复制失败' });
    });
  }

  @Builder
  NewMessageFab() {
    Row() {
      Text('+')
        .fontSize(32)
        .fontColor(Color.White)
    }
    .width(52)
    .height(52)
    .borderRadius(26)
    .backgroundColor($r('sys.color.brand'))
    .justifyContent(FlexAlign.Center)
    .shadow({ radius: 8, color: 'rgba(10,89,241,0.2)', offsetY: 3 })
    .onClick(() => {
      if (!this.store.hasHost()) {
        promptAction.showToast({ message: '请先在设置中完成配对' });
        return;
      }
      AppNav.push('SmsComposePage', null);
    })
  }
}
