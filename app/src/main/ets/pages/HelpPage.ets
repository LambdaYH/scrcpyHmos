import { common, Want } from '@kit.AbilityKit';

@Entry
@Component
struct HelpPage {

  private openUrl(url: string) {
    const context = getContext(this) as common.UIAbilityContext;
    let want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    context.startAbility(want).catch((err: Error) => {
      console.error('Failed to open URL:', err);
    });
  }

  build() {
    Column() {
      // Header
      Row() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.arrow_left'))
            .fontSize(24)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })
        .margin({ right: 12 }) // Gap 12vp

        Text($r('app.string.help_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .height(56 + 38)
      .padding({ left: 12, right: 24, top: 38 }) // Container Padding: Left 12, Right 24
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          Text($r('app.string.help_intro'))
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Bold)
            .width('100%')
            .textAlign(TextAlign.Start)
            .lineHeight(24)
            .margin({ bottom: 12 })

          Text($r('app.string.help_feature'))
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .lineHeight(24)
            .margin({ bottom: 24 })

          Text($r('app.string.help_usage_title'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .margin({ bottom: 12 })
            .width('100%')

          this.InstructionItem(1, $r('app.string.help_step_1'))
          this.InstructionItem(2, $r('app.string.help_step_2'))
          this.InstructionItem(3, $r('app.string.help_step_3'))
          this.InstructionItem(4, $r('app.string.help_step_4'))

          Text($r('app.string.help_note'))
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 24 })
            .width('100%')

          Divider().color($r('app.color.text_tertiary')).margin({ top: 24, bottom: 24 })

          Text($r('app.string.help_config_ref'))
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .margin({ bottom: 8 })

          Text('https://github.com/Genymobile/scrcpy?tab=readme-ov-file')
            .fontSize(14)
            .fontColor($r('app.color.btn_primary'))
            .width('100%')
            .margin({ bottom: 32 })
            .onClick(() => {
               this.openUrl('https://github.com/Genymobile/scrcpy?tab=readme-ov-file');
            })

        }
        .width('100%')
        .padding(16)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  InstructionItem(index: number, text: ResourceStr) {
    Row() {
      Text(`${index}. `)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .lineHeight(24)
        .alignSelf(ItemAlign.Start)
      Text(text)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .lineHeight(24)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 8 })
  }
}
