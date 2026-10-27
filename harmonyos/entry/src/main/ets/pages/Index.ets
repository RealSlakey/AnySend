// App root: Navigation hosts the bottom Tabs (SMS / transfer / history /
// settings). Nested pages (chat, compose) are NavDestinations on the shared
// AppNav stack; 'smsTab' in AppStorage lets any page switch tabs.

import { SmsListPage } from './SmsListPage';
import { TransferPage } from './TransferPage';
import { SettingsPage } from './SettingsPage';
import { SmsChatPage } from './SmsChatPage';
import { SmsComposePage } from './SmsComposePage';
import { SharePage } from './Share';
import { HistoryPage } from './HistoryPage';
import { MirrorPage } from './MirrorPage';
import { AppStreamPage } from './AppStreamPage';
import { MacRemotePage } from './MacRemotePage';
import { AppNav } from '../common/AppNav';

@Entry
@Component
struct Index {
  @StorageLink('smsTab') @Watch('onTabJump') currentTab: number = 0;

  private onTabJump(): void {
    // AppStorage write from any page lands here; Tabs follows currentTab.
  }

  @Builder
  tabBar(icon: Resource, label: string, index: number) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(24)
        .fontColor([this.currentTab === index ? $r('sys.color.brand') : $r('sys.color.icon_secondary')])
      Text(label)
        .fontSize(10)
        .fontColor(this.currentTab === index ? $r('sys.color.brand') : $r('sys.color.font_secondary'))
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .height('100%')
  }

  @Builder
  pageMap(name: string) {
    if (name === 'SmsChatPage') {
      SmsChatPage()
    } else if (name === 'SmsComposePage') {
      SmsComposePage()
    } else if (name === 'SharePage') {
      SharePage()
    } else if (name === 'MirrorPage') {
      MirrorPage()
    } else if (name === 'AppStreamPage') {
      AppStreamPage()
    } else if (name === 'MacRemotePage') {
      MacRemotePage()
    }
  }

  build() {
    Navigation(AppNav.stack) {
      Tabs({ index: this.currentTab, barPosition: BarPosition.End }) {
        TabContent() {
          SmsListPage()
        }
        .tabBar(this.tabBar($r('sys.symbol.message'), '短信', 0))

        TabContent() {
          TransferPage()
        }
        .tabBar(this.tabBar($r('sys.symbol.superdevice'), '设备', 1))

        TabContent() {
          HistoryPage()
        }
        .tabBar(this.tabBar($r('sys.symbol.clock'), '历史', 2))

        TabContent() {
          SettingsPage()
        }
        .tabBar(this.tabBar($r('sys.symbol.gearshape'), '设置', 3))
      }
      .scrollable(false)
      .barMode(BarMode.Fixed)
      .width('100%')
      .height('100%')
      .onChange((index: number) => {
        this.currentTab = index;
      })
    }
    .navDestination(this.pageMap)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
