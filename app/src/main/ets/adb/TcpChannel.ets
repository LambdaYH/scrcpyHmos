// TcpChannel - TCP通道实现
// 参考EasyControl的TcpChannel.java实现
import socket from '@ohos.net.socket';
import { AdbChannel } from './AdbChannel';

// Pending read request class
class PendingReadRequest {
  length: number;
  resolve: (data: ArrayBuffer) => void;
  reject: (err: Error) => void;

  constructor(length: number, resolve: (data: ArrayBuffer) => void, reject: (err: Error) => void) {
    this.length = length;
    this.resolve = resolve;
    this.reject = reject;
  }
}

// TCP通道实现 - 参考EasyControl的TcpChannel
export class TcpChannel implements AdbChannel {
  private tcpSocket?: socket.TCPSocket;
  private isConnected: boolean = false;
  private receiveBuffer: Uint8Array = new Uint8Array(0);
  private pendingReads: Array<PendingReadRequest> = [];
  private isClosed: boolean = false;

  async connect(address: string, port: number): Promise<void> {
    return new Promise((resolve, reject) => {
      console.debug(`TcpChannel: Attempting to connect to ${address}:${port}`);

      const timeoutId = setTimeout(() => {
        console.error(`TcpChannel: Connection timeout after 10 seconds`);
        reject(new Error(`Connection timeout to ${address}:${port}`));
      }, 10000);

      this.tcpSocket = socket.constructTCPSocketInstance();

      // 绑定message事件 - 接收所有数据到缓冲区
      this.tcpSocket.on('message', (value: socket.SocketMessageInfo) => {
        if (value.message) {
          this.onDataReceived(value.message);
        }
      });

      this.tcpSocket.on('connect', () => {
        console.info(`TcpChannel: TCP connected to ${address}:${port}`);
        clearTimeout(timeoutId);
        this.isConnected = true;
        resolve();
      });

      this.tcpSocket.on('close', () => {
        console.info('TcpChannel: TCP closed');
        this.isConnected = false;
        this.isClosed = true;
        // 拒绝所有pending的读取请求
        for (const req of this.pendingReads) {
          req.reject(new Error('Connection closed'));
        }
        this.pendingReads = [];
      });

      this.tcpSocket.on('error', (err: Error) => {
        console.error('TcpChannel: TCP error:', err.message);
        clearTimeout(timeoutId);
        reject(err);
      });

      // 连接
      const connectAddress: socket.TCPConnectOptions = {
        address: {
          address: address,
          port: port,
          family: 1 // IPv4
        },
        timeout: 10000
      };

      console.info('TcpChannel: Calling socket.connect()...');
      this.tcpSocket.connect(connectAddress).catch((err: Error) => {
        console.error('TcpChannel: Connect failed immediately:', err.message);
        clearTimeout(timeoutId);
        reject(err);
      });
    });
  }

  private onDataReceived(data: ArrayBuffer): void {
    // 如果已关闭，忽略接收到的数据
    if (this.isClosed) {
      return;
    }
    
    // 将接收到的数据添加到缓冲区
    const newData = new Uint8Array(data);
    const temp = new Uint8Array(this.receiveBuffer.length + newData.length);
    temp.set(this.receiveBuffer, 0);
    temp.set(newData, this.receiveBuffer.length);
    this.receiveBuffer = temp;

    // console.info('TcpChannel: Received data, buffer size:', this.receiveBuffer.length);

    // 检查是否有pending的read请求可以满足
    this.processPendingReads();
  }

  private processPendingReads(): void {
    while (this.pendingReads.length > 0) {
      const request = this.pendingReads[0];

      if (this.receiveBuffer.length >= request.length) {
        // 有足够的数据，提取并返回
        const result = this.receiveBuffer.slice(0, request.length);
        const buffer = new ArrayBuffer(result.length);
        const view = new Uint8Array(buffer);
        view.set(result);

        // 从缓冲区移除已读数据
        this.receiveBuffer = this.receiveBuffer.slice(request.length);

        // 移除并完成请求
        this.pendingReads.shift();
        request.resolve(buffer);

        // console.info('TcpChannel: Read completed, remaining buffer:', this.receiveBuffer.length);
      } else {
        // 数据不够，等待更多数据
        break;
      }
    }
  }

  async write(data: ArrayBuffer): Promise<void> {
    if (!this.tcpSocket || !this.isConnected) {
      throw new Error('Socket not connected');
    }

    return new Promise((resolve, reject) => {
      this.tcpSocket!.send({
        data: data
      }).then(() => {
        resolve();
      }).catch((err: Error) => {
        reject(err);
      });
    });
  }

  async flush(): Promise<void> {
    // HarmonyOS socket 没有flush方法，不需要实现
  }

  async read(size: number): Promise<ArrayBuffer> {
    return new Promise<ArrayBuffer>((resolve, reject) => {
      if (!this.tcpSocket || !this.isConnected) {
        reject(new Error('Socket not connected'));
        return;
      }

      if (this.isClosed) {
        reject(new Error('Socket closed'));
        return;
      }

      // console.info('TcpChannel: Read request for', size, 'bytes, buffer has:', this.receiveBuffer.length);

      // 设置超时 - 等待ADB授权需要更长时间（60秒）
      const timeoutId = setTimeout(() => {
        // 从pending列表移除
        const index = this.pendingReads.findIndex(r => r.resolve === resolve);
        if (index >= 0) {
          this.pendingReads.splice(index, 1);
        }
        reject(new Error('Read timeout'));
      }, 60000); // 60秒超时，给用户足够时间在设备上授权

      // 添加到pending队列
      const request = new PendingReadRequest(
        size,
        (data: ArrayBuffer) => {
          clearTimeout(timeoutId);
          resolve(data);
        },
        (err: Error) => {
          clearTimeout(timeoutId);
          reject(err);
        }
      );
      this.pendingReads.push(request);

      // 尝试立即处理（如果缓冲区已有足够数据）
      this.processPendingReads();
    });
  }

  close(): void {
    if (this.isClosed) return;
    this.isClosed = true;
    console.info('TcpChannel: Closing connection');

    // 拒绝所有pending的读取请求
    for (const req of this.pendingReads) {
      req.reject(new Error('Connection closed'));
    }
    this.pendingReads = [];

    if (this.tcpSocket) {
      try {
        // 取消所有事件监听
        this.tcpSocket.off('message');
        this.tcpSocket.off('connect');
        this.tcpSocket.off('close');
        this.tcpSocket.off('error');
        
        // 关闭socket
        this.tcpSocket.close();
        console.info('TcpChannel: Socket closed');
      } catch (err) {
        console.error('Close socket failed:', err);
      }
      this.isConnected = false;
      this.tcpSocket = undefined;
    }
  }

  isChannelConnected(): boolean {
    return this.isConnected && !this.isClosed;
  }
}
