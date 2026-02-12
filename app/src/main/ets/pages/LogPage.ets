import { Logger, LoggerIndex, LogLevel } from '../helper/Logger';


@Entry
@Component
struct LogPage {
  @State logContent: string = 'Loading...';
  @State selectedLogLevel: number = Logger.getLogLevel();
  @State isFileLoggingEnabled: boolean = Logger.isFileLoggingEnabled();
  private scroller: Scroller = new Scroller();

  aboutToAppear() {
    this.refreshLogs();
  }

  async refreshLogs() {
    try {
      const content = await Logger.getLogContent();
      this.logContent = content || '暂无日志';
      // Scroll to bottom after loading
      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 100);
    } catch (e) {
      const errMsg = e instanceof Error ? e.message : String(e);
      LoggerIndex.error('Load logs failed:', errMsg);
      this.logContent = 'Failed to load logs.';
    }
  }

  async clearLogs() {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.clear_logs_confirm_title'),
      message: $r('app.string.clear_logs_confirm_msg'),
      primaryButton: {
        value: $r('app.string.cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.clear'),
        fontColor: Object($r('app.color.btn_danger')),
        action: () => {
          Logger.clearLogs();
          this.refreshLogs();
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.logs_cleared') });
        }
      }
    });
  }

  build() {
    Column() {
      // Header
      Row() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.arrow_left'))
            .fontSize(24)
            .fontColor([$r('app.color.text_title')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })

        Text($r('app.string.system_log'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_title'))
          .textAlign(TextAlign.Start)
          .margin({ left: 12, right: 12 })
        
        Toggle({ type: ToggleType.Switch, isOn: this.isFileLoggingEnabled })
          .onChange((isOn: boolean) => {
            this.isFileLoggingEnabled = isOn;
            Logger.setFileLoggingEnabled(isOn);
          })
          .height(24)

        Blank()

        if (this.isFileLoggingEnabled) {
          Select([
            { value: 'DEBUG' },
            { value: 'INFO' },
            { value: 'WARN' },
            { value: 'ERROR' }
          ])
            .selected(this.selectedLogLevel)
            .value(LogLevel[this.selectedLogLevel])
            .font({ size: 12 })
            .fontColor($r('app.color.text_primary'))
            .selectedOptionFont({ size: 12 })
            .optionFont({ size: 12 })
            .backgroundColor($r('app.color.bg_card'))
            .onSelect((index: number) => {
              this.selectedLogLevel = index;
              Logger.setLogLevel(index);
            })
        }
      }
      .width('100%')
      .height(56 + 38)
      .padding({ top: 38, left: 12, right: 24 })
      .backgroundColor(Color.Transparent)
      .alignItems(VerticalAlign.Center)

      // Content
      if (this.isFileLoggingEnabled) {
        Scroll(this.scroller) {
          // 仅显示最后 50KB 日志，避免大量文本渲染导致卡顿
          Text(this.logContent.length > 50000 ? '... (日志过长，仅显示最后部分)\n' + this.logContent.slice(-50000) : this.logContent)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('Monospace')
            .width('100%')
            .padding(16)
            .copyOption(CopyOptions.LocalDevice)
        }
        .layoutWeight(1)
        .width('100%')
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.TopStart)
        .backgroundColor($r('app.color.bg_primary'))
      } else {
        Blank().layoutWeight(1)
      }

      // Footer Actions
      Row() {
        if (this.isFileLoggingEnabled) {
          Button($r('app.string.refresh'))
            .fontSize(14)
            .backgroundColor($r('app.color.btn_secondary'))
            .fontColor($r('app.color.text_primary'))
            .margin({ right: 12 })
            .onClick(() => {
              this.refreshLogs();
            })
            .layoutWeight(1)
        }

        Button($r('app.string.clear_logs'))
          .fontSize(14)
          .backgroundColor($r('app.color.btn_danger'))
          .fontColor(Color.White)
          .onClick(() => {
            this.clearLogs();
          })
          .layoutWeight(this.isFileLoggingEnabled ? 1 : 0.5) // Adjust width
          .width(this.isFileLoggingEnabled ? 'auto' : '50%') // Make it centered or wider if alone?
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 28 })
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.bg_card'))
      .shadow({ radius: 8, color: '#1A000000', offsetY: -2 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
