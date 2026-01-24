import { ConfigurationConstant } from '@kit.AbilityKit';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerIndex } from '../helper/Logger';

@Entry
@Component
struct ThemePage {
  @State selectedMode: string = 'system';
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();

  aboutToAppear() {
    this.initMode();
  }

  async initMode() {
    this.selectedMode = await this.preferencesHelper.getThemeMode();
  }

  async selectMode(mode: string) {
    this.selectedMode = mode;
    await this.preferencesHelper.saveThemeMode(mode);
    this.applyTheme(mode);
  }

  applyTheme(mode: string) {
    let colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === 'light') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === 'dark') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    
    try {
      getContext(this).getApplicationContext().setColorMode(colorMode);
    } catch (err) {
      LoggerIndex.error('Set color mode failed:', err);
    }
  }

  @Builder
  CheckItem(title: string, mode: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      
      if (this.selectedMode === mode) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(24)
          .fontColor([$r('app.color.btn_primary')])
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ bottom: 12 })
    .onClick(() => {
      this.selectMode(mode);
    })
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

        Text('深色模式')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_title'))
          .textAlign(TextAlign.Start)
          .margin({ left: 12 })
      }
      .width('100%')
      .height(56 + 38)
      .padding({ top: 38, left: 12, right: 24 })
      .backgroundColor(Color.Transparent)
      .alignItems(VerticalAlign.Center)

      // Content
      Column() {
        this.CheckItem('跟随系统', 'system')
        this.CheckItem('浅色模式', 'light')
        this.CheckItem('深色模式', 'dark')
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
