// Buffer - 环形缓冲区
// 对应Java: buffer/Buffer.java

export class Buffer {
  private buffer: Uint8Array;
  private capacity: number;
  private head: number = 0;
  private tail: number = 0;

  constructor(capacity: number) {
    this.capacity = capacity;
    this.buffer = new Uint8Array(capacity);
  }

  // 获取当前缓冲区数据大小
  getSize(): number {
    if (this.tail >= this.head) {
      return this.tail - this.head;
    } else {
      return this.capacity - this.head + this.tail;
    }
  }

  // 写入数据到缓冲区
  write(data: Uint8Array): void {
    const remainingBytes = this.capacity - this.tail;
    if (data.length < remainingBytes) {
      // 无需环回
      this.buffer.set(data, this.tail);
      this.tail += data.length;
    } else {
      // 需要环回
      this.buffer.set(data.subarray(0, remainingBytes), this.tail);
      const remaining = data.subarray(remainingBytes);
      this.buffer.set(remaining, 0);
      this.tail = remaining.length;
    }
  }

  // 读取指定大小的数据
  read(size: number): Uint8Array {
    const data = new Uint8Array(size);
    const remainingBytes = this.capacity - this.head;

    if (size <= remainingBytes) {
      // 无需环回
      data.set(this.buffer.subarray(this.head, this.head + size));
      this.head += size;
    } else {
      // 需要环回
      data.set(this.buffer.subarray(this.head, this.capacity), 0);
      const remaining = size - remainingBytes;
      data.set(this.buffer.subarray(0, remaining), remainingBytes);
      this.head = remaining;
    }

    return data;
  }

  // 清空缓冲区
  clear(): void {
    this.head = 0;
    this.tail = 0;
  }

  // 检查是否为空
  isEmpty(): boolean {
    return this.getSize() === 0;
  }
}
