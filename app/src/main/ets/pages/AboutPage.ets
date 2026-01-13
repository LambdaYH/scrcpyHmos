import router from '@ohos.router';
import web_webview from '@ohos.web.webview';

@Entry
@Component
struct AboutPage {
  private scrcpyRepo: string = 'https://github.com/LambdaYH/scrcpyHmos';
  private easyControlRepo: string = 'https://github.com/mingzhixian/Easycontrol';

  build() {
    Column() {
      // Title Bar
      Row() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.arrow_left'))
            .fontSize(24)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor('#00000000')
        .onClick(() => {
          router.back();
        })
        
        Text('关于 / 开源说明')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 16 })
      }
      .width('100%')
      .height(56 + 38)
      .padding({ left: 16, right: 16, top: 38 })
      
      Scroll() {
        Column() {
          Image($r('app.media.icon_startwindow'))
            .width(80)
            .height(80)
            .margin({ top: 24, bottom: 16 })
            
          Text('Scrcpy Hmos')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 8 })
            
          Text('v1.0.0')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: 32 })
            
          // Project Info
          Column() {
            Text('开源地址')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 8 })
              
            Text(this.scrcpyRepo)
              .fontSize(14)
              .fontColor($r('app.color.btn_primary'))
              .alignSelf(ItemAlign.Start)
              .onClick(() => {
                // In a real app we might want to open a webview or copy to clipboard
                // For now, let's just show it visually
              })
              .margin({ bottom: 24 })

            Text('致谢 (Credits)')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 8 })
              
            Text('本项目源代码部分衍生自 mingzhixian 的 Easycontrol 项目。')
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 4 })
              
            Text(this.easyControlRepo)
              .fontSize(14)
              .fontColor($r('app.color.btn_primary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 8 })
              
            Text('Easycontrol 遵循 GPL-3.0 开源协议。本项目同样遵循 GPL-3.0 协议发布。')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 24 })
              
            // License Text Area
            Text('GPL-3.0 License Summary')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 8 })
              
            TextArea({ text: `GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007

Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>
Everyone is permitted to copy and distribute verbatim copies
of this license document, but changing it is not allowed.

(See full license in source code repository)` })
              .width('100%')
              .height(150)
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.bg_primary'))
              .focusable(false)
              .margin({ bottom: 24 })
          }
          .width('90%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
        }
        .width('100%')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
