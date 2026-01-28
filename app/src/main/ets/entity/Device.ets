// 额外参数接口
export interface ExtraParam {
  key: string;
  value: string;
}

// 设备实体类
export class Device {
  uuid: string = '';
  name: string = '';
  address: string = '';
  adbPort: number = 5555;
  type: number = Device.TYPE_NETWORK;

  // 视频参数
  videoCodec: string = 'h265'; // 'h264', 'h265'
  maxSize: number = 0;
  maxFps: number = 0;
  maxVideoBit: number = 0; // bps
  crop: string = ''; // 格式: "width:height:x:y"
  displayId: number = 0;

  // 显示设置
  showBottomNavBar: boolean = false; // 底部显示导航栏

  // 音频参数
  isAudio: boolean = true;
  audioCodec: string = 'opus'; // 'opus', 'aac', 'raw', 'flac'
  maxAudioBit: number = 0; // bps

  // 连接时操作
  customResolutionOnConnect: boolean = false;
  customResolutionWidth: number = 1920;
  customResolutionHeight: number = 1080;
  wakeOnConnect: boolean = true;
  lightOffOnConnect: boolean = false;
  changeToFullOnConnect: boolean = false;

  // 运行时操作
  stayAwake: boolean = true; // 原 keepAwake
  showTouches: boolean = false;
  clipboardAutosync: boolean = true; // 原 listenClipOnRunning
  changeResolutionOnRunning: boolean = false;
  control: boolean = true;
  cleanup: boolean = true;

  // 断开时操作
  lockOnClose: boolean = false;
  lightOnClose: boolean = false;
  reconnectOnClose: boolean = false;
  powerOffScreenOnClose: boolean = false;

  // 高级选项
  downsizeOnError: boolean = true;
  connectOnStart: boolean = false;
  logLevel: string = 'info'; // 'verbose', 'debug', 'info', 'warn', 'error'
  
  // 额外参数 (key-value pairs for custom server arguments)
  extraParams: ExtraParam[] = [];

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
