// ClientController - 客户端控制器 (触摸/输入处理)
// 对应Java: client/tools/ClientController.java
import { ClientStream } from './ClientStream';
import { ControlPacket, TouchAction, KeyCode } from './ControlPacket';
import { MyFunctionString, MyFunction } from '../../entity/MyInterface';
import { util } from '@kit.ArkTS';

export class ClientController {
  private clientStream: ClientStream;
  private surfaceWidth: number = 0;
  private surfaceHeight: number = 0;
  private videoWidth: number = 0;
  private videoHeight: number = 0;
  private pointerDownTime: Map<number, number> = new Map();

  // 回调
  private onClipboardChange: MyFunctionString | null = null;
  private onClose: MyFunction | null = null;

  constructor(clientStream: ClientStream) {
    this.clientStream = clientStream;
  }

  // 设置Surface尺寸
  setSurfaceSize(width: number, height: number): void {
    this.surfaceWidth = width;
    this.surfaceHeight = height;
  }

  // 设置视频尺寸
  setVideoSize(width: number, height: number): void {
    this.videoWidth = width;
    this.videoHeight = height;
  }

  // 处理触摸按下
  async handleTouchDown(pointerId: number, x: number, y: number): Promise<void> {
    const normalizedX = this.normalizeX(x);
    const normalizedY = this.normalizeY(y);

    this.pointerDownTime.set(pointerId, Date.now());
    const packet = ControlPacket.createTouchEvent(TouchAction.ACTION_DOWN, pointerId, normalizedX, normalizedY, 0);
    await this.clientStream.writeMain(packet);
  }

  // 处理触摸移动
  async handleTouchMove(pointerId: number, x: number, y: number): Promise<void> {
    const normalizedX = this.normalizeX(x);
    const normalizedY = this.normalizeY(y);

    const downTime = this.pointerDownTime.get(pointerId) || Date.now();
    const offsetTime = Date.now() - downTime;

    const packet = ControlPacket.createTouchEvent(TouchAction.ACTION_MOVE, pointerId, normalizedX, normalizedY, offsetTime);
    await this.clientStream.writeMain(packet);
  }

  // 处理触摸抬起
  async handleTouchUp(pointerId: number, x: number, y: number): Promise<void> {
    const normalizedX = this.normalizeX(x);
    const normalizedY = this.normalizeY(y);

    const downTime = this.pointerDownTime.get(pointerId) || Date.now();
    const offsetTime = Date.now() - downTime;

    const packet = ControlPacket.createTouchEvent(TouchAction.ACTION_UP, pointerId, normalizedX, normalizedY, offsetTime);
    await this.clientStream.writeMain(packet);
    this.pointerDownTime.delete(pointerId);
  }

  // 发送按键事件
  async sendKeyEvent(keyCode: KeyCode, metaState: number = 0): Promise<void> {
    const packet = ControlPacket.createKeyEvent(keyCode, metaState);
    await this.clientStream.writeMain(packet);
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
    const packet = ControlPacket.createClipboardEvent(text);
    await this.clientStream.writeMain(packet);
  }

  // 旋转设备
  async rotateDevice(): Promise<void> {
    const packet = ControlPacket.createRotateDeviceEvent();
    await this.clientStream.writeMain(packet);
  }

  // 设置屏幕电源
  async setScreenPower(mode: number): Promise<void> {
    const packet = ControlPacket.createScreenPowerEvent(mode);
    await this.clientStream.writeMain(packet);
  }

  // 修改分辨率
  async changeResolution(width: number, height: number): Promise<void> {
    const packet = ControlPacket.createChangeResolutionEventExact(width, height);
    await this.clientStream.writeMain(packet);
  }

  // 发送保活包
  async sendKeepAlive(): Promise<void> {
    const packet = ControlPacket.createKeepAliveEvent();
    await this.clientStream.writeMain(packet);
  }

  // 坐标归一化 X
  private normalizeX(x: number): number {
    if (this.surfaceWidth === 0) return 0;
    let normalized = x / this.surfaceWidth;
    if (normalized < 0) normalized = 0;
    if (normalized > 1) normalized = 1;
    return normalized;
  }

  // 坐标归一化 Y
  private normalizeY(y: number): number {
    if (this.surfaceHeight === 0) return 0;
    let normalized = y / this.surfaceHeight;
    if (normalized < 0) normalized = 0;
    if (normalized > 1) normalized = 1;
    return normalized;
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
