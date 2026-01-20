import scrcpy_native from 'libscrcpy_native.so';

// 音频解码器 - 使用Native C++ AudioDecoder
export class AudioDecoder {
  // 静态实例追踪 - 确保只有一个解码器实例
  private static currentInstance: AudioDecoder | null = null;

  private decoderId: number = 0;
  private codecType: string = 'opus';
  private sampleRate: number = 48000;
  private channelCount: number = 2;
  private isStarted: boolean = false;
  private frameCount: number = 0;

  async init(codecType: string, sampleRate: number = 48000, channelCount: number = 2): Promise<void> {
    this.codecType = codecType;
    this.sampleRate = sampleRate;
    this.channelCount = channelCount;

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
        const error = new Error(`Native audio decoder init failed: ${ret}`);
        throw error;
      }
      console.info(`[AudioDecoder] Native decoder initialized`);

      // 启动解码器
      const startRet: number = scrcpy_native.startAudioDecoder(this.decoderId);
      if (startRet !== 0) {
        const error = new Error(`Native audio decoder start failed: ${startRet}`);
        throw error;
      }

      this.isStarted = true;
      console.info(`[AudioDecoder] ✅ Native audio decoder started successfully!`);

    } catch (err) {
      const error = err as Error;
      console.error(`[AudioDecoder] Init failed: ${error.message}`);
      const newError = new Error(`AudioDecoder init failed: ${error.message}`);
      throw newError;
    }
  }

  async decode(data: ArrayBuffer, pts: number): Promise<void> {
    if (!this.isStarted || this.decoderId === 0) {
      console.warn('[AudioDecoder] Not ready, frame dropped');
      return;
    }

    try {
      // 推送数据到Native解码器，带重试机制
      const maxRetries = 5;
      let retryCount = 0;
      let result: number = -2;

      while (retryCount < maxRetries) {
        result = scrcpy_native.pushAudioData(this.decoderId, data, pts);

        if (result === 0) {
          // 成功
          break;
        } else if (result === -2) {
          // 没有可用输入缓冲区，等待后重试
          retryCount++;
          if (retryCount < maxRetries) {
            await new Promise<void>((resolve: () => void) => setTimeout(resolve, 5));
          }
        } else {
          // 其他错误，不重试
          console.error(`[AudioDecoder] pushData failed with error: ${result}`);
          break;
        }
      }

      if (result === 0) {
        this.frameCount++;
      } else if (result === -2) {
        console.warn(`[AudioDecoder] Frame dropped after ${maxRetries} retries`);
      }
    } catch (err) {
      console.error('[AudioDecoder] Decode error:', err);
    }
  }

  async release(): Promise<void> {
    if (this.decoderId !== 0) {
      try {
        this.isStarted = false;
        scrcpy_native.releaseAudioDecoder(this.decoderId);
        this.decoderId = 0;
        console.info(`[AudioDecoder] Released | Total frames decoded: ${this.frameCount}`);
      } catch (err) {
        console.error('[AudioDecoder] Release failed:', err);
      }
    }
  }

  isReady(): boolean {
    return this.isStarted && this.decoderId !== 0;
  }
}
