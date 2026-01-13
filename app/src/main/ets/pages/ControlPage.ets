import { Device } from '../entity/Device';
import { Client } from '../client/Client';
import { TouchAction, KeyCode, Action } from '../client/tools/ControlPacket';
import router from '@ohos.router';
import window from '@ohos.window';
import { common } from '@kit.AbilityKit';

@Entry
@Component
struct ControlPage {
  @State device?: Device = undefined;
  @State surfaceId: string = '';
  @State videoWidth: number = 1920;
  @State videoHeight: number = 1080;
  @State componentWidth: number = 0;  // 实际组件宽度(px)
  @State componentHeight: number = 0;  // 实际组件高度(px)
  @State isConnected: boolean = false;
  @State connectionStatus: string = 'Connecting...';
  @State showLoading: boolean = true;
  
  // 悬浮按钮状态
  @State showControlPanel: boolean = false;  // 控制面板是否展开
  @State fabX: number = 0; // 悬浮按钮X位置
  @State fabY: number = 0; // 悬浮按钮Y位置
  @State checkFabPosition: boolean = false; // 是否需要初始化位置
  
  private client: Client | null = null;
  private xComponentController: XComponentController = new XComponentController();
  private pointerDownTime: Map<number, number> = new Map();  // 存储毫秒时间戳
  private surfaceReady: boolean = false;
  private clientReady: boolean = false;
  private autoHideTimer: number = -1;
  private readonly FAB_SIZE = 30; // 悬浮按钮大小
  // 临时存储拖动开始时的位置
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  // 追踪是否正在滑动，防止 TapGesture 干扰滑动操作
  private isPanning: boolean = false;
  private panMoveCount: number = 0;  // 记录 MOVE 事件数量
  
  aboutToAppear() {
    try {
      const params = this.getUIContext().getRouter().getState().params as Record<string, Object>;
      if (params && params['device']) {
        this.device = params['device'] as Device;
        this.connectDevice();
      }
    } catch (e) {
      console.error('Failed to get router params:', e);
    }
    
    // 设置全屏并隐藏导航条
    this.setFullScreen();
  }
  
  async setFullScreen() {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass = await window.getLastWindow(ctx);
      // 设置全屏布局
      await windowClass.setWindowLayoutFullScreen(true);
      // 隐藏状态栏和导航栏
      await windowClass.setWindowSystemBarEnable([]);
    } catch (err) {
      console.error('Set fullscreen failed:', err);
    }
  }
  
  async connectDevice() {
    if (!this.device) {
      console.error('ControlPage: No device available');
      return;
    }
    
    try {
      this.connectionStatus = 'Connecting to device...';
      console.info('ControlPage: Starting connection to device:', this.device.name);
      console.info('ControlPage: Device address:', this.device.address, 'port:', this.device.adbPort);
      
      // 显示授权提示
      this.connectionStatus = '连接中...如果是首次连接，请在Android设备上授权USB调试';

      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.client = await Client.startDevice(this.device, ctx, this.getUIContext());
      console.info('ControlPage: Client.startDevice returned:', this.client ? 'success' : 'null');
      
      if (this.client) {
        this.isConnected = true;
        this.showLoading = false;
        this.connectionStatus = 'Connected';
        this.clientReady = true;
        console.info('ControlPage: Device connected successfully');
        
        // 如果surface已经就绪，立即初始化视频解码器
        if (this.surfaceReady && this.surfaceId) {
          this.initVideoDecoder();
        }
        
        // 启动自动隐藏定时器
        this.startAutoHideTimer();
      } else {
        this.showLoading = false;
        this.connectionStatus = 'Connection failed';
        console.error('ControlPage: Client.startDevice returned null');
        try {
          this.getUIContext().getPromptAction().showToast({ message: '连接失败。请检查设备是否开启ADB，并在设备上授权USB调试。' });
        } catch (e) {
          console.error('Show toast failed:', e);
        }
        console.error('Failed to start client - check if device is reachable and ADB is enabled');
      }
    } catch (err) {
      this.showLoading = false;
      this.connectionStatus = 'Connection error';
      const errMsg = err instanceof Error ? err.message : String(err);
      console.error('ControlPage: Connect device exception:', errMsg);
      
      // 根据错误类型显示不同的提示
      let toastMsg = '连接错误';
      if (errMsg.includes('timeout')) {
        toastMsg = '连接超时。请确保在Android设备上点击了"允许"授权USB调试。';
      }
      
      try {
        this.getUIContext().getPromptAction().showToast({ message: toastMsg });
      } catch (e) {
        console.error('Show toast failed:', e);
      }
    }
  }
  
  aboutToDisappear() {
    this.clearAutoHideTimer();
    this.client?.close();
    // 恢复系统栏
    this.restoreSystemBar();
  }
  
  async restoreSystemBar() {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass = await window.getLastWindow(ctx);
      await windowClass.setWindowSystemBarEnable(['status', 'navigation']);
    } catch (err) {
      console.error('Restore system bar failed:', err);
    }
  }
  
  // 启动自动隐藏定时器
  startAutoHideTimer() {
    this.clearAutoHideTimer();
    this.autoHideTimer = setTimeout(() => {
      if (!this.showControlPanel && this.componentWidth > 0) {
        // 贴边隐藏：只露出一半
        const hiddenX = this.componentWidth - this.FAB_SIZE / 2;
        animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
          this.fabX = hiddenX;
        })
      }
    }, 3000) as number;
  }
  
  // 清除自动隐藏定时器
  clearAutoHideTimer() {
    if (this.autoHideTimer !== -1) {
      clearTimeout(this.autoHideTimer);
      this.autoHideTimer = -1;
    }
  }
  
  // 显示悬浮按钮
  showFab() {
    if (this.componentWidth > 0) {
      const visibleX = this.componentWidth - this.FAB_SIZE - 20; // 离右边20px
      animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
        this.fabX = visibleX;
      })
      this.startAutoHideTimer();
    }
  }
  
  // 切换控制面板
  toggleControlPanel() {
    // 如果当前是隐藏状态(靠边)，先显示出来
    if (this.componentWidth > 0 && this.fabX > this.componentWidth - this.FAB_SIZE) {
        this.showFab();
        return;
    }

    this.showControlPanel = !this.showControlPanel;
    if (this.showControlPanel) {
      this.clearAutoHideTimer();
    } else {
      this.startAutoHideTimer();
    }
  }

  // 初始化悬浮按钮位置
  initFabPosition() {
    if (this.componentWidth > 0 && this.componentHeight > 0 && !this.checkFabPosition) {
       this.fabX = this.componentWidth - this.FAB_SIZE - 20; // 默认右下角
       this.fabY = this.componentHeight - 150;
       this.checkFabPosition = true;
    }
  }
  
  build() {
    Stack() {
      // Loading indicator
      if (this.showLoading) {
        Column() {
          LoadingProgress()
            .width(80)
            .height(80)
            .color('#FFFFFF')
          Text(this.connectionStatus)
            .fontSize(16)
            .fontColor('#FFFFFF')
            .margin({ top: 16 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#000000')
      }
      
      // 视频显示区域
      XComponent({
        id: 'video_surface',
        type: 'surface',
        controller: this.xComponentController
      })
        .onLoad(() => {
          this.surfaceId = this.xComponentController.getXComponentSurfaceId();
          this.surfaceReady = true;
          console.debug('XComponent surfaceId:', this.surfaceId);
          
          // 如果client已经就绪,立即初始化视频解码器
          if (this.clientReady && this.client) {
            this.initVideoDecoder();
          }
        })
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .onAreaChange((oldArea: Area, newArea: Area) => {
          // 获取组件实际尺寸(px)
          this.componentWidth = newArea.width as number;
          this.componentHeight = newArea.height as number;
          console.debug(`XComponent size: ${this.componentWidth}x${this.componentHeight}`);
          this.initFabPosition();
        })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            // 触摸手势
            TapGesture({ count: 1, fingers: 1 })
              .onAction((event: GestureEvent) => {
                this.handleTap(event);
              }),
            // 多指触摸
            PanGesture({ fingers: 1, distance: 0 })
              .onActionStart((event: GestureEvent) => {
                this.handleTouchStart(event);
              })
              .onActionUpdate((event: GestureEvent) => {
                this.handleTouchMove(event);
              })
              .onActionEnd((event: GestureEvent) => {
                this.handleTouchEnd(event);
              })
          )
        )
      
      // 悬浮控制按钮
      Column() {
        // 展开的控制面板
        if (this.showControlPanel) {
          Column({ space: 8 }) {
            // 返回上一页（Android返回键）
            Button() {
              SymbolGlyph($r('sys.symbol.arrow_left'))
                .fontSize(24)
                .fontColor(['#FFFFFF'])
            }
            .width(44)
            .height(44)
            .backgroundColor('#80000000')
            .borderRadius(22)
            .onClick(() => {
              this.client?.sendKeyEvent(KeyCode.KEYCODE_BACK);
            })
            
            // 主页（Android Home键）
            Button() {
              SymbolGlyph($r('sys.symbol.house'))
                .fontSize(22)
                .fontColor(['#FFFFFF'])
            }
            .width(44)
            .height(44)
            .backgroundColor('#80000000')
            .borderRadius(22)
            .onClick(() => {
              this.client?.sendKeyEvent(KeyCode.KEYCODE_HOME);
            })
            
            // 多任务界面（Android Recent Apps键）
            Button() {
              SymbolGlyph($r('sys.symbol.square'))
                .fontSize(22)
                .fontColor(['#FFFFFF'])
            }
            .width(44)
            .height(44)
            .backgroundColor('#80000000')
            .borderRadius(22)
            .onClick(() => {
              this.client?.sendKeyEvent(KeyCode.KEYCODE_APP_SWITCH);
            })
            
            // 断开连接并返回
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(22)
                .fontColor(['#FFFFFF'])
            }
            .width(44)
            .height(44)
            .borderRadius(22)
            .onClick(() => {
              this.client?.close();
              this.getUIContext().getRouter().back();
            })
          }
          .padding(8)
          .backgroundColor('#40000000')
          .borderRadius(12)
          .margin({ bottom: 8 })
          // 防止面板捕获拖动手势
          .gesture(TapGesture().onAction(()=>{
             // 吞噬点击
          }))
        }
        
        // 悬浮触发按钮 - 白色小圆圈
        Column()
          .width(this.FAB_SIZE)
          .height(this.FAB_SIZE)
          .backgroundColor(this.showControlPanel ? '#FFFFFF' : '#B0FFFFFF')
          .borderRadius(this.FAB_SIZE / 2)
          .border({
            width: 2,
            color: '#80FFFFFF'
          })
          .shadow({
            radius: 6,
            color: '#40000000',
            offsetX: 1,
            offsetY: 1
          })
          .onClick(() => {
            this.toggleControlPanel();
          })
      }
      .alignItems(HorizontalAlign.Center)
      .position({ x: this.fabX + this.FAB_SIZE / 2, y: this.fabY + this.FAB_SIZE })
      .markAnchor({ x: '50%', y: '100%' })
      .zIndex(200)
      .gesture(
          PanGesture({ fingers: 1, direction: PanDirection.All })
            .onActionStart((event: GestureEvent) => {
               this.clearAutoHideTimer();
               if (this.showControlPanel) {
                 this.showControlPanel = false;
               }
               this.dragStartX = this.fabX;
               this.dragStartY = this.fabY;
            })
            .onActionUpdate((event: GestureEvent) => {
               if (this.componentWidth > 0) {
                 this.fabX = this.dragStartX + event.offsetX;
                 this.fabY = this.dragStartY + event.offsetY;
               }
            })
            .onActionEnd((event: GestureEvent) => {
               // 拖动结束，吸附到右侧
               if (this.componentWidth > 0) {
                 const dockX = this.componentWidth - this.FAB_SIZE - 20;
                 
                 // 限制Y轴防止跑出屏幕
                 let targetY = this.fabY;
                 if (targetY < 50) targetY = 50;
                 if (targetY > this.componentHeight - 150) targetY = this.componentHeight - 150;

                 animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                    this.fabX = dockX;
                    this.fabY = targetY;
                 });
                 
                 this.startAutoHideTimer();
               }
            })
      )
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
  
  handleTap(event: GestureEvent) {
    if (!this.client) return;
    
    // 如果正在滑动或刚滑动过（有MOVE事件），忽略 TAP 事件
    // 这是因为 PanGesture 和 TapGesture 并行运行，滑动结束时 TAP 会错误触发
    if (this.isPanning || this.panMoveCount > 0) {
      return;
    }
    
    const localX = event.fingerList[0].localX;
    const localY = event.fingerList[0].localY;
    const x = localX / this.componentWidth;
    const y = localY / this.componentHeight;
    
    // 模拟点击（按下-抬起）
    this.client.sendTouchEvent(TouchAction.ACTION_DOWN, 0, x, y, 0);
    setTimeout(() => {
      this.client?.sendTouchEvent(TouchAction.ACTION_UP, 0, x, y, 50);
    }, 50);
  }
  
  handleTouchStart(event: GestureEvent) {
    if (!this.client) return;
    
    // 标记开始滑动
    this.isPanning = true;
    this.panMoveCount = 0;
    
    // GestureEvent.timestamp 是纳秒级，如果为0或无效则使用 Date.now()
    // 注意：模拟器上 timestamp 可能返回0
    const eventTimestampMs = event.timestamp > 0 ? Math.floor(event.timestamp / 1000000) : Date.now();
    
    event.fingerList.forEach((finger) => {
      const localX = finger.localX;
      const localY = finger.localY;
      const x = localX / this.componentWidth;
      const y = localY / this.componentHeight;
      const pointerId = finger.id;
      
      // 存储毫秒时间戳
      this.pointerDownTime.set(pointerId, eventTimestampMs);
      this.client?.sendTouchEvent(TouchAction.ACTION_DOWN, pointerId, x, y, 0);
    });
  }
  
  handleTouchMove(event: GestureEvent) {
    if (!this.client) return;
    
    // 增加 MOVE 事件计数
    this.panMoveCount++;
    
    // GestureEvent.timestamp 是纳秒级，如果为0或无效则使用 Date.now()
    const eventTimestampMs = event.timestamp > 0 ? Math.floor(event.timestamp / 1000000) : Date.now();
    
    event.fingerList.forEach((finger) => {
      const localX = finger.localX;
      const localY = finger.localY;
      const x = localX / this.componentWidth;
      const y = localY / this.componentHeight;
      const pointerId = finger.id;
      const downTimeMs = this.pointerDownTime.get(pointerId) || eventTimestampMs;
      const offsetTime = eventTimestampMs - downTimeMs;
      
      this.client?.sendTouchEvent(TouchAction.ACTION_MOVE, pointerId, x, y, offsetTime);
    });
  }
  
  handleTouchEnd(event: GestureEvent) {
    if (!this.client) return;
    
    // 结束滑动
    this.isPanning = false;
    // 延迟重置 panMoveCount，给 TapGesture 时间先触发并被忽略
    setTimeout(() => {
      this.panMoveCount = 0;
    }, 100);
    
    // GestureEvent.timestamp 是纳秒级，如果为0或无效则使用 Date.now()
    const eventTimestampMs = event.timestamp > 0 ? Math.floor(event.timestamp / 1000000) : Date.now();
    
    event.fingerList.forEach((finger) => {
      const localX = finger.localX;
      const localY = finger.localY;
      const x = localX / this.componentWidth;
      const y = localY / this.componentHeight;
      const pointerId = finger.id;
      const downTimeMs = this.pointerDownTime.get(pointerId) || eventTimestampMs;
      const offsetTime = eventTimestampMs - downTimeMs;
      
      this.client?.sendTouchEvent(TouchAction.ACTION_UP, pointerId, x, y, offsetTime);
      this.pointerDownTime.delete(pointerId);
    });
  }

  
  // 初始化视频解码器的辅助方法
  private initVideoDecoder(): void {
    if (!this.client || !this.surfaceId) {
      console.error('Cannot init video decoder: client or surfaceId missing');
      return;
    }
    
    console.info('Initializing video decoder with surfaceId:', this.surfaceId);
    this.client.initVideoDecoder(this.surfaceId).catch((err: Error) => {
      console.error('Failed to init video decoder:', err.message);
      this.getUIContext().getPromptAction().showToast({ message: '视频解码器初始化失败: ' + err.message });
    });
  }
}
