// Logger - Hilog 封装类
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;

/**
 * Logger 类 - 封装 HarmonyOS Hilog
 * 用于替代 console.log/info/warn/error/debug
 */
export class Logger {
  private tag: string;

  constructor(tag: string) {
    this.tag = tag;
  }

  /**
   * Debug 级别日志
   */
  debug(msg: string, ...args: (string | number | boolean | object | undefined | null)[]): void {
    const formattedMsg = this.formatMessage(msg, args);
    hilog.debug(DOMAIN, this.tag, '%{public}s', formattedMsg);
  }

  /**
   * Info 级别日志
   */
  info(msg: string, ...args: (string | number | boolean | object | undefined | null)[]): void {
    const formattedMsg = this.formatMessage(msg, args);
    hilog.info(DOMAIN, this.tag, '%{public}s', formattedMsg);
  }

  /**
   * Warn 级别日志
   */
  warn(msg: string, ...args: (string | number | boolean | object | undefined | null)[]): void {
    const formattedMsg = this.formatMessage(msg, args);
    hilog.warn(DOMAIN, this.tag, '%{public}s', formattedMsg);
  }

  /**
   * Error 级别日志
   */
  error(msg: string, ...args: (string | number | boolean | object | undefined | null)[]): void {
    const formattedMsg = this.formatMessage(msg, args);
    hilog.error(DOMAIN, this.tag, '%{public}s', formattedMsg);
  }

  /**
   * 格式化消息，将参数拼接到消息中
   */
  private formatMessage(msg: string, args: (string | number | boolean | object | undefined | null)[]): string {
    if (args.length === 0) {
      return msg;
    }
    const argsStr = args.map(arg => {
      if (arg === null) return 'null';
      if (arg === undefined) return 'undefined';
      if (typeof arg === 'object') {
        try {
          return JSON.stringify(arg);
        } catch {
          return String(arg);
        }
      }
      return String(arg);
    }).join(' ');
    return `${msg} ${argsStr}`;
  }
}

// 预定义的 Logger 实例，方便各模块使用
export const LoggerIndex = new Logger('Index');
export const LoggerControlPage = new Logger('ControlPage');
export const LoggerDeviceDetail = new Logger('DeviceDetail');
export const LoggerAdbManage = new Logger('AdbManage');
export const LoggerPublicTools = new Logger('PublicTools');
export const LoggerServerManager = new Logger('ServerManager');
export const LoggerAdbKeyManager = new Logger('AdbKeyManager');
export const LoggerPreferences = new Logger('Preferences');
export const LoggerClient = new Logger('Client');
export const LoggerClientStream = new Logger('ClientStream');
export const LoggerClientController = new Logger('ClientController');
export const LoggerVideoDecoder = new Logger('VideoDecoder');
export const LoggerAudioDecoder = new Logger('AudioDecoder');
export const LoggerAdb = new Logger('Adb');
export const LoggerTcpChannel = new Logger('TcpChannel');
