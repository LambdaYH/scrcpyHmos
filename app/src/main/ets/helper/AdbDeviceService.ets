import * as libscrcpy from 'libscrcpy_native.so';
import { NativeStreamClient } from '../client/tools/NativeStreamClient';
import { ClientSessionManager } from './ClientSessionManager';
import { LoggerAdb } from './Logger';

export class AdbDeviceService {
  private static getCurrentClient(): NativeStreamClient {
    const client = ClientSessionManager.getInstance().getCurrentClient();
    if (!client || !client.isAdbReady()) {
      throw new Error('No active ADB session');
    }
    return client;
  }

  static async pushFileFromFd(
    fd: number,
    fileSize: number,
    remotePath: string,
    onProgress?: (progress: number) => void
  ): Promise<void> {
    LoggerAdb.info(`[AdbDeviceService] Push file to ${remotePath}`);
    await AdbDeviceService.getCurrentClient().pushFileFromFd(fd, fileSize, remotePath, onProgress);
  }

  static async execShell(cmd: string): Promise<libscrcpy.AdbShellCommandResult> {
    LoggerAdb.info(`[AdbDeviceService] Exec shell: ${cmd}`);
    return await AdbDeviceService.getCurrentClient().execShell(cmd);
  }

  static async installPackageFromFd(
    fd: number,
    fileSize: number,
    remoteName: string,
    installArgs: string = '-r',
    onProgress?: (progress: number) => void
  ): Promise<libscrcpy.AdbInstallPackageResult> {
    LoggerAdb.info(`[AdbDeviceService] Install package ${remoteName}`);
    return await AdbDeviceService.getCurrentClient().installPackageFromFd(fd, fileSize, remoteName, installArgs, onProgress);
  }
}
