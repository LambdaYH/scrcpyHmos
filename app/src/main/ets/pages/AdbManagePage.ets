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
        .backgroundColor($r('sys.color.titlebar_icon_background_color'))
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

        Button('自定义密钥')
          .width('80%')
          .height(48)
          .fontSize(16)
          .type(ButtonType.Capsule)
          .backgroundColor('#808080')
          .margin({ top: 12 })
          .onClick(() => {
            this.showCustomKeyDialog();
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

  // 自定义密钥弹框
  @State inputPublicKey: string = '';
  @State inputPrivateKey: string = '';

  private customKeyDialog: CustomDialogController = new CustomDialogController({
    builder: CustomKeyDialog({
      onConfirm: (pub: string, pri: string) => this.handleImportKey(pub, pri)
    }),
    autoCancel: true,
    customStyle: true
  })

  showCustomKeyDialog(): void {
    this.customKeyDialog.open();
  }

  async handleImportKey(pub: string, pri: string): Promise<void> {
    try {
      await this.adbKeyManager.importCustomKey(pri, pub);
      promptAction.showToast({ message: '自定义密钥已保存' });
      this.refreshData();
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      console.error('Import custom key failed:', error);
      
      let friendMsg = '导入失败，请检查密钥格式是否正确';
      // 简单的错误映射
      if (error.message.includes('empty')) {
        friendMsg = '导入失败：公钥或私钥不能为空';
      } else if (error.message.includes('Base64')) {
        friendMsg = '导入失败：密钥包含非法字符或格式错误';
      }
      
      promptAction.showToast({ message: friendMsg });
    }
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

@CustomDialog
struct CustomKeyDialog {
  controller?: CustomDialogController;
  onConfirm?: (pub: string, pri: string) => void;
  @State publicKey: string = '';
  @State privateKey: string = '';

  build() {
    Column() {
      Text('自定义 ADB 密钥')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 16 })
      
      Text('Private Key (PKCS#8 Base64)')
        .fontSize(12)
        .alignSelf(ItemAlign.Start)
        .fontColor('#666666')
        .margin({ bottom: 4 })
      TextArea({ placeholder: '在此粘贴私钥内容...' })
        .height(100)
        .fontSize(12)
        .onChange((val) => this.privateKey = val)
        .margin({ bottom: 12 })
        
      Text('Public Key (PKCS#8 Base64)')
        .fontSize(12)
        .alignSelf(ItemAlign.Start)
        .fontColor('#666666')
        .margin({ bottom: 4 })
      TextArea({ placeholder: '在此粘贴公钥内容...' })
        .height(100)
        .fontSize(12)
        .onChange((val) => this.publicKey = val)
        .margin({ bottom: 24 })
        
      Row() {
        Button('取消')
          .width('40%')
          .backgroundColor('#F5F5F5')
          .fontColor($r('sys.color.black'))
          .onClick(() => {
            this.controller?.close();
          })
          
        Button('保存并应用')
          .width('40%')
          .backgroundColor($r('app.color.btn_primary'))
          .onClick(() => {
            if (this.onConfirm) {
              this.onConfirm(this.publicKey, this.privateKey);
            }
            this.controller?.close();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('90%')
    .padding(24)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
  }
}
