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
    // Apply immediately is tricky without restarting capability, but we can try to update config
    // Actually in HarmonyOS, updating configuration usually requires Ability context.
    // We will rely on the user restarting or navigating back for some changes, 
    // but try to update runtime too if possible.
    // For now, simpler approach: Just save, and show toast to restart or it applies next time/on resume.
    // But user asked for switch.
    
    // We can try adding logic in Ability to update context resource config ? 
    // Or just re-render UI if we use resources correctly.
    // But ability context language needs update.
    
    // For this implementation, we will save, and try to update context if possible in Index or Ability.
    // But since this is a page, we can only update what we can.
    
    // Let's rely on standard mechanism: Update preference -> App logic (in Ability or Base) reacts?
    // ArkTS UI should auto-update if resourceManager config changes.
    // We need to call generic method to update app language.
    
    this.applyLanguage(lan);
  }
  applyLanguage(lan: string) {
    // Just save preference, do not apply immediately to context or AppStorage.
    // User requested to revert to "restart required".
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
        this.CheckItem($r('app.string.language_en'), 'en_US')
        
        Text($r('app.string.restart_hint'))
          .fontSize(14)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 16 })
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
