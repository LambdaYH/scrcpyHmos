import { Device } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { AdbKeyManager } from '../helper/AdbKeyManager';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

@Entry
@Component
struct AdbManagePage {
  @State commonKeyInfo: string = '';
  @State publicKeyDisplay: string = '';
  @State privateKeyDisplay: string = '';
  private adbKeyManager: AdbKeyManager = AdbKeyManager.getInstance();

  aboutToAppear() {
    this.refreshData();
  }

  async refreshData() {
    // 加载公共密钥信息
    const info = this.adbKeyManager.getCommonKeyInfo();
    if (info.hasKey) {
      // this.commonKeyInfo = `当前公共密钥版本: v${info.generation}`;
      this.publicKeyDisplay = this.adbKeyManager.getPublicKey();
      this.privateKeyDisplay = this.adbKeyManager.getPrivateKey();
    } else {
      // this.commonKeyInfo = '未检测到有效密钥 (如果不重新生成，将自动创建)';
      this.publicKeyDisplay = '';
      this.privateKeyDisplay = '';
    }
  }

  build() {
    Column() {
      // 标题栏
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
        
        Text('密钥管理')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 }) // Gap 12vp
      }
      .width('100%')
      .height(56 + 38)
      .padding({ left: 12, right: 24, top: 38 }) // Padding: Left 12, Right 24
      
      Column() {
        Image($r('app.media.icon_startwindow'))
          .width(80)
          .height(80)
          .margin({ top: 48, bottom: 24 })
          
        Text('全局ADB密钥')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 24 })
          
        // Text(this.commonKeyInfo)
        //   .fontSize(14)
        //   .fontColor('#666666')
        //   .margin({ bottom: 24 })
          
        Text('公钥 (Public Key):')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .alignSelf(ItemAlign.Start)
          .margin({ left: 32, bottom: 4 })
          
        TextArea({ text: this.publicKeyDisplay })
          .width('85%')
          .height(100)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.bg_card'))
          .margin({ bottom: 16 })
          .focusable(false)
          .copyOption(CopyOptions.LocalDevice)
          
        Text('私钥 (Private Key):')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .alignSelf(ItemAlign.Start)
          .margin({ left: 32, bottom: 4 })
          
        TextArea({ text: this.privateKeyDisplay })
          .width('85%')
          .height(100)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.bg_card'))
          .margin({ bottom: 24 })
          .focusable(false)
          .copyOption(CopyOptions.LocalDevice)
          
        Button('重新生成密钥')
          .width('80%')
          .height(48)
          .fontSize(16)
          .type(ButtonType.Capsule)
          .backgroundColor($r('app.color.btn_primary'))
          .onClick(() => {
             this.regenerateKey();
          })
          
        Text('注意：重新生成密钥后，所有已连接的设备都需要重新授权。')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 24 })
          .padding({ left: 32, right: 32 })
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  async regenerateKey() {
    try {
      const result = await promptAction.showDialog({
        title: '确认重新生成',
        message: '这将重置所有设备的连接授权状态。连接设备时需要在手机上重新点击"允许调试"。是否继续？',
        buttons: [
          { text: '取消', color: $r('app.color.text_secondary') },
          { text: '确定', color: $r('app.color.btn_primary') }
        ]
      });
      
      if (result.index === 1) {
        await this.adbKeyManager.regenerateCommonKey();
        promptAction.showToast({ message: '密钥已重新生成' });
        this.refreshData();
      }
    } catch (err) {
      console.error('Regenerate key failed:', err);
      promptAction.showToast({ message: '操作失败' });
    }
  }
}
