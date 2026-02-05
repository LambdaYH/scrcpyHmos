import scrcpy_native from 'libscrcpy_native.so';

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
        console.info('[AudioDecoder] Releasing previous decoder instance...');
        await AudioDecoder.currentInstance.release();
      }
      AudioDecoder.currentInstance = this;

      console.info(`[AudioDecoder] Initializing Native decoder...`);
      console.info(`[AudioDecoder] Codec: ${codecType.toUpperCase()}`);
      console.info(`[AudioDecoder] Sample Rate: ${sampleRate}Hz`);
      console.info(`[AudioDecoder] Channels: ${channelCount}`);

      // 创建Native解码器
      this.decoderId = scrcpy_native.createAudioDecoder();
      console.info(`[AudioDecoder] Native decoder created, ID: ${this.decoderId}`);

      // 初始化解码器
      const ret: number = scrcpy_native.initAudioDecoder(this.decoderId, codecType, sampleRate, channelCount);
      if (ret !== 0) {
        throw new Error(`Native audio decoder init failed: ${ret}`);
      }
      console.info(`[AudioDecoder] Native decoder initialized`);

      // 启动解码器
      const startRet: number = scrcpy_native.startAudioDecoder(this.decoderId);
      if (startRet !== 0) {
        throw new Error(`Native audio decoder start failed: ${startRet}`);
      }

      this.isStarted = true;
      console.info(`[AudioDecoder] Native audio decoder started!`);

    } catch (err) {
      const error = err as Error;
      console.error(`[AudioDecoder] Init failed: ${error.message}`);
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

  /**
   * 旧方法名（兼容）
   */
  pushDataToStream(data: ArrayBuffer, pts: number): number {
    return this.pushFrame(data, pts);
  }

  async release(): Promise<void> {
    if (this.decoderId !== 0) {
      try {
        this.isStarted = false;
        scrcpy_native.releaseAudioDecoder(this.decoderId);
        this.decoderId = 0;
        console.info('[AudioDecoder] Released');
      } catch (err) {
        console.error('[AudioDecoder] Release failed:', err);
      }
    }
  }

  // ============== Stream Mode APIs（保留兼容，但已废弃）==============

  private streamProcessorId: number = 0;

  /**
   * @deprecated 不再需要，使用 direct pushFrame()
   */
  async createStreamProcessor(codecType: string, sampleRate: number, channelCount: number): Promise<number> {
    console.warn('[AudioDecoder] Stream processor is deprecated, use direct pushFrame()');
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
