import { Device } from '../entity/Device';
import { TouchAction, KeyCode, ControlPacket } from '../client/tools/ControlPacket';
import { LoggerControlPage } from '../helper/Logger';
import { NativeStreamClient, NativeStreamListener } from '../client/tools/NativeStreamClient';
import { AdbKeyManager } from '../helper/AdbKeyManager';
import { ServerManager } from '../helper/ServerManager';
import { ClientSessionManager } from '../helper/ClientSessionManager';
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
  @State connectionStatus: string = '';
  @State showLoading: boolean = true;

  // 悬浮按钮状态
  @State showControlPanel: boolean = false;  // 控制面板是否展开
  @State fabX: number = 0; // 悬浮按钮X位置
  @State fabY: number = 0; // 悬浮按钮Y位置
  @State checkFabPosition: boolean = false; // 是否需要初始化位置

  // Native Client 实例
  private nativeClient?: NativeStreamClient;
  private serverJarData: ArrayBuffer | null = null;
  private isStarted: boolean = false;
  private xComponentController: XComponentController = new XComponentController();
  private pointerDownTime: Map<number, number> = new Map();  // 存储毫秒时间戳
  private surfaceReady: boolean = false;
  private context?: common.UIAbilityContext;
  private autoHideTimer: number = -1;
  private readonly FAB_SIZE = 30; // 悬浮按钮大小
  private readonly BOTTOM_SAFE_AREA = 28; // 底部安全区域高度(系统导航条)
  // 临时存储拖动开始时的位置
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  // 追踪是否正在滑动，防止 TapGesture 干扰滑动操作
  private isPanning: boolean = false;
  private panMoveCount: number = 0;  // 记录 MOVE 事件数量
  
  @State stepTime: number = 0;
  private stepTimer: number = -1;

  // Start the step timer (resets count)
  private startStepTimer() {
    this.stopStepTimer();
    this.stepTime = 0;
    this.stepTimer = setInterval(() => {
      this.stepTime++;
    }, 1000);
  }

  // Stop the step timer
  private stopStepTimer() {
    if (this.stepTimer !== -1) {
      clearInterval(this.stepTimer);
      this.stepTimer = -1;
    }
  }

  // Helper to update status and restart timer
  private updateConnectionStatus(status: string) {
    this.connectionStatus = status;
    this.startStepTimer();
  }

  // 辅助方法：将 Resource 引用解析为字符串
  private getResString(res: Resource): string {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return ctx.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  aboutToAppear() {
    this.isPageActive = true;
    this.isExiting = false;
    try {
      const params = this.getUIContext().getRouter().getState().params as Record<string, Object>;
      if (params && params['device']) {
        this.device = params['device'] as Device;

        // 检查是否是从 Index 页面预连接后跳转的
        if (params['clientReady'] === true) {
          // 客户端已连接，从缓存获取
          this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          // Note: Index already started connecting, so we might want to sync state if possible
          // But for now, just show "Connecting..."
          this.updateConnectionStatus(this.getResString($r('app.string.connecting_status')));
          this.initFromExistingClient();
        } else {
          try {
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.init_control_page_error') });
          } catch (e) {
            LoggerControlPage.error('Show toast failed:', e);
          }
          setTimeout(() => {
            this.exitPage();
          }, 1000);
        }
      }
    } catch (e) {
      LoggerControlPage.error('Failed to get router params:', e);
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.init_control_page_error') });
      } catch (e) {
        LoggerControlPage.error('Show toast failed:', e);
      }
      setTimeout(() => {
        this.exitPage();
      }, 1000);
    }

    // 确保没有残留的会话
    ClientSessionManager.getInstance().stopAll();

    // 设置全屏并隐藏导航条
    this.setFullScreen();
  }
  
  aboutToDisappear() {
    this.isPageActive = false;
    this.stopStepTimer(); // Clean up timer
    LoggerControlPage.info('ControlPage: aboutToDisappear - cleaning up');

    // 停止自动隐藏定时器
    if (this.autoHideTimer !== -1) {
      clearTimeout(this.autoHideTimer);
      this.autoHideTimer = -1;
    }

    // 关闭 Native Client (使用 SessionManager 统一管理)
    LoggerControlPage.info('ControlPage: aboutToDisappear - calling stopAll');
    ClientSessionManager.getInstance().stopAll();
    this.nativeClient = undefined;

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

  // 追踪是否正在退出，防止多重调用
  private isExiting: boolean = false;
  private isPageActive: boolean = false;

  // 统一退出页面逻辑
  async exitPage() {
    if (this.isExiting) {
      LoggerControlPage.warn('ExitPage: Already exiting, ignoring call');
      return;
    }
    this.isExiting = true;

    // 先恢复窗口状态
    await this.restoreWindow();
    // 再返回
    try {
      const router = this.getUIContext().getRouter();
      const length = router.getLength(); // 返回页面栈数量
      const lenNum = typeof length === 'string' ? parseInt(length) : Number(length);
      
      LoggerControlPage.info('ExitPage: Router length:', lenNum);

      if (lenNum > 1) {
        router.back();
      } else {
        LoggerControlPage.warn('ExitPage: No previous page, replacing with Index');
        router.replaceUrl({ url: 'pages/Index' });
      }
    } catch (e) {
      LoggerControlPage.error('Router back failed:', e);
      // 尝试强制跳转首页
      try {
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
      } catch (err) {
        LoggerControlPage.error('Force replace Index failed:', err);
      }
    }
  }
  
  // 发送按键事件到 Native
  private sendKeyToWorker(keyCode: KeyCode): void {
    if (!this.nativeClient || !this.isConnected) return;
    const packets = ControlPacket.createKeyEventPair(keyCode);
    packets.forEach(p => this.nativeClient!.sendControl(p));
  }

  // 从已连接的客户端初始化（Native 架构）
  private async initFromExistingClient(): Promise<void> {
    if (!this.device || !this.context) return;

    try {
      LoggerControlPage.info('ControlPage: Initializing Native Client...');

      // 1. 预加载 server.jar
      this.serverJarData = await ServerManager.loadServerFromRawfile(this.context);
      LoggerControlPage.info('ControlPage: Server jar loaded, size:', this.serverJarData?.byteLength || 0);

      // 2. 初始化 Native Client
      this.initNativeClient();

      // 3. 尝试启动会话 (如果 Surface 还没准备好，会在 onLoad 中再次调用)
      this.startNativeSession();

    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerControlPage.error('ControlPage: Init failed:', errMsg);
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.init_control_page_error') });
      } catch (e) {
        LoggerControlPage.error('Show toast failed:', e);
      }
      setTimeout(() => {
        this.exitPage();
      }, 1500);
    }
  }

  // 初始化 Native Client 并设置监听器
  private initNativeClient(): void {
    if (!this.context || !this.device) return;

    const listener: NativeStreamListener = {
      onVideoConfig: (width: number, height: number) => {
        this.videoWidth = width;
        this.videoHeight = height;
        LoggerControlPage.info(`[ControlPage] Video dimensions: ${width}x${height}`);
        this.calcVideoDisplaySize();
      },
      onAudioConfig: (codec: string) => {
        LoggerControlPage.info(`[ControlPage] Audio codec: ${codec}`);
      },
      onDisconnect: (reason: string) => {
        this.stopStepTimer(); // Stop timer on disconnect
        LoggerControlPage.warn('[ControlPage] Client disconnected:', reason);
        this.isConnected = false;
        this.connectionStatus = this.getResString($r('app.string.control_disconnected'));
        try {
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.control_disconnected') });
        } catch (err) {
          LoggerControlPage.error('Show toast failed:', err);
        }
        setTimeout(() => {
          this.exitPage();
        }, 1500);
      },
      onError: (error: string) => {
        this.stopStepTimer(); // Stop timer on error
        LoggerControlPage.error('[ControlPage] Client error:', error);
        try {
          this.getUIContext().getPromptAction().showToast({ message: error });
        } catch (err) {
          LoggerControlPage.error('Show toast failed:', err);
        }
        setTimeout(() => {
            this.exitPage();
        }, 1500);
      },
      onClipboard: (text: string) => {
        this.syncClipboardToSystem(text);
      },
      onWaitAuth: () => {
        LoggerControlPage.info('[ControlPage] Waiting for ADB Authorization...');
        this.updateConnectionStatus(this.getResString($r('app.string.adb_auth_waiting')));
        try {
             this.getUIContext().getPromptAction().showToast({ message: $r('app.string.auth_required_toast') });
        } catch (e) {
          LoggerControlPage.error('Show toast failed:', e);
        }
      }
    };

    this.nativeClient = new NativeStreamClient(this.context, this.device, listener);
    // 注册到 SessionManager
    ClientSessionManager.getInstance().register(this.nativeClient);
  }

  // 尝试启动 Native 会话
  private async startNativeSession(): Promise<void> {
    if (this.isStarted) return;
    if (!this.serverJarData || !this.surfaceReady || !this.surfaceId || !this.nativeClient) {
      LoggerControlPage.debug('Wait for resources ready...');
      return;
    }

    this.isStarted = true;
    try {
      LoggerControlPage.info('[ControlPage] Starting Native Session...');
      this.updateConnectionStatus(this.getResString($r('app.string.connecting_status'))); // "正在连接..."
      
      // 启动会话 (异步)
      await this.nativeClient.start(this.serverJarData, this.surfaceId);
      
      this.isConnected = true;
      this.stopStepTimer(); // Connection successful, stop timer
      this.connectionStatus = this.getResString($r('app.string.control_connected'));
      this.startAutoHideTimer();
      this.showLoading = false; // 实际上等首帧会更好，但这里先隐藏Loading
    } catch (err) {
      this.stopStepTimer(); // Stop timer on failure
      if (!this.isPageActive) {
          LoggerControlPage.warn('[ControlPage] Error ignored, page inactive:', err);
          return;
      }
      this.isStarted = false;
      let errMsg = err instanceof Error ? err.message : String(err);
      
      // Check if it's a resource string key
      if (errMsg.startsWith('app.string.')) {
         try {
             const resName = errMsg.replace('app.string.', '');
             const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext; 
             
             if (errMsg === 'app.string.connect_timeout_toast') {
                 errMsg = this.getResString($r('app.string.connect_timeout_toast'));
             } else if (errMsg === 'app.string.adb_auth_failed') {
                 errMsg = this.getResString($r('app.string.adb_auth_failed'));
             } else if (errMsg === 'app.string.adb_native_connect_failed') {
                 errMsg = this.getResString($r('app.string.adb_native_connect_failed'));
             } else if (errMsg === 'app.string.server_prepare_failed') {
                 errMsg = this.getResString($r('app.string.server_prepare_failed'));
             }
         } catch (e) {
             LoggerControlPage.error('Failed to resolve error resource', e);
         }
      }

      LoggerControlPage.error('[ControlPage] Start session failed:', errMsg);
      try {
          this.getUIContext().getPromptAction().showToast({ message: errMsg });
      } catch (e) {}
      setTimeout(() => {
          if (this.isPageActive) {
             this.exitPage();
          }
      }, 2000);
    }
  }

// 已移除 createStreamWorker

  // 同步剪贴板到系统
  private async syncClipboardToSystem(text: string): Promise<void> {
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await systemPasteboard.setData(pasteData);
      LoggerControlPage.debug('[ControlPage] Clipboard synced to system');
    } catch (err) {
      LoggerControlPage.error('[ControlPage] Failed to sync clipboard:', err);
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

  // 启动自动隐藏定时器
  startAutoHideTimer() {
    this.clearAutoHideTimer();
    this.autoHideTimer = setTimeout(() => {
      if (!this.showControlPanel && this.containerWidth > 0) {
        // 贴边隐藏：只露出一半
        const hiddenX = this.containerWidth - this.FAB_SIZE / 2;
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
    if (this.containerWidth > 0) {
      const visibleX = this.containerWidth - this.FAB_SIZE - 20; // 离右边20px
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
        this.fabX = visibleX;
      })
      this.startAutoHideTimer();
    }
  }
  
  // 切换控制面板
  toggleControlPanel() {
    // 如果当前是隐藏状态(靠边)，先显示出来
    if (this.containerWidth > 0 && this.fabX > this.containerWidth - this.FAB_SIZE) {
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
    if (this.containerWidth > 0 && this.containerHeight > 0 && !this.checkFabPosition) {
       this.fabX = this.containerWidth - this.FAB_SIZE - 20; // 默认右侧
       // 考虑底部安全区域，FAB放在容器中部偏下位置
       this.fabY = this.containerHeight - 150 - this.BOTTOM_SAFE_AREA;
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
    
    LoggerControlPage.debug(`[ControlPage] Calculated Display Size: ${this.displayXComponentWidth}x${this.displayXComponentHeight} (Container: ${this.containerWidth}x${this.containerHeight}, Video: ${this.videoWidth}x${this.videoHeight})`);
    
    // 重新校准悬浮按钮位置（如果有必要）
    if (this.checkFabPosition) {
      // 简单的越界检查，防止resize后按钮跑到看不见的地方
       if (this.fabX > this.containerWidth) this.fabX = this.containerWidth - this.FAB_SIZE;
       if (this.fabY > this.containerHeight) this.fabY = this.containerHeight - this.FAB_SIZE;
    }
  }
  
  build() {
    Column() {
      // 主内容区域（视频 + 悬浮按钮）
      Stack() {
        // Loading indicator - 支持深色/浅色模式
        if (this.showLoading) {
          Column() {
            // 加载动画
            LoadingProgress()
              .width(64)
              .height(64)
              .color($r('sys.color.ohos_id_color_text_primary'))

            // 连接状态文字
            Text(`${this.connectionStatus} (${this.stepTime}s)`)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .margin({ top: 20 })
              .animation({ duration: 300, curve: Curve.EaseInOut })

            // 设备名提示
            if (this.device?.name) {
              Text(this.device.name)
                .fontSize(13)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .margin({ top: 8 })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('sys.color.ohos_id_color_background'))
          .zIndex(100)
          .transition(TransitionEffect.OPACITY.animation({ duration: 400, curve: Curve.EaseOut }))
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

              // 尝试启动 Native Session
              this.startNativeSession();
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
        .backgroundColor('#000000') // 背景黑色，作为信箱模式的黑边
        .onAreaChange((_: Area, newArea: Area) => {
          // 获取容器容器实际尺寸(px)
          this.containerWidth = newArea.width as number;
          this.containerHeight = newArea.height as number;
          LoggerControlPage.debug(`Container size changed: ${this.containerWidth}x${this.containerHeight}`);
          
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
              this.sendKeyToWorker(KeyCode.KEYCODE_BACK);
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
              this.sendKeyToWorker(KeyCode.KEYCODE_HOME);
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
              this.sendKeyToWorker(KeyCode.KEYCODE_APP_SWITCH);
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
                    if (text && this.nativeClient) {
                      // 发送到 Native
                      const packet = ControlPacket.createSetClipboard(text, 0n, true);
                      this.nativeClient.sendControl(packet);
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
               if (this.containerWidth > 0) {
                 this.fabX = this.dragStartX + event.offsetX;
                 this.fabY = this.dragStartY + event.offsetY;
               }
            })
            .onActionEnd((_: GestureEvent) => {
               // 拖动结束，吸附到右侧
               if (this.containerWidth > 0) {
                 const dockX = this.containerWidth - this.FAB_SIZE - 20;
                 
                 // 限制Y轴防止跑出屏幕，考虑底部安全区域
                 let targetY = this.fabY;
                 if (targetY < 50) targetY = 50;
                 const maxY = this.containerHeight - 150 - this.BOTTOM_SAFE_AREA;
                 if (targetY > maxY) targetY = maxY;

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
      .layoutWeight(1) // 占用剩余空间，让底部导航栏不覆盖视频
      .backgroundColor($r('sys.color.ohos_id_color_background'))
      .clip(false) // 允许悬浮按钮超出边界，实现吸边半隐藏效果
      
      // 底部导航栏
      if (this.device?.showBottomNavBar) {
        Row({ space: 40 }) {
          // 返回键
          Button() {
            SymbolGlyph($r('sys.symbol.arrow_left'))
              .fontSize(24)
              .fontColor([$r('sys.color.ohos_id_color_text_primary')])
          }
          .width(52)
          .height(52)
          .backgroundColor(Color.Transparent)
          .borderRadius(26)
          .onClick(() => {
            this.sendKeyToWorker(KeyCode.KEYCODE_BACK);
          })

          // 主页键
          Button() {
            SymbolGlyph($r('sys.symbol.house'))
              .fontSize(24)
              .fontColor([$r('sys.color.ohos_id_color_text_primary')])
          }
          .width(52)
          .height(52)
          .backgroundColor(Color.Transparent)
          .borderRadius(26)
          .onClick(() => {
            this.sendKeyToWorker(KeyCode.KEYCODE_HOME);
          })

          // 多任务键
          Button() {
            SymbolGlyph($r('sys.symbol.square'))
              .fontSize(24)
              .fontColor([$r('sys.color.ohos_id_color_text_primary')])
          }
          .width(52)
          .height(52)
          .backgroundColor(Color.Transparent)
          .borderRadius(26)
          .onClick(() => {
            this.sendKeyToWorker(KeyCode.KEYCODE_APP_SWITCH);
          })
        }
        .width('100%')
        .height(70)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.ohos_id_color_background'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
  
  handleTap(event: GestureEvent) {
    if (!this.nativeClient || !this.isConnected) return;

    // 如果正在滑动或刚滑动过（有MOVE事件），忽略 TAP 事件
    if (this.isPanning || this.panMoveCount > 0) {
      return;
    }

    if (event.fingerList.length === 0) return;
    const localX = event.fingerList[0].localX;
    const localY = event.fingerList[0].localY;

    // Scrcpy uses absolute pixel coordinates mapped to video dimensions
    const x = Math.round((localX / this.componentWidth) * this.videoWidth);
    const y = Math.round((localY / this.componentHeight) * this.videoHeight);

    // 模拟点击（按下-抬起）
    // 发送 ACTION_DOWN
    const packetDown = ControlPacket.createInjectTouchEvent(
      TouchAction.ACTION_DOWN, BigInt(0), x, y, this.videoWidth, this.videoHeight, 1.0, 1, 1
    );
    this.nativeClient.sendControl(packetDown);

    // 延迟发送 ACTION_UP
    setTimeout(() => {
      if (this.nativeClient && this.isConnected) {
        const packetUp = ControlPacket.createInjectTouchEvent(
          TouchAction.ACTION_UP, BigInt(0), x, y, this.videoWidth, this.videoHeight, 0.0, 1, 0
        );
        this.nativeClient.sendControl(packetUp);
      }
    }, 50);
  }

  handleTouchStart(event: GestureEvent) {
    if (!this.nativeClient || !this.isConnected) return;

    // 标记开始滑动
    this.isPanning = true;
    this.panMoveCount = 0;

    const eventTimestampMs = event.timestamp > 0 ? Math.floor(event.timestamp / 1000000) : Date.now();

    event.fingerList.forEach((finger) => {
      const localX = finger.localX;
      const localY = finger.localY;

      const x = Math.round((localX / this.componentWidth) * this.videoWidth);
      const y = Math.round((localY / this.componentHeight) * this.videoHeight);
      const pointerId = finger.id;

      this.pointerDownTime.set(pointerId, eventTimestampMs);

      const packet = ControlPacket.createInjectTouchEvent(
        TouchAction.ACTION_DOWN, BigInt(pointerId), x, y, this.videoWidth, this.videoHeight, 1.0, 1, 1
      );
      this.nativeClient?.sendControl(packet);
    });
  }

  handleTouchMove(event: GestureEvent) {
    if (!this.nativeClient || !this.isConnected) return;

    this.panMoveCount++;

    event.fingerList.forEach((finger) => {
      const localX = finger.localX;
      const localY = finger.localY;

      const x = Math.round((localX / this.componentWidth) * this.videoWidth);
      const y = Math.round((localY / this.componentHeight) * this.videoHeight);
      const pointerId = finger.id;

      const packet = ControlPacket.createInjectTouchEvent(
        TouchAction.ACTION_MOVE, BigInt(pointerId), x, y, this.videoWidth, this.videoHeight, 1.0, 1, 1
      );
      this.nativeClient?.sendControl(packet);
    });
  }

  handleTouchEnd(event: GestureEvent) {
    if (!this.nativeClient || !this.isConnected) return;

    this.isPanning = false;
    setTimeout(() => {
      this.panMoveCount = 0;
    }, 100);

    event.fingerList.forEach((finger) => {
      const localX = finger.localX;
      const localY = finger.localY;

      const x = Math.round((localX / this.componentWidth) * this.videoWidth);
      const y = Math.round((localY / this.componentHeight) * this.videoHeight);
      const pointerId = finger.id;

      const packet = ControlPacket.createInjectTouchEvent(
        TouchAction.ACTION_UP, BigInt(pointerId), x, y, this.videoWidth, this.videoHeight, 0.0, 1, 0
      );
      this.nativeClient?.sendControl(packet);

      this.pointerDownTime.delete(pointerId);
    });
  }

}
