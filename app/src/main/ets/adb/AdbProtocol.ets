// AdbProtocol - ADB协议实现
// 参考EasyControl的AdbProtocol.java实现
import { buffer, util } from '@kit.ArkTS';
import { AdbChannel } from './AdbChannel';

// ADB消息
export class AdbMessage {
  command: number;
  arg0: number;
  arg1: number;
  payloadLength: number;
  payload: ArrayBuffer | null = null;

  constructor(command: number, arg0: number, arg1: number, payloadLength: number) {
    this.command = command;
    this.arg0 = arg0;
    this.arg1 = arg1;
    this.payloadLength = payloadLength;
  }

  static async parseAdbMessage(channel: AdbChannel): Promise<AdbMessage> {
    const headerData = await channel.read(AdbProtocol.ADB_HEADER_LENGTH);
    const view = new DataView(headerData);

    const command = view.getUint32(0, true); // Little endian
    const arg0 = view.getUint32(4, true);
    const arg1 = view.getUint32(8, true);
    const payloadLength = view.getUint32(12, true);
    // checksum at offset 16 - not verified like Java version
    // magic at offset 20 - not verified like Java version

    const msg = new AdbMessage(command, arg0, arg1, payloadLength);

    if (payloadLength > 0) {
      msg.payload = await channel.read(payloadLength);
    }

    return msg;
  }
}

export class AdbProtocol {
  static readonly ADB_HEADER_LENGTH: number = 24;

  static readonly AUTH_TYPE_TOKEN: number = 1;
  static readonly AUTH_TYPE_SIGNATURE: number = 2;
  static readonly AUTH_TYPE_RSA_PUBLIC: number = 3;

  static readonly CMD_AUTH: number = 0x48545541; // "AUTH"
  static readonly CMD_CNXN: number = 0x4e584e43; // "CNXN"
  static readonly CMD_OPEN: number = 0x4e45504f; // "OPEN"
  static readonly CMD_OKAY: number = 0x59414b4f; // "OKAY"
  static readonly CMD_CLSE: number = 0x45534c43; // "CLSE"
  static readonly CMD_WRTE: number = 0x45545257; // "WRTE"

  static readonly CONNECT_VERSION: number = 0x01000000;
  // 最大数据大小一般为1024*1024，此处设置为15*1024
  // 有些设备USB仅支持最大16*1024，所以限制ADB协议最大为15k
  static readonly CONNECT_MAXDATA: number = 15 * 1024;

  static readonly CONNECT_PAYLOAD: Uint8Array = new Uint8Array([
    0x68, 0x6f, 0x73, 0x74, 0x3a, 0x3a, 0x00 // "host::\0"
  ]);

  static generateConnect(): ArrayBuffer {
    return AdbProtocol.generateMessage(
      AdbProtocol.CMD_CNXN,
      AdbProtocol.CONNECT_VERSION,
      AdbProtocol.CONNECT_MAXDATA,
      AdbProtocol.CONNECT_PAYLOAD.buffer as ArrayBuffer
    );
  }

  static generateAuth(type: number, data: ArrayBuffer): ArrayBuffer {
    return AdbProtocol.generateMessage(AdbProtocol.CMD_AUTH, type, 0, data);
  }

  static generateOpen(localId: number, dest: string): ArrayBuffer {
    const destBytes = buffer.from(dest + '\0', 'utf-8');
    return AdbProtocol.generateMessage(AdbProtocol.CMD_OPEN, localId, 0, destBytes.buffer);
  }

  static generateWrite(localId: number, remoteId: number, data: ArrayBuffer): ArrayBuffer {
    return AdbProtocol.generateMessage(AdbProtocol.CMD_WRTE, localId, remoteId, data);
  }

  static generateClose(localId: number, remoteId: number): ArrayBuffer {
    return AdbProtocol.generateMessage(AdbProtocol.CMD_CLSE, localId, remoteId, null);
  }

  static generateOkay(localId: number, remoteId: number): ArrayBuffer {
    return AdbProtocol.generateMessage(AdbProtocol.CMD_OKAY, localId, remoteId, null);
  }

  private static generateMessage(cmd: number, arg0: number, arg1: number, payload: ArrayBuffer | null): ArrayBuffer {
    const payloadLength = payload ? payload.byteLength : 0;
    const size = AdbProtocol.ADB_HEADER_LENGTH + payloadLength;
    const result = new ArrayBuffer(size);
    const view = new DataView(result);

    // Little endian
    view.setUint32(0, cmd, true);
    view.setUint32(4, arg0, true);
    view.setUint32(8, arg1, true);

    if (!payload || payloadLength === 0) {
      view.setUint32(12, 0, true);
      view.setUint32(16, 0, true);
    } else {
      view.setUint32(12, payloadLength, true);
      view.setUint32(16, AdbProtocol.payloadChecksum(payload), true);
    }

    // magic = ~cmd
    view.setUint32(20, (~cmd) >>> 0, true);

    if (payload && payloadLength > 0) {
      const payloadView = new Uint8Array(result, AdbProtocol.ADB_HEADER_LENGTH);
      payloadView.set(new Uint8Array(payload));
    }

    return result;
  }

  private static payloadChecksum(payload: ArrayBuffer): number {
    let checksum = 0;
    const arr = new Uint8Array(payload);
    for (let i = 0; i < arr.length; i++) {
      checksum += (arr[i] & 0xFF);
    }
    return checksum;
  }

  // Sync协议头生成 - 用于文件传输
  static generateSyncHeader(id: string, arg: number): ArrayBuffer {
    // 检查 id 长度是否为 4
    if (id.length !== 4) {
      throw new Error(`ID must be exactly 4 characters, got: ${id}`);
    }

    // 创建 8 字节的 ArrayBuffer
    const resultBuffer = new ArrayBuffer(8);
    const uint8 = new Uint8Array(resultBuffer);
    const view = new DataView(resultBuffer);

    // 写入 4 字节 ID (ASCII)
    for (let i = 0; i < 4; i++) {
      uint8[i] = id.charCodeAt(i);
    }

    // 写入 4 字节小端整数 arg
    view.setInt32(4, arg, true); // true = littleEndian

    return resultBuffer;
  }
}