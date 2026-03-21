// ClientStream - 客户端流管理
import { Device } from '../../entity/Device';
import { AdbKeyManager } from '../../helper/AdbKeyManager';
import { ServerManager } from '../../helper/ServerManager';
import { LoggerClientStream } from '../../helper/Logger';
import { buffer, util } from '@kit.ArkTS';
import * as libscrcpy from 'libscrcpy_native.so';
import fs from '@ohos.file.fs';

export class ClientStream {
  private static readonly SERVER_STOP_WAIT_MS: number = 1200;
  private static readonly SERVER_STOP_POLL_INTERVAL_MS: number = 50;
  private adbId: number = -1;
  private shellStreamId: number = -1;
  
  private currentScid: string = '';
  private isClosing: boolean = false;
  private device: Device;

  constructor(device: Device) {
    this.device = device;
  }

  // 为 Native 模式准备服务端：连接 ADB 并推送服务端。
  async prepareServerForNative(
    context: Context, // 需要Context来获取AdbKeyManager
    serverJarData: ArrayBuffer | null,
    onWaitAuth?: () => void
  ): Promise<number> {
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
          throw new Error('app.string.adb_native_connect_failed');
      }

      const connectRes: number = await libscrcpy.adbConnect(this.adbId, pubKeyPath, priKeyPath, onWaitAuth);
      if (connectRes !== 0) {
          if (connectRes === -2) {
             throw new Error('app.string.connect_timeout_toast');
          } else if (connectRes === -3) {
             throw new Error('app.string.adb_auth_failed');
          } else if (connectRes === -4) {
             throw new Error('app.string.adb_connect_timeout');
          } else if (connectRes === -5) {
             throw new Error('app.string.adb_auth_timeout');
          } else if (connectRes === -6) {
             throw new Error('app.string.connection_cancelled');
          } else if (connectRes === -7) {
             throw new Error('app.string.adb_auth_disconnected');
          } else {
             throw new Error(`app.string.adb_native_connect_failed_code_${connectRes}`);
          }
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

      return this.adbId;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.error('[ClientStream] prepareServerForNative failed:', errMsg);
      this.close();
      throw (err instanceof Error) ? err : new Error(String(err));
    }
  }

  startServer(args: string): void {
    const serverPath = `/data/local/tmp/scrcpy-server-${ServerManager.getVersion()}`;
    this.currentScid = ServerManager.getLastScid();
    const socketName = `scrcpy_${this.currentScid}`;
    const cmd = `CLASSPATH=${serverPath} app_process / com.genymobile.scrcpy.Server ${ServerManager.getVersion()} ${args} 2>&1`;

    LoggerClientStream.info(`[ClientStream] Starting server with command: ${cmd}`);
    this.stopServer();

    this.shellStreamId = libscrcpy.adbGetShell(this.adbId);
    if (this.shellStreamId < 0) {
      throw new Error('Native ADB Get Shell failed');
    }
    const shellStreamId = this.shellStreamId;

    const cmdBytes = buffer.from(cmd + '\n', 'utf-8');
    libscrcpy.adbStreamWrite(this.adbId, shellStreamId, cmdBytes.buffer);

    LoggerClientStream.info(`[ClientStream] Server started, SCID: ${this.currentScid}, socket: ${socketName}`);
    this.readShellOutputAsync(shellStreamId);
  }

  // 异步读取Shell输出
  private async readShellOutputAsync(shellStreamId: number) {
    try {
        const decoder = util.TextDecoder.create('utf-8');
        while (!this.isClosing && this.adbId >= 0) {
            const isClosed: boolean = libscrcpy.adbIsStreamClosed(this.adbId, shellStreamId);
            if (isClosed) {
                LoggerClientStream.info('[ClientStream] Shell stream closed by remote');
                break;
            }
            
            const data: ArrayBuffer = libscrcpy.adbStreamRead(this.adbId, shellStreamId, 1024);
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
    // Do not close the whole ADB connection here.
    // Native stream threads may still be running and own the shutdown order.
    if (this.shellStreamId === shellStreamId) {
      this.shellStreamId = -1;
    }
  }

  stopServer(): void {
    if (this.adbId < 0 || this.shellStreamId < 0) {
      return;
    }

    const shellStreamId = this.shellStreamId;
    this.shellStreamId = -1;
    try {
      libscrcpy.adbStreamClose(this.adbId, shellStreamId);
    } catch (e) {
      LoggerClientStream.error('[ClientStream] stopServer failed', JSON.stringify(e));
    }
  }

  async stopServerAndWait(timeoutMs: number = ClientStream.SERVER_STOP_WAIT_MS): Promise<void> {
    if (this.adbId < 0 || this.shellStreamId < 0) {
      return;
    }

    const shellStreamId = this.shellStreamId;
    this.stopServer();

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.adbId < 0 || libscrcpy.adbIsStreamClosed(this.adbId, shellStreamId)) {
        return;
      }
      await new Promise<void>(resolve => setTimeout(resolve, ClientStream.SERVER_STOP_POLL_INTERVAL_MS));
    }

    LoggerClientStream.warn('[ClientStream] Timed out waiting for server shell to close');
  }

  isServerShellAlive(): boolean {
    if (this.adbId < 0 || this.shellStreamId < 0) {
      return false;
    }
    return !libscrcpy.adbIsStreamClosed(this.adbId, this.shellStreamId);
  }

  close() {
      if (this.isClosing) return;
      this.isClosing = true;
      LoggerClientStream.info('[ClientStream] Closing...');
      this.stopServer();
      
      if (this.adbId >= 0) {
          libscrcpy.adbClose(this.adbId);
          this.adbId = -1;
          this.shellStreamId = -1;
      }
  }
}
