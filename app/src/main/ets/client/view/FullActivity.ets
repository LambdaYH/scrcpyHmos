// FullActivity - 全屏活动/视图
// 对应Java: client/view/FullActivity.java
// 在HarmonyOS中对应一个全屏页面组件

import { ClientController } from '../tools/ClientController';
import { ClientPlayer } from '../tools/ClientPlayer';

export class FullActivity {
  private controller: ClientController | null = null;
  private player: ClientPlayer | null = null;
  private isActive: boolean = false;

  // 设置控制器
  setController(controller: ClientController): void {
    this.controller = controller;
  }

  // 设置播放器
  setPlayer(player: ClientPlayer): void {
    this.player = player;
  }


  // 启动
  start(): void {
    this.isActive = true;
    console.info('FullActivity started');
  }

  // 停止
  stop(): void {
    this.isActive = false;
    console.info('FullActivity stopped');
  }

  // 切换到小窗口
  switchToSmall(): void {
    console.info('Switch to small view from full');
  }

  // 切换到迷你
  switchToMini(): void {
    console.info('Switch to mini view from full');
  }

  // 旋转
  rotate(): void {
    if (this.controller) {
      this.controller.rotateDevice();
    }
  }

  // 返回
  back(): void {
    if (this.controller) {
      this.controller.sendBack();
    }
  }

  // 主页
  home(): void {
    if (this.controller) {
      this.controller.sendHome();
    }
  }

  // 屏幕开关
  toggleScreen(on: boolean): void {
    if (this.controller) {
      this.controller.setScreenPower(on ? 2 : 0);
    }
  }

  // 是否活动中
  isRunning(): boolean {
    return this.isActive;
  }

  // 关闭
  close(): void {
    this.isActive = false;
    if (this.player) {
      this.player.close();
    }
    console.info('FullActivity closed');
  }
}
