import { i18n } from '@kit.LocalizationKit';
import { resourceManager } from '@kit.LocalizationKit';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerIndex } from '../helper/Logger';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct LanguagePage {
  @State selectedLanguage: string = 'system';
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();

  aboutToAppear() {
    this.initLanguage();
  }

  async initLanguage() {
    this.selectedLanguage = await this.preferencesHelper.getLanguage();
  }

  async selectLanguage(lan: string) {
    this.selectedLanguage = lan;
    await this.preferencesHelper.saveLanguage(lan);
    this.applyLanguage(lan);
  }

  applyLanguage(lan: string) {
    try {
      let targetLang = lan;
      if (lan === 'system') {
        // Since 'default' doesn't consistently work, we manually fetch and set the system language.
        // We rely on ScrcpyHmosAbility.onForeground to keep this in sync if system language changes.
        targetLang = i18n.System.getSystemLanguage();
        if(targetLang.startsWith('zh')) {
          targetLang = 'zh-Hans';
        }else{
          targetLang = 'en-Latn-US';
        }
      }
      
      // Use standard API to set app language (API 9+)
      i18n.System.setAppPreferredLanguage(targetLang);
      LoggerIndex.info('[LanguagePage] Set app language via i18n.System.setAppPreferredLanguage:', targetLang);
    } catch (err) {
      LoggerIndex.error('[LanguagePage] Failed to set app language:', err);
    }
  }

  @Builder
  CheckItem(title: ResourceStr, tag: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      
      if (this.selectedLanguage === tag) {
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
      this.selectLanguage(tag);
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

        Text($r('app.string.language_settings'))
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
        this.CheckItem($r('app.string.follow_system'), 'system')
        this.CheckItem($r('app.string.language_zh'), 'zh-Hans')
        this.CheckItem($r('app.string.language_en'), 'en-Latn-US')
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
