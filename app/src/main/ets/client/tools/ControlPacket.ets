import { buffer } from '@kit.ArkTS';

// Action 常量 - 对应 Java ClientController.handleAction
export class Action {
  // 界面切换
  static readonly CHANGE_TO_SMALL = "changeToSmall";
  static readonly CHANGE_TO_FULL = "changeToFull";
  static readonly CHANGE_TO_MINI = "changeToMini";
  static readonly CHANGE_TO_APP = "changeToApp";

  // 按钮操作
  static readonly BUTTON_POWER = "buttonPower";
  static readonly BUTTON_WAKE = "buttonWake";
  static readonly BUTTON_LOCK = "buttonLock";
  static readonly BUTTON_LIGHT = "buttonLight";
  static readonly BUTTON_LIGHT_OFF = "buttonLightOff";
  static readonly BUTTON_BACK = "buttonBack";
  static readonly BUTTON_HOME = "buttonHome";
  static readonly BUTTON_SWITCH = "buttonSwitch";
  static readonly BUTTON_ROTATE = "buttonRotate";

  // 系统操作
  static readonly KEEP_ALIVE = "keepAlive";
  static readonly CHECK_SIZE_AND_SITE = "checkSizeAndSite";
  static readonly CHECK_CLIP_BOARD = "checkClipBoard";
  static readonly UPDATE_SITE = "updateSite";
  static readonly WRITE_BYTE_BUFFER = "writeByteBuffer";
  static readonly UPDATE_MAX_SIZE = "updateMaxSize";
  static readonly UPDATE_VIDEO_SIZE = "updateVideoSize";
  static readonly RUN_SHELL = "runShell";
  static readonly SET_CLIP_BOARD = "setClipBoard";
  static readonly CLOSE = "close";
}

// 控制包工具类 - 完全对应Java ControlPacket.java
// 注意：Java ByteBuffer默认是大端序(big-endian)
export class ControlPacket {
  // 触摸事件 - 类型1
  // Java: 1 + action(1) + pointerId(1) + x(4) + y(4) + offsetTime(4) = 15字节
  static createTouchEvent(action: number, pointerId: number, x: number, y: number, offsetTime: number): ArrayBuffer {
    // 边界检查
    if (x < 0) x = 0;
    if (x > 1) x = 1;
    if (y < 0) y = 0;
    if (y > 1) y = 1;
    
    const buf = new ArrayBuffer(15);
    const view = new DataView(buf);
    view.setUint8(0, 1);  // 触摸事件类型
    view.setUint8(1, action);
    view.setUint8(2, pointerId);
    view.setFloat32(3, x, false);  // big-endian
    view.setFloat32(7, y, false);  // big-endian
    view.setInt32(11, offsetTime, false);  // big-endian
    
    return buf;
  }
  
  // 按键事件 - 类型2
  // Java: 2 + key(4) + meta(4) = 9字节
  static createKeyEvent(keyCode: number, metaState: number = 0): ArrayBuffer {
    const buf = new ArrayBuffer(9);
    const view = new DataView(buf);
    view.setUint8(0, 2);  // 按键事件类型
    view.setInt32(1, keyCode, false);  // big-endian
    view.setInt32(5, metaState, false);  // big-endian
    
    return buf;
  }
  
  // 剪贴板事件 - 类型3
  // Java: 3 + length(4) + text(N)
  static createClipboardEvent(text: string): ArrayBuffer {
    const textBytes = buffer.from(text, 'utf-8');
    const textBytesLen: number = textBytes.buffer.byteLength;
    const buf = new ArrayBuffer(5 + textBytesLen);
    const view = new DataView(buf);
    view.setUint8(0, 3);  // 剪贴板事件类型
    view.setInt32(1, textBytesLen, false);  // big-endian
    
    const result = new Uint8Array(buf);
    result.set(new Uint8Array(textBytes.buffer), 5);
    
    return buf;
  }
  
  // 保活包 - 类型4
  static createKeepAliveEvent(): ArrayBuffer {
    const buf = new ArrayBuffer(1);
    const view = new DataView(buf);
    view.setUint8(0, 4);  // 保活事件类型
    return buf;
  }
  
  // 修改分辨率（比例）- 类型5
  // Java: 5 + scale(4) = 5字节
  static createChangeResolutionEvent(scale: number): ArrayBuffer {
    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, 5);  // 分辨率事件类型
    view.setFloat32(1, scale, false);  // big-endian
    return buf;
  }
  
  // 旋转设备 - 类型6
  static createRotateDeviceEvent(): ArrayBuffer {
    const buf = new ArrayBuffer(1);
    const view = new DataView(buf);
    view.setUint8(0, 6);  // 旋转事件类型
    return buf;
  }
  
  // 屏幕背光控制 - 类型7
  // Java: 7 + mode(1) = 2字节
  static createLightEvent(mode: number): ArrayBuffer {
    const buf = new ArrayBuffer(2);
    const view = new DataView(buf);
    view.setUint8(0, 7);  // 背光事件类型
    view.setUint8(1, mode);
    return buf;
  }
  
  // 屏幕电源模式 - 类型8
  // Java: 8 + mode(4) = 5字节
  static createPowerEvent(mode: number): ArrayBuffer {
    const buf = new ArrayBuffer(5);
    const view = new DataView(buf);
    view.setUint8(0, 8);  // 电源事件类型
    view.setInt32(1, mode, false);  // big-endian
    return buf;
  }
  
  // 修改分辨率（具体值）- 类型9
  // Java: 9 + width(4) + height(4) = 9字节
  static createChangeResolutionEventExact(width: number, height: number): ArrayBuffer {
    const buf = new ArrayBuffer(9);
    const view = new DataView(buf);
    view.setUint8(0, 9);  // 具体分辨率事件类型
    view.setInt32(1, width, false);  // big-endian
    view.setInt32(5, height, false);  // big-endian
    return buf;
  }
  
  // 兼容性：旧的屏幕电源控制（映射到LightEvent）
  static createScreenPowerEvent(mode: number): ArrayBuffer {
    return ControlPacket.createLightEvent(mode);
  }
}

// 触摸动作常量 - 对应Android MotionEvent
export enum TouchAction {
  ACTION_DOWN = 0,
  ACTION_UP = 1,
  ACTION_MOVE = 2,
  ACTION_CANCEL = 3,
  ACTION_POINTER_DOWN = 5,
  ACTION_POINTER_UP = 6
}

// 按键码常量 - 对应Android KeyEvent
export enum KeyCode {
  KEYCODE_UNKNOWN = 0,
  KEYCODE_HOME = 3,
  KEYCODE_BACK = 4,
  KEYCODE_CALL = 5,
  KEYCODE_ENDCALL = 6,
  KEYCODE_VOLUME_UP = 24,
  KEYCODE_VOLUME_DOWN = 25,
  KEYCODE_POWER = 26,
  KEYCODE_CAMERA = 27,
  KEYCODE_DPAD_UP = 19,
  KEYCODE_DPAD_DOWN = 20,
  KEYCODE_DPAD_LEFT = 21,
  KEYCODE_DPAD_RIGHT = 22,
  KEYCODE_DPAD_CENTER = 23,
  KEYCODE_ENTER = 66,
  KEYCODE_DEL = 67,
  KEYCODE_MENU = 82,
  KEYCODE_SEARCH = 84,
  KEYCODE_APP_SWITCH = 187
}

// 元键状态
export enum MetaState {
  META_NONE = 0,
  META_ALT_ON = 0x02,
  META_SHIFT_ON = 0x01,
  META_CTRL_ON = 0x1000
}

// 屏幕电源模式
export enum ScreenPowerMode {
  POWER_MODE_OFF = 0,
  POWER_MODE_DOZE = 1,
  POWER_MODE_NORMAL = 2,
  POWER_MODE_DOZE_SUSPEND = 3
}

// 背光模式
export enum LightMode {
  LIGHT_OFF = 0,
  LIGHT_ON = 1,
  LIGHT_TOGGLE = 2
}
