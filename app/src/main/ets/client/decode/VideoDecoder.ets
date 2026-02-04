import scrcpy_native from 'libscrcpy_native.so';

// Interface for pending frame data
interface PendingFrameData {
  data: ArrayBuffer;
  pts: number;
  flags: number;
}

// 视频解码器 - 使用Native C++ VideoDecoder
export class VideoDecoder {
  // 静态实例追踪 - 确保只有一个解码器实例
  private static currentInstance: VideoDecoder | null = null;

  private decoderId: number = 0;
  private codecType: string = 'h264';
  private isStarted: boolean = false;
  private frameCount: number = 0;

  // Pending data queue - stores frame data until stream processor is ready
  private pendingDataQueue: Array<PendingFrameData> = [];

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
      console.info(`[VideoDecoder] SurfaceId: ${surfaceId}`);

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

      // scrcpy 2.x+ 协议中，CSD 数据作为普通视频帧发送，无需预加载

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
      // Queue the data for later processing when stream processor is ready
      // This ensures CSD data is not lost during initialization
      const frameData: PendingFrameData = { data: data, pts: pts, flags: flags };
      this.pendingDataQueue.push(frameData);
      console.info(`[VideoDecoder] Stream processor not ready, queued CSD/frame data (queue size: ${this.pendingDataQueue.length})`);
    }
  }

  /**
   * Flush queued data to stream processor
   * Called after stream processor is created and started
   */
  async flushPendingData(): Promise<void> {
    if (this.pendingDataQueue.length === 0) {
      return;
    }

    console.info(`[VideoDecoder] Flushing ${this.pendingDataQueue.length} queued frames to stream processor`);

    for (const item of this.pendingDataQueue) {
      const result = this.pushDataToStream(item.data, item.pts, item.flags);
      if (result === 0) {
        this.frameCount++;
      } else if (result === -2) {
        // Buffer full - wait a bit and retry
        await new Promise<void>((resolve) => setTimeout(resolve, 1));
        const retryResult = this.pushDataToStream(item.data, item.pts, item.flags);
        if (retryResult === 0) {
          this.frameCount++;
        } else {
          console.error(`[VideoDecoder] Failed to push queued frame after retry: ${retryResult}`);
        }
      } else {
        console.error(`[VideoDecoder] Failed to push queued frame: ${result}`);
      }
    }

    // Clear the queue
    this.pendingDataQueue = [];
    console.info('[VideoDecoder] Pending data flushed');
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

    // Clear pending data queue
    this.pendingDataQueue = [];
  }

  // ============== Stream Mode APIs (C++ processing) ==============

  private streamProcessorId: number = 0;

  /**
   * Get stream processor ID (for Worker integration)
   */
  getStreamProcessorId(): number {
    return this.streamProcessorId;
  }

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

      // Flush any pending CSD/frame data that was queued during init
      await this.flushPendingData();

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
