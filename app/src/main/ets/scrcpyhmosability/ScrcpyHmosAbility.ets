import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { AdbKeyManager } from '../helper/AdbKeyManager';

const DOMAIN = 0x0000;

export default class ScrcpyHmosAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.debug(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    
    // 初始化数据存储
    PreferencesHelper.getInstance().init(this.context);
    // 初始化ADB密钥
    AdbKeyManager.getInstance().init(this.context);
  }

  onDestroy(): void {
    hilog.debug(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.debug(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

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