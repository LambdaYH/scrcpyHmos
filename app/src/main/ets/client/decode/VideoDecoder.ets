import { BusinessError } from '@ohos.base';
import scrcpy_native from 'libscrcpy_native.so';

// 视频解码器 - 使用Native C++ VideoDecoder
export class VideoDecoder {
  // 静态实例追踪 - 确保只有一个解码器实例
  private static currentInstance: VideoDecoder | null = null;

  private decoderId: number = 0;
  private surfaceId: string = '';
  private isH265: boolean = false;
  private width: number = 0;
  private height: number = 0;
  private isStarted: boolean = false;
  private frameCount: number = 0;
  
  async init(useH265: boolean, surfaceId: string, width: number, height: number, csd0: ArrayBuffer, csd1?: ArrayBuffer): Promise<void> {
    this.isH265 = useH265;
    this.surfaceId = surfaceId;
    this.width = width;
    this.height = height;
    
    try {
      // 释放之前的解码器实例（防止资源泄漏）
      if (VideoDecoder.currentInstance && VideoDecoder.currentInstance !== this) {
        console.info('[VideoDecoder] Releasing previous decoder instance...');
        await VideoDecoder.currentInstance.release();
      }
      VideoDecoder.currentInstance = this;

      console.info(`[VideoDecoder] Initializing Native decoder...`);
      console.info(`[VideoDecoder] Codec: ${useH265 ? 'H.265/HEVC' : 'H.264/AVC'}`);
      console.info(`[VideoDecoder] Resolution: ${width}x${height}`);
      console.info(`[VideoDecoder] SurfaceId: ${surfaceId}`);
      console.info(`[VideoDecoder] CSD-0 (SPS/VPS) size: ${csd0.byteLength} bytes`);
      
      if (csd1) {
        console.info(`[VideoDecoder] CSD-1 (PPS) size: ${csd1.byteLength} bytes`);
      }
      
      // 创建Native解码器
      this.decoderId = scrcpy_native.createDecoder();
      console.info(`[VideoDecoder] Native decoder created, ID: ${this.decoderId}`);
      
      // 初始化解码器
      const ret: number = scrcpy_native.initDecoder(this.decoderId, useH265, surfaceId, width, height);
      if (ret !== 0) {
        const error = new Error(`Native decoder init failed: ${ret}`);
        throw error;
      }
      console.info(`[VideoDecoder] Native decoder initialized`);
      
      // 启动解码器
      const startRet: number = scrcpy_native.startDecoder(this.decoderId);
      if (startRet !== 0) {
        const error = new Error(`Native decoder start failed: ${startRet}`);
        throw error;
      }
      
      this.isStarted = true;
      console.info(`[VideoDecoder] ✅ Native decoder started successfully!`);
      
      // 推送CSD数据
      if (csd0) {
        await this.decode(csd0, 0);
      }
      if (csd1) {
        await this.decode(csd1, 0);
      }
      
    } catch (err) {
      const error = err as Error;
      console.error(`[VideoDecoder] Init failed: ${error.message}`);
      const newError = new Error(`VideoDecoder init failed: ${error.message}`);
      throw newError;
    }
  }
  
  async decode(data: ArrayBuffer, pts: number): Promise<void> {
    // console.info(`[VideoDecoder] decode() called: ${data.byteLength} bytes, isStarted=${this.isStarted}, decoderId=${this.decoderId}`);

    if (!this.isStarted || this.decoderId === 0) {
      console.warn('[VideoDecoder] Not ready, frame dropped');
      return;
    }

    try {
      // 推送数据到Native解码器，带重试机制
      const maxRetries = 10;
      let retryCount = 0;
      let result: number = -2;
      
      while (retryCount < maxRetries) {
        result = scrcpy_native.pushData(this.decoderId, data, pts);
        
        if (result === 0) {
          // 成功
          break;
        } else if (result === -2) {
          // 没有可用输入缓冲区，等待后重试
          retryCount++;
          if (retryCount < maxRetries) {
            await new Promise<void>((resolve: () => void) => setTimeout(resolve, 10));
          }
        } else {
          // 其他错误，不重试
          console.error(`[VideoDecoder] pushData failed with error: ${result}`);
          break;
        }
      }
      
      if (result === 0) {
        this.frameCount++;
        // 每30帧输出一次日志
        // if (this.frameCount % 30 === 0) {
        //   console.info(`[VideoDecoder] 🎬 Decoded ${this.frameCount} frames | Latest: ${data.byteLength} bytes, PTS=${pts}`);
        // }
      } else if (result === -2) {
        console.warn(`[VideoDecoder] Frame dropped after ${maxRetries} retries (no available input buffer)`);
      }
    } catch (err) {
      console.error('[VideoDecoder] Decode error:', err);
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
        scrcpy_native.releaseDecoder(this.decoderId);
        this.decoderId = 0;
        console.info(`[VideoDecoder] Released | Total frames decoded: ${this.frameCount}`);
      } catch (err) {
        console.error('[VideoDecoder] Release failed:', err);
      }
    }
  }
}
