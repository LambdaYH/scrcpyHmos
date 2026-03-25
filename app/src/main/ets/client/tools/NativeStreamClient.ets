import { Device } from '../../entity/Device';
import { ClientStream } from './ClientStream';
import { ControlPacket } from './ControlPacket';
import * as libscrcpy from 'libscrcpy_native.so';
import { ServerManager } from '../../helper/ServerManager';
import { LoggerClientStream } from '../../helper/Logger';

export interface NativeStreamListener {
  onVideoConfig: (width: number, height: number) => void;
  onDisconnect: (reason: string) => void;
  onError: (error: string) => void;
  onClipboard: (text: string) => void;
  onFirstFrame?: () => void;
  onWaitAuth?: () => void;
}

type NativeEventCallback = (type: string, data: string) => void;
type NativeStartReverseStreamsFn = (
  adbId: number,
  expectVideo: boolean,
  expectAudio: boolean,
  expectControl: boolean,
  surfaceId: string,
  audioSampleRate: number,
  audioChannelCount: number,
  callback: NativeEventCallback
) => number;
type AdbReverseFn = (adbId: number, socketName: string, port: number) => number;
type AdbReverseRemoveFn = (adbId: number, socketName: string) => number;

export class NativeStreamClient {
  private static readonly REVERSE_READY_TIMEOUT_MS: number = 10000;
  private static readonly FORWARD_CONNECT_RETRY_DELAY_MS: number = 100;
  private static readonly FALLBACK_SERVER_COOLDOWN_MS: number = 300;
  private clientStream: ClientStream;
  private device: Device;
  private context: Context;
  private adbId: number = -1;
  private listener?: NativeStreamListener;
  private reverseReadyPending: boolean = false;
  private reverseReadyResolve?: () => void;
  private reverseReadyReject?: (error: Error) => void;
  
  // Stream IDs
  private videoStreamId: number = -1;
  private audioStreamId: number = -1;
  private controlStreamId: number = -1;

  constructor(context: Context, device: Device, listener?: NativeStreamListener) {
    this.context = context;
    this.device = device;
    this.listener = listener;
    this.clientStream = new ClientStream(device);
  }

  // Start the session
  async start(serverJarData: ArrayBuffer | null, surfaceId: string): Promise<void> {
    try {
      LoggerClientStream.info('[NativeStreamClient] Starting session...');

      // 1. Prepare the server and reuse the connected ADB session.
      this.adbId = await this.clientStream.prepareServerForNative(this.context, serverJarData, () => {
          LoggerClientStream.info('[NativeStreamClient] onWaitAuth callback received from ClientStream');
          if (this.listener && this.listener.onWaitAuth) {
              this.listener.onWaitAuth();
          }
      });
      
      LoggerClientStream.info(`[NativeStreamClient] Reusing ADB connection ID: ${this.adbId}`);

      const eventCallback = this.createNativeEventCallback();
      if (this.device.forceAdbForward) {
        LoggerClientStream.info('[NativeStreamClient] Tunnel mode: force-adb-forward enabled');
      } else {
        LoggerClientStream.info('[NativeStreamClient] Tunnel mode: trying reverse first');
      }
      const reverseStarted = this.device.forceAdbForward
        ? false
        : await this.tryStartReverse(surfaceId, eventCallback);
      if (!reverseStarted) {
        LoggerClientStream.info('[NativeStreamClient] Tunnel mode: using forward');
        const args = ServerManager.buildServerArgs(this.device, true);
        this.clientStream.startServer(args);
        await this.openNativeStreams();
        this.startNativeProcessing(surfaceId, eventCallback);
      }

      if (this.device.lightOffOnConnect) {
        LoggerClientStream.info('[NativeStreamClient] Requesting device screen off after connection');
        this.sendControl(ControlPacket.createSetDisplayPower(false));
      }

      LoggerClientStream.info('[NativeStreamClient] Session started successfully');
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.error('[NativeStreamClient] Start failed:', errMsg);
      this.stop();
      throw (err instanceof Error) ? err : new Error(String(err));
    }
  }

  // Stop the session
  stop(): void {
    try {
      LoggerClientStream.info('[NativeStreamClient] Stopping session...');
      this.rejectReverseReady(new Error('Session stopped'));
      
      try {
        libscrcpy.nativeStopStreams();
      } catch (e) {
        LoggerClientStream.error('[NativeStreamClient] nativeStopStreams failed:', e);
      }

      this.adbId = -1;

      if (this.clientStream) {
        try {
          this.clientStream.close();
        } catch (e) {
          LoggerClientStream.error('[NativeStreamClient] clientStream close failed:', e);
        }
      }

    } catch (err) {
      LoggerClientStream.error('[NativeStreamClient] Stop global error:', err);
    }
  }

  private async tryStartReverse(
    surfaceId: string,
    eventCallback: NativeEventCallback
  ): Promise<boolean> {
    const reverseArgs = ServerManager.buildServerArgs(this.device, false);
    const socketName = ServerManager.getSocketName();
    LoggerClientStream.info(`[NativeStreamClient] Tunnel mode: preparing reverse for localabstract:${socketName}`);

    const reversePort: number = this.callNativeStartReverseStreams(
      this.adbId,
      true,
      this.device.isAudio,
      true,
      surfaceId,
      48000,
      2,
      eventCallback
    );

    if (reversePort <= 0) {
      LoggerClientStream.warn(`[NativeStreamClient] Reverse listener start failed: ${reversePort}, fallback to forward`);
      libscrcpy.nativeStopStreams();
      return false;
    }

    const reverseResult: number = this.callAdbReverse(this.adbId, socketName, reversePort);
    if (reverseResult !== 0) {
      LoggerClientStream.warn(`[NativeStreamClient] adb reverse failed: ${reverseResult}, fallback to forward`);
      libscrcpy.nativeStopStreams();
      return false;
    }

    LoggerClientStream.info(`[NativeStreamClient] Tunnel mode: using reverse (localabstract:${socketName} -> tcp:${reversePort})`);
    const reverseReadyPromise = this.waitForReverseReady();
    this.clientStream.startServer(reverseArgs);
    try {
      await reverseReadyPromise;
      return true;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.warn(`[NativeStreamClient] Reverse startup incomplete: ${errMsg}, fallback to forward`);
      await this.clientStream.stopServerAndWait();
      this.callAdbReverseRemove(this.adbId, socketName);
      libscrcpy.nativeStopStreams();
      await new Promise<void>(resolve => setTimeout(resolve, NativeStreamClient.FALLBACK_SERVER_COOLDOWN_MS));
      return false;
    }
  }

  // Send control message (e.g. touch event)
  sendControl(data: ArrayBuffer): boolean {
    try {
      return libscrcpy.nativeSendControl(data);
    } catch (err) {
      LoggerClientStream.error('[NativeStreamClient] Send control failed:', err);
      return false;
    }
  }

  private async openNativeStreams(): Promise<void> {
    const socketName = ServerManager.getSocketName(); // e.g. "scrcpy_12345678"
    LoggerClientStream.info(`[NativeStreamClient] Tunnel mode: forward streams to localabstract:${socketName}`);

    // Retry while waiting for the server to listen on the abstract socket.
    let retries = 50; // 50 * 100ms = 5 seconds
    while (retries > 0) {
      this.videoStreamId = libscrcpy.adbLocalSocketForward(this.adbId, socketName);
      if (this.videoStreamId >= 0) {
        break;
      }
      if (!this.clientStream.isServerShellAlive()) {
        throw new Error('Scrcpy server exited before video socket became ready');
      }
      retries--;
      if (retries === 0) {
        throw new Error("Failed to connect Video stream after multiple retries");
      }
      LoggerClientStream.warn(`[NativeStreamClient] Video stream connect failed, retrying... (${retries} left)`);
      await new Promise<void>(resolve => setTimeout(resolve, NativeStreamClient.FORWARD_CONNECT_RETRY_DELAY_MS));
    }
    
    LoggerClientStream.info(`[NativeStreamClient] Video Stream Connected (ID: ${this.videoStreamId})`);

    // 2. Audio Stream
    if (this.device.isAudio) {
        this.audioStreamId = libscrcpy.adbLocalSocketForward(this.adbId, socketName);
        if (this.audioStreamId < 0) {
            LoggerClientStream.warn("Failed to connect Audio stream, disabling audio");
            this.audioStreamId = -1;
        } else {
            LoggerClientStream.info(`[NativeStreamClient] Audio Stream Connected (ID: ${this.audioStreamId})`);
        }
    }

    // 3. Control Stream
    this.controlStreamId = libscrcpy.adbLocalSocketForward(this.adbId, socketName);
    if (this.controlStreamId < 0) throw new Error("Failed to connect Control stream");
    LoggerClientStream.info(`[NativeStreamClient] Control Stream Connected (ID: ${this.controlStreamId})`);
  }

  private createNativeEventCallback(): NativeEventCallback {
    return (type: string, data: string) => {
        switch (type) {
            case 'reverse_ready':
                this.resolveReverseReady();
                return;
            case 'disconnected':
                if (this.reverseReadyPending) {
                    this.rejectReverseReady(new Error('Reverse disconnected before ready'));
                    return;
                }
                break;
            case 'error':
                if (this.reverseReadyPending) {
                    this.rejectReverseReady(new Error(data));
                    return;
                }
                break;
        }

        if (!this.listener) {
            return;
        }

        switch (type) {
            case 'video_config':
            case 'video_size_changed':
                try {
                    interface VideoConfig { width: number; height: number; }
                    const config = JSON.parse(data) as VideoConfig;
                    if (type === 'video_size_changed') {
                        LoggerClientStream.info(`[NativeStreamClient] Dynamic Video Size Changed: ${config.width}x${config.height}`);
                    }
                    this.listener.onVideoConfig(config.width, config.height);
                } catch (e) {
                    LoggerClientStream.error('Parse video config/size failed:', JSON.stringify(e));
                }
                break;
            case 'clipboard':
                this.listener.onClipboard(data);
                break;
            case 'disconnected':
                this.listener.onDisconnect('Server Disconnected');
                break;
            case 'error':
                this.listener.onError(data);
                break;
            case 'first_frame':
                LoggerClientStream.info('First frame received');
                if (this.listener.onFirstFrame) {
                    this.listener.onFirstFrame();
                }
                break;
        }
    };
  }

  private startNativeProcessing(
    surfaceId: string,
    eventCallback: NativeEventCallback
  ): void {
    LoggerClientStream.info('[NativeStreamClient] Starting native threads...');

    const res: number = libscrcpy.nativeStartStreams(
        this.adbId,
        this.videoStreamId,
        this.audioStreamId, // -1 if disabled
        this.controlStreamId,
        surfaceId,
        48000,
        2,
        eventCallback
    );

    if (res !== 0) {
        throw new Error(`nativeStartStreams failed with code ${res}`);
    }
  }

  private callNativeStartReverseStreams(
    adbId: number,
    expectVideo: boolean,
    expectAudio: boolean,
    expectControl: boolean,
    surfaceId: string,
    audioSampleRate: number,
    audioChannelCount: number,
    callback: NativeEventCallback
  ): number {
    const nativeStartReverseStreams = libscrcpy.nativeStartReverseStreams as NativeStartReverseStreamsFn;
    return nativeStartReverseStreams(
      adbId,
      expectVideo,
      expectAudio,
      expectControl,
      surfaceId,
      audioSampleRate,
      audioChannelCount,
      callback
    );
  }

  private callAdbReverse(adbId: number, socketName: string, port: number): number {
    const adbReverse = libscrcpy.adbReverse as AdbReverseFn;
    return adbReverse(adbId, socketName, port);
  }

  private callAdbReverseRemove(adbId: number, socketName: string): number {
    const adbReverseRemove = libscrcpy.adbReverseRemove as AdbReverseRemoveFn;
    return adbReverseRemove(adbId, socketName);
  }

  private waitForReverseReady(): Promise<void> {
    this.rejectReverseReady(new Error('Restarting reverse wait'));
    this.reverseReadyPending = true;

    return new Promise<void>((resolve, reject) => {
      const timeoutId: number = setTimeout(() => {
        this.rejectReverseReady(new Error('Timed out waiting for reverse sockets'));
      }, NativeStreamClient.REVERSE_READY_TIMEOUT_MS) as number;

      this.reverseReadyResolve = () => {
        clearTimeout(timeoutId);
        this.reverseReadyPending = false;
        this.reverseReadyResolve = undefined;
        this.reverseReadyReject = undefined;
        resolve();
      };

      this.reverseReadyReject = (error: Error) => {
        clearTimeout(timeoutId);
        this.reverseReadyPending = false;
        this.reverseReadyResolve = undefined;
        this.reverseReadyReject = undefined;
        reject(error);
      };
    });
  }

  private resolveReverseReady(): void {
    if (!this.reverseReadyPending || !this.reverseReadyResolve) {
      return;
    }
    this.reverseReadyResolve();
  }

  private rejectReverseReady(error: Error): void {
    if (!this.reverseReadyPending || !this.reverseReadyReject) {
      return;
    }
    this.reverseReadyReject(error);
  }
}
