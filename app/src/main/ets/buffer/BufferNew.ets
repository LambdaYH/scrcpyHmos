// BufferNew - 阻塞队列缓冲区
// 参考EasyControl的BufferNew.java实现

// Promise resolver类型
type PromiseResolver = () => void;

export class BufferNew {
  private isClosed: boolean = false;
  private dataQueue: ArrayBuffer[] = [];
  private waitingResolvers: PromiseResolver[] = [];

  write(data: ArrayBuffer): void {
    if (this.isClosed) return;
    this.dataQueue.push(data);
    // 唤醒等待的读取操作
    if (this.waitingResolvers.length > 0) {
      const resolver = this.waitingResolvers.shift();
      if (resolver) {
        resolver();
      }
    }
  }

  async read(len: number): Promise<ArrayBuffer> {
    if (len < 0 || this.isClosed) {
      throw new Error('BufferNew error: invalid read or closed');
    }

    const result = new Uint8Array(len);
    let bytesToRead = len;
    let resultOffset = 0;

    while (bytesToRead > 0) {
      // 等待数据可用
      while (this.dataQueue.length === 0 && !this.isClosed) {
        await new Promise<void>((resolve) => {
          this.waitingResolvers.push(resolve);
        });
      }

      if (this.isClosed && this.dataQueue.length === 0) {
        throw new Error('BufferNew error: closed during read');
      }

      // 优化：零拷贝场景 - 当队列只有一个buffer且正好等于剩余需要的长度时直接返回
      if (this.dataQueue.length === 1 && this.dataQueue[0].byteLength === bytesToRead) {
        return this.dataQueue.shift()!;
      }

      const tmpData = this.dataQueue[0];
      const tmpArray = new Uint8Array(tmpData);
      const remaining = tmpArray.length;

      if (remaining <= bytesToRead) {
        // 整个buffer都需要
        result.set(tmpArray, resultOffset);
        resultOffset += remaining;
        bytesToRead -= remaining;
        this.dataQueue.shift();
      } else {
        // 只需要部分数据
        result.set(tmpArray.subarray(0, bytesToRead), resultOffset);
        // 保留剩余数据
        this.dataQueue[0] = tmpData.slice(bytesToRead);
        bytesToRead = 0;
      }
    }

    return result.buffer;
  }

  async readNext(): Promise<ArrayBuffer> {
    if (this.isClosed) {
      throw new Error('BufferNew error: closed');
    }

    // 等待数据可用
    while (this.dataQueue.length === 0 && !this.isClosed) {
      await new Promise<void>((resolve) => {
        this.waitingResolvers.push(resolve);
      });
    }

    if (this.isClosed && this.dataQueue.length === 0) {
      throw new Error('BufferNew error: closed during readNext');
    }

    const data = this.dataQueue.shift();
    return data || new ArrayBuffer(0);
  }

  readByteArrayBeforeClose(): ArrayBuffer {
    let totalSize = 0;
    for (const buf of this.dataQueue) {
      totalSize += buf.byteLength;
    }

    const result = new Uint8Array(Math.max(totalSize, 1));
    let offset = 0;
    for (const buf of this.dataQueue) {
      const data = new Uint8Array(buf);
      result.set(data, offset);
      offset += buf.byteLength;
    }

    return result.buffer;
  }

  isEmpty(): boolean {
    return this.dataQueue.length === 0;
  }

  getSize(): number {
    let size = 0;
    for (const buf of this.dataQueue) {
      size += buf.byteLength;
    }
    return size;
  }

  close(): void {
    if (this.isClosed) return;
    this.isClosed = true;
    // 添加一个空buffer来唤醒等待的读取
    this.dataQueue.push(new ArrayBuffer(1));
    // 唤醒所有等待的读取操作
    for (const resolver of this.waitingResolvers) {
      resolver();
    }
    this.waitingResolvers = [];
  }

  isBufferClosed(): boolean {
    return this.isClosed;
  }
}
