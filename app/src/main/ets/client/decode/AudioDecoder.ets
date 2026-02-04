import scrcpy_native from 'libscrcpy_native.so';

// 音频解码器 - 使用Native C++ AudioDecoder
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
      console.info(`[AudioDecoder] Native audio decoder started successfully!`);

    } catch (err) {
      const error = err as Error;
      console.error(`[AudioDecoder] Init failed: ${error.message}`);
      const newError = new Error(`AudioDecoder init failed: ${error.message}`);
      throw newError;
    }
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

  // ============== Stream Mode APIs (C++ processing) ==============

  private streamProcessorId: number = 0;

  /**
   * Create and initialize stream processor (C++ mode)
   * Must be called after init() and startAudioDecoder()
   */
  async createStreamProcessor(codecType: string, sampleRate: number, channelCount: number): Promise<number> {
    try {
      console.info(`[AudioDecoder] Creating stream processor...`);

      // Create stream processor linked to this decoder
      this.streamProcessorId = scrcpy_native.createAudioStreamProcessor(
        this.decoderId, codecType, sampleRate, channelCount
      );

      if (this.streamProcessorId <= 0) {
        throw new Error(`Failed to create stream processor: ${this.streamProcessorId}`);
      }

      console.info(`[AudioDecoder] Stream processor created, ID: ${this.streamProcessorId}`);
      return this.streamProcessorId;

    } catch (err) {
      const error = err as Error;
      console.error(`[AudioDecoder] createStreamProcessor failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Start stream processor (C++ processing thread)
   */
  async startStreamProcessor(): Promise<void> {
    if (this.streamProcessorId === 0) {
      console.warn('[AudioDecoder] Stream processor not created');
      return;
    }

    const ret: number = scrcpy_native.startAudioStreamProcessor(this.streamProcessorId);
    if (ret !== 0) {
      throw new Error(`Failed to start stream processor: ${ret}`);
    }

    console.info('[AudioDecoder] Stream processor started');
  }

  /**
   * Push data to stream processor (ArkTS continuously calls this)
   * For audio: prepends 4-byte size header since ArkTS parses the protocol header
   * The C++ processor expects: [4 bytes size][N bytes audio data]
   */
  pushDataToStream(data: ArrayBuffer, pts: number): number {
    if (this.streamProcessorId === 0) {
      return -1;
    }

    // Construct header + data format for C++ processor
    // C++ ParseAudioFrame expects: [4 bytes size][N bytes data]
    const size = data.byteLength;
    const header = new ArrayBuffer(4);
    const headerView = new DataView(header);
    headerView.setInt32(0, size, false);  // Big-endian

    // Combine header + data
    const combined = new ArrayBuffer(4 + size);
    const combinedView = new Uint8Array(combined);
    const dataView = new Uint8Array(data);
    combinedView.set(new Uint8Array(header), 0);
    combinedView.set(dataView, 4);

    return scrcpy_native.pushAudioStreamData(this.streamProcessorId, combined, pts);
  }

  /**
   * Release stream processor
   */
  async releaseStreamProcessor(): Promise<void> {
    if (this.streamProcessorId !== 0) {
      try {
        scrcpy_native.releaseAudioStreamProcessor(this.streamProcessorId);
        this.streamProcessorId = 0;
        console.info('[AudioDecoder] Stream processor released');
      } catch (err) {
        console.error('[AudioDecoder] Release stream processor failed:', err);
      }
    }
  }
}
