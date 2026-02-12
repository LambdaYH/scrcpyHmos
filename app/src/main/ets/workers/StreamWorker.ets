// StreamWorker.ets - Worker 线程，负责 ADB 连接、视频流、音频流、控制流处理
import { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { Device } from '../entity/Device';
import { ClientStream, VideoConfig } from '../client/tools/ClientStream';
import { VideoDecoder } from '../client/decode/VideoDecoder';
import { AudioDecoder } from '../client/decode/AudioDecoder';
import { ControlPacket, Action, TouchAction, KeyCode } from '../client/tools/ControlPacket';
import { LoggerClient } from '../helper/Logger';
import { util } from '@kit.ArkTS';
import { AdbKeySerialData } from '../helper/AdbKeyManager';

import {
  WorkerMessageType, WorkerMessage, TouchEventData, KeyEventData,
  InitData, VideoDecoderInitData, AudioDecoderInitData, ClipboardData, ActionData
} from './WorkerMessages';
import { NativeBufferPool } from '../buffer/NativeBufferPool';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

// Worker 状态
class WorkerState {
  private device?: Device;
  private clientStream?: ClientStream;
  private videoDecoder?: VideoDecoder;
  private audioDecoder?: AudioDecoder;
  private isClosed: boolean = false;
  private keepAliveTimer?: number = undefined;
  private videoLoopRunning: boolean = false;
  private audioLoopRunning: boolean = false;
  private videoConfig?: VideoConfig;
  private audioCodec?: string;
  private firstFrameReceived: boolean = false;

  // 触控事件优化
  private isWritingMove: boolean = false;
  private pendingMovePacket: ArrayBuffer | null = null;

  constructor() {
    LoggerClient.info('[StreamWorker] Worker state initialized');
  }

  // 发送消息到主线程
  private postMessage(message: WorkerMessage): void {
    workerPort.postMessage(message);
  }

  // 初始化并连接（使用预加载的序列化数据）
  async init(device: Device, adbKeyData: AdbKeySerialData, serverJarData?: ArrayBuffer): Promise<void> {
    try {
      this.device = device;
      this.isClosed = false;

      LoggerClient.info('[StreamWorker] Starting connection...');
      this.postMessage({ type: WorkerMessageType.STATUS_UPDATE, data: { status: 'connecting' } });

      // 建立流连接（使用 Worker 兼容的连接方法）
      this.clientStream = new ClientStream(this.device);

      const connected = await this.clientStream.connectInWorker(
        adbKeyData,
        serverJarData || null,
        () => {
          // 授权回调 → 通知主线程
          this.postMessage({ type: WorkerMessageType.AUTH_REQUIRED });
        },
        (errMsg: string) => {
          // 错误回调 → 通知主线程（如超时等）
          this.postMessage({
            type: WorkerMessageType.ERROR,
            data: { message: errMsg }
          });
        }
      );

      if (!connected) {
        LoggerClient.error('[StreamWorker] Connection failed');
        if (this.clientStream) {
          await this.clientStream.close();
          this.clientStream = undefined;
        }
        this.postMessage({
          type: WorkerMessageType.ERROR,
          data: { message: 'Connection failed' }
        });
        return;
      }

      this.postMessage({ type: WorkerMessageType.STATUS_UPDATE, data: { status: 'getting_video_config' } });

      // 获取视频配置
      const videoConfig = this.clientStream.getVideoConfig();
      if (videoConfig) {
        this.videoConfig = videoConfig;
        LoggerClient.debug('[StreamWorker] Video config: ' + videoConfig.width + 'x' + videoConfig.height);
        this.postMessage({
          type: WorkerMessageType.VIDEO_CONFIG,
          data: { config: videoConfig }
        });
      } else {
        LoggerClient.warn('[StreamWorker] Video config not available');
      }

      // 启动保活定时器
      this.startKeepAlive();

      // 启动主消息循环
      this.startMainLoop();

      // 执行连接时操作
      try {
        if (this.device.wakeOnConnect) {
          LoggerClient.debug('[StreamWorker] Waking up screen...');
          this.handleAction(Action.BUTTON_WAKE);
        }

        if (this.device.lightOffOnConnect) {
          LoggerClient.info('[StreamWorker] Turning off screen...');
          await new Promise<void>((resolve) => setTimeout(resolve, 2000));
          this.handleAction(Action.BUTTON_LIGHT_OFF);
        }
      } catch (err) {
        LoggerClient.error('[StreamWorker] Failed to handle connect actions:', err);
      }

      LoggerClient.info('[StreamWorker] Connection established');
      this.postMessage({ type: WorkerMessageType.CONNECTED });

    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClient.error('[StreamWorker] Init failed:', errMsg);
      this.postMessage({
        type: WorkerMessageType.ERROR,
        data: { message: errMsg }
      });

      if (this.clientStream) {
        await this.clientStream.close();
        this.clientStream = undefined;
      }
    }
  }

  // 初始化视频解码器
  async initVideoDecoder(surfaceId: string): Promise<void> {
    if (!this.clientStream) {
      throw new Error('ClientStream not initialized');
    }

    try {
      LoggerClient.debug('[StreamWorker] Initializing video decoder...');

      const config = this.clientStream.getVideoConfig();
      if (!config) {
        throw new Error('Video configuration not available');
      }

      // 映射 codecId 到字符串
      let codecType = 'h264';
      if (config.codecId === 1 || config.codecId === 1748121141) codecType = 'h265';
      if (config.codecId === 2 || config.codecId === 1635135537) codecType = 'av1';

      LoggerClient.info('[StreamWorker] Codec: ' + codecType + ', Size: ' + config.width + 'x' + config.height);

      // 初始化解码器
      this.videoDecoder = new VideoDecoder();
      await this.videoDecoder.init(codecType, surfaceId, config.width, config.height);

      LoggerClient.debug('[StreamWorker] Video decoder initialized, starting loop...');

      // 启动视频循环
      this.startVideoLoop();

    } catch (err) {
      const error = err as Error;
      LoggerClient.error('[StreamWorker] initVideoDecoder failed:', error.message);
      throw error;
    }
  }

  // 初始化音频解码器
  async initAudioDecoder(codecType: string = 'opus', sampleRate: number = 48000, channelCount: number = 2): Promise<void> {
    if (!this.clientStream) {
      throw new Error('ClientStream not initialized');
    }

    if (!this.device?.isAudio) {
      LoggerClient.info('[StreamWorker] Audio disabled, skipping');
      return;
    }

    try {
      // 读取音频编码头
      const audioConfig = this.clientStream.getAudioConfig();
      let actualCodec = codecType;

      if (audioConfig) {
        if (audioConfig.codecName === 'disabled') {
          LoggerClient.info('[StreamWorker] Audio disabled by server');
          if (this.device) {
            this.device.isAudio = false;
          }
          return;
        }
        actualCodec = audioConfig.codecName;
        this.audioCodec = actualCodec;
      } else {
        LoggerClient.debug('[StreamWorker] Reading audio codec header...');
        const codecRead = await this.clientStream.readAudioCodecHeader();
        const newConfig = this.clientStream.getAudioConfig();

        if (newConfig) {
          if (newConfig.codecName === 'disabled') {
            LoggerClient.info('[StreamWorker] Audio disabled by server');
            if (this.device) {
              this.device.isAudio = false;
            }
            return;
          }
          actualCodec = newConfig.codecName;
          this.audioCodec = actualCodec;
        } else if (!codecRead) {
          LoggerClient.warn('[StreamWorker] Failed to read audio codec, using device config');
          actualCodec = this.device?.audioCodec || 'opus';
          this.audioCodec = actualCodec;
        }
      }

      LoggerClient.debug('[StreamWorker] Initializing audio decoder: ' + actualCodec);

      this.audioDecoder = new AudioDecoder();
      await this.audioDecoder.init(actualCodec, sampleRate, channelCount);

      LoggerClient.info('[StreamWorker] Audio decoder initialized');

      await this.audioDecoder.createStreamProcessor(actualCodec, sampleRate, channelCount);
      await this.audioDecoder.startStreamProcessor();

      // 启动音频循环
      this.startAudioLoop();

    } catch (err) {
      const error = err as Error;
      LoggerClient.error('[StreamWorker] initAudioDecoder failed:', error.message);
      throw error;
    }
  }

  // 视频循环
  private startVideoLoop(): void {
    if (this.videoLoopRunning) return;
    if (!this.videoDecoder || !this.clientStream) {
      LoggerClient.error('[StreamWorker] Decoder or stream not initialized');
      return;
    }

    this.videoLoopRunning = true;

    const videoThread = async () => {
      let frameCount = 0;

      try {
        while (!this.isClosed && this.videoLoopRunning && this.clientStream) {
          try {
            const frame = await this.clientStream.readFrameFromVideo();
            const decoder = this.videoDecoder;

            if (frame.data.byteLength > 0 && decoder) {
              const pushResult = decoder.pushFrame(frame.data, frame.pts, frame.flags);

              if (pushResult === 0) {
                frameCount++;
                if (frameCount === 1 && !this.firstFrameReceived) {
                  this.firstFrameReceived = true;
                  LoggerClient.info('[StreamWorker] First video frame received');
                  this.postMessage({ type: WorkerMessageType.FIRST_FRAME });
                }
              } else if (pushResult === -2) {
                // Buffer 满，等待重试
                let waitCount = 0;
                const maxWait = 50;
                while (waitCount < maxWait && !this.isClosed && decoder) {
                  await new Promise<void>((resolve) => setTimeout(resolve, 1));
                  const retryResult = decoder.pushFrame(frame.data, frame.pts, frame.flags);
                  if (retryResult === 0) {
                    frameCount++;
                    break;
                  }
                  waitCount++;
                }
              }

              // 显式释放 Native Buffer (即使是 GC 也会释放，但显式释放更快)
              // 注意: pushFrame 时 NAPI 已经 memcpy 数据，所以此时 frame.data 已经不再需要了
              NativeBufferPool.release(frame.data);
            }
          } catch (err) {
            const errMsg = err instanceof Error ? err.message : String(err);
            if (this.isClosed || errMsg.includes('closed')) {
              LoggerClient.debug('[StreamWorker] Video loop terminated');
              break;
            }
            LoggerClient.error('[StreamWorker] Video frame error:', errMsg);
            break;
          }
        }
      } catch (err) {
        LoggerClient.error('[StreamWorker] Video loop error:', err);
      } finally {
        this.videoLoopRunning = false;
        LoggerClient.info('[StreamWorker] Video loop stopped');
      }
    };

    videoThread();
  }

  // 音频循环
  private startAudioLoop(): void {
    if (this.audioLoopRunning) return;
    if (!this.device?.isAudio || !this.clientStream) {
      LoggerClient.debug('[StreamWorker] Audio disabled or not initialized');
      return;
    }

    this.audioLoopRunning = true;

    const pushLoop = async () => {
      try {
        LoggerClient.debug('[StreamWorker] Audio push loop started');
        while (!this.isClosed && this.audioLoopRunning && this.clientStream) {
          try {
            const frame = await this.clientStream.readFrameFromAudio();
            if (frame.data.byteLength > 0 && this.audioDecoder) {
              const pushResult = this.audioDecoder.pushFrame(frame.data, frame.pts);
              if (pushResult < 0) {
                await new Promise<void>((resolve) => setTimeout(resolve, 1));
              }
            }
          } catch (frameErr) {
            const errMsg = frameErr instanceof Error ? frameErr.message : String(frameErr);
            if (this.isClosed || errMsg.includes('closed')) {
              LoggerClient.debug('[StreamWorker] Audio loop terminated');
              break;
            }
            LoggerClient.error('[StreamWorker] Audio frame error:', errMsg);
          }
        }
      } catch (err) {
        LoggerClient.error('[StreamWorker] Audio loop error:', err);
      } finally {
        this.audioLoopRunning = false;
        LoggerClient.debug('[StreamWorker] Audio loop stopped');
      }
    };

    pushLoop();
  }

  // 处理剪贴板文本
  private async handleClipboardText(data: ArrayBuffer): Promise<void> {
    const decoder = util.TextDecoder.create('utf-8');
    const text = decoder.decodeToString(new Uint8Array(data));

    // 发送到主线程处理剪贴板同步
    this.postMessage({
      type: WorkerMessageType.CLIPBOARD_RECEIVED,
      data: { text, autoSync: this.device?.clipboardAutosync }
    });
  }

  // 启动主消息循环
  private startMainLoop(): void {
    const readLoop = async (): Promise<void> => {
      while (!this.isClosed && this.clientStream) {
        try {
          const eventType = await this.clientStream.readByteFromMain();

          if (this.isClosed) break;

          switch (eventType) {
            case 0: // DEVICE_MSG_TYPE_CLIPBOARD
              LoggerClient.debug('[StreamWorker] Received clipboard event');
              const clipLen = await this.clientStream.readIntFromMain();
              if (clipLen > 0 && clipLen <= 100000) {
                const clipTextData = await this.clientStream.readBytesFromMain(clipLen);
                await this.handleClipboardText(clipTextData);
              }
              break;

            case 1: // DEVICE_MSG_TYPE_ACK_CLIPBOARD
              LoggerClient.debug('[StreamWorker] Received ack clipboard event');
              await this.clientStream.readBytesFromMain(8);
              break;

            case 2: // DEVICE_MSG_TYPE_UHID_OUTPUT
              LoggerClient.debug('[StreamWorker] Received UHID output event');
              await this.clientStream.readBytesFromMain(2);
              const sizeData = await this.clientStream.readBytesFromMain(2);
              const view = new DataView(sizeData);
              const size = view.getUint16(0, false);
              if (size > 0) {
                await this.clientStream.readBytesFromMain(size);
              }
              break;

            default:
              LoggerClient.debug('[StreamWorker] Unknown event type: ' + eventType);
              break;
          }
        } catch (err) {
          if (this.isClosed) {
            LoggerClient.debug('[StreamWorker] Main loop exiting (closed)');
            break;
          }

          const errorMsg = err instanceof Error ? err.message : String(err);
          if (!errorMsg.includes('timeout') && !errorMsg.includes('closed')) {
            LoggerClient.error('[StreamWorker] Main loop error:', err);
            await new Promise<void>((resolve) => setTimeout(resolve, 100));
          }
        }
      }
    };

    readLoop().catch((err: Error) => {
      LoggerClient.error('[StreamWorker] Main loop fatal error:', err);
    });
  }

  // 启动保活定时器
  private startKeepAlive(): void {
    this.keepAliveTimer = setInterval(() => {
      if (!this.isClosed && this.clientStream) {
        this.handleAction(Action.KEEP_ALIVE);
      }
    }, 3000) as number;
  }

  // 处理动作
  handleAction(action: string, data?: ArrayBuffer): void {
    if (!this.clientStream || this.isClosed) return;

    try {
      switch (action) {
        case Action.BUTTON_BACK:
          this.writeToMain(ControlPacket.createBackOrScreenOn(0));
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
          this.writeToMain(ControlPacket.createScreenOn());
          break;
        case Action.BUTTON_LIGHT_OFF:
          this.writeToMain(ControlPacket.createScreenOff());
          break;
        case Action.KEEP_ALIVE:
          // Scrcpy 不需要特殊的 keepalive
          break;
        case Action.WRITE_BYTE_BUFFER:
          if (data) {
            this.writeToMain(data);
          }
          break;
        case Action.SET_CLIP_BOARD:
          if (data && data.byteLength > 0) {
            this.writeToMain(data);
          }
          break;
        default:
          LoggerClient.warn('[StreamWorker] Unknown action: ' + action);
          if (data) {
            this.writeToMain(data);
          }
          break;
      }
    } catch (err) {
      LoggerClient.error('[StreamWorker] handleAction error for ' + action + ':', err);
    }
  }

  // 写入数据到主流
  private async writeToMain(data: ArrayBuffer): Promise<void> {
    if (this.clientStream) {
      await this.clientStream.writeMain(data);
    }
  }

  // 发送触摸事件
  async sendTouchEvent(data: TouchEventData): Promise<void> {
    if (!this.clientStream) {
      LoggerClient.warn('[StreamWorker] sendTouchEvent: clientStream is null');
      return;
    }

    const packet = ControlPacket.createInjectTouchEvent(
      data.action,
      BigInt(data.pointerId),
      Math.round(data.x),
      Math.round(data.y),
      data.screenWidth,
      data.screenHeight,
      data.pressure || 1.0
    );

    // 优化 MOVE 事件
    if (data.action === TouchAction.ACTION_MOVE) {
      if (this.isWritingMove) {
        this.pendingMovePacket = packet;
        return;
      }
      this.isWritingMove = true;
    }

    try {
      await this.clientStream.writeMain(packet);
    } finally {
      if (data.action === TouchAction.ACTION_MOVE) {
        this.isWritingMove = false;
        if (this.pendingMovePacket) {
          const nextPacket = this.pendingMovePacket;
          this.pendingMovePacket = null;
          this.sendRawMovePacket(nextPacket);
        }
      }
    }
  }

  // 递归发送移动包
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

  // 发送按键事件
  async sendKeyEvent(data: KeyEventData): Promise<void> {
    if (!this.clientStream) {
      LoggerClient.warn('[StreamWorker] sendKeyEvent: clientStream is null');
      return;
    }

    const packets = ControlPacket.createKeyEventPair(data.keyCode, data.metaState || 0);
    for (const packet of packets) {
      await this.clientStream.writeMain(packet);
    }
  }

  // 发送剪贴板
  async sendClipboard(text: string, paste: boolean = true): Promise<void> {
    if (!this.clientStream || this.isClosed) return;

    const packet = ControlPacket.createSetClipboard(text, 0n, paste);
    await this.writeToMain(packet);
    const displayText = text.length > 50 ? text.substring(0, 50) + '...' : text;
    LoggerClient.info('[StreamWorker] Sent clipboard: ' + displayText);
  }

  // 关闭连接
  async close(): Promise<void> {
    if (this.isClosed) return;

    this.isClosed = true;

    // 停止循环
    this.videoLoopRunning = false;
    this.audioLoopRunning = false;

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

    if (this.audioDecoder) {
      await this.audioDecoder.release();
      this.audioDecoder = undefined;
    }

    if (this.clientStream) {
      await this.clientStream.close();
      this.clientStream = undefined;
    }

    LoggerClient.info('[StreamWorker] Worker closed');
    this.postMessage({ type: WorkerMessageType.DISCONNECTED });
  }

  // 获取视频尺寸
  getVideoSize(): VideoConfig | null {
    return this.videoConfig || null;
  }
}

// Worker 全局状态
const workerState = new WorkerState();

/**
 * Defines the event handler to be called when the worker thread receives a message sent by the host thread.
 */
workerPort.onmessage = (e: MessageEvents) => {
  const message = e.data as WorkerMessage;

  try {
    switch (message.type) {
      case WorkerMessageType.INIT:
        const initData = message.data as InitData;
        workerState.init(initData.device, initData.adbKeyData, initData.serverJarData);
        break;

      case WorkerMessageType.INIT_VIDEO_DECODER:
        const videoData = message.data as VideoDecoderInitData;
        workerState.initVideoDecoder(videoData.surfaceId);
        break;

      case WorkerMessageType.INIT_AUDIO_DECODER:
        const audioData = message.data as AudioDecoderInitData;
        workerState.initAudioDecoder(
          audioData.codecType || 'opus',
          audioData.sampleRate || 48000,
          audioData.channelCount || 2
        );
        break;

      case WorkerMessageType.SEND_TOUCH:
        const touchData = message.data as TouchEventData;
        workerState.sendTouchEvent(touchData);
        break;

      case WorkerMessageType.SEND_KEY:
        const keyData = message.data as KeyEventData;
        workerState.sendKeyEvent(keyData);
        break;

      case WorkerMessageType.SEND_CLIPBOARD:
        const clipData = message.data as ClipboardData;
        workerState.sendClipboard(clipData.text, clipData.paste !== false);
        break;

      case WorkerMessageType.HANDLE_ACTION:
        const actionData = message.data as ActionData;
        workerState.handleAction(actionData.action, actionData.data);
        break;

      case WorkerMessageType.CLOSE:
        workerState.close();
        break;

      default:
        LoggerClient.warn('[StreamWorker] Unknown message type: ' + message.type);
        break;
    }
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    LoggerClient.error('[StreamWorker] Error handling message ' + message.type + ':', errMsg);
    workerPort.postMessage({
      type: WorkerMessageType.ERROR,
      data: { message: errMsg, originalType: message.type }
    } as WorkerMessage);
  }
};

/**
 * Defines the event handler to be called when the worker receives a message that cannot be deserialized.
 */
workerPort.onmessageerror = (e: MessageEvents) => {
  LoggerClient.error('[StreamWorker] Message deserialization failed:', e.data);
};

/**
 * Defines the event handler to be called when an exception occurs during worker execution.
 */
workerPort.onerror = (e: ErrorEvent) => {
  LoggerClient.error('[StreamWorker] Worker error:', e.message);
};
