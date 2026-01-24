import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { AdbKeyManager } from '../helper/AdbKeyManager';
import { i18n } from '@kit.LocalizationKit';

const DOMAIN = 0x0000;

export default class ScrcpyHmosAbility extends UIAbility {
  private initPromise: Promise<void> | undefined;

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.debug(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    
    // 初始化ADB密钥
    AdbKeyManager.getInstance().init(this.context);

    // 初始化数据存储并设置语言/主题
    this.initPromise = PreferencesHelper.getInstance().init(this.context).then(async () => {
      // Apply saved theme
      const theme = await PreferencesHelper.getInstance().getThemeMode();
      let colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      if (theme === 'light') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      } else if (theme === 'dark') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
      this.context.getApplicationContext().setColorMode(colorMode);

      // Apply saved language or follow system logic
      const language = await PreferencesHelper.getInstance().getLanguage();
      hilog.info(DOMAIN, 'testTag', 'Loaded language preference: %{public}s', language);
      if (language !== 'system') {
        try {
           hilog.info(DOMAIN, 'testTag', 'Setting app language to: %{public}s', language);
           this.context.getApplicationContext().setLanguage(language);
        } catch (err) {
           hilog.error(DOMAIN, 'testTag', 'Failed to set language. Cause: %{public}s', JSON.stringify(err));
        }
      } else {
        // Handle system language edge cases (Traditional Chinese -> Simplified Chinese)
        try {
          const sysLang = i18n.System.getSystemLanguage(); // e.g., "zh-Hant-HK"
          hilog.info(DOMAIN, 'testTag', 'System language: %{public}s', sysLang);
          
          if (sysLang.startsWith('zh') && (sysLang.includes('Hant') || sysLang.includes('HK') || sysLang.includes('TW') || sysLang.includes('MO'))) {
             hilog.info(DOMAIN, 'testTag', 'System is Traditional Chinese, forcing Simplified Chinese');
             this.context.getApplicationContext().setLanguage('zh-Hans');
          }
        } catch (e) {
             hilog.error(DOMAIN, 'testTag', 'Failed to check system language: ' + JSON.stringify(e));
        }
      }
    });
  }


  onDestroy(): void {
    hilog.debug(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  private windowStage?: window.WindowStage;

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.debug(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.windowStage = windowStage;

    windowStage.loadContent('pages/Index', async (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      // Enable full screen
      try {
        let windowClass: window.Window = windowStage.getMainWindowSync();
        await windowClass.setWindowLayoutFullScreen(true);
      } catch (exception) {
        hilog.error(DOMAIN, 'testTag', 'Failed to set the window layout to full-screen mode. Cause: ' + JSON.stringify(exception));
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    if (this.initPromise) {
      this.initPromise.then(() => {
        // Init done
      }).catch((err: Error) => {
        hilog.error(DOMAIN, 'testTag', 'Init promise failed: %{public}s', JSON.stringify(err));
      });
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.debug(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.debug(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.debug(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}