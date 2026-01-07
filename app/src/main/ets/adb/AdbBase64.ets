// AdbBase64 - 完全按照原版AdbBase64.java
// Base64编解码接口
import { util } from '@kit.ArkTS';

export interface AdbBase64 {
  encodeToString(data: Uint8Array): string;
  decode(data: Uint8Array): Uint8Array;
}


export class AdbBase64Impl implements AdbBase64 {
  private base64Helper: util.Base64Helper = new util.Base64Helper();

  encodeToString(data: Uint8Array): string {
    return this.base64Helper.encodeToStringSync(data);
  }

  decode(data: Uint8Array): Uint8Array {
    return this.base64Helper.decodeSync(data);
  }
}
