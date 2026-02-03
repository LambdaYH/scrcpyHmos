import { Device, ExtraParam } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerDeviceDetail } from '../helper/Logger';

import { util } from '@kit.ArkTS';

@Entry
@Component
struct DeviceDetail {
  @State device: Device = new Device('', 0);
  @State isEditMode: boolean = false;
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();

  // 视频编码选项
  private videoCodecOptions: SelectOption[] = [
    { value: 'h264' },
    { value: 'h265' }
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
        this.isEditMode = true;
      } else {
        this.initDefaultDevice();
      }
    } catch (e) {
      LoggerDeviceDetail.error('Failed to get router params:', e);
      // 默认为新设备
      this.initDefaultDevice();
    }
  }

  private initDefaultDevice(): void {
    // 生成UUID
    this.device.uuid = util.generateRandomUUID(true);

    // 生成时间戳 YYYYMMDDHHmm
    const now = new Date();
    const timestamp = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}`;

    try {
      const baseName = this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.new_device').id);
      this.device.name = `${baseName} ${timestamp}`;
    } catch (e) {
      this.device.name = `New Device ${timestamp}`;
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

        Text(this.isEditMode ? $r('app.string.edit_device') : $r('app.string.add_device_title'))
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
            TextInput({ text: this.device.address, placeholder: '127.0.0.1' })
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

          Row() {
            Text($r('app.string.show_bottom_nav_bar'))
            Toggle({ type: ToggleType.Switch, isOn: this.device.showBottomNavBar })
              .onChange((isOn: boolean) => {
                this.device.showBottomNavBar = isOn;
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)

          // 视频设置
          Column({ space: 12 }) {
            Text($r('app.string.video_settings'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.video_codec'))
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
              Text($r('app.string.max_size'))
                .layoutWeight(1)
              TextInput({ text: this.device.maxSize ? this.device.maxSize.toString() : '', placeholder: $r('app.string.default_value') })
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
              Text($r('app.string.max_fps'))
                .layoutWeight(1)
              TextInput({ text: this.device.maxFps ? this.device.maxFps.toString() : '', placeholder: $r('app.string.default_value') })
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
              Text($r('app.string.bitrate'))
                .layoutWeight(1)
              TextInput({ text: this.device.maxVideoBit ? this.device.maxVideoBit.toString() : '', placeholder: $r('app.string.default_value') })
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
              Text($r('app.string.crop'))
                .layoutWeight(1)
              TextInput({ text: this.device.crop, placeholder: $r('app.string.crop_placeholder') })
                .width(150)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  this.device.crop = value;
                })
            }
            .width('100%')

            Row() {
              Text($r('app.string.display_id'))
                .layoutWeight(1)
              TextInput({ text: this.device.displayId ? this.device.displayId.toString() : '', placeholder: $r('app.string.default_value') })
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
            Text($r('app.string.audio_settings'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.enable_audio'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.isAudio })
                .onChange((isOn: boolean) => {
                  this.device.isAudio = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            if (this.device.isAudio) {
              Row() {
                Text($r('app.string.audio_codec'))
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
                Text($r('app.string.audio_bitrate'))
                  .layoutWeight(1)
                TextInput({ text: this.device.maxAudioBit ? this.device.maxAudioBit.toString() : '', placeholder: $r('app.string.default_value') })
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
            Text($r('app.string.behavior_settings'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.show_touches'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.showTouches })
                .onChange((isOn: boolean) => {
                  this.device.showTouches = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.stay_awake'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.stayAwake })
                .onChange((isOn: boolean) => {
                  this.device.stayAwake = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.clipboard_autosync'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.clipboardAutosync })
                .onChange((isOn: boolean) => {
                  this.device.clipboardAutosync = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.turn_screen_off_on_close'))
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
            Text($r('app.string.connection_actions'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.turn_screen_on'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.wakeOnConnect })
                .onChange((isOn: boolean) => {
                  this.device.wakeOnConnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.turn_screen_off'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.lightOffOnConnect })
                .onChange((isOn: boolean) => {
                  this.device.lightOffOnConnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.fullscreen_on_connect'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.changeToFullOnConnect })
                .onChange((isOn: boolean) => {
                  this.device.changeToFullOnConnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.custom_resolution'))
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
            Text($r('app.string.disconnection_actions'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.lock_screen'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.lockOnClose })
                .onChange((isOn: boolean) => {
                  this.device.lockOnClose = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.turn_screen_on_disconnect'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.lightOnClose })
                .onChange((isOn: boolean) => {
                  this.device.lightOnClose = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.auto_reconnect'))
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
            Text($r('app.string.advanced_options'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.downsize_on_error'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.downsizeOnError })
                .onChange((isOn: boolean) => {
                  this.device.downsizeOnError = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.connect_on_start'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.connectOnStart })
                .onChange((isOn: boolean) => {
                  this.device.connectOnStart = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.server_log_level'))
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
              Text($r('app.string.extra_params'))
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

            Text($r('app.string.extra_params_hint'))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')

            ForEach(this.device.extraParams, (param: ExtraParam, index: number) => {
              Row({ space: 8 }) {
                TextInput({ text: param.key, placeholder: $r('app.string.param_name') })
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.device.extraParams[index].key = value;
                  })
                
                Text('=')
                  .fontSize(16)
                  .fontColor($r('app.color.text_secondary'))
                
                TextInput({ text: param.value, placeholder: $r('app.string.param_value') })
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
      .edgeEffect(EdgeEffect.Spring) // 添加下拉/上拉回弹效果

      // 底部按钮
      Row({ space: 16 }) {
        if (this.isEditMode) {
          Button($r('app.string.delete'), { type: ButtonType.Capsule, stateEffect: true })
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
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.fill_complete_info') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
      return;
    }

    try {
      if (this.isEditMode) {
        await this.preferencesHelper.update(this.device);
      } else {
        await this.preferencesHelper.insert(this.device);
      }
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_success') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
      this.getUIContext().getRouter().back();
    } catch (err) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_fail') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
    }
  }

  async deleteDevice() {
    try {
      await this.preferencesHelper.delete(this.device.uuid);
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_success') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
      this.getUIContext().getRouter().back();
    } catch (err) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_fail') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
    }
  }
}
