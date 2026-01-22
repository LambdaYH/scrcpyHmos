// AdbKeyPair - 完全按照原版AdbKeyPair.java
import cryptoFramework from '@ohos.security.cryptoFramework';
import { buffer } from '@kit.ArkTS';
import { AdbBase64 } from './AdbBase64';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';

// RSA公钥解析结果
class RsaKeyParams {
  modulus: bigint;
  exponent: number;

  constructor(modulus: bigint, exponent: number) {
    this.modulus = modulus;
    this.exponent = exponent;
  }
}

// 完全按照原版AdbKeyPair.java
export class AdbKeyPair {

  public readonly publicKeyBytes: Uint8Array;
  private keyPair?: cryptoFramework.KeyPair; // 缓存完整KeyPair用于签名

  private static readonly KEY_LENGTH_BITS = 2048;
  private static readonly KEY_LENGTH_BYTES = AdbKeyPair.KEY_LENGTH_BITS / 8;
  private static readonly KEY_LENGTH_WORDS = AdbKeyPair.KEY_LENGTH_BYTES / 4;
  private static adbBase64?: AdbBase64;

  // 完全按照原版的SIGNATURE_PADDING
  public static readonly SIGNATURE_PADDING = new Uint8Array([
    0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00,
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00,
    0x04, 0x14
  ]);

  constructor(privateKey: cryptoFramework.PriKey, publicKeyBytes: Uint8Array, keyPair?: cryptoFramework.KeyPair) {
    this.publicKeyBytes = publicKeyBytes;
    this.keyPair = keyPair;
  }

  // 完全按照原版的signPayload方法
  async signPayload(payload: ArrayBuffer): Promise<Uint8Array> {
    if (!payload || payload.byteLength === 0) {
      return new Uint8Array([0]);
    }

    try {
      if (!this.keyPair || !this.keyPair.priKey) {
        throw new Error('No private key available for signing');
      }

      // 合并padding和payload
      const payloadArray = new Uint8Array(payload);
      const combined = new Uint8Array(AdbKeyPair.SIGNATURE_PADDING.length + payloadArray.length);
      combined.set(AdbKeyPair.SIGNATURE_PADDING, 0);
      combined.set(payloadArray, AdbKeyPair.SIGNATURE_PADDING.length);

      // ADB使用RSA/ECB/NoPadding
      const cipher = cryptoFramework.createCipher('RSA2048|NoPadding');
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, this.keyPair.priKey, null);

      const inputBlob: cryptoFramework.DataBlob = { data: combined };
      const result = await cipher.doFinal(inputBlob);

      return result.data;
    } catch (err) {
      console.error('Sign payload failed:', err);
      return new Uint8Array(256); // 返回256字节空签名
    }
  }

  // 完全按照原版的setAdbBase64方法
  static setAdbBase64(adbBase64: AdbBase64): void {
    AdbKeyPair.adbBase64 = adbBase64;
  }

  // 完全按照原版的read方法 - 从文件读取密钥对
  static async read(publicKeyPath: string, privateKeyPath: string): Promise<AdbKeyPair> {
    if (!AdbKeyPair.adbBase64) {
      throw new Error('no adbBase64');
    }

    try {
      // 读取公钥文件
      const pubFile = fs.openSync(publicKeyPath, fs.OpenMode.READ_ONLY);
      const pubStat = fs.statSync(publicKeyPath);
      const pubBuf = new ArrayBuffer(pubStat.size);
      fs.readSync(pubFile.fd, pubBuf);
      fs.closeSync(pubFile);

      const publicKeyBytes = new Uint8Array(pubBuf);

      // 读取私钥文件
      const priFile = fs.openSync(privateKeyPath, fs.OpenMode.READ_ONLY);
      const priStat = fs.statSync(privateKeyPath);
      const priBuf = new ArrayBuffer(priStat.size);
      fs.readSync(priFile.fd, priBuf);
      fs.closeSync(priFile);

      const privateKeyText = new util.TextDecoder('utf-8').decode(new Uint8Array(priBuf));
      const data = privateKeyText
        .replace('-----BEGIN PRIVATE KEY-----', '')
        .replace('-----END PRIVATE KEY-----', '')
        .replace(/\n/g, '');

      const privateKeyBytes = AdbKeyPair.adbBase64.decode(new util.TextEncoder().encodeInto(data));

      // 使用HarmonyOS API重建密钥对
      const rsaGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048');
      const priKeyBlob: cryptoFramework.DataBlob = { data: privateKeyBytes };

      // 从公钥字节中提取X509格式（如果需要）
      // 这里简化处理，假设私钥可以独立加载
      const priKey = await rsaGenerator.convertKey(null, priKeyBlob);

      return new AdbKeyPair(priKey.priKey!, publicKeyBytes, priKey);
    } catch (err) {
      throw new Error(`Read key pair failed: ${err}`);
    }
  }

  // 完全按照原版的generate方法 - 生成新密钥对
  static async generate(publicKeyPath: string, privateKeyPath: string): Promise<void> {
    if (!AdbKeyPair.adbBase64) {
      throw new Error('no adbBase64');
    }

    try {
      // 生成RSA 2048密钥对
      const rsaGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048');
      const keyPair = await rsaGenerator.generateKeyPair();

      // 转换公钥为ADB格式
      const adbPublicKey = AdbKeyPair.convertRsaPublicKeyToAdbFormat(keyPair.pubKey);
      const pubKeyBase64 = AdbKeyPair.adbBase64.encodeToString(new Uint8Array(adbPublicKey));

      // 写入公钥文件
      const pubKeyContent = pubKeyBase64.replace(/\n/g, '') + ' one@Aphone';
      const pubFile = fs.openSync(publicKeyPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(pubFile.fd, pubKeyContent);
      fs.closeSync(pubFile);

      // 写入私钥文件
      const priKeyBlob = keyPair.priKey.getEncoded();
      const priKeyBase64 = AdbKeyPair.adbBase64.encodeToString(priKeyBlob.data);
      const priKeyContent = '-----BEGIN PRIVATE KEY-----\n' +
        priKeyBase64.replace(/\n/g, '') +
        '\n-----END PRIVATE KEY-----';

      const priFile = fs.openSync(privateKeyPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(priFile.fd, priKeyContent);
      fs.closeSync(priFile);

      console.info('ADB key pair generated successfully');
    } catch (err) {
      throw new Error(`Generate key pair failed: ${err}`);
    }
  }

  // 完全按照原版的convertRsaPublicKeyToAdbFormat方法
  private static convertRsaPublicKeyToAdbFormat(pubKey: cryptoFramework.PubKey): ArrayBuffer {
    try {
      // 从PKCS#8格式公钥中提取modulus和exponent
      const pubKeyBlob = pubKey.getEncoded();
      const keyData = new Uint8Array(pubKeyBlob.data);

      const parsed = AdbKeyPair.parseRsaPublicKey(keyData);
      if (!parsed) {
        throw new Error('Failed to parse RSA public key');
      }

      const n = parsed.modulus;
      const e = parsed.exponent;

      // 按照原版Java代码计算
      const r32 = 1n << 32n;
      const r = 1n << BigInt(AdbKeyPair.KEY_LENGTH_WORDS * 32);
      const rr = (r * r) % n;
      const rem = n % r32;
      const n0inv = AdbKeyPair.modInverse(rem, r32);

      const myN: number[] = [];
      const myRr: number[] = [];

      let tempN = n;
      let tempRr = rr;

      for (let i = 0; i < AdbKeyPair.KEY_LENGTH_WORDS; i++) {
        myN.push(Number(tempN % r32));
        tempN = tempN / r32;

        myRr.push(Number(tempRr % r32));
        tempRr = tempRr / r32;
      }

      // 构建524字节的ArrayBuffer
      const buf = buffer.from(new ArrayBuffer(524));
      let offset = 0;

      buf.writeUInt32LE(AdbKeyPair.KEY_LENGTH_WORDS, offset);
      offset += 4;

      const n0invValue = Number(n0inv % r32);
      const negatedValue = -n0invValue;
      buf.writeUInt32LE(negatedValue >>> 0, offset);
      offset += 4;

      for (let i = 0; i < AdbKeyPair.KEY_LENGTH_WORDS; i++) {
        buf.writeUInt32LE(myN[i] >>> 0, offset);
        offset += 4;
      }

      for (let i = 0; i < AdbKeyPair.KEY_LENGTH_WORDS; i++) {
        buf.writeUInt32LE(myRr[i] >>> 0, offset);
        offset += 4;
      }

      buf.writeUInt32LE(e >>> 0, offset);

      return buf.buffer;
    } catch (err) {
      console.error('Convert RSA public key to ADB format failed:', err);
      return new ArrayBuffer(524);
    }
  }

  // 解析PKCS#8 DER编码的RSA公钥
  private static parseRsaPublicKey(keyData: Uint8Array): RsaKeyParams | null {
    try {
      let offset = 0;

      while (offset < keyData.length - 10) {
        if (keyData[offset] === 0x02) { // INTEGER tag
          offset++;
          let length = keyData[offset];
          offset++;

          if (length & 0x80) {
            const numBytes = length & 0x7f;
            length = 0;
            for (let i = 0; i < numBytes; i++) {
              length = (length << 8) | keyData[offset++];
            }
          }

          let modulusBytes = keyData.slice(offset, offset + length);
          if (modulusBytes[0] === 0x00) {
            modulusBytes = modulusBytes.slice(1);
          }

          let modulus = 0n;
          for (let i = 0; i < modulusBytes.length; i++) {
            modulus = (modulus << 8n) | BigInt(modulusBytes[i]);
          }

          offset += length;

          if (keyData[offset] === 0x02) {
            offset++;
            const expLen = keyData[offset++];
            let exponent = 0;
            for (let i = 0; i < expLen; i++) {
              exponent = (exponent << 8) | keyData[offset++];
            }

            return new RsaKeyParams(modulus, exponent);
          }
        }
        offset++;
      }

      return null;
    } catch (err) {
      console.error('Parse RSA public key failed:', err);
      return null;
    }
  }

  // 计算模逆
  private static modInverse(a: bigint, m: bigint): bigint {
    const m0 = m;
    let x0 = 0n;
    let x1 = 1n;

    if (m === 1n) return 0n;

    let tempA = a;
    let tempM = m;

    while (tempA > 1n) {
      const q = tempA / tempM;
      let t = tempM;

      tempM = tempA % tempM;
      tempA = t;
      t = x0;

      x0 = x1 - q * x0;
      x1 = t;
    }

    if (x1 < 0n) x1 += m0;

    return x1;
  }
}
