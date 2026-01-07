import { Device } from '../entity/Device';
import { ClientStream } from './tools/ClientStream';
import { VideoDecoder } from './decode/VideoDecoder';
import { ControlPacket, Action, TouchAction, KeyCode } from './tools/ControlPacket';
import pasteboard from '@ohos.pasteboard';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

// 视频配置接口
interface VideoConfig {
  useH265: boolean;
  width: number;
  height: number;
  csd0: ArrayBuffer;
  csd1?: ArrayBuffer;
}

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
  
  constructor(device: Device) {
    this.device = device;
  }
  
  static async startDevice(device: Device, context: common.UIAbilityContext, uiContext: UIContext): Promise<Client | null> {
    if (Client.allClients.has(device.uuid)) {
      return Client.allClients.get(device.uuid) || null;
    }
    
    const client = new Client(device);
    const success = await client.connect(context, uiContext);
    
    if (success) {
      Client.allClients.set(device.uuid, client);
      return client;
    }
    
    return null;
  }
  
  private async connect(context: common.UIAbilityContext, uiContext: UIContext): Promise<boolean> {
    try {
      // 1. 建立流连接
      this.clientStream = new ClientStream(this.device);
      const connected = await this.clientStream.connect(context, uiContext);
      
      if (!connected) {
        console.error('ClientStream connection failed');
        return false;
      }
      
      // 2. 立即开始读取视频配置(不等待surface),防止服务器超时
      this.preloadVideoConfig();
      
      // 3. 启动保活定时器
      this.startKeepAlive();

      // 4. 启动主消息循环（接收剪贴板和视频大小事件）
      this.startMainLoop();

      // 5. 根据设置执行连接时操作 (match Android Client.java lines 47-49)
      try {
        // 唤醒屏幕 - Android uses "buttonWake" which sends createPowerEvent(1)
        if (this.device.wakeOnConnect) {
          console.info('🔆 Waking up remote device screen (wakeOnConnect=true)...');
          this.handleAction(Action.BUTTON_WAKE); // createPowerEvent(1)
        }

        // 连接时熄屏 - Android uses "buttonLightOff" with 2000ms delay
        if (this.device.lightOffOnConnect) {
          console.info('🌑 Turning off remote device screen (lightOffOnConnect=true)...');
          // Android: clientController.handleAction("buttonLightOff", null, 2000);
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 2000));
          this.handleAction(Action.BUTTON_LIGHT_OFF); // createLightEvent(0)
        }
      } catch (wakeErr) {
        console.error('🔆 Failed to handle connect actions:', wakeErr);
      }

      console.info('Client connected successfully');
      return true;
    } catch (err) {
      console.error('Client connect failed:', err);
      return false;
    }
  }
  
  private handleClipboardEvent(data: ArrayBuffer): void {
    if (data.byteLength < 5) return;
    
    const view = new DataView(data);
    const textLen = view.getUint32(1, true);
    
    if (data.byteLength < 5 + textLen) return;
    
    const textBytes = new Uint8Array(data, 5, textLen);
    const decoder = util.TextDecoder.create('utf-8');
    const text = decoder.decodeToString(textBytes);
    
    // 设置剪贴板
    if (this.device.listenClipOnRunning) {
      try {
        const systemPasteboard = pasteboard.getSystemPasteboard();
        const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
        systemPasteboard.setData(pasteData);
      } catch (err) {
        console.error('Set clipboard failed:', err);
      }
    }
  }
  
  private handleVideoSizeEvent(data: ArrayBuffer): void {
    if (data.byteLength < 9) return;
    
    const view = new DataView(data);
    const width = view.getUint32(1, true);
    const height = view.getUint32(5, true);
    
    console.info(`Video size changed: ${width}x${height}`);
    // TODO: 更新视频解码器配置
  }
  
  // 预加载视频配置 - 立即读取防止服务器超时
  private preloadVideoConfig(): void {
    console.info('preloadVideoConfig() called');
    
    if (!this.clientStream) {
      console.error('preloadVideoConfig: clientStream is null');
      return;
    }
    
    console.info('Starting async video config loading...');
    
    const loadConfig = async (): Promise<void> => {
      try {
        console.info('📹 Preloading video configuration...');
        
        if (!this.clientStream) {
          throw new Error('clientStream became null during preload');
        }
        
        // 读取视频配置 - 按Java版本顺序
        console.info('Reading useH265 byte...');
        const useH265Byte: number = await this.clientStream.readByteFromVideo();
        console.info(`useH265Byte raw value: ${useH265Byte} (0x${useH265Byte.toString(16)})`);
        const useH265: boolean = useH265Byte === 1;
        console.info(`useH265 = ${useH265}`);
        
        console.info('Reading width...');
        const widthData: ArrayBuffer = await this.clientStream.readBytesFromVideo(4);
        const widthBytes = new Uint8Array(widthData);
        console.info(`width bytes: [${Array.from(widthBytes).map(b => '0x' + b.toString(16)).join(', ')}]`);
        const widthView = new DataView(widthData);
        const width: number = widthView.getInt32(0, false);
        console.info(`width = ${width}`);
        
        console.info('Reading height...');
        const heightData: ArrayBuffer = await this.clientStream.readBytesFromVideo(4);
        const heightBytes = new Uint8Array(heightData);
        console.info(`height bytes: [${Array.from(heightBytes).map(b => '0x' + b.toString(16)).join(', ')}]`);
        const heightView = new DataView(heightData);
        const height: number = heightView.getInt32(0, false);
        console.info(`height = ${height}`);
        
        console.info(`Video config preloaded: ${useH265 ? 'H265' : 'H264'}, ${width}x${height}`);
        
        // 读取csd-0 (SPS for H264, or VPS/SPS for H265)
        console.info('Reading CSD-0...');
        const csd0: ArrayBuffer = await this.clientStream.readFrameFromVideo();
        console.info(`CSD-0 size: ${csd0.byteLength}`);
        
        // H264需要csd-1 (PPS)
        let csd1: ArrayBuffer | undefined = undefined;
        if (!useH265) {
          console.info('Reading CSD-1...');
          csd1 = await this.clientStream.readFrameFromVideo();
          console.info(`CSD-1 size: ${csd1.byteLength}`);
        }
        
        // 保存配置
        const config: VideoConfig = {
          useH265: useH265,
          width: width,
          height: height,
          csd0: csd0,
          csd1: csd1
        };
        this.videoConfig = config;
        console.info('✅ Video configuration preloaded successfully');
      } catch (err) {
        const error = err as Error;
        console.error('❌ Failed to preload video config:', error.message);
        if (error.stack) {
          console.error('Stack:', error.stack);
        }
      }
    };
    
    // 异步加载，不阻塞连接流程
    console.info('Calling loadConfig()...');
    loadConfig().catch((err: Error) => {
      console.error('loadConfig() promise rejected:', err.message);
    });
    console.info('loadConfig() call initiated');
  }
  
  async initVideoDecoder(surfaceId: string): Promise<void> {
    if (!this.clientStream) {
      throw new Error('ClientStream not initialized');
    }
    
    try {
      console.info('Initializing video decoder...');
      console.info('Waiting for video config (timeout: 5 seconds)...');
      
      // 等待视频配置预加载完成
      let retries = 0;
      while (!this.videoConfig && retries < 50) {
        await new Promise<void>((resolve: (value: void) => void) => setTimeout(resolve, 100));
        retries++;
        if (retries % 10 === 0) {
          console.info(`Still waiting for video config... (${retries * 100}ms elapsed)`);
        }
      }
      
      if (!this.videoConfig) {
        throw new Error('Video configuration not available');
      }
      
      const useH265 = this.videoConfig.useH265;
      const width = this.videoConfig.width;
      const height = this.videoConfig.height;
      const csd0 = this.videoConfig.csd0;
      const csd1 = this.videoConfig.csd1;
      console.info(`Using preloaded config: ${useH265 ? 'H265' : 'H264'}, ${width}x${height}`);
      
      // 初始化解码器
      this.videoDecoder = new VideoDecoder();
      await this.videoDecoder.init(useH265, surfaceId, width, height, csd0, csd1);
      
      console.info('Video decoder initialized, starting video loop...');
      
      // 启动视频读取循环
      this.startVideoLoop();
      
    } catch (err) {
      const error = err as Error;
      console.error('initVideoDecoder failed:', error.message);
      throw error;
    }
  }
  
  private startVideoLoop(): void {
    if (this.videoLoopRunning) return;

    this.videoLoopRunning = true;

    const readLoop = async () => {
      try {
        console.info('📺 Video loop started, waiting for frames...');
        let frameCount = 0;
        while (!this.isClosed && this.videoLoopRunning && this.clientStream) {
          try {
            // 读取帧大小
            console.info(`[Frame ${frameCount}] Reading frame size...`);
            const frameData = await this.clientStream.readFrameFromVideo();
            console.info(`[Frame ${frameCount}] Got frame data: ${frameData.byteLength} bytes`);

            if (frameData.byteLength > 0 && this.videoDecoder) {
              // 解码帧 (PTS由解码器内部处理)
              console.info(`[Frame ${frameCount}] Calling videoDecoder.decode()...`);
              await this.videoDecoder.decode(frameData, 0);
              console.info(`[Frame ${frameCount}] videoDecoder.decode() completed`);
              frameCount++;
            } else {
              console.warn(`[Frame ${frameCount}] Empty frame received: videoDecoder=${!!this.videoDecoder}`);
            }
          } catch (frameErr) {
            const errMsg = frameErr instanceof Error ? frameErr.message : String(frameErr);
            console.error('Video frame read error:', errMsg);
            if (frameErr instanceof Error && frameErr.stack) {
              console.error('Stack:', frameErr.stack);
            }
            break;
          }
        }
      } catch (err) {
        console.error('Video loop error:', err);
      } finally {
        this.videoLoopRunning = false;
        console.info('Video loop stopped');
      }
    };

    // 启动读取循环
    readLoop();
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

        // 按钮操作 - 对应 Java 版本
        case Action.BUTTON_BACK:
          this.writeToMain(ControlPacket.createKeyEvent(KeyCode.KEYCODE_BACK, 0));
          break;
        case Action.BUTTON_HOME:
          this.writeToMain(ControlPacket.createKeyEvent(KeyCode.KEYCODE_HOME, 0));
          break;
        case Action.BUTTON_SWITCH:
          this.writeToMain(ControlPacket.createKeyEvent(KeyCode.KEYCODE_APP_SWITCH, 0));
          break;
        case Action.BUTTON_ROTATE:
          this.writeToMain(ControlPacket.createRotateDeviceEvent());
          break;
        case Action.BUTTON_POWER:
          this.writeToMain(ControlPacket.createPowerEvent(-1));
          break;
        case Action.BUTTON_WAKE:
          this.writeToMain(ControlPacket.createPowerEvent(1));
          break;
        case Action.BUTTON_LOCK:
          this.writeToMain(ControlPacket.createPowerEvent(0));
          break;
        case Action.BUTTON_LIGHT:
          // Android: Display.STATE_ON (2) then Display.STATE_OFF (1) - this is a wake/toggle sequence
          this.writeToMain(ControlPacket.createLightEvent(2)); // Display.STATE_ON
          this.writeToMain(ControlPacket.createLightEvent(1)); // Display.STATE_OFF
          break;
        case Action.BUTTON_LIGHT_OFF:
          // Android: Display.STATE_UNKNOWN (0) - turns off screen while keeping stream
          this.writeToMain(ControlPacket.createLightEvent(0)); // Display.STATE_UNKNOWN
          break;

        // 系统操作
        case Action.KEEP_ALIVE:
          this.writeToMain(ControlPacket.createKeepAliveEvent());
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
          console.warn(`[Client] Unknown action: ${action}`);
          // 兼容：如果有 data，默认执行 writeByteBuffer
          if (data) {
            this.writeToMain(data);
          }
          break;
      }
    } catch (err) {
      console.error(`[Client] handleAction error for ${action}:`, err);
    }
  }

  // 内部方法：写入数据流
  private async writeToMain(data: ArrayBuffer): Promise<void> {
    if (this.clientStream) {
      await this.clientStream.writeMain(data);
    }
  }

  // 发送触摸事件
  async sendTouchEvent(action: TouchAction, pointerId: number, x: number, y: number, offsetTime: number = 0): Promise<void> {
    const actionName = action === TouchAction.ACTION_DOWN ? 'DOWN' : action === TouchAction.ACTION_UP ? 'UP' : action === TouchAction.ACTION_MOVE ? 'MOVE' : `${action}`;
    console.info(`[Client] sendTouchEvent: action=${actionName}, pointerId=${pointerId}, pos=(${x.toFixed(4)}, ${y.toFixed(4)}), offsetTime=${offsetTime}ms`);
    
    if (!this.clientStream) {
      console.error('[Client] sendTouchEvent: clientStream is null, cannot send touch event');
      return;
    }
    
    const packet = ControlPacket.createTouchEvent(action, pointerId, x, y, offsetTime);
    console.info(`[Client] sendTouchEvent: packet created, size=${packet.byteLength} bytes`);
    
    try {
      await this.clientStream.writeMain(packet);
      console.info(`[Client] sendTouchEvent: packet sent successfully`);
    } catch (err) {
      console.error(`[Client] sendTouchEvent: failed to send packet:`, err);
    }
  }
  
  // 发送按键事件
  async sendKeyEvent(keyCode: KeyCode, metaState: number = 0): Promise<void> {
    const packet = ControlPacket.createKeyEvent(keyCode, metaState);
    await this.clientStream?.writeMain(packet);
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
            case 1: // 音频事件 - 暂不处理
              console.warn('[MainLoop] Received audio event (not supported)');
              break;

            case 2: // 剪贴板事件
              console.info('[MainLoop] Received clipboard event');
              const clipSize = await this.clientStream.readIntFromMain();
              if (clipSize > 0 && clipSize <= 5000) {
                const clipData = await this.clientStream.readBytesFromMain(clipSize);
                this.handleClipboardEvent(clipData);
              }
              break;

            case 3: // 视频大小改变事件
              console.info('[MainLoop] Received video size event');
              const sizeData = await this.clientStream.readBytesFromMain(8);
              this.handleVideoSizeEvent(sizeData);
              break;

            default:
              console.warn(`[MainLoop] Unknown event type: ${eventType}`);
              break;
          }
        } catch (err) {
          if (this.isClosed) {
            console.info('[MainLoop] Client closed, exiting loop');
            break;
          }

          const errorMsg = err instanceof Error ? err.message : String(err);
          if (!errorMsg.includes('timeout') && !errorMsg.includes('closed')) {
            console.error('[MainLoop] Read error:', err);
            // 短暂延迟后重试
            await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
          }
        }
      }
    };

    // 启动异步读取循环
    readLoop().catch((err: Error) => {
      console.error('[MainLoop] Loop error:', err);
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
    
    console.info('Client closed');
  }
  
  static getClient(uuid: string): Client | undefined {
    return Client.allClients.get(uuid);
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
