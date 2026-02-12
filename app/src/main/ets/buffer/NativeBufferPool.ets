// NativeBufferPool - Native 内存池的 ArkTS 封装
// 用于视频帧的零拷贝优化
import scrcpy_native from 'libscrcpy_native.so';

export class NativeBufferPool {
  /**
   * 从 Native 缓冲池分配一个 external ArrayBuffer
   * 底层内存由 Native 管理，不走 JS 堆 GC
   * 当 ArrayBuffer 被 GC 回收时，native 内存自动归还池
   *
   * @param size 请求的字节大小
   * @returns external ArrayBuffer，或 null（分配失败时）
   */
  static alloc(size: number): ArrayBuffer | null {
    try {
      const buffer: ArrayBuffer | undefined = scrcpy_native.allocNativeBuffer(size);
      if (buffer === undefined) {
        return null;
      }
      return buffer;
    } catch (err) {
      console.error('[NativeBufferPool] alloc failed:', err);
      return null;
    }
  }

  /**
   * 主动释放（不等 GC）
   * 调用此方法后，底层 native 内存立即归还池。
   * 注意：调用后不要再访问该 ArrayBuffer！
   */
  static release(buffer: ArrayBuffer): void {
    try {
      scrcpy_native.releaseNativeBuffer(buffer);
    } catch (err) {
      console.error('[NativeBufferPool] release failed:', err);
    }
  }

  /**
   * 销毁缓冲池（关闭时调用）
   */
  static destroy(): void {
    try {
      scrcpy_native.destroyBufferPool();
    } catch (err) {
      console.error('[NativeBufferPool] destroy failed:', err);
    }
  }
}
