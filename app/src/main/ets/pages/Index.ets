import { Device } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { Client } from '../client/Client';

import { common } from '@kit.AbilityKit';

@Entry
@Component
struct Index {
  @State devicesList: Device[] = [];
  @State currentIndex: number = 0;
  @State isConnecting: boolean = false;
  @State connectionStatus: string = '';
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private tabsController: TabsController = new TabsController();
  private connectingClient: Client | null = null;

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
        SymbolGlyph($r('sys.symbol.house'))
          .fontSize(24) // Standard 24vp
          .fontColor([this.currentIndex === 0 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary')])
        Text('设备')
          .fontSize(10) // Standard 10fp
          .fontWeight(FontWeight.Medium)
          .fontColor(this.currentIndex === 0 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary'))
          .margin({ top: 4 }) // Standard 4vp spacing
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .stateStyles({
        pressed: {
          .scale({ x: 0.8, y: 0.8 })
        },
        normal: {
          .scale({ x: 1.0, y: 1.0 })
        }
      })
      .animation({ duration: 150, curve: Curve.EaseInOut })
      .onClick(() => {
        this.currentIndex = 0;
        this.tabsController.changeIndex(0);
      })

      // Tab 2: Add Device (Floating Action Button Style)
      Column() {
        Column() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(28)
            .fontColor([Color.White])
        }
        .width(48)
        .height(48)
        .borderRadius(24)
        .backgroundColor($r('app.color.btn_primary'))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .shadow({
          radius: 8,
          color: '#40007AFF',
          offsetX: 0,
          offsetY: 4
        })
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .stateStyles({
        pressed: {
          .scale({ x: 0.9, y: 0.9 })
        },
        normal: {
          .scale({ x: 1.0, y: 1.0 })
        }
      })
      .animation({ duration: 150, curve: Curve.EaseInOut })
      .onClick(() => {
        // Direct action
        this.getUIContext().getRouter().pushUrl({ url: 'pages/DeviceDetail' }).catch((err: Error) => {
          console.error('Navigate failed:', err);
        });
      })

      // Tab 3: More
      Column() {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(24) // Standard 24vp
          .fontColor([this.currentIndex === 2 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary')])
        Text('更多')
          .fontSize(10) // Standard 10fp
          .fontWeight(FontWeight.Medium)
          .fontColor(this.currentIndex === 2 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary'))
          .margin({ top: 4 }) // Standard 4vp spacing
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .stateStyles({
        pressed: {
          .scale({ x: 0.9, y: 0.9 })
        },
        normal: {
          .scale({ x: 1.0, y: 1.0 })
        }
      })
      .animation({ duration: 150, curve: Curve.EaseInOut })
      .onClick(() => {
        this.currentIndex = 2;
        this.tabsController.changeIndex(2);
      })
    }
    .width('100%')
    .height(56 + 12) // 56vp content + bottom padding (approx)
    .padding({ bottom: 12 }) // Safe area padding
    .backgroundColor(Color.Transparent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK) // Glassmorphism
    .border({ width: { top: 0.5 }, color: '#1A000000' }) // Subtle top border
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
      
      // Layer 3: Connection Loading Overlay
      if (this.isConnecting) {
        Column() {
          Column() {
            Text('连接中')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .margin({ bottom: 16 })
            
            Text(this.connectionStatus)
              .fontSize(16)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
              .margin({ bottom: 24 })
            
            Button('取消')
              .fontSize(16)
              .fontColor($r('app.color.btn_primary'))
              .backgroundColor(Color.Transparent)
              .width(80)
              .height(40)
              .onClick(() => {
                console.info('[Index] Cancel button clicked');
                this.cancelConnect();
              })
          }
          .width('80%')
          .padding(24)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(16)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.mask_secondary'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .zIndex(999)
        .onClick(() => {
          // 点击遮罩层不做任何事，阻止点击穿透到下层
        })
      }
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
      .height(56 + 38)
      .padding({ left: 24, right: 24, top: 38 })
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
        .height('100%')
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
      .height(56 + 38)
      .padding({ left: 24, right: 24, top: 38 })
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
              this.getUIContext().getRouter().pushUrl({ url: 'pages/AdbManagePage' }).catch((err: Error) => {
                console.error('Push url failed:', err);
              });
            })
          }
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ bottom: 12 })
          
          ListItem() {
             Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.doc_text'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text('使用说明')
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
              this.getUIContext().getRouter().pushUrl({ url: 'pages/HelpPage' }).catch((err: Error) => {
                console.error('Push url failed:', err);
              });
            })
          }
           .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .padding(16)
      }
      .layoutWeight(1)



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
  
  async connectDevice(device: Device) {
    if (this.isConnecting) return;
    
    this.isConnecting = true;
    
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      
      // 第一阶段：等待ADB授权 (在连接开始前提示)
      this.connectionStatus = '正在等待ADB授权...';
      
      // 启动连接
      // 如果设备未授权，这里会阻塞等待用户在该设备上点击允许
      const client = await Client.startDevice(device, ctx, this.getUIContext(), (status: string) => {
        // 更新连接状态
        if (this.isConnecting) {
          this.connectionStatus = status;
        }
      });
      
      // 检查连接过程中是否被取消
      if (!this.isConnecting) {
        console.info('[Index] Connection cancelled by user');
        if (client) {
          await client.close();
        }
        return;
      }
      
      this.connectingClient = client;
      
      if (this.connectingClient) {
        // 连接成功，立即跳转到控制页面
        // 注意：视频解码需要 ControlPage 的 Surface，所以不能在这里等首帧
        console.info('[Index] Connection successful, navigating to ControlPage');
        this.isConnecting = false;
        
        // 跳转到控制页面，传递已连接的 client
        this.getUIContext().getRouter().pushUrl({
          url: 'pages/ControlPage',
          params: { device: device, clientReady: true }
        }).catch((err: Error) => {
          console.error('Navigate failed:', err);
          this.getUIContext().getPromptAction().showToast({ message: '跳转失败' });
        });
        
      } else {
        this.isConnecting = false;
        this.getUIContext().getPromptAction().showToast({ 
          message: '连接失败。请检查设备是否开启ADB，并在设备上授权USB调试。' 
        });
      }
    } catch (err) {
      this.isConnecting = false;
      this.connectingClient = null;
      const errMsg = err instanceof Error ? err.message : String(err);
      console.error('Connect device failed:', errMsg);
      this.getUIContext().getPromptAction().showToast({ message: '连接错误: ' + errMsg });
    }
  }
  
  // 取消连接
  cancelConnect() {
    if (this.connectingClient) {
      this.connectingClient.close();
      this.connectingClient = null;
    }
    this.isConnecting = false;
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
    .backgroundColor(Color.Transparent)
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