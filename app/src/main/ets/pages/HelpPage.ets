@Entry
@Component
struct HelpPage {
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

        Text('使用说明')
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
          Text('本应用为Scrcpy（https://github.com/Genymobile/scrcpy）的第三方鸿蒙客户端。')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .fontWeight(FontWeight.Bold)
            .width('100%')
            .textAlign(TextAlign.Start)
            .lineHeight(24)
            .margin({ bottom: 12 })

          Text('目前支持通过ADB的TCP/IP模式实现免Root控制Android设备。')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .lineHeight(24)
            .margin({ bottom: 24 })

          Text('使用方法：')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .margin({ bottom: 12 })
            .width('100%')

          this.InstructionItem(1, 'Android设备端进入开发者模式，启用USB调试。')
          this.InstructionItem(2, '将Android设备连接至PC，下载ADB工具，进入ADB目录，输入adb devices，确保设备连接成功。')
          this.InstructionItem(3, 'ADB命令行输入`adb tcpip 5555`，其中5555可换为其他端口。')
          this.InstructionItem(4, '本应用添加设备，ip选取Android设备的IP地址，端口输入第三步设置的端口，按需启用各配置项后点击连接即可。')

          Text('注：首次连接Android设备需在Android设备端弹出的确认框中允许USB调试。')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 24 })
            .width('100%')

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
  InstructionItem(index: number, text: string) {
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
