import { Device } from '../entity/Device';
import { ClientStream } from './tools/ClientStream';
import { VideoDecoder } from './decode/VideoDecoder';
import { ControlPacket, Action, TouchAction, KeyCode } from './tools/ControlPacket';
import { LoggerClient } from '../helper/Logger';
import pasteboard from '@ohos.pasteboard';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

// 视频配置接口
// 视频配置接口（使用ClientStream中的定义）
import { VideoConfig } from './tools/ClientStream';

// 客户端管理器
export class Client {
  private static allClients: Map<string, Client> = new Map();
  private device: Device;
  private clientStream?: ClientStream;
  private videoDecoder?: VideoDecoder;
  private isClosed: boolean = false;
  private keepAliveTimer?: number;
  private videoLoopRunning: boolean = false;
  // 预加载的视频配置
  private videoConfig?: VideoConfig;
  // 断开连接回调
  private onDisconnectCallback?: (reason: string) => void;
  // 首帧回调 - 视频开始传输时触发
  private onFirstFrameCallback?: () => void;
  private firstFrameReceived: boolean = false;
  
  // 触控事件优化
  private isWritingMove: boolean = false;
  private pendingMovePacket: ArrayBuffer | null = null;
  
  constructor(device: Device) {
    this.device = device;
  }
  
  // 获取视频尺寸 (用于触摸坐标计算)
  getVideoSize(): VideoConfig | null {
    return this.videoConfig || null;
  }
  
  // 设置断开连接回调
  setOnDisconnect(callback: (reason: string) => void): void {
    this.onDisconnectCallback = callback;
  }
  
  // 触发断开回调
  private triggerDisconnect(reason: string): void {
    LoggerClient.warn(`[Client] Disconnect triggered: ${reason}`);
    if (this.onDisconnectCallback && !this.isClosed) {
      this.onDisconnectCallback(reason);
    }
    this.close();
  }

  // 设置首帧回调 - 视频开始传输时触发
  setOnFirstFrame(callback: () => void): void {
    this.onFirstFrameCallback = callback;
  }
  
  // 从缓存获取已连接的客户端
  static getClient(uuid: string): Client | null {
    return Client.allClients.get(uuid) || null;
  }
  
  static async startDevice(device: Device, context: common.UIAbilityContext, uiContext: UIContext, onStatusChange?: (status: string) => void, onClientCreated?: (client: Client) => void, onAuth?: () => void): Promise<Client | null> {
    if (Client.allClients.has(device.uuid)) {
      const existingClient = Client.allClients.get(device.uuid);
      if (existingClient && onClientCreated) {
        onClientCreated(existingClient);
      }
      return existingClient || null;
    }
    
    const client = new Client(device);
    if (onClientCreated) {
      onClientCreated(client);
    }
    const success = await client.connect(context, uiContext, onStatusChange, onAuth);
    
    if (success) {
      Client.allClients.set(device.uuid, client);
      return client;
    }
    
    // 连接失败，确保清理资源
    LoggerClient.info('[Client] startDevice failed, cleaning up...');
    await client.close();
    return null;
  }
  
  private async connect(context: common.UIAbilityContext, uiContext: UIContext, onStatusChange?: (status: string) => void, onAuth?: () => void): Promise<boolean> {
    try {
      // 1. 建立流连接
      this.clientStream = new ClientStream(this.device);
      
      if (onStatusChange) {
        try {
          onStatusChange(context.resourceManager.getStringSync($r('app.string.connecting_status').id));
        } catch (e) {
          onStatusChange('Connecting...');
        }
      }
      const connected = await this.clientStream.connect(context, uiContext, onAuth);
      
      if (!connected) {
        LoggerClient.error('ClientStream connection failed');
        // 连接失败，关闭流
        await this.clientStream.close();
        this.clientStream = undefined;
        return false;
      }
      
      if (onStatusChange) {
        try {
          onStatusChange(context.resourceManager.getStringSync($r('app.string.getting_video_config').id));
        } catch (e) {
          onStatusChange('Getting video config...');
        }
      }
      // 2. 立即开始读取视频配置(不等待surface),防止服务器超时
      // 2. Video config is already loaded during handshake
      const videoConfig = this.clientStream.getVideoConfig();
      if (videoConfig) {
        LoggerClient.info(`Video config loaded: ${videoConfig.width}x${videoConfig.height}`);
      } else {
        LoggerClient.warn('Video config not available after connect');
      }
      
      // 3. 启动保活定时器
      this.startKeepAlive();

      // 4. 启动主消息循环（接收剪贴板和视频大小事件）
      this.startMainLoop();

      // 5. 根据设置执行连接时操作 (match Android Client.java lines 47-49)
      try {
        // 唤醒屏幕 - Android uses "buttonWake" which sends createPowerEvent(1)
        if (this.device.wakeOnConnect) {
          LoggerClient.debug('Waking up remote device screen (wakeOnConnect=true)...');
          this.handleAction(Action.BUTTON_WAKE); // createPowerEvent(1)
        }

        // 连接时熄屏 - Android uses "buttonLightOff" with 2000ms delay
        if (this.device.lightOffOnConnect) {
          LoggerClient.info('Turning off remote device screen (lightOffOnConnect=true)...');
          // Android: clientController.handleAction("buttonLightOff", null, 2000);
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 2000));
          this.handleAction(Action.BUTTON_LIGHT_OFF); // createLightEvent(0)
        }
      } catch (wakeErr) {
        LoggerClient.error('Failed to handle connect actions:', wakeErr);
      }

      LoggerClient.info('Client connected successfully');
      return true;
    } catch (err) {
      LoggerClient.error('Client connect failed:', err);
      // 发生异常，确保关闭流
      if (this.clientStream) {
        await this.clientStream.close();
        this.clientStream = undefined;
      }
      return false;
    }
  }
  
  private async handleClipboardText(data: ArrayBuffer): Promise<void> {
    const decoder = util.TextDecoder.create('utf-8');
    const text = decoder.decodeToString(new Uint8Array(data));
    
    // 设置剪贴板
    if (this.device.clipboardAutosync) {
      try {
        const systemPasteboard = pasteboard.getSystemPasteboard();
        const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
        await systemPasteboard.setData(pasteData);
      } catch (err) {
        LoggerClient.error('Set clipboard failed:', err);
      }
    }
  }
  
  // 预加载视频配置 - 已移至 ClientStream.performHandshake
  // private preloadVideoConfig(): void { ... }
  
  async initVideoDecoder(surfaceId: string): Promise<void> {
    if (!this.clientStream) {
      throw new Error('ClientStream not initialized');
    }
    
    try {
      LoggerClient.info('Initializing video decoder...');
      LoggerClient.debug('Waiting for video config (timeout: 5 seconds)...');
      
      // 等待视频配置预加载完成
      const config = this.clientStream.getVideoConfig();
      if (!config) {
         throw new Error('Video configuration not available from handshake');
      }
      
      // 保存配置供 getVideoSize() 使用
      this.videoConfig = config;

      // 映射codecId到string
      // 0=H264, 1=H265, 2=AV1
      // Scrcpy v2+ uses FourCC:
      // h264 = 0x68323634 = 1748121140
      // h265 = 0x68323635 = 1748121141
      // av01 = 0x61763031 = 1635135537
      let codecType = 'h264';
      if (config.codecId === 1 || config.codecId === 1748121141) codecType = 'h265';
      if (config.codecId === 2 || config.codecId === 1635135537) codecType = 'av1';

      const width = config.width;
      const height = config.height;
      
      // scrcpy 2.x+ 协议中，SPS/PPS (csd) 是作为普通视频帧发送的，而不是在头部
      // 所以这里不需要初始化csd
      const csd0: ArrayBuffer = new ArrayBuffer(0);
      const csd1: ArrayBuffer | undefined = undefined;
      
      LoggerClient.info(`Using handshake config: ${codecType.toUpperCase()}, ${width}x${height}`);
      
      // 初始化解码器
      this.videoDecoder = new VideoDecoder();
      await this.videoDecoder.init(codecType, surfaceId, width, height, csd0, csd1);
      
      LoggerClient.info('Video decoder initialized, starting video loop...');
      
      // 启动视频读取循环
      this.startVideoLoop();
      
    } catch (err) {
      const error = err as Error;
      LoggerClient.error('initVideoDecoder failed:', error.message);
      throw error;
    }
  }
  
  private startVideoLoop(): void {
    if (this.videoLoopRunning) return;

    this.videoLoopRunning = true;

    const readLoop = async () => {
      let disconnectReason = '';
      try {
        LoggerClient.info('Video loop started, waiting for frames...');
        let frameCount = 0;
        while (!this.isClosed && this.videoLoopRunning && this.clientStream) {
          try {
            // 读取帧大小
            // LoggerClient.debug(`[Frame ${frameCount}] Reading frame size...`);
            const frameObj = await this.clientStream.readFrameFromVideo();
            const frameData = frameObj.data;
            const pts = frameObj.pts;
            // LoggerClient.debug(`[Frame ${frameCount}] Got frame data: ${frameData.byteLength} bytes`);

            if (frameData.byteLength > 0 && this.videoDecoder) {
              // Scrcpy Strategy: Decode EVERYTHING.
              // If the queue is full, we BLOCK (wait). This creates backpressure on the network (TCP flow control),
              // causing the server to slow down sending.
              while (this.frameQueue.length >= this.MAX_QUEUE_SIZE && !this.isClosed && this.videoLoopRunning) {
                 // Wait for consumer to consume frames
                 await new Promise<void>((resolve) => setTimeout(resolve, 2));
              }

              this.frameQueue.push({ data: frameData, pts, flags: frameObj.flags });

              // Notification: first frame callback (early)
               if (!this.firstFrameReceived && this.onFirstFrameCallback) {
                  this.firstFrameReceived = true;
                  LoggerClient.info('🎬 First frame received (read), triggering callback');
                  this.onFirstFrameCallback();
                }
                
                frameCount++;
            } else {
              LoggerClient.warn(`[Frame ${frameCount}] Empty frame or no decoder: size=${frameData.byteLength}, decoder=${!!this.videoDecoder}`);
            }
          } catch (frameErr) {
            const errMsg = frameErr instanceof Error ? frameErr.message : String(frameErr);
            LoggerClient.error('Video frame read error:', errMsg);
            if (frameErr instanceof Error && frameErr.stack) {
              LoggerClient.error('Stack:', frameErr.stack);
            }
            disconnectReason = '连接已断开: ' + errMsg;
            break;
          }
        }
      } catch (err) {
        const errMsg = err instanceof Error ? err.message : String(err);
        LoggerClient.error('Video loop error:', errMsg);
        disconnectReason = '视频循环错误: ' + errMsg;
      } finally {
        this.videoLoopRunning = false;
        LoggerClient.info('Video loop stopped');
        
        // 如果不是正常关闭，触发断开回调
        if (disconnectReason && !this.isClosed) {
          this.triggerDisconnect(disconnectReason);
        }
      }
    };

    // 启动读取循环
    readLoop();
    
    // 2. 消费者：解码循环 (Restore Pipeline)
    const decodeLoop = async () => {
      LoggerClient.info('Video decode loop started');
      while (!this.isClosed && this.videoLoopRunning) {
        if (this.frameQueue.length > 0 && this.videoDecoder) {
          const frame = this.frameQueue.shift();
          if (frame) {
            // Pass flags to decoder (CSD handling)
            await this.videoDecoder.decode(frame.data, frame.pts, frame.flags);
          }
        } else {
           // Queue empty, wait
           await new Promise<void>((resolve) => setTimeout(resolve, 1));
        }
      }
      LoggerClient.info('Video decode loop stopped');
    };

    decodeLoop();
  }

  // handleAction - 对应 Java ClientController.handleAction
  // 统一操作处理入口，使用 action 字符串分发
  handleAction(action: string, data?: ArrayBuffer): void {
    if (!this.clientStream || this.isClosed) return;

    try {
      switch (action) {
        // 界面切换 - HarmonyOS 暂不实现
        case Action.CHANGE_TO_SMALL:
        case Action.CHANGE_TO_FULL:
        case Action.CHANGE_TO_MINI:
        case Action.CHANGE_TO_APP:
          // HarmonyOS 不支持多窗口模式，暂不处理
          break;

        // 按钮操作 - 使用 Scrcpy 官方协议
        case Action.BUTTON_BACK:
          // 使用 BACK_OR_SCREEN_ON 类型，ACTION_DOWN 触发返回
          this.writeToMain(ControlPacket.createBackOrScreenOn(0)); // ACTION_DOWN
          break;
        case Action.BUTTON_HOME:
          for (const pkt of ControlPacket.createHomeKey()) {
            this.writeToMain(pkt);
          }
          break;
        case Action.BUTTON_SWITCH:
          for (const pkt of ControlPacket.createAppSwitchKey()) {
            this.writeToMain(pkt);
          }
          break;
        case Action.BUTTON_ROTATE:
          this.writeToMain(ControlPacket.createRotateDevice());
          break;
        case Action.BUTTON_POWER:
          for (const pkt of ControlPacket.createPowerKey()) {
            this.writeToMain(pkt);
          }
          break;
        case Action.BUTTON_WAKE:
          this.writeToMain(ControlPacket.createScreenOn());
          break;
        case Action.BUTTON_LOCK:
          this.writeToMain(ControlPacket.createScreenOff());
          break;
        case Action.BUTTON_LIGHT:
          // 切换屏幕状态
          this.writeToMain(ControlPacket.createScreenOn());
          break;
        case Action.BUTTON_LIGHT_OFF:
          this.writeToMain(ControlPacket.createScreenOff());
          break;

        // 系统操作 - Scrcpy 没有 keepalive，使用空操作或跳过
        case Action.KEEP_ALIVE:
          // Scrcpy 不需要 keepalive，可以发送一个无害的消息如 GET_CLIPBOARD
          // 或直接跳过
          break;
        case Action.CHECK_SIZE_AND_SITE:
          // HarmonyOS 不需要检查悬浮窗位置
          break;
        case Action.CHECK_CLIP_BOARD:
          // 剪贴板检查在 mainLoop 中处理
          break;
        case Action.UPDATE_SITE:
          // 悬浮窗位置更新，HarmonyOS 不需要
          break;
        case Action.UPDATE_MAX_SIZE:
          // 最大尺寸更新，HarmonyOS 暂不需要
          break;
        case Action.UPDATE_VIDEO_SIZE:
          // 视频尺寸更新，在 handleVideoSizeEvent 中处理
          break;
        case Action.RUN_SHELL:
          // Shell 命令执行，暂不实现
          break;

        // 直接写入数据包
        case Action.WRITE_BYTE_BUFFER:
          if (data) {
            this.writeToMain(data);
          }
          break;

        // 设置剪贴板
        case Action.SET_CLIP_BOARD:
          if (data && data.byteLength > 0) {
            this.writeToMain(data);
          }
          break;

        default:
          LoggerClient.warn(`[Client] Unknown action: ${action}`);
          // 兼容：如果有 data，默认执行 writeByteBuffer
          if (data) {
            this.writeToMain(data);
          }
          break;
      }
    } catch (err) {
      LoggerClient.error(`[Client] handleAction error for ${action}:`, err);
    }
  }

  // 发送剪贴板内容到 Android 设备
  async sendClipboard(text: string, paste: boolean = true): Promise<void> {
    if (!this.clientStream || this.isClosed) return;
    
    const packet = ControlPacket.createSetClipboard(text, 0n, paste);
    await this.writeToMain(packet);
    LoggerClient.info(`Sent clipboard to Android: ${text.substring(0, 50)}${text.length > 50 ? '...' : ''}`);
  }

  // 内部方法：写入数据流
  private async writeToMain(data: ArrayBuffer): Promise<void> {
    if (this.clientStream) {
      await this.clientStream.writeMain(data);
    }
  }

  // 发送触摸事件 - Scrcpy 协议格式
  // x, y: 屏幕坐标 (像素值)
  // screenWidth, screenHeight: 屏幕尺寸
  async sendTouchEvent(
    action: TouchAction, 
    pointerId: number, 
    x: number, 
    y: number, 
    screenWidth: number,
    screenHeight: number,
    pressure: number = 1.0
  ): Promise<void> {
    if (!this.clientStream) {
      LoggerClient.warn('[Control] sendTouchEvent: clientStream is null');
      return;
    }
    
    // LoggerClient.debug(`[Control] sendTouchEvent: action=${action}, pointerId=${pointerId}, pos=(${x},${y}), screen=${screenWidth}x${screenHeight}`);
    
    const packet = ControlPacket.createInjectTouchEvent(
      action, 
      BigInt(pointerId), 
      Math.round(x), 
      Math.round(y), 
      screenWidth, 
      screenHeight,
      pressure
    );

    // 优化：合并 ACTION_MOVE 事件
    // 如果之前有 ACTION_MOVE 正在发送，则暂存最新的这个包，等待发送完成后立即发送
    // 这样可以避免 Socket 缓冲区积压导致的延迟
    if (action === TouchAction.ACTION_MOVE) {
      if (this.isWritingMove) {
        // 覆盖待发送的包，只保留最新的位置
        this.pendingMovePacket = packet;
        return;
      }
      this.isWritingMove = true;
    }

    try {
      await this.clientStream.writeMain(packet);
    } finally {
      if (action === TouchAction.ACTION_MOVE) {
        this.isWritingMove = false;
        // 检查是否有排队的包需要发送
        if (this.pendingMovePacket) {
           const nextPacket = this.pendingMovePacket;
           this.pendingMovePacket = null;
           // 递归发送最新的包
           this.sendRawMovePacket(nextPacket);
        }
      }
    }
  }

  // 内部方法：递归发送排队的移动包
  private async sendRawMovePacket(packet: ArrayBuffer): Promise<void> {
    if (this.isWritingMove) {
       this.pendingMovePacket = packet;
       return;
    }
    
    this.isWritingMove = true;
    try {
      if (this.clientStream) {
        await this.clientStream.writeMain(packet);
      }
    } finally {
      this.isWritingMove = false;
      if (this.pendingMovePacket) {
        const nextPacket = this.pendingMovePacket;
        this.pendingMovePacket = null;
        this.sendRawMovePacket(nextPacket);
      }
    }
  }

  
  // 发送按键事件 - 发送按下和抬起
  async sendKeyEvent(keyCode: KeyCode, metaState: number = 0): Promise<void> {
    if (!this.clientStream) {
      LoggerClient.warn('[Control] sendKeyEvent: clientStream is null');
      return;
    }
    
    // LoggerClient.debug(`[Control] sendKeyEvent: keyCode=${keyCode}, metaState=${metaState}`);
    
    const packets = ControlPacket.createKeyEventPair(keyCode, metaState);
    for (const packet of packets) {
      await this.clientStream.writeMain(packet);
    }
  }

  private startKeepAlive(): void {
    this.keepAliveTimer = setInterval(() => {
      if (!this.isClosed && this.clientStream) {
        this.handleAction(Action.KEEP_ALIVE);
      }
    }, 3000);
  }

  // 启动主消息循环 - 接收服务器发送的事件（剪贴板、视频大小等）
  private startMainLoop(): void {
    const readLoop = async (): Promise<void> => {
      while (!this.isClosed && this.clientStream) {
        try {
          // 读取事件类型
          const eventType = await this.clientStream.readByteFromMain();

          if (this.isClosed) break;

          switch (eventType) {
            case 0: // DEVICE_MSG_TYPE_CLIPBOARD
              LoggerClient.debug('[MainLoop] Received clipboard event');
              // clipboard message: type(1) + length(4) + text
              const clipLen = await this.clientStream.readIntFromMain();
              if (clipLen > 0 && clipLen <= 100000) { // Limit sanity check
                const clipTextData = await this.clientStream.readBytesFromMain(clipLen);
                await this.handleClipboardText(clipTextData);
              }
              break;

            case 1: // DEVICE_MSG_TYPE_ACK_CLIPBOARD
              LoggerClient.debug('[MainLoop] Received ack clipboard event');
              // ack clipboard: type(1) + sequence(8)
              await this.clientStream.readBytesFromMain(8); // Ignore sequence
              break;
              
            case 2: // DEVICE_MSG_TYPE_UHID_OUTPUT
              LoggerClient.debug('[MainLoop] Received UHID output event');
               // uhid output: type(1) + id(2) + size(2) + data
              await this.clientStream.readBytesFromMain(2); // read 2 bytes
              const sizeData = await this.clientStream.readBytesFromMain(2);
              const view = new DataView(sizeData);
              const size = view.getUint16(0, false);
              if (size > 0) {
                await this.clientStream.readBytesFromMain(size);
              }
              break;

            default:
              LoggerClient.debug(`[MainLoop] Unknown event type: ${eventType}`);
              break;
          }
        } catch (err) {
          if (this.isClosed) {
            LoggerClient.debug('[MainLoop] Client closed, exiting loop');
            break;
          }

          const errorMsg = err instanceof Error ? err.message : String(err);
          if (!errorMsg.includes('timeout') && !errorMsg.includes('closed')) {
            LoggerClient.error('[MainLoop] Read error:', err);
            // 短暂延迟后重试
            await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
          }
        }
      }
    };

    // 启动异步读取循环
    readLoop().catch((err: Error) => {
      LoggerClient.error('[MainLoop] Loop error:', err);
    });
  }
  
  async close(): Promise<void> {
    if (this.isClosed) return;
    
    this.isClosed = true;
    
    // 停止视频循环
    this.videoLoopRunning = false;
    
    // 停止保活
    if (this.keepAliveTimer) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = undefined;
    }
    
    // 释放资源
    if (this.videoDecoder) {
      await this.videoDecoder.release();
      this.videoDecoder = undefined;
    }
    
    if (this.clientStream) {
      await this.clientStream.close();
      this.clientStream = undefined;
    }
    
    // 从管理器移除
    Client.allClients.delete(this.device.uuid);
    
    LoggerClient.info('Client closed');
  }
  
  static async closeAll(): Promise<void> {
    for (const client of Client.allClients.values()) {
      await client.close();
    }
    Client.allClients.clear();
  }
  
  getDevice(): Device {
    return this.device;
  }
  
  isClientClosed(): boolean {
    return this.isClosed;
  }
}
