// ClientStream - 客户端流管理
// 完全按照EasyControl的ClientStream.java实现
import { Device } from '../../entity/Device';
import { Adb, AdbKeyPair } from '../../adb/Adb';
import { BufferStream } from '../../buffer/BufferStream';
import { AdbKeyManager } from '../../helper/AdbKeyManager';
import { ServerManager, ServerStartResult } from '../../helper/ServerManager';
import socket from '@ohos.net.socket';
import { buffer, util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

// Video configuration from handshake
export interface VideoConfig {
  codecId: number;
  width: number;
  height: number;
}

export class ClientStream {
  private mainSocket?: socket.TCPSocket;
  private videoSocket?: socket.TCPSocket;
  
  // Correctly mapped streams
  private vidStream?: BufferStream; // 1st connection: Video
  private audStream?: BufferStream; // 2nd connection: Audio
  private msgStream?: BufferStream; // 3rd connection: Control
  
  private shellStream?: BufferStream;
  private currentScid: string = '';
  private isConnected: boolean = false;
  private connectDirect: boolean = false;
  private device: Device;
  private adb?: Adb;
  
  // Handshake data
  private deviceName: string = '';
  private videoConfig?: VideoConfig;

  private static readonly timeoutDelay = 15000;

  constructor(device: Device) {
    this.device = device;
  }

  async connect(context: common.UIAbilityContext, uiContext: UIContext): Promise<boolean> {
    try {
      console.info('Starting device connection...');

      // 0. Initialize ADB key manager with device address
      const keyManager = AdbKeyManager.getInstance();
      await keyManager.init(context);
      console.info('ADB key manager initialized');

      // 1. 通过ADB连接设备
      console.info(`Connecting to ADB at ${this.device.address}:${this.device.adbPort}`);

      const keyPair = keyManager.getAdbKeyPair();
      if (!keyPair) {
        throw new Error('Failed to get ADB key pair');
      }
      const adb = await Adb.connectTcp(this.device.address, this.device.adbPort, keyPair, uiContext);
      console.info('ADB connected successfully');

      // 保存adb实例用于后续转发
      this.adb = adb;

      // 2. 检查并推送服务端
      const serverExists = await ServerManager.checkServerExists(adb);
      if (!serverExists) {
        // 加载 rawfile/server.jar
        const serverData = await ServerManager.loadServerFromRawfile(context);
        if (!serverData) {
          throw new Error('Load server.jar failed');
        }

        // 推送
        const pushed = await ServerManager.pushServer(adb, serverData);
        if (!pushed) {
          throw new Error('Push server.jar failed');
        }
      }

      // 3. 启动服务端 - 使用ServerManager的scrcpy启动命令
      console.info(`Starting scrcpy server v${ServerManager.getVersion()}...`);

      const serverResult: ServerStartResult = await ServerManager.startServer(adb, this.device);
      this.shellStream = serverResult.shellStream;
      this.currentScid = serverResult.scid;
      this.adb = adb;
      
      // 构建socket名称
      const socketName = `scrcpy_${this.currentScid}`;
      console.info(`Server started with SCID: ${this.currentScid}, socket name: ${socketName}`);

      // 4. 等待服务器启动并连接
      console.info('Waiting for server to start...');
      await new Promise<void>(resolve => setTimeout(resolve, 50));
      
      // 重试连接服务器（参考easycontrol原版）
      const reTry = 40;
      const reTryTime = 15000 / reTry;
      
      for (let i = 0; i < reTry; i++) {
        try {
          // Sequential Connection & Handshake logic matching official client
          // Server sends dummy byte ONLY on the FIRST accepted socket (DesktopConnection.java:68-88)
          // So we only read from Video stream, not Audio or Control.
          
          // 1. Connect Video -> Read Dummy (FIRST socket, gets dummy byte)
          console.info('Connecting Video Stream...');
          this.vidStream = await adb.localSocketForward(socketName);
          console.debug('Reading video dummy byte...');
          await this.vidStream.readByteArray(1);

          // Auto-detect audio support (Android 11+ required)
          if (this.device.isAudio) {
             try {
               const sdkStr = await adb.runAdbCmd('shell getprop ro.build.version.sdk');
               const sdk = parseInt(sdkStr.trim());
               if (!isNaN(sdk) && sdk < 30) {
                 console.warn(`Device SDK ${sdk} < 30 (Android 11), disabling audio automatically.`);
                 this.device.isAudio = false;
               }
             } catch (e) {
               console.warn('Failed to check Android version, assuming audio supported:', e);
             }
          }

          // 2. Connect Audio (NO dummy byte - server already set sendDummyByte=false)
          if (this.device.isAudio) {
            console.info('Connecting Audio Stream...');
            this.audStream = await adb.localSocketForward(socketName);
            // No dummy byte read - server only sends on first socket
          }

          // 3. Connect Control (NO dummy byte)
          console.info('Connecting Control Stream...');
          this.msgStream = await adb.localSocketForward(socketName);
          // No dummy byte read - server only sends on first socket
          
          break;
        } catch (err) {
          const errMsg = err instanceof Error ? err.message : String(err);
          console.warn(`Server connection attempt ${i + 1}/${reTry} failed:`, errMsg);
          this.vidStream = undefined;
          this.audStream = undefined;
          this.msgStream = undefined;
          if (i < reTry - 1) {
            await new Promise<void>(resolve => setTimeout(resolve, reTryTime));
          }
        }
      }
      
      if (!this.vidStream || !this.audStream || !this.msgStream) {
        throw new Error('Failed to connect to server streams after all retries');
      }

      // 5. Perform Handshake (Rest)
      console.info('Performing handshake (Device Name, Codec)...');
      await this.performHandshakeRest();

      // 连接成功后才开始读取shell输出
      this.readShellOutputAsync();

      this.isConnected = true;
      console.info('Connection established successfully');
      return true;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      console.error('ClientStream connect failed:', errMsg);

      if (errMsg.includes('Read timeout')) {
        try {
          uiContext.getPromptAction().showDialog({
            title: '连接超时',
            message: '连接设备超时。通常是因为：\n1. 手机未弹出授权框或您未点击允许。\n2. 手机处于锁屏状态。\n\n请解锁手机并检查屏幕上是否有"允许USB调试"的弹窗。',
            buttons: [{ text: '知道了', color: '#007AFF' }]
          });
        } catch (e) {
          console.error('Show timeout dialog failed:', e);
        }
      }
      return false;
    }
  }

  // 旧的buildServerArgs已经移到ServerManager，此方法仅为向后兼容保留
  private buildServerArgs(): string {
    // 返回空字符串，实际参数由ServerManager.buildServerArgs构建
    return '';
  }

  // 使用ServerManager启动服务器 - 旧方法，已迁移到connect()
  private async startServer(context: common.UIAbilityContext, adb: Adb): Promise<void> {
    // 检查服务器是否存在
    const exists = await ServerManager.checkServerExists(adb);
    
    if (!exists) {
      console.info('Server not found, pushing new server...');
      const serverData = await ServerManager.loadServerFromRawfile(context);
      if (!serverData) {
        throw new Error('Load server.jar failed');
      }
      await ServerManager.pushServer(adb, serverData);
    } else {
      console.info('Server already exists');
    }

    // 启动服务器
    console.info(`Server params: stayAwake=${this.device.stayAwake}`);
    const result = await ServerManager.startServer(adb, this.device);
    this.shellStream = result.shellStream;
    this.currentScid = result.scid;
    console.info('Server start command sent via ServerManager');
  }

  private readShellOutputAsync(): void {
    if (!this.shellStream) return;

    const stream = this.shellStream;

    // 异步读取shell输出
    const readLoop = async () => {
      try {
        let count = 0;
        while (!stream.isStreamClosed() && count < 100) { // 限制最多读100次
          try {
            if (!stream.isEmpty()) {
              const data = await stream.readAllBytes();
              if (data.byteLength > 0) {
                const text = buffer.from(data).toString('utf-8');
                console.debug('=== Server shell output ===');
                console.debug(text);
                console.debug('===========================');
                count++;
              }
            } else {
              // 空数据，等���一下再继续
              await this.delay(200);
            }
          } catch (readErr) {
            const errMsg = readErr instanceof Error ? readErr.message : String(readErr);
            if (!errMsg.includes('timeout')) {
              console.error('Shell read error:', errMsg);
              break;
            }
            // 超时是正常的，继续
            await this.delay(100);
          }
        }
        console.info('Shell output reading finished');
      } catch (err) {
        console.error('Shell read loop error:', err);
      }
    };

    // 启动读取循环（不阻塞主流程）
    readLoop();
  }

  // Remaining Handshake implementation (Device Name, Codec Meta)
  private async performHandshakeRest(): Promise<void> {
    if (!this.vidStream) {
      throw new Error('Video stream not connected');
    }

    // Dummy bytes already read in connect()

    // 2. Read Device Name (64 bytes) from Video Stream
    console.debug('Reading device name...');
    const deviceNameData = await this.vidStream.readByteArray(64);
    const decoder = util.TextDecoder.create('utf-8');
    this.deviceName = decoder.decodeToString(new Uint8Array(deviceNameData)).replace(/\0/g, '');
    console.info(`Device Name: ${this.deviceName}`);

    // 3. Read Codec Metadata (12 bytes) from Video Stream
    console.debug('Reading codec metadata...');
    const codecData = await this.vidStream.readByteArray(12);
    const view = new DataView(codecData);
    const codecId = view.getInt32(0, false);
    const width = view.getInt32(4, false);
    const height = view.getInt32(8, false);
    
    this.videoConfig = {
      codecId: codecId,
      width: width,
      height: height
    };
    console.info(`Video Config: Codec=${codecId}, Size=${width}x${height}`);
  }
  
  getVideoConfig(): VideoConfig | undefined {
    return this.videoConfig;
  }

  private async connectSocket(tcpSocket: socket.TCPSocket, address: string, port: number): Promise<void> {
    return new Promise((resolve, reject) => {
      tcpSocket.on('connect', () => {
        console.debug('Socket connected');
        resolve();
      });

      tcpSocket.on('error', (err: Error) => {
        console.error('Socket error:', err.message);
        reject(err);
      });

      const connectAddress: socket.TCPConnectOptions = {
        address: {
          address: address,
          port: port,
          family: 1
        },
        timeout: 10000
      };

      tcpSocket.connect(connectAddress).catch((err: Error) => {
        reject(err);
      });
    });
  }

  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  async writeMain(data: ArrayBuffer): Promise<void> {
    try {
      if (this.connectDirect && this.mainSocket) {
        await this.mainSocket.send({ data: data });
      } else if (!this.connectDirect && this.msgStream) {
        await this.msgStream.write(data);
      } else {
        throw new Error('No valid main connection');
      }
    } catch (err) {
      console.error('Write to main socket failed:', err);
      const error = err instanceof Error ? err : new Error(String(err));
      throw error;
    }
  }

  async readFromMain(length: number): Promise<ArrayBuffer> {
    if (this.connectDirect) {
      // TODO: 实现从socket读取
      return new ArrayBuffer(0);
    } else if (this.msgStream) {
      return await this.msgStream.readByteArray(length);
    }
    return new ArrayBuffer(0);
  }

  // 从main stream读取一个字节
  async readByteFromMain(): Promise<number> {
    const data: ArrayBuffer = await this.readBytesFromMain(1);
    return new Uint8Array(data)[0];
  }

  // 从main stream读取4字节整数（big-endian）
  async readIntFromMain(): Promise<number> {
    const data: ArrayBuffer = await this.readBytesFromMain(4);
    const view = new DataView(data);
    return view.getInt32(0, false); // big-endian
  }

  // 从main stream读取指定长度的字节
  async readBytesFromMain(length: number): Promise<ArrayBuffer> {
    if (!this.msgStream) {
      throw new Error('Message stream not connected');
    }
    return await this.msgStream.readByteArray(length);
  }

  // 从video stream读取一个字节
  async readByteFromVideo(): Promise<number> {
    const data = await this.readBytesFromVideo(1);
    return new Uint8Array(data)[0];
  }

  // 从video stream读取4字节整数（big-endian）
  async readIntFromVideo(): Promise<number> {
    const data = await this.readBytesFromVideo(4);
    const view = new DataView(data);
    return view.getInt32(0, false); // big-endian
  }

  // 从video stream读取指定长度的字节
  async readBytesFromVideo(length: number): Promise<ArrayBuffer> {
    if (!this.vidStream) {
      throw new Error('Video stream not connected');
    }

    // 从BufferStream读取
    return await this.vidStream.readByteArray(length);
  }

  // 读取一帧视频数据（Scrcpy V2协议：PTS(8) + Size(4) + Data）
  async readFrameFromVideo(): Promise<ArrayBuffer> {
    // console.debug('[ClientStream] Reading frame header...');
    
    // 1. Read PTS (8 bytes)
    const ptsBytes = await this.readBytesFromVideo(8);
    const view = new DataView(ptsBytes);
    const pts = view.getBigInt64(0, false);
    
    // Check Config Packet flag (bit 63)
    const PACKET_FLAG_CONFIG = 1n << 63n;
    const isConfig = (pts & PACKET_FLAG_CONFIG) !== 0n;
    
    if (isConfig) {
       console.info('[ClientStream] Received Configuration Packet (SPS/PPS)');
    }

    // 2. Read Size (4 bytes)
    const frameSize = await this.readIntFromVideo();
    // console.debug(`[ClientStream] Frame size: ${frameSize} bytes`);
    
    if (frameSize <= 0 || frameSize > 20 * 1024 * 1024) { // Increase limit to 20MB for I-frames
      throw new Error(`Invalid frame size: ${frameSize}`);
    }

    // 3. Read Data
    // console.debug(`[ClientStream] Reading frame data (${frameSize} bytes)...`);
    const frameData = await this.readBytesFromVideo(frameSize);
    // console.debug(`[ClientStream] Frame data read complete`);
    return frameData;
  }

  async readFromVideo(length: number): Promise<ArrayBuffer> {
    if (this.connectDirect) {
      // TODO: 实现从socket读取
      return new ArrayBuffer(0);
    } else if (this.vidStream) {
      return await this.vidStream.readByteArray(length);
    }
    return new ArrayBuffer(0);
  }

  setMainMessageCallback(callback: (data: ArrayBuffer) => void): void {
    if (this.mainSocket) {
      this.mainSocket.on('message', (value: socket.SocketMessageInfo) => {
        if (value.message) {
          callback(value.message);
        }
      });
    }
  }

  setVideoMessageCallback(callback: (data: ArrayBuffer) => void): void {
    if (this.videoSocket) {
      this.videoSocket.on('message', (value: socket.SocketMessageInfo) => {
        if (value.message) {
          callback(value.message);
        }
      });
    }
  }

  async close(): Promise<void> {
    // 关闭直连socket
    if (this.mainSocket) {
      try {
        await this.mainSocket.close();
      } catch (err) {
        console.error('Close main socket failed:', err);
      }
      this.mainSocket = undefined;
    }
    if (this.videoSocket) {
      try {
        await this.videoSocket.close();
      } catch (err) {
        console.error('Close video socket failed:', err);
      }
      this.videoSocket = undefined;
    }

    // 关闭ADB转发streams
    if (this.vidStream) {
      try {
        this.vidStream.close();
      } catch (err) {
        console.error('Close video stream failed:', err);
      }
      this.vidStream = undefined;
    }
    if (this.audStream) {
      try {
        this.audStream.close();
      } catch (err) {
        console.error('Close audio stream failed:', err);
      }
      this.audStream = undefined;
    }
    if (this.msgStream) {
      try {
        this.msgStream.close();
      } catch (err) {
        console.error('Close msg stream failed:', err);
      }
      this.msgStream = undefined;
    }
    if (this.shellStream) {
      try {
        this.shellStream.close();
      } catch (err) {
        console.error('Close shell stream failed:', err);
      }
      this.shellStream = undefined;
    }

    // 关闭ADB连接
    if (this.adb) {
      this.adb.close();
      this.adb = undefined;
    }

    this.isConnected = false;
  }

  isStreamConnected(): boolean {
    return this.isConnected;
  }
}
