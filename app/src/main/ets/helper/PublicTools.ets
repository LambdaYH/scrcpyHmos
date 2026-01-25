// PublicTools - 公共工具类
// 对应Java: helper/PublicTools.java
import { buffer } from '@kit.ArkTS';
import { LoggerPublicTools } from './Logger';

export class PublicTools {
  // 日志并Toast (注意：静态方法无法使用UIContext，如需Toast请在调用处使用UIContext.getPromptAction())
  static logToast(tag: string, message: string): void {
    LoggerPublicTools.info(`[${tag}] ${message}`);
    // Note: promptAction.showToast is deprecated since API 18
    // Use this.getUIContext().getPromptAction().showToast() in component context instead
  }

  // 仅日志
  static log(tag: string, message: string): void {
    LoggerPublicTools.info(`[${tag}] ${message}`);
  }

  // 错误日志
  static logError(tag: string, error: Error | string): void {
    const msg = error instanceof Error ? error.message : error;
    LoggerPublicTools.error(`[${tag}] ${msg}`);
  }

  // 扫描局域网地址
  static async scanAddress(): Promise<string[]> {
    const scannedAddresses: string[] = [];
    // HarmonyOS网络扫描实现
    // 使用socket逐个尝试连接常见的ADB端口
    // TODO: 实现完整的网络扫描逻辑
    return scannedAddresses;
  }

  // 获取本机IP
  static async getLocalIp(): Promise<string> {
    // TODO: 实现获取本机IP
    return '0.0.0.0';
  }

  // Base64编码
  static encodeBase64(data: Uint8Array): string {
    try {
      return buffer.from(data).toString('base64');
    } catch (e) {
      LoggerPublicTools.error('Base64 encode failed:', e);
      return '';
    }
  }

  // Base64解码
  static decodeBase64(str: string): Uint8Array {
    return new Uint8Array(buffer.from(str, 'base64').buffer);
  }

  // 字节数组转十六进制字符串
  static bytesToHex(bytes: Uint8Array): string {
    return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
  }

  // 十六进制字符串转字节数组
  static hexToBytes(hex: string): Uint8Array {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) {
      bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
    }
    return bytes;
  }

  // 延迟
  static delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  // 读取原始文件
  static async readRawFile(context: Context, fileName: string): Promise<ArrayBuffer | null> {
    try {
      const resMgr = context.resourceManager;
      const data = await resMgr.getRawFileContent(fileName);
      return data.buffer as ArrayBuffer;
    } catch (err) {
      LoggerPublicTools.error('Read raw file failed:', err);
      return null;
    }
  }

  // 比较版本号
  static compareVersion(v1: string, v2: string): number {
    const parts1 = v1.split('.').map(n => parseInt(n, 10));
    const parts2 = v2.split('.').map(n => parseInt(n, 10));

    for (let i = 0; i < Math.max(parts1.length, parts2.length); i++) {
      const p1 = parts1[i] || 0;
      const p2 = parts2[i] || 0;
      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }
    return 0;
  }
}
