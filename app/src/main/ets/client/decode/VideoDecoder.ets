import scrcpy_native from 'libscrcpy_native.so';

// 视频解码器 - 使用Native C++ VideoDecoder
export class VideoDecoder {
  // 静态实例追踪 - 确保只有一个解码器实例
  private static currentInstance: VideoDecoder | null = null;

  private decoderId: number = 0;
  private codecType: string = 'h264';
  private isStarted: boolean = false;
  private frameCount: number = 0;

  // Flags
  static readonly AVCODEC_BUFFER_FLAGS_CODEC_DATA = 8;

  async init(codecType: string, surfaceId: string, width: number, height: number, csd0: ArrayBuffer, csd1?: ArrayBuffer): Promise<void> {
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
      console.info(`[VideoDecoder] SurfaceId: ${surfaceId}`);
      console.info(`[VideoDecoder] CSD-0 (SPS/VPS) size: ${csd0.byteLength} bytes`);

      if (csd1) {
        console.info(`[VideoDecoder] CSD-1 (PPS) size: ${csd1.byteLength} bytes`);
      }

      // 创建Native解码器
      this.decoderId = scrcpy_native.createVideoDecoder();
      console.info(`[VideoDecoder] Native decoder created, ID: ${this.decoderId}`);

      // 初始化解码器 - 使用codecType字符串
      const ret: number = scrcpy_native.initVideoDecoder(this.decoderId, this.codecType, surfaceId, width, height);
      if (ret !== 0) {
        const error = new Error(`Native decoder init failed: ${ret}`);
        throw error;
      }
      console.info(`[VideoDecoder] Native decoder initialized`);

      // 启动解码器
      const startRet: number = scrcpy_native.startVideoDecoder(this.decoderId);
      if (startRet !== 0) {
        const error = new Error(`Native decoder start failed: ${startRet}`);
        throw error;
      }

      this.isStarted = true;
      console.info(`[VideoDecoder] Native decoder started successfully!`);

      // 等待一小段时间确保解码器准备好
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));

      // 推送CSD数据（Codec Specific Data）
      // H264: SPS/PPS
      // H265: VPS/SPS/PPS
      // Pass AVCODEC_BUFFER_FLAGS_CODEC_DATA (8)
      if (csd0 && csd0.byteLength > 0) {
        console.info(`[VideoDecoder] Pushing CSD-0 (size: ${csd0.byteLength} bytes)`);
        await this.decode(csd0, 0, VideoDecoder.AVCODEC_BUFFER_FLAGS_CODEC_DATA);
        // 等待CSD-0被处理
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 50));
      }
      if (csd1 && csd1.byteLength > 0) {
        console.info(`[VideoDecoder] Pushing CSD-1 (PPS) (size: ${csd1.byteLength} bytes)`);
        await this.decode(csd1, 0, VideoDecoder.AVCODEC_BUFFER_FLAGS_CODEC_DATA);
        // 等待CSD-1被处理
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 50));
      }

      console.info(`[VideoDecoder] CSD data pushed, ready for frame data`);

    } catch (err) {
      const error = err as Error;
      console.error(`[VideoDecoder] Init failed: ${error.message}`);
      const newError = new Error(`VideoDecoder init failed: ${error.message}`);
      throw newError;
    }
  }

  async decode(data: ArrayBuffer, pts: number, flags: number = 0): Promise<void> {
    if (!this.isStarted || this.decoderId === 0) {
      console.warn('[VideoDecoder] Not ready, frame dropped');
      return;
    }

    // 使用 stream processor 推送数据（CSD 数据推送）
    if (this.streamProcessorId !== 0) {
      const result: number = this.pushDataToStream(data, pts, flags);
      if (result === 0) {
        this.frameCount++;
      } else if (result === -2) {
        // Buffer full, frame dropped
      } else {
        console.error(`[VideoDecoder] pushDataToStream failed: ${result}`);
      }
    } else {
      console.warn('[VideoDecoder] Stream processor not ready, frame dropped');
    }
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
        console.info(`[VideoDecoder] Released | Total frames decoded: ${this.frameCount}`);
      } catch (err) {
        console.error('[VideoDecoder] Release failed:', err);
      }
    }
  }

  // ============== Stream Mode APIs (C++ processing) ==============

  private streamProcessorId: number = 0;

  /**
   * Create and initialize stream processor (C++ mode)
   * Must be called after init() and startVideoDecoder()
   */
  async createStreamProcessor(codecType: string): Promise<number> {
    try {
      console.info(`[VideoDecoder] Creating stream processor...`);

      // Create stream processor linked to this decoder
      this.streamProcessorId = scrcpy_native.createVideoStreamProcessor(this.decoderId, codecType);

      if (this.streamProcessorId <= 0) {
        throw new Error(`Failed to create stream processor: ${this.streamProcessorId}`);
      }

      console.info(`[VideoDecoder] Stream processor created, ID: ${this.streamProcessorId}`);
      return this.streamProcessorId;

    } catch (err) {
      const error = err as Error;
      console.error(`[VideoDecoder] createStreamProcessor failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Start stream processor (C++ processing thread)
   */
  async startStreamProcessor(): Promise<void> {
    if (this.streamProcessorId === 0) {
      console.warn('[VideoDecoder] Stream processor not created');
      return;
    }
    const ret: number = scrcpy_native.startVideoStreamProcessor(this.streamProcessorId);
    if (ret !== 0) {
      throw new Error(`Failed to start stream processor: ${ret}`);
    }

    console.info('[VideoDecoder] Stream processor started');
  }

  /**
   * Push data to stream processor (ArkTS continuously calls this)
   * Prepends 12-byte header [PTS(8)][size(4)] since ArkTS parses the protocol header
   * The C++ processor expects: [8 bytes PTS][4 bytes size][N bytes video data]
   */
  pushDataToStream(data: ArrayBuffer, pts: number, flags: number = 0): number {
    if (this.streamProcessorId === 0) {
      return -1;
    }

    // Construct header + data format for C++ processor
    // C++ ParseVideoFrame expects: [8 bytes PTS][4 bytes size][N bytes data]
    const size = data.byteLength;
    const header = new ArrayBuffer(12);
    const headerView = new DataView(header);

    // PTS: 8 bytes big-endian
    headerView.setBigInt64(0, BigInt(Math.floor(pts)), false);

    // Size: 4 bytes big-endian
    headerView.setInt32(8, size, false);

    // Combine header + data
    const combined = new ArrayBuffer(12 + size);
    const combinedView = new Uint8Array(combined);
    const dataView = new Uint8Array(data);
    combinedView.set(new Uint8Array(header), 0);
    combinedView.set(dataView, 12);

    return scrcpy_native.pushVideoStreamData(this.streamProcessorId, combined, pts, flags);
  }

  /**
   * Release stream processor
   */
  async releaseStreamProcessor(): Promise<void> {
    if (this.streamProcessorId !== 0) {
      try {
        scrcpy_native.releaseVideoStreamProcessor(this.streamProcessorId);
        this.streamProcessorId = 0;
        console.info('[VideoDecoder] Stream processor released');
      } catch (err) {
        console.error('[VideoDecoder] Release stream processor failed:', err);
      }
    }
  }
}
