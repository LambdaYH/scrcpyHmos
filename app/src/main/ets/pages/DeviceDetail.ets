import { Device } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { util } from '@kit.ArkTS';

@Entry
@Component
struct DeviceDetail {
  @State device: Device = new Device();
  @State isEdit: boolean = false;
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();

  aboutToAppear() {
    try {
      const params = this.getUIContext().getRouter().getState().params as Record<string, Object>;
      if (params && params['device']) {
        this.device = params['device'] as Device;
        this.isEdit = true;
      } else {
        // 生成UUID
        this.device.uuid = util.generateRandomUUID(true);
        this.device.name = '新设备';
      }
    } catch (e) {
      console.error('Failed to get router params:', e);
      // 默认为新设备
      this.device.uuid = util.generateRandomUUID(true);
      this.device.name = '新设备';
    }
  }

  build() {
    Column() {
      // 标题栏
      // 标题栏
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
        
        Text(this.isEdit ? '编辑设备' : '添加设备')
          .fontSize(20) // 20fp
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_title'))
          .textAlign(TextAlign.Start) // Left aligned
          .margin({ left: 12 }) // Gap 12vp
      }
      .width('100%')
      .height(56 + 38)
      .padding({ top: 38, left: 12, right: 24 }) // Padding: Left 12, Right 24
      .backgroundColor(Color.Transparent)
      .alignItems(VerticalAlign.Center)

      // 表单内容
      Scroll() {
        Column({ space: 16 }) {
          // 设备名称
          Column({ space: 8 }) {
            Text($r('app.string.device_name'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            TextInput({ text: this.device.name })
              .onChange((value: string) => {
                this.device.name = value;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 设备地址
          Column({ space: 8 }) {
            Text($r('app.string.device_address'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            TextInput({ text: this.device.address, placeholder: '192.168.1.100' })
              .onChange((value: string) => {
                this.device.address = value;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // ADB端口
          Column({ space: 8 }) {
            Text($r('app.string.device_adb_port'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            TextInput({ text: this.device.adbPort.toString(), placeholder: '5555' })
              .type(InputType.Number)
              .onChange((value: string) => {
                this.device.adbPort = parseInt(value) || 5555;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 服务端口
          Column({ space: 8 }) {
            Text($r('app.string.device_server_port'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            TextInput({ text: this.device.serverPort.toString(), placeholder: '12580' })
              .type(InputType.Number)
              .onChange((value: string) => {
                this.device.serverPort = parseInt(value) || 12580;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 连接时操作
          Column({ space: 12 }) {
            Text('连接时操作')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
            
            Row() {
              Text('唤醒屏幕')
              Toggle({ type: ToggleType.Switch, isOn: this.device.wakeOnConnect })
                .onChange((isOn: boolean) => {
                  this.device.wakeOnConnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('连接时熄屏')
              Toggle({ type: ToggleType.Switch, isOn: this.device.lightOffOnConnect })
                .onChange((isOn: boolean) => {
                  this.device.lightOffOnConnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('连接时全屏')
              Toggle({ type: ToggleType.Switch, isOn: this.device.changeToFullOnConnect })
                .onChange((isOn: boolean) => {
                  this.device.changeToFullOnConnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('自定义分辨率')
              Toggle({ type: ToggleType.Switch, isOn: this.device.customResolutionOnConnect })
                .onChange((isOn: boolean) => {
                  this.device.customResolutionOnConnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            if (this.device.customResolutionOnConnect) {
              Row({ space: 8 }) {
                TextInput({ text: this.device.customResolutionWidth.toString(), placeholder: 'Width' })
                  .type(InputType.Number)
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.device.customResolutionWidth = parseInt(value) || 1920;
                  })
                
                Text('x')
                
                TextInput({ text: this.device.customResolutionHeight.toString(), placeholder: 'Height' })
                  .type(InputType.Number)
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.device.customResolutionHeight = parseInt(value) || 1080;
                  })
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 运行时操作
          Column({ space: 12 }) {
            Text('运行时操作')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
            
            Row() {
              Text('保持唤醒')
              Toggle({ type: ToggleType.Switch, isOn: this.device.keepAwake })
                .onChange((isOn: boolean) => {
                  this.device.keepAwake = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('运行时修改分辨率')
              Toggle({ type: ToggleType.Switch, isOn: this.device.changeResolutionOnRunning })
                .onChange((isOn: boolean) => {
                  this.device.changeResolutionOnRunning = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            
            Row() {
              Text('剪贴板同步')
              Toggle({ type: ToggleType.Switch, isOn: this.device.listenClipOnRunning })
                .onChange((isOn: boolean) => {
                  this.device.listenClipOnRunning = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('启用音频')
              Toggle({ type: ToggleType.Switch, isOn: this.device.isAudio })
                .onChange((isOn: boolean) => {
                  this.device.isAudio = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            
            Row() {
              Text('使用H265编码')
              Toggle({ type: ToggleType.Switch, isOn: this.device.useH265 })
                .onChange((isOn: boolean) => {
                  this.device.useH265 = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 断开时操作
          Column({ space: 12 }) {
            Text('断开时操作')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
            
            Row() {
              Text('断开时锁屏')
              Toggle({ type: ToggleType.Switch, isOn: this.device.lockOnClose })
                .onChange((isOn: boolean) => {
                  this.device.lockOnClose = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('断开时亮屏')
              Toggle({ type: ToggleType.Switch, isOn: this.device.lightOnClose })
                .onChange((isOn: boolean) => {
                  this.device.lightOnClose = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('断开自动重连')
              Toggle({ type: ToggleType.Switch, isOn: this.device.reconnectOnClose })
                .onChange((isOn: boolean) => {
                  this.device.reconnectOnClose = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 投屏参数
          Column({ space: 12 }) {
            Text('投屏参数')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text('最大尺寸')
                .layoutWeight(1)
              TextInput({ text: this.device.maxSize.toString(), placeholder: '1920' })
                .type(InputType.Number)
                .width(100)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  this.device.maxSize = parseInt(value) || 1920;
                })
            }
            .width('100%')

            Row() {
              Text('最大帧率')
                .layoutWeight(1)
              TextInput({ text: this.device.maxFps.toString(), placeholder: '60' })
                .type(InputType.Number)
                .width(100)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  this.device.maxFps = parseInt(value) || 60;
                })
            }
            .width('100%')

            Row() {
              Text('比特率 (Mbps)')
                .layoutWeight(1)
              TextInput({ text: this.device.maxVideoBit.toString(), placeholder: '4' })
                .type(InputType.Number)
                .width(100)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  this.device.maxVideoBit = parseInt(value) || 4;
                })
            }
            .width('100%')
            
            Row() {
              Text('开机自动连接')
              Toggle({ type: ToggleType.Switch, isOn: this.device.connectOnStart })
                .onChange((isOn: boolean) => {
                  this.device.connectOnStart = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)
        }
        .padding(16)
      }
      .layoutWeight(1)

      // 底部按钮
      Row({ space: 16 }) {
        if (this.isEdit) {
          Button('删除', { type: ButtonType.Capsule, stateEffect: true })
            .fontSize(16)
            .backgroundColor($r('app.color.btn_danger_bg'))
            .fontColor($r('app.color.btn_danger_text'))
            .width(120)
            .height(44)
            .onClick(() => {
              this.deleteDevice();
            })
        }
        
        Button($r('app.string.device_button'), { type: ButtonType.Capsule, stateEffect: true })
          .fontSize(16)
          .backgroundColor($r('app.color.btn_primary'))
          .width(120)
          .height(44)
          .layoutWeight(1)
          .onClick(() => {
            this.saveDevice();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 + 24 }) // Add nav bar height
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  async saveDevice() {
    if (!this.device.name || !this.device.address) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '请填写完整信息' });
      } catch (e) {
        console.error('Show toast failed:', e);
      }
      return;
    }

    try {
      if (this.isEdit) {
        await this.preferencesHelper.update(this.device);
      } else {
        await this.preferencesHelper.insert(this.device);
      }
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_success') });
      } catch (e) {
        console.error('Show toast failed:', e);
      }
      this.getUIContext().getRouter().back();
    } catch (err) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_fail') });
      } catch (e) {
        console.error('Show toast failed:', e);
      }
    }
  }

  async deleteDevice() {
    try {
      await this.preferencesHelper.delete(this.device.uuid);
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_success') });
      } catch (e) {
        console.error('Show toast failed:', e);
      }
      this.getUIContext().getRouter().back();
    } catch (err) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_fail') });
      } catch (e) {
        console.error('Show toast failed:', e);
      }
    }
  }
}
