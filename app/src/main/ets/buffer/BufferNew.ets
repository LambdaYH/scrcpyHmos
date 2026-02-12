// BufferNew - 阻塞队列缓冲区
// 参考EasyControl的BufferNew.java实现

import { NativeBufferPool } from './NativeBufferPool';

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

  /**
   * 使用 Native 缓冲池读取数据（零拷贝优化）
   * 与 read() 逻辑相同，但目标 buffer 使用 NativeBufferPool 分配的 native 内存，
   * 后续传给 NAPI 时 napi_get_arraybuffer_info 直接返回同一个 native 指针。
   */
  async readToNativeBuffer(len: number): Promise<ArrayBuffer> {
    if (len < 0 || this.isClosed) {
      throw new Error('BufferNew error: invalid read or closed');
    }

    // 等待数据
    while (this.dataQueue.length === 0 && !this.isClosed) {
      await new Promise<void>((resolve) => {
        this.waitingResolvers.push(resolve);
      });
    }

    if (this.isClosed && this.dataQueue.length === 0) {
      throw new Error('BufferNew error: closed during read');
    }

    // 零拷贝快捷路径 - 如果队列恰好只有一个 buffer 且大小匹配
    if (this.dataQueue.length === 1 && this.dataQueue[0].byteLength === len) {
      return this.dataQueue.shift()!;
    }

    // 从 Native 池分配 buffer
    const nativeBuffer = NativeBufferPool.alloc(len);
    if (nativeBuffer === null) {
      // Fallback: 使用普通 JS 堆分配
      return await this.read(len);
    }

    const result = new Uint8Array(nativeBuffer);
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

      const tmpData = this.dataQueue[0];
      const tmpArray = new Uint8Array(tmpData);
      const remaining = tmpArray.length;

      if (remaining <= bytesToRead) {
        result.set(tmpArray, resultOffset);
        resultOffset += remaining;
        bytesToRead -= remaining;
        this.dataQueue.shift();
      } else {
        result.set(tmpArray.subarray(0, bytesToRead), resultOffset);
        this.dataQueue[0] = tmpData.slice(bytesToRead);
        bytesToRead = 0;
      }
    }

    return nativeBuffer;
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
