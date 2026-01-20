// ClientStream - 客户端流管理
// 完全按照EasyControl的ClientStream.java实现
import { Device } from '../../entity/Device';
import { Adb, AdbKeyPair } from '../../adb/Adb';
import { BufferStream } from '../../buffer/BufferStream';
import { AdbKeyManager } from '../../helper/AdbKeyManager';
import { ServerManager, ServerStartResult } from '../../helper/ServerManager';
import socket from '@ohos.net.socket';
import { buffer } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

// 客户端流管理
export class ClientStream {
  private mainSocket?: socket.TCPSocket;
  private videoSocket?: socket.TCPSocket;
  private mainStream?: BufferStream;  // ADB转发的主stream
  private videoStream?: BufferStream; // ADB转发的视频stream
  private controlStream?: BufferStream; // ADB转发的控制stream
  private shellStream?: BufferStream; // 保存shell stream用于读取服务器日志
  private currentScid: string = ''; // 当前连接的SCID
  private isConnected: boolean = false;
  private connectDirect: boolean = false; // 是否直连（true）或ADB转发（false）
  private device: Device;
  private adb?: Adb; // 保存adb实例用于转发

  // 完全按照原版：服务器名称包含版本号
  // private static readonly serverName = '/data/local/tmp/easycontrol_server_1000000.jar'; // Moved to ServerManager
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
          // scrcpy使用localabstract socket（tunnel_forward模式）
          // socket名称格式: scrcpy_<SCID>
          if (!this.mainStream) {
            this.mainStream = await adb.localSocketForward(socketName);
            console.info('Main stream connected via localabstract socket');
          }
          if (!this.videoStream) {
            this.videoStream = await adb.localSocketForward(socketName);
            console.info('Audio stream connected via localabstract socket');
          }
          if (!this.controlStream) {
            this.controlStream = await adb.localSocketForward(socketName);
            console.info('Control stream connected via localabstract socket');
          }
          break;
        } catch (err) {
          const errMsg = err instanceof Error ? err.message : String(err);
          console.warn(`Server connection attempt ${i + 1}/${reTry} failed:`, errMsg);
          this.mainStream = undefined;
          this.videoStream = undefined;
          this.controlStream = undefined;
          if (i < reTry - 1) {
            await new Promise<void>(resolve => setTimeout(resolve, reTryTime));
          }
        }
      }
      
      if (!this.mainStream || !this.videoStream || !this.controlStream) {
        throw new Error('Failed to connect to server after all retries');
      }

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

  // 连接服务器 - 直接使用ADB转发（远程设备必须使用转发）
  private async connectServer(): Promise<void> {
    // 等待服务器启动 - 减少到100ms，服务器只等20秒超时
    await this.delay(100);

    const reTry = 40;
    const reTryTime = 15000 / reTry;

    // 对于远程ADB设备，必须使用ADB转发，不能直连
    // 因为服务器监听的是Android设备本地的端口
    console.info('Using ADB TCP forward (required for remote devices)...');

    if (!this.adb) {
      throw new Error('ADB instance not available');
    }

    for (let i = 0; i < reTry; i++) {
      try {
        if (!this.mainStream) {
          // scrcpy使用固定端口27183
          const scrcpyPort = 27183;
          this.mainStream = await this.adb.tcpForward(scrcpyPort);
          console.info('Main stream forwarded via ADB');
        }

        if (!this.videoStream) {
          // scrcpy使用固定端口27183
          const scrcpyPort = 27183;
          this.videoStream = await this.adb.tcpForward(scrcpyPort);
          console.info('Video stream forwarded via ADB');
        }

        this.connectDirect = false;
        console.info('ADB forward connection established');
        return;
      } catch (err) {
        const errMsg = err instanceof Error ? err.message : String(err);
        console.warn(`ADB forward attempt ${i + 1}/${reTry} failed:`, errMsg);

        // 清理失败的stream
        this.mainStream = undefined;
        this.videoStream = undefined;

        if (i < reTry - 1) {
          await this.delay(reTryTime);
        }
      }
    }

    throw new Error('Failed to connect to server after all retries');
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
      } else if (!this.connectDirect && this.mainStream) {
        await this.mainStream.write(data);
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
    } else if (this.mainStream) {
      return await this.mainStream.readByteArray(length);
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
    if (!this.mainStream) {
      throw new Error('Main stream not connected');
    }
    return await this.mainStream.readByteArray(length);
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
    if (!this.videoStream) {
      throw new Error('Video stream not connected');
    }

    // 从BufferStream读取
    return await this.videoStream.readByteArray(length);
  }

  // 读取一帧视频数据（先读4字节大小，再读帧数据）
  async readFrameFromVideo(): Promise<ArrayBuffer> {
    console.debug('[ClientStream] Reading frame size (4 bytes)...');
    const frameSize = await this.readIntFromVideo();
    console.debug(`[ClientStream] Frame size: ${frameSize} bytes`);
    if (frameSize <= 0 || frameSize > 10 * 1024 * 1024) { // 最大10MB
      throw new Error(`Invalid frame size: ${frameSize}`);
    }
    console.debug(`[ClientStream] Reading frame data (${frameSize} bytes)...`);
    const frameData = await this.readBytesFromVideo(frameSize);
    console.debug(`[ClientStream] Frame data read complete`);
    return frameData;
  }

  async readFromVideo(length: number): Promise<ArrayBuffer> {
    if (this.connectDirect) {
      // TODO: 实现从socket读取
      return new ArrayBuffer(0);
    } else if (this.videoStream) {
      return await this.videoStream.readByteArray(length);
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
    if (this.mainStream) {
      try {
        this.mainStream.close();
      } catch (err) {
        console.error('Close main stream failed:', err);
      }
      this.mainStream = undefined;
    }
    if (this.videoStream) {
      try {
        this.videoStream.close();
      } catch (err) {
        console.error('Close video stream failed:', err);
      }
      this.videoStream = undefined;
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
