import scrcpy_native from 'libscrcpy_native.so';
import { Logger } from '../../helper/Logger';

const LoggerVideoDecoder = new Logger('VideoDecoder');

// 视频解码器 - 使用Native C++ VideoDecoder（EasyControl风格）
export class VideoDecoder {
  // 静态实例追踪 - 确保只有一个解码器实例
  private static currentInstance: VideoDecoder | null = null;

  private decoderId: number = 0;
  private codecType: string = 'h264';
  private isStarted: boolean = false;
  private frameCount: number = 0;

  // Flags
  static readonly AVCODEC_BUFFER_FLAGS_CODEC_DATA: number = 8;

  async init(codecType: string, surfaceId: string, width: number, height: number): Promise<void> {
    this.codecType = codecType;

    try {
      // 释放之前的解码器实例（防止资源泄漏）
      if (VideoDecoder.currentInstance && VideoDecoder.currentInstance !== this) {
        LoggerVideoDecoder.info('Releasing previous decoder instance...');
        await VideoDecoder.currentInstance.release();
      }
      VideoDecoder.currentInstance = this;

      LoggerVideoDecoder.info('Initializing Native decoder...');
      LoggerVideoDecoder.info('Codec: ' + this.codecType.toUpperCase());
      LoggerVideoDecoder.info('Resolution: ' + width + 'x' + height);

      // 创建Native解码器
      this.decoderId = scrcpy_native.createVideoDecoder();
      LoggerVideoDecoder.info('Native decoder created, ID: ' + this.decoderId);

      // 初始化解码器
      const ret: number = scrcpy_native.initVideoDecoder(this.decoderId, this.codecType, surfaceId, width, height);
      if (ret !== 0) {
        throw new Error(`Native decoder init failed: ${ret}`);
      }
      LoggerVideoDecoder.info('Native decoder initialized');

      // 启动解码器
      const startRet: number = scrcpy_native.startVideoDecoder(this.decoderId);
      if (startRet !== 0) {
        throw new Error(`Native decoder start failed: ${startRet}`);
      }

      this.isStarted = true;
      LoggerVideoDecoder.info('Native decoder started!');

    } catch (err) {
      const error = err as Error;
      LoggerVideoDecoder.error('Init failed: ' + error.message);
      throw new Error(`VideoDecoder init failed: ${error.message}`);
    }
  }

  /**
   * 直接推送视频帧数据（EasyControl 风格）
   * 直接调用 native PushData，无中间层
   */
  pushFrame(data: ArrayBuffer, pts: number, flags: number = 0): number {
    if (!this.isStarted || this.decoderId === 0) {
      return -1;
    }

    const result: number = scrcpy_native.pushVideoData(this.decoderId, data, pts, flags);
    if (result === 0) {
      this.frameCount++;
    }
    return result;
  }

  async flush(): Promise<void> {
    if (this.isStarted) {
      LoggerVideoDecoder.info('Flushing decoder...');
      this.frameCount = 0;
    }
  }

  async release(): Promise<void> {
    if (this.decoderId !== 0) {
      try {
        this.isStarted = false;
        scrcpy_native.releaseVideoDecoder(this.decoderId);
        this.decoderId = 0;
        LoggerVideoDecoder.info('Released | Total frames: ' + this.frameCount);
      } catch (err) {
        LoggerVideoDecoder.error('Release failed:', err);
      }
    }
  }


}
