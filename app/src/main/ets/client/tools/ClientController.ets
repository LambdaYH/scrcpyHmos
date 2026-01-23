// ClientController - 客户端控制器 (触摸/输入处理)
// 对应Java: client/tools/ClientController.java
import { ClientStream } from './ClientStream';
import { ControlPacket, TouchAction, KeyCode } from './ControlPacket';
import { MyFunctionString, MyFunction } from '../../entity/MyInterface';
import { util } from '@kit.ArkTS';

export class ClientController {
  private clientStream: ClientStream;
  private videoWidth: number = 0;
  private videoHeight: number = 0;
  private pointerDownTime: Map<number, number> = new Map();

  // 回调
  private onClipboardChange: MyFunctionString | null = null;
  private onClose: MyFunction | null = null;

  constructor(clientStream: ClientStream) {
    this.clientStream = clientStream;
  }

  // 设置视频尺寸
  setVideoSize(width: number, height: number): void {
    this.videoWidth = width;
    this.videoHeight = height;
  }

  // 处理触摸按下
  async handleTouchDown(pointerId: number, x: number, y: number): Promise<void> {
    this.pointerDownTime.set(pointerId, Date.now());
    // ControlPage 已经转换坐标到视频尺寸，这里直接使用
    // 注意: ControlPacket 需要 pointerId 为 bigint (虽然JS number可以传, 但建议显式转换)
    const packet = ControlPacket.createInjectTouchEvent(
      TouchAction.ACTION_DOWN, 
      BigInt(pointerId), 
      x, 
      y, 
      this.videoWidth, 
      this.videoHeight, 
      1.0, 
      0, 
      0
    );
    await this.clientStream.writeMain(packet);
  }

  // 处理触摸移动
  async handleTouchMove(pointerId: number, x: number, y: number): Promise<void> {
    const packet = ControlPacket.createInjectTouchEvent(
      TouchAction.ACTION_MOVE, 
      BigInt(pointerId), 
      x, 
      y, 
      this.videoWidth, 
      this.videoHeight, 
      1.0, 
      0, 
      0
    );
    await this.clientStream.writeMain(packet);
  }

  // 处理触摸抬起
  async handleTouchUp(pointerId: number, x: number, y: number): Promise<void> {
    const packet = ControlPacket.createInjectTouchEvent(
      TouchAction.ACTION_UP, 
      BigInt(pointerId), 
      x, 
      y, 
      this.videoWidth, 
      this.videoHeight, 
      1.0, 
      0, 
      0
    );
    await this.clientStream.writeMain(packet);
    this.pointerDownTime.delete(pointerId);
  }

  // 发送按键事件 (Click: Down + Up)
  async sendKeyEvent(keyCode: KeyCode, metaState: number = 0): Promise<void> {
    const packets = ControlPacket.createKeyEventPair(keyCode, metaState);
    for (const packet of packets) {
      await this.clientStream.writeMain(packet);
    }
  }

  // 发送返回键
  async sendBack(): Promise<void> {
    await this.sendKeyEvent(KeyCode.KEYCODE_BACK);
  }

  // 发送主页键
  async sendHome(): Promise<void> {
    await this.sendKeyEvent(KeyCode.KEYCODE_HOME);
  }

  // 发送菜单键
  async sendMenu(): Promise<void> {
    await this.sendKeyEvent(KeyCode.KEYCODE_MENU);
  }

  // 发送电源键
  async sendPower(): Promise<void> {
    await this.sendKeyEvent(KeyCode.KEYCODE_POWER);
  }

  // 发送剪贴板内容
  async sendClipboard(text: string): Promise<void> {
    const packet = ControlPacket.createSetClipboard(text, 0n, false);
    await this.clientStream.writeMain(packet);
  }

  // 旋转设备
  async rotateDevice(): Promise<void> {
    const packet = ControlPacket.createRotateDevice();
    await this.clientStream.writeMain(packet);
  }

  // 设置屏幕电源
  async setScreenPower(mode: number): Promise<void> {
    // 假设 mode 1=ON, 0=OFF (近似映射)
    const on = mode === 1; // 简单判断
    const packet = ControlPacket.createSetDisplayPower(on);
    await this.clientStream.writeMain(packet);
  }



  // 发送保活包 (暂不支持 或 使用空包)
  // 发送保活包
  // Scrcpy 协议没有专门的 KEEP_ALIVE 包
  // 我们可以发送一个副作用最小的包，例如 GET_CLIPBOARD (copyKey=0)
  async sendKeepAlive(): Promise<void> {
    const packet = ControlPacket.createGetClipboard(0);
    await this.clientStream.writeMain(packet);
  }

  // 设置剪贴板变化回调
  setOnClipboardChange(callback: MyFunctionString): void {
    this.onClipboardChange = callback;
  }

  // 设置关闭回调
  setOnClose(callback: MyFunction): void {
    this.onClose = callback;
  }

  // 处理来自服务端的消息
  handleServerMessage(data: ArrayBuffer): void {
    if (data.byteLength < 1) return;

    const view = new DataView(data);
    const messageType = view.getUint8(0);

    switch (messageType) {
      case 0: // 剪贴板
        this.handleClipboardMessage(data);
        break;
      case 1: // 关闭
        if (this.onClose) {
          this.onClose();
        }
        break;
      default:
        console.warn('Unknown server message type:', messageType);
    }
  }

  private handleClipboardMessage(data: ArrayBuffer): void {
    if (data.byteLength < 5) return;

    const view = new DataView(data);
    const textLen = view.getUint32(1, true);

    if (data.byteLength < 5 + textLen) return;

    const textBytes = new Uint8Array(data, 5, textLen);
    const decoder = util.TextDecoder.create('utf-8');
    const text = decoder.decodeToString(textBytes);

    if (this.onClipboardChange) {
      this.onClipboardChange(text);
    }
  }
}
