import { Device } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

@Entry
@Component
struct Index {
  @State devicesList: Device[] = [];
  @State currentIndex: number = 0;
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private tabsController: TabsController = new TabsController();

  aboutToAppear() {
    this.initPreferences();
  }
  
  onPageShow() {
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

  @Builder
  CustomTabBar() {
    Row() {
      // Tab 1: Home
      Column() {
        SymbolGlyph(this.currentIndex === 0 ? $r('sys.symbol.house') : $r('sys.symbol.house'))
          .fontSize(24)
          .fontColor([this.currentIndex === 0 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary')])
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.currentIndex = 0;
        this.tabsController.changeIndex(0);
      })

      // Tab 2: Add Device (Center Button)
      Column() {
         Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(30)
            .fontColor(['#FFFFFF'])
            .fontWeight(FontWeight.Bold)
        }
        .width(56)
        .height(56)
        .backgroundColor($r('app.color.btn_primary'))
        // .shadow({ radius: 8, color: '#40000000', offsetY: 4 }) // Shadow handled by container
        .onClick(() => {
           router.pushUrl({ url: 'pages/DeviceDetail' }).catch((err: Error) => {
             console.error('Navigate failed:', err);
           });
        })
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)

      // Tab 3: More
      Column() {
        SymbolGlyph(this.currentIndex === 2 ? $r('sys.symbol.gearshape_fill') : $r('sys.symbol.gearshape'))
          .fontSize(24)
          .fontColor([this.currentIndex === 2 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary')])
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.currentIndex = 2;
        this.tabsController.changeIndex(2);
      })
    }
    .width('90%')
    .height(70)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(35) // Capsule shape
    .shadow({ radius: 10, color: '#1A000000', offsetY: 5 })
    .margin({ bottom: 20 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // Layer 1: Tabs Content (Bar hidden)
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
        // Tab 1: Devices
        TabContent() {
          this.DeviceListPage()
        }
        .tabBar(null) // Hide default bar

        // Tab 2: Placeholder for index alignment (Add Button)
        TabContent() {
        }
        .tabBar(null)

        // Tab 3: More
        TabContent() {
          this.MorePage()
        }
        .tabBar(null)
      }
      .width('100%')
      .height('100%')
      .barHeight(0) // Hide default bar
      .scrollable(false)
      .onChange((index: number) => {
        if (index === 1) {
             this.tabsController.changeIndex(this.currentIndex);
        } else {
             this.currentIndex = index;
        }
      })
      .backgroundColor($r('app.color.bg_primary'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // Layer 2: Custom Floating Navigation Bar
      this.CustomTabBar()
    }
    .width('100%')
    .height('100%')
  }

  // --- Page Content Builders ---

  @Builder
  DeviceListPage() {
    Column() {
      // Title
      Row() {
        Text('Scrcpy设备')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16, top: 38 })
      .alignItems(VerticalAlign.Center)

      // Device List
      if (this.devicesList.length === 0) {
        Column() {
          Text('暂无设备')
            .fontSize(16)
            .fontColor($r('app.color.text_tertiary'))
          Text('点击下方 + 按钮添加设备')
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
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MorePage() {
    Column() {
      // Title
      Row() {
        Text('更多')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16, top: 38 })
      .alignItems(VerticalAlign.Center)

      Column() {
        List() {
          ListItem() {
            Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.key'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text('密钥设置')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }
              
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/AdbManagePage' });
            })
          }
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ bottom: 12 })
          
          ListItem() {
             Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.info_circle'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text('关于 / 开源说明')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }
              
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/AboutPage' });
            })
          }
           .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
        }
        .width('100%')
        .padding(16)
      }
      .layoutWeight(1)

      // Footer
      Text('开源说明')
        .fontSize(14)
        .fontColor($r('app.color.btn_primary')) // Blue text
        .margin({ bottom: 24 })
        .onClick(() => {
           // Optionally link to about page as well or just a text
           router.pushUrl({ url: 'pages/AboutPage' });
        })
    }
    .width('100%')
    .height('100%')
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
    .backgroundColor('#00000000')
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