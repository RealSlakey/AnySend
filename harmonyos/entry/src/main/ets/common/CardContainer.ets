// Reusable surface card: white/gray surface with HDS radius, used by the
// transfer and settings tabs so all cards stay visually identical.

import { Tokens } from './DesignTokens';

@Builder
function emptyContent() {
}

@Component
export struct CardContainer {
  @BuilderParam content: () => void = emptyContent;

  build() {
    Column() {
      this.content()
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(14)
    .borderRadius(Tokens.RADIUS_CARD)
    .backgroundColor($r('app.color.card'))
    .margin({ bottom: Tokens.SPACE_MD })
  }
}
