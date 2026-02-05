import scrcpy_native from 'libscrcpy_native.so';

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
        console.info('[VideoDecoder] Releasing previous decoder instance...');
        await VideoDecoder.currentInstance.release();
      }
      VideoDecoder.currentInstance = this;

      console.info(`[VideoDecoder] Initializing Native decoder...`);
      console.info(`[VideoDecoder] Codec: ${this.codecType.toUpperCase()}`);
      console.info(`[VideoDecoder] Resolution: ${width}x${height}`);

      // 创建Native解码器
      this.decoderId = scrcpy_native.createVideoDecoder();
      console.info(`[VideoDecoder] Native decoder created, ID: ${this.decoderId}`);

      // 初始化解码器
      const ret: number = scrcpy_native.initVideoDecoder(this.decoderId, this.codecType, surfaceId, width, height);
      if (ret !== 0) {
        throw new Error(`Native decoder init failed: ${ret}`);
      }
      console.info(`[VideoDecoder] Native decoder initialized`);

      // 启动解码器
      const startRet: number = scrcpy_native.startVideoDecoder(this.decoderId);
      if (startRet !== 0) {
        throw new Error(`Native decoder start failed: ${startRet}`);
      }

      this.isStarted = true;
      console.info(`[VideoDecoder] Native decoder started!`);

    } catch (err) {
      const error = err as Error;
      console.error(`[VideoDecoder] Init failed: ${error.message}`);
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

  /**
   * 旧方法名（兼容）
   */
  pushDataToStream(data: ArrayBuffer, pts: number, flags: number = 0): number {
    return this.pushFrame(data, pts, flags);
  }

  async flush(): Promise<void> {
    if (this.isStarted) {
      console.info('[VideoDecoder] Flushing decoder...');
      this.frameCount = 0;
    }
  }

  async release(): Promise<void> {
    if (this.decoderId !== 0) {
      try {
        this.isStarted = false;
        scrcpy_native.releaseVideoDecoder(this.decoderId);
        this.decoderId = 0;
        console.info(`[VideoDecoder] Released | Total frames: ${this.frameCount}`);
      } catch (err) {
        console.error('[VideoDecoder] Release failed:', err);
      }
    }
  }

  // ============== Stream Mode APIs（保留兼容，但已废弃）==============

  private streamProcessorId: number = 0;

  /**
   * @deprecated 不再需要，使用 direct pushFrame()
   */
  async createStreamProcessor(codecType: string): Promise<number> {
    console.warn('[VideoDecoder] Stream processor is deprecated, use direct pushFrame()');
    return 0;
  }

  /**
   * @deprecated 不再需要
   */
  async startStreamProcessor(): Promise<void> {
    // 空实现
  }

  /**
   * @deprecated 不再需要，使用 pushFrame()
   */
  async releaseStreamProcessor(): Promise<void> {
    // 空实现
  }

  /**
   * @deprecated
   */
  getStreamProcessorId(): number {
    return 0;
  }
}
