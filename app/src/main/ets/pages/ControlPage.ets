import { Device } from '../entity/Device';
import { Client } from '../client/Client';
import { TouchAction, KeyCode } from '../client/tools/ControlPacket';
import { LoggerControlPage } from '../helper/Logger';
import window from '@ohos.window';
import { common } from '@kit.AbilityKit';
import pasteboard from '@ohos.pasteboard';

@Entry
@Component
struct ControlPage {
  @State device?: Device = undefined;
  @State surfaceId: string = '';
  @State videoWidth: number = 1920;
  @State videoHeight: number = 1080;
  @State componentWidth: number = 0;  // 实际组件宽度(px)
  @State componentHeight: number = 0;  // 实际组件高度(px)
  @State containerWidth: number = 0;    // 容器宽度(px)
  @State containerHeight: number = 0;   // 容器高度(px)
  @State displayXComponentWidth: number = 0; // 计算后的显示宽度
  @State displayXComponentHeight: number = 0; // 计算后的显示高度

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
        
        // 检查是否是从 Index 页面预连接后跳转的
        if (params['clientReady'] === true) {
          // 客户端已连接，从缓存获取
          this.initFromExistingClient();
        } else {
          // 旧的流程 - 在本页面连接 (兼容性保留)
          this.connectDevice();
        }
      }
    } catch (e) {
      LoggerControlPage.error('Failed to get router params:', e);
    }
    
    // 设置全屏并隐藏导航条
    this.setFullScreen();
  }
  
  aboutToDisappear() {
    LoggerControlPage.info('ControlPage: aboutToDisappear - cleaning up');
    
    // 停止自动隐藏定时器
    if (this.autoHideTimer !== -1) {
      clearTimeout(this.autoHideTimer);
      this.autoHideTimer = -1;
    }
    
    // 关闭客户端连接
    if (this.client) {
      LoggerControlPage.info('ControlPage: Closing client connection');
      this.client.close();
      this.client = null;
    }
    
    // 恢复窗口状态
    this.restoreWindow();
  }
  
  async restoreWindow() {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass = await window.getLastWindow(ctx);
      // 恢复状态栏和导航栏
      await windowClass.setWindowSystemBarEnable(['status', 'navigation']);
      // 保持全屏布局，避免跳动，因为主页也是全屏布局
      await windowClass.setWindowLayoutFullScreen(true);
    } catch (err) {
      LoggerControlPage.error('Restore window failed:', err);
    }
  }

  // 统一退出页面逻辑
  async exitPage() {
    // 先恢复窗口状态
    await this.restoreWindow();
    // 再返回
    try {
      this.getUIContext().getRouter().back();
    } catch (e) {
      LoggerControlPage.error('Router back failed:', e);
    }
  }
  
  // 从已连接的客户端初始化
  private initFromExistingClient(): void {
    if (!this.device) return;
    
    // 从 Client 缓存获取已连接的实例
    this.client = Client.getClient(this.device.uuid);
    
    if (this.client) {
      this.isConnected = true;
      this.showLoading = false;  // 已经有视频流了
      this.connectionStatus = 'Connected';
      this.clientReady = true;
      LoggerControlPage.info('ControlPage: Using existing client connection');
      
      // 重新设置断开回调
      this.client.setOnDisconnect((reason: string) => {
        LoggerControlPage.warn('[ControlPage] Disconnected:', reason);
        this.showLoading = false;
        try {
          this.getUIContext().getPromptAction().showToast({ message: reason });
        } catch (e) {
          LoggerControlPage.error('Show toast failed:', e);
        }
        setTimeout(() => {
          this.exitPage();
        }, 1000);
      });
      
      // 获取视频尺寸
      const videoSize = this.client.getVideoSize();
      if (videoSize) {
        this.videoWidth = videoSize.width;
        this.videoHeight = videoSize.height;
        LoggerControlPage.info(`[ControlPage] Video dimensions: ${this.videoWidth}x${this.videoHeight}`);
        // 尝试重新计算布局
        this.calcVideoDisplaySize();
      }
      
      // 如果surface已经就绪，立即初始化视频解码器
      if (this.surfaceReady && this.surfaceId) {
        this.initVideoDecoder();
      }
      
      // 启动自动隐藏定时器
      this.startAutoHideTimer();
    } else {
      LoggerControlPage.error('ControlPage: Client not found in cache, falling back to connect');
      this.connectDevice();
    }
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
      LoggerControlPage.error('Set fullscreen failed:', err);
    }
  }
  
  async connectDevice() {
    if (!this.device) {
      LoggerControlPage.error('ControlPage: No device available');
      return;
    }
    
    try {
      this.connectionStatus = 'Connecting to device...';
      LoggerControlPage.info('ControlPage: Starting connection to device:', this.device.name);
      LoggerControlPage.info('ControlPage: Device address:', this.device.address, 'port:', this.device.adbPort);
      
      // 显示授权提示
      this.connectionStatus = '连接中...如果是首次连接，请在Android设备上授权USB调试';

      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.client = await Client.startDevice(this.device, ctx, this.getUIContext(), undefined, (client: Client) => {
        // 立即保存Client引用，以便退出页面时关闭
        this.client = client;
      });
      LoggerControlPage.info('ControlPage: Client.startDevice returned:', this.client ? 'success' : 'null');
      
      if (this.client) {
        this.isConnected = true;
        this.showLoading = false;
        this.connectionStatus = 'Connected';
        this.clientReady = true;
        LoggerControlPage.info('ControlPage: Device connected successfully');
        
        // 设置断开连接回调 - 自动返回上一页
        this.client.setOnDisconnect((reason: string) => {
          LoggerControlPage.warn('[ControlPage] Disconnected:', reason);
          try {
            this.getUIContext().getPromptAction().showToast({ message: reason });
          } catch (e) {
            LoggerControlPage.error('Show toast failed:', e);
          }
          // 延迟返回，让用户看到提示
          setTimeout(() => {
            this.exitPage();
          }, 1000);
        });
        
        // 如果surface已经就绪，立即初始化视频解码器
        if (this.surfaceReady && this.surfaceId) {
          this.initVideoDecoder();
        }
        
        // 启动自动隐藏定时器
        this.startAutoHideTimer();
      } else {
        this.showLoading = false;
        this.connectionStatus = 'Connection failed';
        LoggerControlPage.error('ControlPage: Client.startDevice returned null');
        try {
          this.getUIContext().getPromptAction().showToast({ message: '连接失败。请检查设备是否开启ADB，并在设备上授权USB调试。' });
        } catch (e) {
          LoggerControlPage.error('Show toast failed:', e);
        }
        LoggerControlPage.error('Failed to start client - check if device is reachable and ADB is enabled');
      }
    } catch (err) {
      this.showLoading = false;
      this.connectionStatus = 'Connection error';
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerControlPage.error('ControlPage: Connect device exception:', errMsg);
      
      // 根据错误类型显示不同的提示
      let toastMsg = '连接错误';
      if (errMsg.includes('timeout')) {
        try {
          toastMsg = this.getUIContext().getHostContext()?.resourceManager.getStringSync($r('app.string.connect_timeout_toast').id) || 'Connection timeout';
        } catch (e) {
          toastMsg = 'Connection timeout';
        }
      }
      
      try {
        this.getUIContext().getPromptAction().showToast({ message: toastMsg });
      } catch (e) {
        LoggerControlPage.error('Show toast failed:', e);
      }
    }
  }
  
  // 启动自动隐藏定时器
  startAutoHideTimer() {
    this.clearAutoHideTimer();
    this.autoHideTimer = setTimeout(() => {
      if (!this.showControlPanel && this.componentWidth > 0) {
        // 贴边隐藏：只露出一半
        const hiddenX = this.componentWidth - this.FAB_SIZE / 2;
        this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
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
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
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

  // 计算视频显示尺寸 - 保持比例
  calcVideoDisplaySize() {
    if (this.containerWidth === 0 || this.containerHeight === 0 || this.videoWidth === 0 || this.videoHeight === 0) {
      return;
    }

    const containerRatio = this.containerWidth / this.containerHeight;
    const videoRatio = this.videoWidth / this.videoHeight;

    if (containerRatio > videoRatio) {
      // 容器比视频宽，以高度为基准
      this.displayXComponentHeight = this.containerHeight;
      this.displayXComponentWidth = this.containerHeight * videoRatio;
    } else {
      // 容器比视频窄，以宽度为基准
      this.displayXComponentWidth = this.containerWidth;
      this.displayXComponentHeight = this.containerWidth / videoRatio;
    }
    
    // 更新组件实际尺寸，用于触摸映射和UI布局
    this.componentWidth = this.displayXComponentWidth;
    this.componentHeight = this.displayXComponentHeight;
    
    LoggerControlPage.info(`[ControlPage] Calculated Display Size: ${this.displayXComponentWidth}x${this.displayXComponentHeight} (Container: ${this.containerWidth}x${this.containerHeight}, Video: ${this.videoWidth}x${this.videoHeight})`);
    
    // 重新校准悬浮按钮位置（如果有必要）
    if (this.checkFabPosition) {
      // 简单的越界检查，防止resize后按钮跑到看不见的地方
       if (this.fabX > this.componentWidth) this.fabX = this.componentWidth - this.FAB_SIZE;
       if (this.fabY > this.componentHeight) this.fabY = this.componentHeight - this.FAB_SIZE;
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
            .color($r('sys.color.comp_background_list_card'))
          Text(this.connectionStatus)
            .fontSize(16)
            .fontColor($r('sys.color.comp_background_list_card'))
            .margin({ top: 16 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.black'))
        .zIndex(100)
      }
      
      // 视频显示区域容器 - 用于获取可用空间
      Stack({ alignContent: Alignment.Center }) {
        XComponent({
          id: 'video_surface',
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .onLoad(() => {
            this.surfaceId = this.xComponentController.getXComponentSurfaceId();
            this.surfaceReady = true;
            LoggerControlPage.debug('XComponent surfaceId:', this.surfaceId);
            
            // 如果client已经就绪,立即初始化视频解码器
            if (this.clientReady && this.client) {
              this.initVideoDecoder();
            }
          })
          .width(this.displayXComponentWidth > 0 ? this.displayXComponentWidth : '100%')
          .height(this.displayXComponentHeight > 0 ? this.displayXComponentHeight : '100%')
          .backgroundColor($r('sys.color.black'))
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
                }),
              PanGesture({ fingers: 1, distance: 0 })
                .onActionUpdate((event: GestureEvent) => {
                  this.handleTouchMove(event);
                }),
              PanGesture({ fingers: 1, distance: 0 })
                .onActionEnd((event: GestureEvent) => {
                  this.handleTouchEnd(event);
                })
            )
          )
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.black')) // 背景黑色，作为信箱模式的黑边
      .onAreaChange((_: Area, newArea: Area) => {
        // 获取容器容器实际尺寸(px)
        this.containerWidth = newArea.width as number;
        this.containerHeight = newArea.height as number;
        LoggerControlPage.info(`Container size changed: ${this.containerWidth}x${this.containerHeight}`);
        
        // 重新计算视频显示尺寸
        this.calcVideoDisplaySize();
        this.initFabPosition();
      })
      
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
            
            // 剪贴板同步按钮 - 使用安全控件
            PasteButton({ icon: PasteIconStyle.LINES, buttonType: ButtonType.Circle })
              .width(44)
              .height(44)
              .backgroundColor('#80000000')
              .onClick(async (_event: ClickEvent, result: PasteButtonOnClickResult) => {
                if (result === PasteButtonOnClickResult.SUCCESS) {
                  try {
                    const systemPasteboard = pasteboard.getSystemPasteboard();
                    const hasData = await systemPasteboard.hasData();
                    if (!hasData) {
                      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.clipboard_empty') });
                      return;
                    }
                    const pasteData = await systemPasteboard.getData();
                    const text = pasteData.getPrimaryText();
                    if (text && this.client) {
                      await this.client.sendClipboard(text, true);
                      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.clipboard_synced') });
                    } else {
                      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.clipboard_no_text') });
                    }
                  } catch (err) {
                    LoggerControlPage.error('Paste failed:', err);
                    this.getUIContext().getPromptAction().showToast({ message: $r('app.string.paste_failed') });
                  }
                }
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
              this.exitPage();
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
            .onActionStart((_: GestureEvent) => {
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
            .onActionEnd((_: GestureEvent) => {
               // 拖动结束，吸附到右侧
               if (this.componentWidth > 0) {
                 const dockX = this.componentWidth - this.FAB_SIZE - 20;
                 
                 // 限制Y轴防止跑出屏幕
                 let targetY = this.fabY;
                 if (targetY < 50) targetY = 50;
                 if (targetY > this.componentHeight - 150) targetY = this.componentHeight - 150;

                 this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
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
    .backgroundColor($r('sys.color.black'))
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
    
    // Scrcpy uses absolute pixel coordinates mapped to video dimensions
    const x = Math.round((localX / this.componentWidth) * this.videoWidth);
    const y = Math.round((localY / this.componentHeight) * this.videoHeight);
    
    // 模拟点击（按下-抬起）
    this.client.sendTouchEvent(TouchAction.ACTION_DOWN, 0, x, y, this.videoWidth, this.videoHeight);
    setTimeout(() => {
      this.client?.sendTouchEvent(TouchAction.ACTION_UP, 0, x, y, this.videoWidth, this.videoHeight);
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
      
      // Scrcpy uses absolute pixel coordinates mapped to video dimensions
      const x = Math.round((localX / this.componentWidth) * this.videoWidth);
      const y = Math.round((localY / this.componentHeight) * this.videoHeight);
      const pointerId = finger.id;
      
      // 存储毫秒时间戳
      this.pointerDownTime.set(pointerId, eventTimestampMs);
      this.client?.sendTouchEvent(TouchAction.ACTION_DOWN, pointerId, x, y, this.videoWidth, this.videoHeight);
    });
  }
  
  handleTouchMove(event: GestureEvent) {
    if (!this.client) return;
    
    // 增加 MOVE 事件计数
    this.panMoveCount++;
    
    // GestureEvent.timestamp 是纳秒级，如果为0或无效则使用 Date.now()
    
    event.fingerList.forEach((finger) => {
      const localX = finger.localX;
      const localY = finger.localY;
      
      // Scrcpy uses absolute pixel coordinates mapped to video dimensions
      const x = Math.round((localX / this.componentWidth) * this.videoWidth);
      const y = Math.round((localY / this.componentHeight) * this.videoHeight);
      const pointerId = finger.id;
      
      this.client?.sendTouchEvent(TouchAction.ACTION_MOVE, pointerId, x, y, this.videoWidth, this.videoHeight);
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
    
    event.fingerList.forEach((finger) => {
      const localX = finger.localX;
      const localY = finger.localY;
      
      // Scrcpy uses absolute pixel coordinates mapped to video dimensions
      const x = Math.round((localX / this.componentWidth) * this.videoWidth);
      const y = Math.round((localY / this.componentHeight) * this.videoHeight);
      const pointerId = finger.id;
      
      this.client?.sendTouchEvent(TouchAction.ACTION_UP, pointerId, x, y, this.videoWidth, this.videoHeight);
      this.pointerDownTime.delete(pointerId);
    });
  }

  
  // 初始化视频解码器的辅助方法
  private initVideoDecoder(): void {
    if (!this.client || !this.surfaceId) {
      LoggerControlPage.error('Cannot init video decoder: client or surfaceId missing');
      return;
    }
    
    LoggerControlPage.info('Initializing video decoder with surfaceId:', this.surfaceId);
    this.client.initVideoDecoder(this.surfaceId).then(() => {
      // 从 Client 获取实际视频尺寸
      const videoSize = this.client?.getVideoSize();
      if (videoSize) {
        this.videoWidth = videoSize.width;
        this.videoHeight = videoSize.height;
        LoggerControlPage.info(`[ControlPage] Updated video dimensions: ${this.videoWidth}x${this.videoHeight}`);
      }
    }).catch((err: Error) => {
      LoggerControlPage.error('Failed to init video decoder:', err.message);
      try {
        this.getUIContext().getPromptAction().showToast({ message: '视频解码器初始化失败: ' + err.message });
      } catch (e) {
        LoggerControlPage.error('Show toast failed:', e);
      }
    });
  }
}
