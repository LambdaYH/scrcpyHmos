// ServerManager - 服务端管理器
// Scrcpy官方服务端启动逻辑
import { Adb } from '../adb/Adb';
import { BufferStream } from '../buffer/BufferStream';
import { Device } from '../entity/Device';
import { buffer, util } from '@kit.ArkTS';

// 服务器启动结果
export interface ServerStartResult {
  shellStream: BufferStream;
  scid: string; // 8位十六进制字符串
}

export class ServerManager {
  // Scrcpy版本号 - 必须与rawfile中的服务端版本匹配
  private static readonly SCRCPY_VERSION = '3.3.4';
  // 服务端文件名包含版本号，确保版本更新后不混淆
  private static readonly SERVER_PATH = `/data/local/tmp/scrcpy-server-${ServerManager.SCRCPY_VERSION}`;
  
  // 最后生成的SCID
  private static lastScid: string = '';

  // 获取当前Scrcpy版本
  static getVersion(): string {
    return ServerManager.SCRCPY_VERSION;
  }

  // 检查服务端是否存在
  static async checkServerExists(adb: Adb): Promise<boolean> {
    try {
      // 使用runAdbCmd执行检查命令
      const result = await adb.runAdbCmd(`ls ${ServerManager.SERVER_PATH} && echo FILE_EXISTS || echo FILE_NOT_FOUND`);
      console.debug('Check server result:', result);

      if (result.includes('No such file') || result.includes('FILE_NOT_FOUND')) {
        console.info('Server.jar does NOT exist on device');
        return false;
      }

      if (result.includes(ServerManager.SERVER_PATH) && result.includes('FILE_EXISTS')) {
        console.info('Server.jar exists on device');
        return true;
      }

      console.warn('Could not determine server existence, assuming not exists');
      return false;
    } catch (err) {
      console.error('Check server failed:', err);
      return false;
    }
  }

  // 检查服务端是否存在 - 使用已有的shell stream
  static async checkServerExistsViaStream(stream: BufferStream): Promise<boolean> {
    try {
      const cmd = `ls ${ServerManager.SERVER_PATH} && echo FILE_EXISTS || echo FILE_NOT_FOUND\n`;
      console.info('Checking server with command:', cmd);
      await stream.write(buffer.from(cmd, 'utf-8').buffer);

      // 等待并读取输出
      let output = '';
      const maxAttempts = 10;
      const decoder = util.TextDecoder.create('utf-8');

      for (let i = 0; i < maxAttempts; i++) {
        await new Promise<void>(resolve => setTimeout(resolve, 100));

        try {
          // 检查是否有数据可读
          if (!stream.isEmpty()) {
            const result = await stream.readAllBytes();
            if (result.byteLength > 0) {
              output += decoder.decodeToString(new Uint8Array(result));
              console.info('Check server output:', output);

              // 检查是否有结果
              if (output.includes('No such file')) {
                console.info('Server.jar does NOT exist on device');
                return false;
              }
              if (output.includes(ServerManager.SERVER_PATH) && output.includes('FILE_EXISTS')) {
                console.info('Server.jar exists on device');
                return true;
              }
            }
          }
        } catch (readErr) {
          // 继续尝试
        }
      }

      console.warn('Could not determine server existence, assuming not exists');
      return false;
    } catch (err) {
      console.error('Check server failed:', err);
      return false;
    }
  }

  // 推送服务端jar - 使用Adb.pushFile方法
  static async pushServer(adb: Adb, serverData: ArrayBuffer): Promise<boolean> {
    try {
      console.info(`Pushing server.jar, size: ${serverData.byteLength} bytes`);

      await adb.pushFile(serverData, ServerManager.SERVER_PATH, (progress: number) => {
        if (progress % 10 === 0) {
          // console.info(`Pushing: ${progress}%`);
        }
      });

      console.info('Server.jar pushed successfully, verifying...');

      // 验证文件是否真的存在
      await new Promise<void>(resolve => setTimeout(resolve, 500)); // 等待文件系统同步
      const exists = await ServerManager.checkServerExists(adb);

      if (!exists) {
        console.warn('Verification failed: file does not exist after push');
        throw new Error('File verification failed');
      }

      console.info('Server.jar verified on device');
      return true;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      console.error('Push server failed:', errMsg);

      // 如果sync协议失败，尝试使用shell方式
      console.info('Trying shell-based push method...');
      return await ServerManager.pushServerViaShell(adb, serverData);
    }
  }

  // 通过shell+base64推送文件（更可靠）
  static async pushServerViaShell(adb: Adb, serverData: ArrayBuffer): Promise<boolean> {
    try {
      console.info('Opening shell for file push via base64...');
      const shellStream = await adb.getShell();

      // 删除旧文件
      const rmCmd = `rm -f ${ServerManager.SERVER_PATH}\n`;
      await shellStream.write(buffer.from(rmCmd, 'utf-8').buffer);
      await new Promise<void>(resolve => setTimeout(resolve, 100));

      // 将二进制数据转换为base64
      const base64Data = buffer.from(serverData).toString('base64');
      console.info(`Base64 encoded size: ${base64Data.length} chars`);

      // 分块发送base64数据（避免命令行长度限制）
      const chunkSize = 4000; // base64 字符，不是字节
      const totalChunks = Math.ceil(base64Data.length / chunkSize);

      for (let i = 0; i < totalChunks; i++) {
        const start = i * chunkSize;
        const end = Math.min(start + chunkSize, base64Data.length);
        const chunk = base64Data.substring(start, end);

        // 第一块创建文件，后续追加
        const redirectOp = i === 0 ? '>' : '>>';
        const echoCmd = `echo '${chunk}' ${redirectOp} ${ServerManager.SERVER_PATH}.b64\n`;
        await shellStream.write(buffer.from(echoCmd, 'utf-8').buffer);

        if (i % 5 === 0) {
          const progress = Math.floor((i / totalChunks) * 100);
          // console.info(`Pushing via shell (base64): ${progress}%`);
        }

        // 每10块等待一下，避免缓冲区溢出
        if (i % 10 === 9) {
          await new Promise<void>(resolve => setTimeout(resolve, 50));
        }
      }

      console.info('Base64 data written, decoding...');
      await new Promise<void>(resolve => setTimeout(resolve, 200));

      // 解码base64文件
      const decodeCmd = `base64 -d ${ServerManager.SERVER_PATH}.b64 > ${ServerManager.SERVER_PATH}\n`;
      await shellStream.write(buffer.from(decodeCmd, 'utf-8').buffer);
      await new Promise<void>(resolve => setTimeout(resolve, 500));

      // 删除临时base64文件
      const cleanCmd = `rm -f ${ServerManager.SERVER_PATH}.b64\n`;
      await shellStream.write(buffer.from(cleanCmd, 'utf-8').buffer);
      await new Promise<void>(resolve => setTimeout(resolve, 100));

      // 设置权限
      const chmodCmd = `chmod 755 ${ServerManager.SERVER_PATH}\n`;
      await shellStream.write(buffer.from(chmodCmd, 'utf-8').buffer);
      await new Promise<void>(resolve => setTimeout(resolve, 200));

      // 验证文件大小
      const sizeCmd = `stat -c %s ${ServerManager.SERVER_PATH} 2>/dev/null || wc -c < ${ServerManager.SERVER_PATH}\n`;
      await shellStream.write(buffer.from(sizeCmd, 'utf-8').buffer);
      await new Promise<void>(resolve => setTimeout(resolve, 300));

      shellStream.close();
      console.info('Server.jar pushed successfully via shell, verifying...');

      // 等待文件系统同步后再次验证
      await new Promise<void>(resolve => setTimeout(resolve, 500));
      const exists = await ServerManager.checkServerExists(adb);

      if (!exists) {
        console.error('Verification failed: file does not exist after shell push');
        return false;
      }

      console.info('Server.jar verified on device after shell push');
      return true;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      console.error('Shell push failed:', errMsg);
      return false;
    }
  }

  // 从rawfile加载server
  static async loadServerFromRawfile(context: Context): Promise<ArrayBuffer | null> {
    try {
      const resMgr = context.resourceManager;
      const fileName = `scrcpy-server-v${ServerManager.SCRCPY_VERSION}`;
      console.info(`Loading server from rawfile: ${fileName}`);
      const rawFileData = await resMgr.getRawFileContent(fileName);
      return rawFileData.buffer;
    } catch (err) {
      console.error('Load rawfile failed:', err);
      return null;
    }
  }

  // 生成随机scid（31位非负整数的十六进制表示，避免Java端NumberFormatException）
  private static generateScid(): string {
    // Generate a random integer between 0 and 0x7FFFFFFF (31-bit positive integer)
    const scid = Math.floor(Math.random() * 0x80000000);
    const scidHex = scid.toString(16).padStart(8, '0');
    ServerManager.lastScid = scidHex;
    return scidHex;
  }
  
  // 获取最后生成的SCID（用于连接socket）
  static getLastScid(): string {
    return ServerManager.lastScid;
  }
  
  // 获取socket名称
  static getSocketName(): string {
    return `scrcpy_${ServerManager.lastScid}`;
  }

  // 构建scrcpy启动参数
  static buildServerArgs(device: Device): string {
    const args: string[] = [];

    // 必需参数
    args.push(`scid=${ServerManager.generateScid()}`);

    // 视频参数
    args.push(`video=true`);
    args.push(`video_codec=${device.videoCodec}`);
    args.push(`max_size=${device.maxSize}`);
    args.push(`max_fps=${device.maxFps}`);
    args.push(`video_bit_rate=${device.maxVideoBit}`);
    if (device.crop) {
      args.push(`crop=${device.crop}`);
    }
    if (device.displayId !== 0) {
      args.push(`display_id=${device.displayId}`);
    }

    // 音频参数
    args.push(`audio=${device.isAudio}`);
    if (device.isAudio) {
      args.push(`audio_codec=${device.audioCodec}`);
      args.push(`audio_bit_rate=${device.maxAudioBit}`);
    }

    // 控制和行为参数
    args.push(`control=true`);
    args.push(`tunnel_forward=true`);
    args.push(`show_touches=${device.showTouches}`);
    args.push(`stay_awake=${device.stayAwake}`);
    args.push(`power_off_on_close=${device.powerOffScreenOnClose}`);
    args.push(`clipboard_autosync=${device.clipboardAutosync}`);
    args.push(`downsize_on_error=${device.downsizeOnError}`);
    args.push(`cleanup=true`);

    args.push(`log_level=${device.logLevel}`);
    
    // 元数据参数（用于客户端解析）
    // 官方客户端不传递以下Meta参数，使用默认值(true)。
    // 但为了解决某些设备的握手超时问题，我们需要显式禁用send_dummy_byte。
    // args.push(`send_device_meta=true`);
    // args.push(`send_frame_meta=true`);
    // args.push(`send_codec_meta=true`);
    
    // args.push(`send_dummy_byte=false`);

    return args.join(' ');
  }

  // 启动服务端 - 返回shell stream和scid
  static async startServer(adb: Adb, device: Device): Promise<ServerStartResult> {
    const stream = await adb.getShell();

    // 构建参数
    const params = ServerManager.buildServerArgs(device);

    // 官方scrcpy启动命令格式:
    // app_process -Djava.class.path=<jar_path> / com.genymobile.scrcpy.Server <version> <args...>
    const cmd = `CLASSPATH=${ServerManager.SERVER_PATH} app_process / com.genymobile.scrcpy.Server ${ServerManager.SCRCPY_VERSION} ${params}\n`;

    console.info('Starting scrcpy server with command:', cmd);
    await stream.write(buffer.from(cmd, 'utf-8').buffer);
    console.debug('Server started with scrcpy version:', ServerManager.SCRCPY_VERSION);
    
    return {
      shellStream: stream,
      scid: ServerManager.lastScid
    };
  }

  // 停止服务端
  static async stopServer(adb: Adb): Promise<void> {
    try {
      await adb.runAdbCmd('pkill -f scrcpy');
    } catch (err) {
      console.error('Stop server failed:', err);
    }
  }
}
