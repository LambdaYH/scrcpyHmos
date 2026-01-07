// BufferStream - 带写入控制的双向流
// 参考EasyControl的BufferStream.java实现
import { BufferNew } from './BufferNew';

// 底层Socket功能接口
export interface UnderlySocketFunction {
  connect(bufferStream: BufferStream): void;
  write(bufferStream: BufferStream, data: ArrayBuffer): void;
  flush(bufferStream: BufferStream): void;
  close(bufferStream: BufferStream): void;
}

export class BufferStream {
  private isClosed: boolean = false;
  private canWrite: boolean;
  private readonly canMultipleSend: boolean;

  private readonly source: BufferNew = new BufferNew();
  private readonly sink: BufferNew = new BufferNew();
  private readonly underlySocketFunction: UnderlySocketFunction;

  // canWrite的设立，是为了兼容某些底层连接不能随时发送，例如adb协议规定需等待对方回复确认后才可以开始下一次发送
  // canMultipleSend的设立，是为了兼容某些上层应用需逐次发送的场景，即上层的一次写入对应底层的一次写入
  constructor(canWrite: boolean, canMultipleSend: boolean, underlySocketFunction: UnderlySocketFunction) {
    this.canWrite = canWrite;
    this.canMultipleSend = canMultipleSend;
    this.underlySocketFunction = underlySocketFunction;
    underlySocketFunction.connect(this);
  }

  static createWithWriteControl(canWrite: boolean, underlySocketFunction: UnderlySocketFunction): BufferStream {
    return new BufferStream(canWrite, true, underlySocketFunction);
  }

  static create(underlySocketFunction: UnderlySocketFunction): BufferStream {
    return new BufferStream(true, true, underlySocketFunction);
  }

  pushSource(data: ArrayBuffer): void {
    if (data) {
      this.source.write(data);
    }
  }

  async readByte(): Promise<number> {
    const buf = await this.readByteArray(1);
    return new Uint8Array(buf)[0];
  }

  async readShort(): Promise<number> {
    const buf = await this.readByteArray(2);
    const view = new DataView(buf);
    return view.getInt16(0, false); // Big endian by default like Java
  }

  async readInt(): Promise<number> {
    const buf = await this.readByteArray(4);
    const view = new DataView(buf);
    return view.getInt32(0, false); // Big endian by default like Java
  }

  async readLong(): Promise<bigint> {
    const buf = await this.readByteArray(8);
    const view = new DataView(buf);
    return view.getBigInt64(0, false); // Big endian by default like Java
  }

  async readAllBytes(): Promise<ArrayBuffer> {
    return await this.readByteArray(this.getSize());
  }

  async readByteArray(size: number): Promise<ArrayBuffer> {
    if (this.isClosed) {
      throw new Error('connection is closed');
    }
    return await this.source.read(size);
  }

  readByteArrayBeforeClose(): ArrayBuffer {
    return this.source.readByteArrayBeforeClose();
  }

  async write(data: ArrayBuffer): Promise<void> {
    if (this.isClosed) {
      throw new Error('connection is closed');
    }
    this.sink.write(data);
    await this.pollSink();
  }

  async setCanWrite(canWrite: boolean): Promise<void> {
    if (this.isClosed) return;
    this.canWrite = canWrite;
    if (canWrite) {
      await this.pollSink();
    }
  }

  private async pollSink(): Promise<void> {
    if (this.canWrite && !this.sink.isEmpty()) {
      const data = this.canMultipleSend
        ? await this.sink.read(this.sink.getSize())
        : await this.sink.readNext();
      if (!this.canMultipleSend) {
        this.canWrite = false;
      }
      this.underlySocketFunction.write(this, data);
    }
  }

  isEmpty(): boolean {
    return this.source.isEmpty();
  }

  getSize(): number {
    return this.source.getSize();
  }

  isStreamClosed(): boolean {
    return this.isClosed;
  }

  flush(): void {
    this.underlySocketFunction.flush(this);
  }

  close(): void {
    if (this.isClosed) return;
    this.isClosed = true;
    this.source.close();
    this.sink.close();
    try {
      this.underlySocketFunction.close(this);
    } catch (err) {
      // ignored
    }
  }
}
