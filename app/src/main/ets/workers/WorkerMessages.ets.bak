// WorkerMessages.ets - Shared message types between UI thread and Worker thread
// This file is intentionally separate from StreamWorker.ets to avoid
// importing Worker-only code (worker.workerPort) on the UI thread.

import { TouchAction, KeyCode } from '../client/tools/ControlPacket';
import { AdbKeySerialData } from '../helper/AdbKeyManager';
import { Device } from '../entity/Device';

// Worker 消息类型定义
export enum WorkerMessageType {
  // 主线程 -> Worker
  INIT = 'init',
  INIT_VIDEO_DECODER = 'init_video_decoder',
  INIT_AUDIO_DECODER = 'init_audio_decoder',
  SEND_TOUCH = 'send_touch',
  SEND_KEY = 'send_key',
  SEND_CLIPBOARD = 'send_clipboard',
  HANDLE_ACTION = 'handle_action',
  CLOSE = 'close',

  // Worker -> 主线程
  STATUS_UPDATE = 'status_update',
  CONNECTED = 'connected',
  DISCONNECTED = 'disconnected',
  ERROR = 'error',
  VIDEO_CONFIG = 'video_config',
  FIRST_FRAME = 'first_frame',
  CLIPBOARD_RECEIVED = 'clipboard_received',
  AUTH_REQUIRED = 'auth_required',
}

// 消息接口
export interface WorkerMessage {
  type: WorkerMessageType;
  data?: ESObject;
}

// 触摸事件数据
export interface TouchEventData {
  action: TouchAction;
  pointerId: number;
  x: number;
  y: number;
  screenWidth: number;
  screenHeight: number;
  pressure?: number;
}

// 按键事件数据
export interface KeyEventData {
  keyCode: KeyCode;
  metaState?: number;
}

// 初始化数据（使用预加载的可序列化数据）
export interface InitData {
  device: Device;
  adbKeyData: AdbKeySerialData;       // 主线程预加载的 ADB 密钥数据
  serverJarData?: ArrayBuffer;  // 主线程预加载的 server.jar 二进制
}

// 视频解码器初始化数据
export interface VideoDecoderInitData {
  surfaceId: string;
}

// 音频解码器初始化数据
export interface AudioDecoderInitData {
  codecType?: string;
  sampleRate?: number;
  channelCount?: number;
}

// 剪贴板数据
export interface ClipboardData {
  text: string;
  paste?: boolean;
}

// 动作数据
export interface ActionData {
  action: string;
  data?: ArrayBuffer;
}
