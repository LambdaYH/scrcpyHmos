// 设备实体类
export class Device {
  uuid: string = '';
  name: string = '';
  address: string = '';
  adbPort: number = 5555;
  serverPort: number = 12580;
  type: number = Device.TYPE_NETWORK;
  
  // 连接时操作
  customResolutionOnConnect: boolean = false;
  customResolutionWidth: number = 1920;
  customResolutionHeight: number = 1080;
  wakeOnConnect: boolean = true;
  lightOffOnConnect: boolean = false;
  changeToFullOnConnect: boolean = false;
  
  // 运行时操作
  keepAwake: boolean = true;
  changeResolutionOnRunning: boolean = false;
  listenClipOnRunning: boolean = true;
  
  // 断开时操作
  lockOnClose: boolean = false;
  lightOnClose: boolean = false;
  reconnectOnClose: boolean = false;
  
  // 参数
  isAudio: boolean = true;
  maxSize: number = 1920;
  maxFps: number = 60;
  maxVideoBit: number = 4;
  useH265: boolean = true;
  connectOnStart: boolean = false;
  
  static readonly TYPE_NETWORK: number = 0;
  
  constructor(uuid?: string, type?: number) {
    if (uuid) {
      this.uuid = uuid;
    }
    if (type !== undefined) {
      this.type = type;
    }
  }
  
  isNetworkDevice(): boolean {
    return this.type === Device.TYPE_NETWORK;
  }
}
