// ClientStream - 客户端流管理
import { Device } from '../../entity/Device';
import { Adb } from '../../adb/Adb';
import { BufferStream } from '../../buffer/BufferStream';
import { AdbKeyManager } from '../../helper/AdbKeyManager';
import { ServerManager, ServerStartResult } from '../../helper/ServerManager';
import { LoggerClientStream } from '../../helper/Logger';
import { buffer, util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

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
  // Correctly mapped streams
  private vidStream?: BufferStream; // 1st connection: Video
  private audStream?: BufferStream; // 2nd connection: Audio
  private msgStream?: BufferStream; // 3rd connection: Control

  private shellStream?: BufferStream;
  private currentScid: string = '';
  private isConnected: boolean = false;
  private isClosing: boolean = false;
  private device: Device;
  private adb?: Adb;
  // Handshake data
  private deviceName: string = '';
  private videoConfig?: VideoConfig;
  private audioConfig?: AudioConfig;

  constructor(device: Device) {
    this.device = device;
  }

  async connect(context: common.UIAbilityContext, uiContext: UIContext, onAuth?: () => void): Promise<boolean> {
    try {
      this.isClosing = false;
      LoggerClientStream.info('Starting device connection...');

      // 0. Initialize ADB key manager with device address
      const keyManager = AdbKeyManager.getInstance();
      await keyManager.init(context);
      LoggerClientStream.info('ADB key manager initialized');

      // 1. 通过ADB连接设备
      LoggerClientStream.info(`Connecting to ADB at ${this.device.address}:${this.device.adbPort}`);

      const keyPair = keyManager.getAdbKeyPair();
      if (!keyPair) {
        throw new Error('Failed to get ADB key pair');
      }
      const adb = await Adb.connectTcp(this.device.address, this.device.adbPort, keyPair, uiContext, onAuth);
      LoggerClientStream.info('ADB connected successfully');

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
      LoggerClientStream.info(`Starting scrcpy server v${ServerManager.getVersion()}...`);

      const serverResult: ServerStartResult = await ServerManager.startServer(adb, this.device);
      this.shellStream = serverResult.shellStream;
      this.currentScid = serverResult.scid;
      this.adb = adb;

      // 构建socket名称
      const socketName = `scrcpy_${this.currentScid}`;
      LoggerClientStream.info(`Server started with SCID: ${this.currentScid}, socket name: ${socketName}`);

      // 4. 等待服务器启动并连接
      LoggerClientStream.info('Waiting for server to start...');
      await new Promise<void>(resolve => setTimeout(resolve, 50));

      // 重试连接服务器（参考easycontrol原版）
      const reTry = 40;
      const reTryTime = 15000 / reTry;

      for (let i = 0; i < reTry; i++) {
        if (this.isClosing) {
          LoggerClientStream.info('Connection cancelled during retry loop');
          return false;
        }

        try {
          // Sequential Connection & Handshake logic matching official client
          // Server sends dummy byte ONLY on the FIRST accepted socket (DesktopConnection.java:68-88)
          // So we only read from Video stream, not Audio or Control.

          // 1. Connect Video -> Read Dummy (FIRST socket, gets dummy byte)
          LoggerClientStream.info('Connecting Video Stream...');
          this.vidStream = await adb.localSocketForward(socketName);
          LoggerClientStream.debug('Reading video dummy byte...');
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
              LoggerClientStream.warn('Failed to check Android version, assuming audio supported:', e);
            }
          }

          // 2. Connect Audio
          if (this.device.isAudio) {
            LoggerClientStream.info('Connecting Audio Stream...');
            this.audStream = await adb.localSocketForward(socketName);
            // No dummy byte read - server only sends on first socket
          }

          // 3. Connect Control
          LoggerClientStream.info('Connecting Control Stream...');
          this.msgStream = await adb.localSocketForward(socketName);
          // No dummy byte read - server only sends on first socket

          break;
        } catch (err) {
          const errMsg = err instanceof Error ? err.message : String(err);

          if (errMsg === 'error forward') {
            // "error forward" usually means the server socket is not ready yet (Connection Refused)
            // This is normal during the startup phase.
            LoggerClientStream.info(`Server socket not ready (attempt ${i + 1}/${reTry}), waiting...`);
          } else {
            LoggerClientStream.warn(`Server connection attempt ${i + 1}/${reTry} failed:`, errMsg);

            // If server crashed (EOF or closed), we might see it in shellStream
            // Only read output for unexpected errors
            if (this.shellStream && !this.shellStream.isStreamClosed() && !this.shellStream.isEmpty()) {
              try {
                const data = await this.shellStream.readAllBytes();
                if (data.byteLength > 0) {
                  const text = buffer.from(data).toString('utf-8');
                  LoggerClientStream.error('Server output during connection failure:', text);
                }
              } catch (e) {
                // ignore
              }
            }
          }

          this.vidStream = undefined;
          this.audStream = undefined;
          this.msgStream = undefined;
          if (i < reTry - 1) {
            await new Promise<void>(resolve => setTimeout(resolve, reTryTime));
          }
        }
      }

      if (!this.vidStream || (this.device.isAudio && !this.audStream) || !this.msgStream) {
        // Try one last read of server output
        if (this.shellStream) {
          try {
            const data = await this.shellStream.readAllBytes();
            if (data.byteLength > 0) {
              LoggerClientStream.error('Final server output:',
                buffer.from(data).toString('utf-8'));
            }
          } catch (e) {
          }
        }
        throw new Error('Failed to connect to server streams after all retries');
      }

      // 5. Perform Handshake (Rest)
      LoggerClientStream.info('Performing handshake (Device Name, Codec)...');
      await this.performHandshakeRest();

      // 连接成功后才开始读取shell输出
      // this.readShellOutputAsync(); // Move this to be safer or ensure it doesn't race
      this.readShellOutputAsync();

      this.isConnected = true;
      LoggerClientStream.info('Connection established successfully');
      return true;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.error('ClientStream connect failed:', errMsg);

      // 短暂延迟再检查isClosing，避免取消连接时的竞态条件
      await new Promise<void>(resolve => setTimeout(resolve, 200));

      if (errMsg.includes('Read timeout') && !this.isClosing) {
        try {
          await uiContext.getPromptAction().showDialog({
            title: context.resourceManager.getStringSync($r('app.string.timeout_dialog_title').id),
            message: context.resourceManager.getStringSync($r('app.string.timeout_dialog_message').id),
            buttons: [{
              text: context.resourceManager.getStringSync($r('app.string.timeout_dialog_button').id),
              color: '#007AFF'
            }]
          });
        } catch (e) {
          LoggerClientStream.error('Show timeout dialog failed:', e);
        }
      }
      return false;
    }
  }

  private readShellOutputAsync(): void {
    if (!this.shellStream) {
      return;
    }

    const stream = this.shellStream;

    // 异步读取shell输出
    const readLoop = async () => {
      try {
        let count = 0;
        while (!stream.isStreamClosed() && count < 100) { // 限制最多读100次
          if (this.isClosing) {
            break;
          }

          try {
            if (!stream.isEmpty()) {
              const data = await stream.readAllBytes();
              if (data.byteLength > 0) {
                const text = buffer.from(data).toString('utf-8');
                LoggerClientStream.debug('=== Server shell output ===');
                LoggerClientStream.debug(text);
                LoggerClientStream.debug('===========================');
                count++;
              }
            } else {
              // 空数据，等待一下再继续
              await this.delay(200);
            }
          } catch (readErr) {
            const errMsg = readErr instanceof Error ? readErr.message : String(readErr);
            if (!errMsg.includes('timeout')) {
              LoggerClientStream.error('Shell read error:', errMsg);
              break;
            }
            // 超时是正常的，继续
            await this.delay(100);
          }
        }
        LoggerClientStream.info('Shell output reading finished');
      } catch (err) {
        LoggerClientStream.error('Shell read loop error:', err);
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
    LoggerClientStream.debug('Reading device name...');
    const deviceNameData = await this.vidStream.readByteArray(64);
    const decoder = util.TextDecoder.create('utf-8');
    this.deviceName = decoder.decodeToString(new Uint8Array(deviceNameData)).replace(/\0/g, '');
    LoggerClientStream.info(`Device Name: ${this.deviceName}`);

    // 3. Read Codec Metadata (12 bytes) from Video Stream
    LoggerClientStream.debug('Reading codec metadata...');
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
    LoggerClientStream.info(`Video Config: Codec=${codecId}, Size=${width}x${height}`);
  }

  getVideoConfig(): VideoConfig | undefined {
    return this.videoConfig;
  }

  // Audio codec ID constants (4-byte ASCII representation in big-endian)
  private static readonly AUDIO_CODEC_OPUS: number = 0x6F707573; // "opus"
  private static readonly AUDIO_CODEC_AAC: number = 0x00616163; // "aac\0"
  private static readonly AUDIO_CODEC_FLAC: number = 0x666C6163; // "flac"
  private static readonly AUDIO_CODEC_RAW: number = 0x00726177; // "raw\0"

  // Get the actual audio codec configuration
  getAudioConfig(): AudioConfig | undefined {
    return this.audioConfig;
  }

  // Convert codec ID to codec name
  private codecIdToName(codecId: number): string {
    switch (codecId) {
      case ClientStream.AUDIO_CODEC_OPUS:
        return 'opus';
      case ClientStream.AUDIO_CODEC_AAC:
        return 'aac';
      case ClientStream.AUDIO_CODEC_FLAC:
        return 'flac';
      case ClientStream.AUDIO_CODEC_RAW:
        return 'raw';
      default:
        LoggerClientStream.warn(`[ClientStream] Unknown audio codec ID: 0x${codecId.toString(16)}, fallback to opus`);
        return 'opus';
    }
  }

  // Read audio codec header from server (4 bytes)
  // This must be called after connecting to audio stream
  async readAudioCodecHeader(): Promise<boolean> {
    if (!this.audStream) {
      LoggerClientStream.error('[ClientStream] Audio stream not connected');
      return false;
    }

    try {
      // Read 4-byte codec ID
      const codecBytes = await this.readBytesFromAudio(4);
      const view = new DataView(codecBytes);
      const codecId = view.getInt32(0, false); // big-endian

      // Check for audio disabled (codecId == 0) or error (codecId == 1)
      if (codecId === 0) {
        LoggerClientStream.info('[ClientStream] Audio stream disabled by server');
        this.audioConfig = { codecId: 0, codecName: 'disabled' };
        return true;
      }

      if (codecId === 1) {
        LoggerClientStream.error('[ClientStream] Audio stream configuration error');
        return false;
      }

      const codecName = this.codecIdToName(codecId);
      this.audioConfig = { codecId, codecName };

      LoggerClientStream.info(`[ClientStream] Audio codec: ${codecName} (0x${codecId.toString(16).toUpperCase()})`);
      return true;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.error('[ClientStream] Failed to read audio codec header:', errMsg);
      return false;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  async writeMain(data: ArrayBuffer): Promise<void> {
    if (!this.msgStream) {
      throw new Error('Control stream not connected');
    }
    try {
      await this.msgStream.write(data);
    } catch (err) {
      LoggerClientStream.error('Write to control stream failed:', err);
      const error = err instanceof Error ? err : new Error(String(err));
      throw error;
    }
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
  async readFrameFromVideo(): Promise<VideoFrame> {
    if (this.isClosing) {
      throw new Error('Client is closing');
    }

    // console.debug('[ClientStream] Reading frame header...');

    // 1. Read PTS (8 bytes)
    const ptsBytes = await this.readBytesFromVideo(8);
    const view = new DataView(ptsBytes);
    const pts = view.getBigInt64(0, false);

    // Check Config Packet flag (bit 63)
    const PACKET_FLAG_CONFIG = 1n << 63n;
    const isConfig = (pts & PACKET_FLAG_CONFIG) !== 0n;

    // Clean PTS (remove flag)
    const cleanPts = pts & ~PACKET_FLAG_CONFIG;

    let flags = 0;
    if (isConfig) {
      LoggerClientStream.info('[ClientStream] Received Configuration Packet (SPS/PPS)');
      flags = 8; // AVCODEC_BUFFER_FLAGS_CODEC_DATA
    }

    // DEBUG: Log raw PTS for diagnosis
    // 调试日志：诊断第一帧 PTS 问题
    LoggerClientStream.debug(`[ClientStream] Raw PTS: 0x${pts.toString(16)}, cleanPTS: ${Number(cleanPts)}`);

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

    // Convert BigInt PTS to number
    // Note: cleanPts can be > 2^53 when bit 63 was set (config frames), causing Number() overflow
    // If Number() overflows, the result is negative, so we need to recover the unsigned value
    const UINT64_MAX_PLUS_1 = 18446744073709551616n;
    let ptsNumber = Number(cleanPts);
    if (ptsNumber < 0) {
      // Recover the unsigned 64-bit value: unsigned = 2^64 + signed
      ptsNumber = Number(UINT64_MAX_PLUS_1 + cleanPts);
    }

    const frame: VideoFrame = { data: frameData, pts: ptsNumber, flags: flags };
    return frame;
  }

  // 从audio stream读取指定长度的字节
  async readBytesFromAudio(length: number): Promise<ArrayBuffer> {
    if (!this.audStream) {
      throw new Error('Audio stream not connected');
    }
    return await this.audStream.readByteArray(length);
  }

  // 读取一帧音频数据
  // Scrcpy V2 audio format: [8 bytes PTS] [4 bytes size] [N bytes audio data]
  // Reference: scrcpy/app/src/demuxer.c sc_demuxer_recv_packet()
  async readFrameFromAudio(): Promise<AudioFrame> {
    if (this.isClosing) {
      throw new Error('Client is closing');
    }

    // Constants for packet flags (same as video)
    const PACKET_FLAG_CONFIG = 1n << 63n;
    const PACKET_FLAG_KEY_FRAME = 1n << 62n;
    const PTS_MASK = PACKET_FLAG_KEY_FRAME - 1n;

    // 1. Read PTS (8 bytes, big-endian)
    const ptsBytes = await this.readBytesFromAudio(8);
    const ptsView = new DataView(ptsBytes);
    const ptsRaw = ptsView.getBigInt64(0, false);

    // Check if this is a config packet (for opus/flac, the config data comes as a packet with special PTS)
    const isConfig = (ptsRaw & PACKET_FLAG_CONFIG) !== 0n;
    const cleanPts = Number(ptsRaw & PTS_MASK); // Convert to microseconds

    // 2. Read Size (4 bytes, big-endian)
    const sizeBytes = await this.readBytesFromAudio(4);
    const sizeView = new DataView(sizeBytes);
    const frameSize = sizeView.getInt32(0, false);

    if (frameSize <= 0 || frameSize > 1024 * 1024) { // 1MB limit
      throw new Error(`Invalid audio frame size: ${frameSize}`);
    }

    // 3. Read Audio Data
    const frameData = await this.readBytesFromAudio(frameSize);

    // Log config packet reception
    if (isConfig) {
      LoggerClientStream.info(`[ClientStream] Audio config packet received: ${frameSize} bytes`);
    }

    const frame: AudioFrame = { data: frameData, pts: cleanPts };
    return frame;
  }


  async close(): Promise<void> {
    this.isClosing = true;

    // 关闭ADB转发streams
    if (this.vidStream) {
      try {
        this.vidStream.close();
      } catch (err) {
        LoggerClientStream.error('Close video stream failed:', err);
      }
      this.vidStream = undefined;
    }
    if (this.audStream) {
      try {
        this.audStream.close();
      } catch (err) {
        LoggerClientStream.error('Close audio stream failed:', err);
      }
      this.audStream = undefined;
    }
    if (this.msgStream) {
      try {
        this.msgStream.close();
      } catch (err) {
        LoggerClientStream.error('Close msg stream failed:', err);
      }
      this.msgStream = undefined;
    }
    if (this.shellStream) {
      try {
        this.shellStream.close();
      } catch (err) {
        LoggerClientStream.error('Close shell stream failed:', err);
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
