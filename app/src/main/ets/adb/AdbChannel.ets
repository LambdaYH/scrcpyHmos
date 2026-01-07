// AdbChannel - ADB通道接口
// 参考EasyControl的AdbChannel.java实现

export interface AdbChannel {
  write(data: ArrayBuffer): Promise<void>;
  flush(): Promise<void>;
  read(size: number): Promise<ArrayBuffer>;
  close(): void;
}
