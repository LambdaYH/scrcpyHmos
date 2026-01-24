// Adb - 完整的ADB实现
// 参考EasyControl的Adb.java实现
import { AdbChannel } from './AdbChannel';
import { TcpChannel } from './TcpChannel';
import { AdbProtocol, AdbMessage } from './AdbProtocol';
import { BufferStream, UnderlySocketFunction } from '../buffer/BufferStream';
import { LoggerAdb } from '../helper/Logger';
import { buffer, util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { AdbKeyPair } from './AdbKeyPair';
import { AdbBase64Impl } from './AdbBase64';

export { AdbKeyPair };

AdbKeyPair.setAdbBase64(new AdbBase64Impl());

// 进度回调函数类型
export type ProcessCallback = (progress: number) => void;

// Promise resolver类型
type PromiseResolver = () => void;

// 底层Socket功能接口实现类
class UnderlySocketFunctionImpl implements UnderlySocketFunction {
  private adb: Adb;
  private localId: number;
  private remoteId: number;

  constructor(adb: Adb, localId: number, remoteId: number) {
    this.adb = adb;
    this.localId = localId;
    this.remoteId = remoteId;
  }

  connect(bufferStream: BufferStream): void {
    this.adb.connectionStreams.set(this.localId, bufferStream);
    this.adb.openStreams.set(this.localId, bufferStream);
  }

  write(_bufferStream: BufferStream, data: ArrayBuffer): void {
    // 分块发送
    const dataArray = new Uint8Array(data);
    let offset = 0;
    while (offset < dataArray.length) {
      const chunkSize = Math.min(this.adb.getMaxData() - 128, dataArray.length - offset);
      const chunk = dataArray.slice(offset, offset + chunkSize);
      this.adb.writeToChannel(AdbProtocol.generateWrite(this.localId, this.remoteId, chunk.buffer as ArrayBuffer));
      offset += chunkSize;
    }
  }

  flush(_bufferStream: BufferStream): void {
    this.adb.writeToChannel(AdbProtocol.generateOkay(this.localId, this.remoteId));
  }

  close(_bufferStream: BufferStream): void {
    this.adb.connectionStreams.delete(this.localId);
    this.adb.writeToChannel(AdbProtocol.generateClose(this.localId, this.remoteId));
  }
}

// ADB主类 - 完全参考EasyControl的Adb.java
export class Adb {
  private isClosed: boolean = false;
  private channel: AdbChannel;
  private localIdPool: number = 1;
  private maxData: number = AdbProtocol.CONNECT_MAXDATA;

  // 连接流管理 - 对应Java的ConcurrentHashMap
  connectionStreams: Map<number, BufferStream> = new Map();
  openStreams: Map<number, BufferStream> = new Map();

  // 等待通知的Promise resolver列表
  waitResolvers: PromiseResolver[] = [];

  // 后台消息处理
  private handleInRunning: boolean = false;

  private constructor(channel: AdbChannel) {
    this.channel = channel;
  }

  // 通过TCP连接创建ADB实例
  static async connectTcp(address: string, port: number, keyPair: AdbKeyPair, uiContext: UIContext): Promise<Adb> {
    const channel = new TcpChannel();
    await channel.connect(address, port);
    const adb = new Adb(channel);
    await adb.connect(keyPair, uiContext);
    return adb;
  }

  private async connect(keyPair: AdbKeyPair, uiContext: UIContext): Promise<void> {
    // 连接ADB并认证
    await this.channel.write(AdbProtocol.generateConnect());

    let message = await AdbMessage.parseAdbMessage(this.channel);

    if (message.command === AdbProtocol.CMD_AUTH) {
      // 发送签名
      const signature = await keyPair.signPayload(message.payload!);
      // 重要：创建正确大小的ArrayBuffer，避免Uint8Array.buffer的偏移问题
      const signatureBuffer = new ArrayBuffer(signature.length);
      const signatureView = new Uint8Array(signatureBuffer);
      signatureView.set(signature);
      await this.channel.write(AdbProtocol.generateAuth(AdbProtocol.AUTH_TYPE_SIGNATURE, signatureBuffer));

      message = await AdbMessage.parseAdbMessage(this.channel);

      if (message.command === AdbProtocol.CMD_AUTH) {
        // 需要发送公钥
        
        // 重要：不能直接使用 Uint8Array.buffer，因为它可能指向一个更大的底层buffer
        // 必须创建一个新的正确大小的ArrayBuffer
        const pubKeyBuffer = new ArrayBuffer(keyPair.publicKeyBytes.length);
        const pubKeyView = new Uint8Array(pubKeyBuffer);
        pubKeyView.set(keyPair.publicKeyBytes);
        
        LoggerAdb.debug('ADB: Sending public key, size:', pubKeyBuffer.byteLength);

        const context = uiContext.getHostContext() as common.UIAbilityContext;
        uiContext.getPromptAction().showDialog({
          title: context.resourceManager.getStringSync($r('app.string.adb_auth_title').id),
          message: context.resourceManager.getStringSync($r('app.string.adb_auth_message').id),
          buttons: [{ text: context.resourceManager.getStringSync($r('app.string.adb_auth_button').id), color: '#007AFF' }]
        }).catch((error: Error) => {
          LoggerAdb.error('Show auth dialog failed:', error);
        });
        await this.channel.write(AdbProtocol.generateAuth(AdbProtocol.AUTH_TYPE_RSA_PUBLIC, pubKeyBuffer));
        message = await AdbMessage.parseAdbMessage(this.channel);
      }
    }

    if (message.command !== AdbProtocol.CMD_CNXN) {
      this.channel.close();
      throw new Error('ADB连接失败');
    }

    this.maxData = message.arg0;
    LoggerAdb.info('ADB: 连接成功, maxData:', this.maxData);

    // 启动后台消息处理
    this.startHandleIn();
  }

  private startHandleIn(): void {
    this.handleInRunning = true;
    this.handleIn();
  }

  private async handleIn(): Promise<void> {
    try {
      let wrteCount = 0;
      while (this.handleInRunning && !this.isClosed) {
        const message = await AdbMessage.parseAdbMessage(this.channel);
        
        // 检查是否已关闭，如果是则立即退出
        if (this.isClosed || !this.handleInRunning) {
          LoggerAdb.info('[ADB] handleIn: Connection closed, exiting loop');
          break;
        }
        
        let bufferStream: BufferStream | undefined = this.connectionStreams.get(message.arg1);
        let isNeedNotify = bufferStream === undefined;

        // 新连接
        if (isNeedNotify) {
          LoggerAdb.debug(`[ADB] New connection: localId=${message.arg1}, remoteId=${message.arg0}`);
          bufferStream = this.createNewStream(message.arg1, message.arg0, message.arg1 > 0);
        }

        if (!bufferStream) {
          continue;
        }

        switch (message.command) {
          case AdbProtocol.CMD_OKAY:
            await bufferStream.setCanWrite(true);
            break;
          case AdbProtocol.CMD_WRTE:
            // 如果已关闭，不处理新数据
            if (this.isClosed) break;
            
            bufferStream.pushSource(message.payload!);
            wrteCount++;
            await this.writeToChannel(AdbProtocol.generateOkay(message.arg1, message.arg0));
            break;
          case AdbProtocol.CMD_CLSE:
            LoggerAdb.info(`[ADB] Connection closed: localId=${message.arg1}`);
            bufferStream.close();
            isNeedNotify = true;
            break;
        }

        if (isNeedNotify) {
          this.notifyAll();
        }
      }
      LoggerAdb.info('[ADB] handleIn loop exited normally');
    } catch (err) {
      if (!this.isClosed) {
        LoggerAdb.error('ADB handleIn error:', err);
      } else {
        LoggerAdb.info('[ADB] handleIn exited due to close');
      }
      this.close();
    }
  }

  private async open(destination: string, canMultipleSend: boolean): Promise<BufferStream> {
    const localId = this.localIdPool++ * (canMultipleSend ? 1 : -1);
    await this.writeToChannel(AdbProtocol.generateOpen(localId, destination));

    let bufferStream: BufferStream | undefined;
    do {
      await this.wait();
      bufferStream = this.openStreams.get(localId);
    } while (!this.isClosed && bufferStream === undefined);

    this.openStreams.delete(localId);

    if (!bufferStream) {
      throw new Error('Failed to open stream');
    }

    return bufferStream;
  }

  // 切换到TCP模式
  async restartOnTcpip(port: number): Promise<string> {
    const bufferStream = await this.open(`tcpip:${port}`, false);
    do {
      await this.wait();
    } while (!bufferStream.isStreamClosed());
    const result = bufferStream.readByteArrayBeforeClose();
    const textDecoder = new util.TextDecoder('utf-8');
    return textDecoder.decodeToString(new Uint8Array(result));
  }

  // 推送文件
  async pushFile(fileData: ArrayBuffer, remotePath: string, handleProcess?: ProcessCallback): Promise<void> {
    // 打开sync连接 - sync协议不会每个DATA包都回复OKAY，所以必须用canMultipleSend=true
    const bufferStream = await this.open('sync:', true);

    // 发送信令，建立push通道
    const sendString = `${remotePath},33206`;
    const bufferHelper = buffer.from(sendString, 'utf-8');

    await bufferStream.write(AdbProtocol.generateSyncHeader('SEND', sendString.length));
    await bufferStream.write(bufferHelper.buffer);

    // 发送文件
    const chunkSize = 10240 - 8;
    const fileArray = new Uint8Array(fileData);
    let hasSendLen = 0;
    const allNeedSendLen = fileArray.length;
    let lastProcess = 0;

    let offset = 0;
    while (offset < fileArray.length) {
      const len = Math.min(chunkSize, fileArray.length - offset);
      const chunk = fileArray.slice(offset, offset + len);

      await bufferStream.write(AdbProtocol.generateSyncHeader('DATA', len));
      await bufferStream.write(chunk.buffer as ArrayBuffer);

      hasSendLen += len;
      const newProcess = Math.floor((hasSendLen / allNeedSendLen) * 100);
      if (newProcess !== lastProcess) {
        lastProcess = newProcess;
        if (handleProcess) {
          handleProcess(lastProcess);
        }
      }

      offset += len;
    }

    // 传输完成，文件日期设为2024.1.1 0:0
    await bufferStream.write(AdbProtocol.generateSyncHeader('DONE', 1704038400));
    await bufferStream.write(AdbProtocol.generateSyncHeader('QUIT', 0));
    do {
      await this.wait();
    } while (!bufferStream.isStreamClosed());
  }

  // 执行ADB命令
  async runAdbCmd(cmd: string): Promise<string> {
    const bufferStream = await this.open(`shell:${cmd}`, true);
    do {
      await this.wait();
    } while (!bufferStream.isStreamClosed());
    const result = bufferStream.readByteArrayBeforeClose();
    const textDecoder = new util.TextDecoder('utf-8');
    return textDecoder.decodeToString(new Uint8Array(result));
  }

  // 获取Shell流
  async getShell(): Promise<BufferStream> {
    return await this.open('shell:', true);
  }

  // TCP端口转发
  async tcpForward(port: number): Promise<BufferStream> {
    const bufferStream = await this.open(`tcp:${port}`, true);
    if (bufferStream.isStreamClosed()) {
      throw new Error('error forward');
    }
    return bufferStream;
  }

  // 本地Socket转发
  async localSocketForward(socketName: string): Promise<BufferStream> {
    const bufferStream = await this.open(`localabstract:${socketName}`, true);
    if (bufferStream.isStreamClosed()) {
      throw new Error('error forward');
    }
    return bufferStream;
  }

  async writeToChannel(data: ArrayBuffer): Promise<void> {
    try {
      await this.channel.write(data);
    } catch (err) {
      LoggerAdb.error('ADB writeToChannel error:', err);
      this.close();
    }
  }

  private createNewStream(localId: number, remoteId: number, canMultipleSend: boolean): BufferStream {
    const underlySocketFunction = new UnderlySocketFunctionImpl(this, localId, remoteId);
    return new BufferStream(false, canMultipleSend, underlySocketFunction);
  }

  private async wait(): Promise<void> {
    return new Promise<void>((resolve) => {
      this.waitResolvers.push(resolve);
    });
  }

  private notifyAll(): void {
    const resolvers = this.waitResolvers;
    this.waitResolvers = [];
    for (const resolver of resolvers) {
      resolver();
    }
  }

  isAdbClosed(): boolean {
    return this.isClosed;
  }

  close(): void {
    if (this.isClosed) return;
    this.isClosed = true;
    this.handleInRunning = false;

    // 关闭所有流
    for (const bufferStream of this.connectionStreams.values()) {
      bufferStream.close();
    }

    this.channel.close();
    this.notifyAll();
  }

  // 获取最大数据大小
  getMaxData(): number {
    return this.maxData;
  }
}