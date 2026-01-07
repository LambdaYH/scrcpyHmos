// ClientPlayer - 客户端播放器
// 对应Java: client/tools/ClientPlayer.java
import { ClientStream } from './ClientStream';
import { VideoDecoder } from '../decode/VideoDecoder';

export class ClientPlayer {
  private clientStream: ClientStream;
  private videoDecode: VideoDecoder | null = null;
  private isClose: boolean = false;

  // 视频配置
  private useH265: boolean = false;
  private videoWidth: number = 0;
  private videoHeight: number = 0;

  constructor(clientStream: ClientStream) {
    this.clientStream = clientStream;
  }

  async init(surfaceId: string): Promise<void> {
    try {
      // 读取视频配置
      console.info('Reading video configuration...');

      // 读取编码格式 (1字节)
      const useH265Byte = await this.clientStream.readByteFromVideo();
      this.useH265 = useH265Byte === 1;
      console.info(`Video codec: ${this.useH265 ? 'H.265' : 'H.264'}`);

      // 读取宽度 (4字节, big-endian)
      this.videoWidth = await this.clientStream.readIntFromVideo();
      console.info(`Video width: ${this.videoWidth}`);

      // 读取高度 (4字节, big-endian)
      this.videoHeight = await this.clientStream.readIntFromVideo();
      console.info(`Video height: ${this.videoHeight}`);

      // 读取CSD-0 (SPS/VPS)
      const csd0 = await this.clientStream.readFrameFromVideo();
      console.info(`CSD-0 size: ${csd0.byteLength}`);

      // H.264需要CSD-1 (PPS)
      let csd1: ArrayBuffer | undefined = undefined;
      if (!this.useH265) {
        csd1 = await this.clientStream.readFrameFromVideo();
        console.info(`CSD-1 size: ${csd1.byteLength}`);
      }

      // 初始化视频解码器
      this.videoDecode = new VideoDecoder();
      await this.videoDecode.init(this.useH265, surfaceId, this.videoWidth, this.videoHeight, csd0, csd1);

      console.info('ClientPlayer initialized successfully');
    } catch (err) {
      console.error('ClientPlayer init failed:', err);
      if (err instanceof Error) {
        throw err;
      } else {
        throw new Error(String(err));
      }
    }
  }

  // 启动视频流读取
  startVideoStream(): void {
    if (this.isClose) return;

    const readLoop = async () => {
      try {
        while (!this.isClose && this.videoDecode) {
          const frameData = await this.clientStream.readFrameFromVideo();
          if (frameData.byteLength > 0) {
            await this.videoDecode.decode(frameData, 0);
          }
        }
      } catch (err) {
        if (!this.isClose) {
          console.error('Video stream error:', err);
        }
      }
    };

    readLoop();
  }

  // 关闭播放器
  async close(): Promise<void> {
    if (this.isClose) return;
    this.isClose = true;

    if (this.videoDecode) {
      await this.videoDecode.release();
      this.videoDecode = null;
    }

    console.info('ClientPlayer closed');
  }

  getVideoWidth(): number {
    return this.videoWidth;
  }

  getVideoHeight(): number {
    return this.videoHeight;
  }

  isH265(): boolean {
    return this.useH265;
  }
}
