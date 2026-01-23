import { Device, ExtraParam } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';

import { util } from '@kit.ArkTS';

@Entry
@Component
struct DeviceDetail {
  @State device: Device = new Device();
  @State isEdit: boolean = false;
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();

  // 视频编码选项
  private videoCodecOptions: SelectOption[] = [
    { value: 'h264' },
    { value: 'h265' },
    { value: 'av1' }
  ];

  // 音频编码选项
  private audioCodecOptions: SelectOption[] = [
    { value: 'opus' },
    { value: 'aac' },
    { value: 'flac' },
    { value: 'raw' }
  ];

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

      // 表单内容
      Scroll() {
        Column({ space: 16 }) {
          // 基本信息
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

          Column({ space: 8 }) {
            Text($r('app.string.device_adb_port'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            TextInput({ text: this.device.adbPort.toString(), placeholder: '5555' })
              .type(InputType.Number)
              .onChange((value: string) => {
                const num = parseInt(value);
                this.device.adbPort = isNaN(num) ? 0 : num;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 视频设置
          Column({ space: 12 }) {
            Text('视频设置')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text('视频编码')
                .layoutWeight(1)
              Select(this.videoCodecOptions)
                .selected(this.getVideoCodecIndex())
                .value(this.device.videoCodec.toUpperCase())
                .onSelect((index: number) => {
                  this.device.videoCodec = this.videoCodecOptions[index].value as string;
                })
            }
            .width('100%')

            Row() {
              Text('最大尺寸')
                .layoutWeight(1)
              TextInput({ text: this.device.maxSize ? this.device.maxSize.toString() : '', placeholder: '默认' })
                .type(InputType.Number)
                .width(100)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  const num = parseInt(value);
                  this.device.maxSize = isNaN(num) ? 0 : num;
                })
            }
            .width('100%')

            Row() {
              Text('最大帧率')
                .layoutWeight(1)
              TextInput({ text: this.device.maxFps ? this.device.maxFps.toString() : '', placeholder: '默认' })
                .type(InputType.Number)
                .width(100)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  const num = parseInt(value);
                  this.device.maxFps = isNaN(num) ? 0 : num;
                })
            }
            .width('100%')

            Row() {
              Text('比特率 (bps)')
                .layoutWeight(1)
              TextInput({ text: this.device.maxVideoBit ? this.device.maxVideoBit.toString() : '', placeholder: '默认' })
                .type(InputType.Number)
                .width(120)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  const num = parseInt(value);
                  this.device.maxVideoBit = isNaN(num) ? 0 : num;
                })
            }
            .width('100%')

            Row() {
              Text('裁剪区域')
                .layoutWeight(1)
              TextInput({ text: this.device.crop, placeholder: '宽:高:X:Y' })
                .width(150)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  this.device.crop = value;
                })
            }
            .width('100%')

            Row() {
              Text('显示器ID')
                .layoutWeight(1)
              TextInput({ text: this.device.displayId ? this.device.displayId.toString() : '', placeholder: '默认' })
                .type(InputType.Number)
                .width(80)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  const num = parseInt(value);
                  this.device.displayId = isNaN(num) ? 0 : num;
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 音频设置
          Column({ space: 12 }) {
            Text('音频设置')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text('启用音频')
              Toggle({ type: ToggleType.Switch, isOn: this.device.isAudio })
                .onChange((isOn: boolean) => {
                  this.device.isAudio = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            if (this.device.isAudio) {
              Row() {
                Text('音频编码')
                  .layoutWeight(1)
                Select(this.audioCodecOptions)
                  .selected(this.getAudioCodecIndex())
                  .value(this.device.audioCodec.toUpperCase())
                  .onSelect((index: number) => {
                    this.device.audioCodec = this.audioCodecOptions[index].value as string;
                  })
              }
              .width('100%')

              Row() {
                Text('音频比特率 (bps)')
                  .layoutWeight(1)
                TextInput({ text: this.device.maxAudioBit ? this.device.maxAudioBit.toString() : '', placeholder: '默认' })
                  .type(InputType.Number)
                  .width(120)
                  .textAlign(TextAlign.End)
                  .onChange((value: string) => {
                    const num = parseInt(value);
                    this.device.maxAudioBit = isNaN(num) ? 0 : num;
                  })
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 行为设置
          Column({ space: 12 }) {
            Text('行为设置')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text('显示触摸点')
              Toggle({ type: ToggleType.Switch, isOn: this.device.showTouches })
                .onChange((isOn: boolean) => {
                  this.device.showTouches = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('保持唤醒')
              Toggle({ type: ToggleType.Switch, isOn: this.device.stayAwake })
                .onChange((isOn: boolean) => {
                  this.device.stayAwake = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('剪贴板同步')
              Toggle({ type: ToggleType.Switch, isOn: this.device.clipboardAutosync })
                .onChange((isOn: boolean) => {
                  this.device.clipboardAutosync = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('断开时熄屏')
              Toggle({ type: ToggleType.Switch, isOn: this.device.powerOffScreenOnClose })
                .onChange((isOn: boolean) => {
                  this.device.powerOffScreenOnClose = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

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
                    const num = parseInt(value);
                    this.device.customResolutionWidth = isNaN(num) ? 0 : num;
                  })

                Text('x')

                TextInput({ text: this.device.customResolutionHeight.toString(), placeholder: 'Height' })
                  .type(InputType.Number)
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    const num = parseInt(value);
                    this.device.customResolutionHeight = isNaN(num) ? 0 : num;
                  })
              }
              .width('100%')
            }
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

          // 高级选项
          Column({ space: 12 }) {
            Text('高级选项')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text('错误时降低分辨率')
              Toggle({ type: ToggleType.Switch, isOn: this.device.downsizeOnError })
                .onChange((isOn: boolean) => {
                  this.device.downsizeOnError = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('开机自动连接')
              Toggle({ type: ToggleType.Switch, isOn: this.device.connectOnStart })
                .onChange((isOn: boolean) => {
                  this.device.connectOnStart = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text('日志级别')
                .layoutWeight(1)
              Select([
                { value: 'verbose' },
                { value: 'debug' },
                { value: 'info' },
                { value: 'warn' },
                { value: 'error' }
              ])
                .selected(['verbose', 'debug', 'info', 'warn', 'error'].indexOf(this.device.logLevel))
                .value(this.device.logLevel)
                .onSelect((index: number) => {
                  const levels = ['verbose', 'debug', 'info', 'warn', 'error'];
                  this.device.logLevel = levels[index];
                })
                .width(100)
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 额外参数
          Column({ space: 12 }) {
            Row() {
              Text('额外参数')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
              
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(20)
                  .fontColor([Color.White])
              }
              .width(32)
              .height(32)
              .backgroundColor($r('app.color.btn_primary'))
              .onClick(() => {
                const newParam: ExtraParam = { key: '', value: '' };
                this.device.extraParams.push(newParam);
                this.device.extraParams = [...this.device.extraParams]; // trigger re-render
              })
            }
            .width('100%')

            Text('格式: 参数名=值，用于设置未在界面中定义的服务端参数')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')

            ForEach(this.device.extraParams, (param: ExtraParam, index: number) => {
              Row({ space: 8 }) {
                TextInput({ text: param.key, placeholder: '参数名' })
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.device.extraParams[index].key = value;
                  })
                
                Text('=')
                  .fontSize(16)
                  .fontColor($r('app.color.text_secondary'))
                
                TextInput({ text: param.value, placeholder: '值' })
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.device.extraParams[index].value = value;
                  })
                
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.minus'))
                    .fontSize(18)
                    .fontColor([$r('app.color.icon_red')])
                }
                .width(32)
                .height(32)
                .backgroundColor($r('app.color.bg_action_red'))
                .onClick(() => {
                  this.device.extraParams.splice(index, 1);
                  this.device.extraParams = [...this.device.extraParams]; // trigger re-render
                })
              }
              .width('100%')
            }, (param: ExtraParam, index: number) => `${index}`)
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
      .padding({ left: 16, right: 16, bottom: 16 + 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  getVideoCodecIndex(): number {
    const index = this.videoCodecOptions.findIndex(opt => opt.value === this.device.videoCodec);
    return index >= 0 ? index : 0;
  }

  getAudioCodecIndex(): number {
    const index = this.audioCodecOptions.findIndex(opt => opt.value === this.device.audioCodec);
    return index >= 0 ? index : 0;
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
