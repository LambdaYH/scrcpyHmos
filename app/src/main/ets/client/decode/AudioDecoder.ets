import scrcpy_native from 'libscrcpy_native.so';
import { Logger } from '../../helper/Logger';

const LoggerAudioDecoder = new Logger('AudioDecoder');

// 音频解码器 - 使用Native C++ AudioDecoder（EasyControl 风格）
export class AudioDecoder {
  // 静态实例追踪 - 确保只有一个解码器实例
  private static currentInstance: AudioDecoder | null = null;

  private decoderId: number = 0;
  private isStarted: boolean = false;

  async init(codecType: string, sampleRate: number = 48000, channelCount: number = 2): Promise<void> {

    try {
      // 释放之前的解码器实例（防止资源泄漏）
      if (AudioDecoder.currentInstance && AudioDecoder.currentInstance !== this) {
        LoggerAudioDecoder.info('Releasing previous decoder instance...');
        await AudioDecoder.currentInstance.release();
      }
      AudioDecoder.currentInstance = this;

      LoggerAudioDecoder.info('Initializing Native decoder...');
      LoggerAudioDecoder.info('Codec: ' + codecType.toUpperCase());
      LoggerAudioDecoder.info('Sample Rate: ' + sampleRate + 'Hz');
      LoggerAudioDecoder.info('Channels: ' + channelCount);

      // 创建Native解码器
      this.decoderId = scrcpy_native.createAudioDecoder();
      LoggerAudioDecoder.info('Native decoder created, ID: ' + this.decoderId);

      // 初始化解码器
      const ret: number = scrcpy_native.initAudioDecoder(this.decoderId, codecType, sampleRate, channelCount);
      if (ret !== 0) {
        throw new Error(`Native audio decoder init failed: ${ret}`);
      }
      LoggerAudioDecoder.info('Native decoder initialized');

      // 启动解码器
      const startRet: number = scrcpy_native.startAudioDecoder(this.decoderId);
      if (startRet !== 0) {
        throw new Error(`Native audio decoder start failed: ${startRet}`);
      }

      this.isStarted = true;
      LoggerAudioDecoder.info('Native audio decoder started!');

    } catch (err) {
      const error = err as Error;
      LoggerAudioDecoder.error('Init failed: ' + error.message);
      throw new Error(`AudioDecoder init failed: ${error.message}`);
    }
  }

  /**
   * 直接推送音频帧（EasyControl 风格）
   * 直接调用 native PushData，无中间层
   */
  pushFrame(data: ArrayBuffer, pts: number): number {
    if (!this.isStarted || this.decoderId === 0) {
      return -1;
    }
    return scrcpy_native.pushAudioData(this.decoderId, data, pts);
  }

  async release(): Promise<void> {
    if (this.decoderId !== 0) {
      try {
        this.isStarted = false;
        scrcpy_native.releaseAudioDecoder(this.decoderId);
        this.decoderId = 0;
        LoggerAudioDecoder.info('Released');
      } catch (err) {
        LoggerAudioDecoder.error('Release failed:', err);
      }
    }
  }


}
