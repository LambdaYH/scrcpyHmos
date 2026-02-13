/*
 * NativeStreamClient.ets
 * 
 * Manages the native stream connection for Scrcpy.
 * Replaces the original ArkTS Worker-based stream management.
 * 
 * Workflow:
 * 1. Uses ClientStream (ArkTS) to connect ADB, push server, and start server.
 * 2. Creates a NEW, separate socket connection to ADB for streaming.
 * 3. Passes the socket FD to Native layer.
 * 4. Exports ADB keys to temp files and authenticates Native ADB.
 * 5. Establishes multiplexed streams (Video, Audio, Control) via Native ADB.
 * 6. Starts native processing threads.
 */

import { Device } from '../../entity/Device';
import { ClientStream } from './ClientStream';
// Import as any/unknown first to allow casting
import * as libscrcpy from 'libscrcpy_native.so';
import { AdbKeyManager } from '../../helper/AdbKeyManager';
import { ServerManager } from '../../helper/ServerManager';
import fs from '@ohos.file.fs';
import socket from '@ohos.net.socket';
import { LoggerClientStream } from '../../helper/Logger';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';


export interface NativeStreamListener {
  onVideoConfig: (width: number, height: number) => void;
  onAudioConfig: (codec: string) => void;
  onDisconnect: (reason: string) => void;
  onError: (error: string) => void;
  onClipboard: (text: string) => void;
  onWaitAuth?: () => void;
}

export class NativeStreamClient {
  private clientStream: ClientStream;
  private device: Device;
  private context: Context;
  private adbId: number = -1;
  private listener?: NativeStreamListener;
  
  // Stream IDs
  private videoStreamId: number = -1;
  private audioStreamId: number = -1;
  private controlStreamId: number = -1;

  // Socket
  private nativeSocket?: socket.TCPSocket;

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

      // 1. Prepare Server (ArkTS side)
      // This ensures scrcpy-server is running on the device
      // 1. Prepare Server (ArkTS side)
      // This ensures scrcpy-server is running on the device
      await this.clientStream.prepareServerForNative(this.context, serverJarData, () => {
          LoggerClientStream.info('[NativeStreamClient] onWaitAuth callback received from ClientStream');
          if (this.listener && this.listener.onWaitAuth) {
              this.listener.onWaitAuth();
          }
      });

      // 2. Connect Native ADB
      // Establish a dedicated connection for streaming
      await this.connectNativeAdb();

      // 3. Open Streams (Video, Audio, Control)
      await this.openNativeStreams();

      // 4. Start Native Processing
      this.startNativeProcessing(surfaceId);

      LoggerClientStream.info('[NativeStreamClient] Session started successfully');
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.error('[NativeStreamClient] Start failed:', errMsg);
      this.stop(); // Cleanup
      // Don't call listener.onError here, let the caller handle the promise rejection
      throw (err instanceof Error) ? err : new Error(String(err));
    }
  }

  // Stop the session
  stop(): void {
    try {
      LoggerClientStream.info('[NativeStreamClient] Stopping session...');
      
      // Stop native streams
      libscrcpy.nativeStopStreams();

      // Close native ADB connection
      if (this.adbId >= 0) {
        libscrcpy.adbClose(this.adbId);
        this.adbId = -1;
      }

      // Close socket
      if (this.nativeSocket) {
        // 关闭socket
        /*
        try {
          this.nativeSocket.close(); // AdbNative close might already close FD?
        } catch (e) {}
        */
        // Note: libscrcpy.adbClose closes the FD. 
        // We should just release the ArkTS object reference.
        this.nativeSocket = undefined;
      }

      // Stop ArkTS client stream (closes shell stream)
      this.clientStream.close();

    } catch (err) {
      LoggerClientStream.error('[NativeStreamClient] Stop error:', err);
    }
  }

  // Send control message (e.g. touch event)
  sendControl(data: ArrayBuffer): void {
    try {
      libscrcpy.nativeSendControl(data);
    } catch (err) {
      LoggerClientStream.error('[NativeStreamClient] Send control failed:', err);
    }
  }

  private async connectNativeAdb(): Promise<void> {
    LoggerClientStream.info('[NativeStreamClient] Establishing native ADB connection...');

    const ip = this.device.address;
    const port = this.device.adbPort;

    LoggerClientStream.info(`[NativeStreamClient] Connecting to ${ip}:${port} via Native C++...`);

    // Call native adbCreate with IP and Port directly
    // This avoids ArkTS socket ownership issues where data might be read away by the runtime
    this.adbId = await libscrcpy.adbCreate(ip, port);
    
    if (this.adbId < 0) {
        throw new Error(`Native ADB Create/Connect failed to ${ip}:${port}`);
    }
    
    LoggerClientStream.info(`[NativeStreamClient] Native ADB instance created: ${this.adbId}`);

    // 2. Authenticate
    // We need to write keys to temp files for native layer to read
    const keyManager = AdbKeyManager.getInstance();
    const tempDir = this.context.tempDir;
    const pubKeyPath = tempDir + '/temp_adbkey.pub';
    const priKeyPath = tempDir + '/temp_adbkey';

    try {
        // Write Public Key (ADB Format + Comment)
        const pubKeyBytes = keyManager.getPublicKeyBytes();
        const pubFile = fs.openSync(pubKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(pubFile.fd, pubKeyBytes as ArrayBuffer);
        fs.closeSync(pubFile);

        // Write Private Key (PEM Format)
        const priKeyBase64 = keyManager.getPrivateKey();
        const pemContent = "-----BEGIN PRIVATE KEY-----\n" + priKeyBase64 + "\n-----END PRIVATE KEY-----";

        const priFile = fs.openSync(priKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(priFile.fd, pemContent);
        fs.closeSync(priFile);

        LoggerClientStream.info(`[NativeStreamClient] Keys written to temp: ${pubKeyPath}`);

        // Call Native Connect with onWaitAuth callback
        const res: number = await libscrcpy.adbConnect(this.adbId, pubKeyPath, priKeyPath, () => {
            LoggerClientStream.info('[NativeStreamClient] onWaitAuth callback received from native');
            if (this.listener && this.listener.onWaitAuth) {
                this.listener.onWaitAuth();
            }
        });
        
        // Clean up keys (optional, maybe keep them for debugging or next time?)
        // fs.unlinkSync(pubKeyPath);
        // fs.unlinkSync(priKeyPath);

        if (res !== 0) { // 0=OK
             if (res === -2) {
                 throw new Error('app.string.connect_timeout_toast');
             } else if (res === -3) {
                 throw new Error('app.string.adb_auth_failed');
             } else {
                 throw new Error(`Native ADB Connect failed with code ${res}`);
             }
        }
        LoggerClientStream.info('[NativeStreamClient] Native ADB Authenticated');

    } catch (err) {
        LoggerClientStream.error('[NativeStreamClient] Auth failed:', JSON.stringify(err));
        throw (err instanceof Error) ? err : new Error(String(err));
    }
  }

  private async openNativeStreams(): Promise<void> {
    const socketName = ServerManager.getSocketName(); // e.g. "scrcpy_12345678"
    LoggerClientStream.info(`[NativeStreamClient] Forwarding streams to localabstract:${socketName}`);

    // 1. Video Stream (Wait for 1st connection behaviour - Dummy Byte handled by native thread)
    // Retry mechanism to wait for server to start listening
    let retries = 50; // 50 * 100ms = 5 seconds
    while (retries > 0) {
      this.videoStreamId = libscrcpy.adbLocalSocketForward(this.adbId, socketName);
      if (this.videoStreamId >= 0) {
        break;
      }
      retries--;
      if (retries === 0) {
        throw new Error("Failed to connect Video stream after multiple retries");
      }
      LoggerClientStream.warn(`[NativeStreamClient] Video stream connect failed, retrying... (${retries} left)`);
      await new Promise<void>(resolve => setTimeout(resolve, 100));
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

  private startNativeProcessing(surfaceId: string): void {
    LoggerClientStream.info('[NativeStreamClient] Starting native threads...');
    
    // Callback to handle events from C++
    const eventCallback = (type: string, data: string) => {
        if (!this.listener) return;

        switch (type) {
            case 'video_config':
                try {
                    interface VideoConfig { width: number; height: number; }
                    const config = JSON.parse(data) as VideoConfig;
                    this.listener.onVideoConfig(config.width, config.height);
                } catch (e) {
                    LoggerClientStream.error('Parse video config failed:', JSON.stringify(e));
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
                break;
        }
    };

    // Defaults
    const videoWidth = 0; // Decoder will determine from stream
    const videoHeight = 0;
    const audioSampleRate = 48000;
    const audioChannels = 2;

        const res: number = libscrcpy.nativeStartStreams(
        this.adbId,
        this.videoStreamId,
        this.audioStreamId, // -1 if disabled
        this.controlStreamId,
        surfaceId,
        videoWidth,
        videoHeight,
        audioSampleRate,
        audioChannels,
        eventCallback
    );

    if (res !== 0) {
        throw new Error(`nativeStartStreams failed with code ${res}`);
    }
  }
}
