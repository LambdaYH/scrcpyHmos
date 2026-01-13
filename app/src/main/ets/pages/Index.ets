import { Device } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';

import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

@Entry
@Component
struct Index {
  @State devicesList: Device[] = [];
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();

  aboutToAppear() {
    this.initPreferences();
  }
  
  onPageShow() {
    // Reload devices when page shows (e.g., after adding a device)
    this.loadDevices();
  }
  
  async initPreferences() {
    try {
      const context = getContext(this) as Context;
      await this.preferencesHelper.init(context);
      await this.loadDevices();
    } catch (err) {
      console.error('Init preferences failed:', err);
    }
  }

  async loadDevices() {
    this.devicesList = this.preferencesHelper.getDevicesList();
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('Scrcpy设备')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        
        Row() {
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(24)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor('#00000000')
          .onClick(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/DeviceDetail' }).catch((err: Error) => {
              console.error('Navigate failed:', err);
            });
          })

          // 更多菜单按钮
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
              .fontSize(24)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(40)
          .height(40)
          .backgroundColor('#00000000')
          .margin({ left: 8 })
          .bindMenu([
            {
              value: '密钥管理',
              action: () => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/AdbManagePage' });
              }
            },
            {
              value: '关于 / 开源说明',
              action: () => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/AboutPage' });
              }
            }
          ])
        }
      }
      .width('100%')
      .height(56 + 38)
      .padding({ left: 16, right: 16, top: 38 })
      .justifyContent(FlexAlign.SpaceBetween)
      
      // 设备列表
      if (this.devicesList.length === 0) {
        Column() {
          Text('暂无设备')
            .fontSize(16)
            .fontColor($r('app.color.text_tertiary'))
          Text('点击右上角添加设备')
            .fontSize(14)
            .fontColor($r('app.color.text_placeholder'))
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 12 }) {
          ForEach(this.devicesList, (device: Device) => {
            ListItem() {
              this.DeviceItemView(device)
            }
            .swipeAction({ end: this.ItemEnd(device) })
          })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 0, bottom: 0 })
      }
      
      // 底部按钮
      // Row() {
      //   Button('添加设备')
      //     ...
      // }
      // .width('100%')
      // .height(60 + 24) 
      // .padding({ bottom: 24 })
      // .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
  
  @Builder
  DeviceItemView(device: Device) {
    Column() {
      Row() {
        Column() {
          Text(device.name)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(`${device.address}:${device.adbPort}`)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        
        Button('连接')
          .fontSize(14)
          .width(80)
          .height(36)
          .onClick(() => {
            this.connectDevice(device);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(8)
  }
  
  connectDevice(device: Device) {
    // 跳转到控制页面
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ControlPage',
      params: { device: device }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '连接失败' });
    });
  }
  @Builder
  ItemEnd(device: Device) {
    Row({ space: 12 }) {
      // 编辑按钮
      Column() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(20)
            .fontColor([$r('app.color.icon_blue')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.bg_action_blue'))
        .onClick(() => {
          this.editDevice(device);
        })
      }
      .justifyContent(FlexAlign.Center)
      .height('100%')

      // 删除按钮
      Column() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(20)
            .fontColor([$r('app.color.icon_red')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.bg_action_red'))
        .onClick(() => {
          this.deleteDevice(device);
        })
      }
      .justifyContent(FlexAlign.Center)
      .height('100%')
    }
    .padding({ left: 16, right: 16 })
    .height('100%')
    .backgroundColor('#00000000') // 透明背景
  }

  editDevice(device: Device) {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/DeviceDetail',
      params: { device: device }
    }).catch((err: Error) => {
      console.error('Navigate to edit page failed:', err);
    });
  }

  async deleteDevice(device: Device) {
    try {
      // 1. Delete device from preferences
      await this.preferencesHelper.delete(device.uuid);
      
      await this.loadDevices();
      try {
        this.getUIContext().getPromptAction().showToast({ message: 'Deleted successfully' });
      } catch (e) {
        console.error('Show toast failed:', e);
      }
    } catch (err) {
      console.error('Delete device failed:', err);
      try {
        this.getUIContext().getPromptAction().showToast({ message: 'Delete failed' });
      } catch (e) {
        console.error('Show toast failed:', e);
      }
    }
  }
}