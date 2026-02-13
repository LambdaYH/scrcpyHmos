// ClientStream - 客户端流管理
import { Device } from '../../entity/Device';
// import { Adb } from '../../adb/Adb'; 
// import { BufferStream } from '../../buffer/BufferStream';
import { AdbKeyManager } from '../../helper/AdbKeyManager';
import { ServerManager } from '../../helper/ServerManager';
import { LoggerClientStream } from '../../helper/Logger';
import { buffer, util } from '@kit.ArkTS';
import * as libscrcpy from 'libscrcpy_native.so';
import fs from '@ohos.file.fs';

// Video configuration from handshake
export interface VideoConfig {
  codecId: number;
  width: number;
  height: number;
}

// Audio configuration - actual codec from server
export interface AudioConfig {
  codecId: number; // Raw codec ID from server (e.g., 0x6F707573 for opus)
  codecName: string; // Human readable codec name (e.g., "opus", "aac")
}

// 视频帧接口
export interface VideoFrame {
  data: ArrayBuffer;
  pts: number;
  flags: number;
}

// 音频帧接口
export interface AudioFrame {
  data: ArrayBuffer;
  pts: number; // Presentation timestamp in microseconds
}

export class ClientStream {
  // Native ADB ID
  private adbId: number = -1;
  private shellStreamId: number = -1;
  
  private currentScid: string = '';
  private isConnected: boolean = false;
  private isClosing: boolean = false;
  private device: Device;
  // private adb?: Adb; // Removed
  // Handshake data
  private deviceName: string = '';
  private videoConfig?: VideoConfig;
  private audioConfig?: AudioConfig;

  constructor(device: Device) {
    this.device = device;
  }


  // 为 Native 模式准备服务端：连接ADB，推送服务端，启动服务端，但不打开流
  async prepareServerForNative(
    context: Context, // 需要Context来获取AdbKeyManager
    serverJarData: ArrayBuffer | null,
    onWaitAuth?: () => void
  ): Promise<boolean> {
    try {
      this.isClosing = false;
      LoggerClientStream.info('[ClientStream] Preparing server for native mode (Native ADB)...');

      // 1. 初始化 ADB 密钥管理器
      const keyManager = AdbKeyManager.getInstance();
      await keyManager.init(context);

      // 导出密钥到临时文件
      const tempDir = context.tempDir;
      const pubKeyPath = tempDir + '/scrcpy_adbkey.pub';
      const priKeyPath = tempDir + '/scrcpy_adbkey';
      
      // Write Public Key
      const pubKeyBytes = keyManager.getPublicKeyBytes();
      const pubFile = fs.openSync(pubKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(pubFile.fd, pubKeyBytes as ArrayBuffer);
      fs.closeSync(pubFile);

      // Write Private Key (PEM)
      const priKeyBase64 = keyManager.getPrivateKeyBase64();
      const pemContent = "-----BEGIN PRIVATE KEY-----\n" + priKeyBase64 + "\n-----END PRIVATE KEY-----";
      const priFile = fs.openSync(priKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(priFile.fd, pemContent);
      fs.closeSync(priFile);

      // 2. 连接ADB (Native)
      LoggerClientStream.info(`[ClientStream] Connecting to Native ADB at ${this.device.address}:${this.device.adbPort}`);
      this.adbId = await libscrcpy.adbCreate(this.device.address, this.device.adbPort);
      if (this.adbId < 0) {
          throw new Error('Native ADB Create failed');
      }

      const connectRes: number = await libscrcpy.adbConnect(this.adbId, pubKeyPath, priKeyPath, onWaitAuth);
      if (connectRes !== 0) {
          throw new Error(`Native ADB Connect failed: ${connectRes}`);
      }
      LoggerClientStream.info('[ClientStream] Native ADB connected');

      // 3. 推送服务端
      const serverPath = `/data/local/tmp/scrcpy-server-${ServerManager.getVersion()}`;
      if (serverJarData && serverJarData.byteLength > 0) {
          LoggerClientStream.info(`[ClientStream] Pushing server to ${serverPath}...`);
          libscrcpy.adbPushFile(this.adbId, serverJarData, serverPath);
      } else {
          LoggerClientStream.warn('[ClientStream] No server jar data, skipping push');
      }

      // 4. 启动服务端
      const args = ServerManager.buildServerArgs(this.device);
      // Ensure SCID is generated (ServerManager generates it during buildServerArgs if not present, but better to check)
      // Actually buildServerArgs calls generateScid.
      this.currentScid = ServerManager.getLastScid();
      const socketName = `scrcpy_${this.currentScid}`;
      
      const cmd = `CLASSPATH=${serverPath} app_process / com.genymobile.scrcpy.Server ${ServerManager.getVersion()} ${args} 2>&1`;
      LoggerClientStream.info(`[ClientStream] Starting server with command: ${cmd}`);
      
      this.shellStreamId = libscrcpy.adbGetShell(this.adbId);
      if (this.shellStreamId < 0) {
          throw new Error('Native ADB Get Shell failed');
      }
      
      const cmdBytes = buffer.from(cmd + '\n', 'utf-8');
      libscrcpy.adbStreamWrite(this.adbId, this.shellStreamId, cmdBytes.buffer);

      LoggerClientStream.info(`[ClientStream] Server started, SCID: ${this.currentScid}, socket: ${socketName}`);

      // 5. Monitor output
      this.readShellOutputAsync();
      
      this.isConnected = true;
      return true;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.error('[ClientStream] prepareServerForNative failed:', errMsg);
      this.close();
      return false;
    }
  }

  // 异步读取Shell输出
  private async readShellOutputAsync() {
    try {
        const decoder = util.TextDecoder.create('utf-8');
        while (!this.isClosing && this.adbId >= 0 && this.shellStreamId >= 0) {
            // Check if closed
            const isClosed: boolean = libscrcpy.adbIsStreamClosed(this.adbId, this.shellStreamId);
            if (isClosed) {
                LoggerClientStream.info('[ClientStream] Shell stream closed by remote');
                break;
            }
            
            // Read
            const data: ArrayBuffer = libscrcpy.adbStreamRead(this.adbId, this.shellStreamId, 1024);
            if (data.byteLength > 0) {
                const text = decoder.decodeToString(new Uint8Array(data));
                LoggerClientStream.info('[ServerOutput] ' + text.trim());
            } else {
                await new Promise<void>(resolve => setTimeout(resolve, 100));
            }
        }
    } catch (e) {
        LoggerClientStream.error('[ClientStream] Read shell output failed', JSON.stringify(e));
    }
    this.close();
  }

  close() {
      if (this.isClosing) return;
      this.isClosing = true;
      LoggerClientStream.info('[ClientStream] Closing...');
      
      if (this.adbId >= 0) {
          libscrcpy.adbClose(this.adbId);
          this.adbId = -1;
          this.shellStreamId = -1;
      }
      this.isConnected = false;
  }
}
