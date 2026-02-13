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
import * as libscrcpyAny from 'libscrcpy_native.so';
import { AdbKeyManager } from '../../helper/AdbKeyManager';
import { ServerManager } from '../../helper/ServerManager';
import fs from '@ohos.file.fs';
import socket from '@ohos.net.socket';
import { LoggerClientStream } from '../../helper/Logger';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

// Define explicit interface to avoid 'any' type errors if .d.ts is not picked up
interface ScrcpyNativeModule {
  adbCreate(fd: number): number;
  adbConnect(adbId: number, pubKeyPath: string, priKeyPath: string): number;
  adbLocalSocketForward(adbId: number, socketName: string): number;
  adbClose(adbId: number): void;
  nativeStartStreams(
    adbId: number,
    videoStreamId: number,
    audioStreamId: number,
    controlStreamId: number,
    surfaceId: string,
    videoWidth: number,
    videoHeight: number,
    audioSampleRate: number,
    audioChannelCount: number,
    callback: (type: string, data: string) => void
  ): number;
  nativeStopStreams(): void;
  nativeSendControl(data: ArrayBuffer): void;
}

// Cast the imported module to the interface
const libscrcpy = libscrcpyAny as Object as ScrcpyNativeModule;

export interface NativeStreamListener {
  onVideoConfig: (width: number, height: number) => void;
  onAudioConfig: (codec: string) => void;
  onDisconnect: (reason: string) => void;
  onError: (error: string) => void;
  onClipboard: (text: string) => void;
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
      const ready = await this.clientStream.prepareServerForNative(this.context, serverJarData);
      if (!ready) {
        throw new Error("Failed to prepare scrcpy server");
      }

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
      if (this.listener) {
        this.listener.onError(errMsg);
      }
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

    // 1. Create Socket
    this.nativeSocket = socket.constructTCPSocketInstance();
    const address: socket.NetAddress = {
      address: this.device.address,
      port: this.device.adbPort,
      family: 1 // IPv4
    };
    
    await this.nativeSocket.connect({ address: address });
    LoggerClientStream.info(`[NativeStreamClient] Connected to ${this.device.address}:${this.device.adbPort}`);

    // 2. Get FD
    let fd = -1;
    try {
       // Use type assertion to access getSocketFd via Object
       // Note: getSocketFd() returns a Promise<number>, must await
       const rawSocket = this.nativeSocket as Object as Record<string, Object>;
       if (typeof rawSocket.getSocketFd === 'function') {
         fd = await (rawSocket.getSocketFd as Function)() as number;
       } else {
         // Try accessing via property if method doesn't exist (hack)
         fd = (rawSocket['fd'] as number) || -1;
       }
    } catch (e) {
      LoggerClientStream.error('[NativeStreamClient] Failed to get socket FD:', e);
    }

    if (fd < 0) {
      throw new Error("Failed to retrieve valid socket file descriptor. Platform not supported?");
    }
    LoggerClientStream.info(`[NativeStreamClient] Got Socket FD: ${fd}`);

    // 3. Create Native ADB Instance
    this.adbId = libscrcpy.adbCreate(fd);
    if (this.adbId < 0) {
      throw new Error("Failed to create native ADB instance");
    }

    // 4. Authenticate
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
        // Native AdbKeyPair expects PEM
        const base64Helper = new util.Base64Helper();
        const priKeyBase64 = keyManager.getPrivateKey();
        
        let pemContent = "-----BEGIN PRIVATE KEY-----\n";
        // Simple manual formatting to add newlines every 64 chars is respectful but not strictly required for all parsers
        // But let's just write the whole base64 blob, most parsers handle it.
        // Better: AdbKeyPair.cpp handles cleaning newlines, so one line is fine.
        pemContent += priKeyBase64;
        pemContent += "\n-----END PRIVATE KEY-----";

        const priFile = fs.openSync(priKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(priFile.fd, pemContent);
        fs.closeSync(priFile);

        LoggerClientStream.info(`[NativeStreamClient] Keys written to temp: ${pubKeyPath}`);

        // Call Native Connect
        const res = libscrcpy.adbConnect(this.adbId, pubKeyPath, priKeyPath);
        
        // Clean up keys
        try {
            fs.unlinkSync(pubKeyPath);
            fs.unlinkSync(priKeyPath);
        } catch (e) {}

        if (res !== 0) {
            throw new Error(`Native ADB Connect failed with code ${res}`);
        }
        LoggerClientStream.info('[NativeStreamClient] Native ADB Authenticated');

    } catch (err) {
        LoggerClientStream.error('[NativeStreamClient] Auth failed:', err);
        throw (err instanceof Error) ? err : new Error(String(err));
    }
  }

  private async openNativeStreams(): Promise<void> {
    const socketName = ServerManager.getSocketName(); // e.g. "scrcpy_12345678"
    LoggerClientStream.info(`[NativeStreamClient] Forwarding streams to localabstract:${socketName}`);

    // 1. Video Stream (Wait for 1st connection behaviour - Dummy Byte handled by native thread)
    this.videoStreamId = libscrcpy.adbLocalSocketForward(this.adbId, socketName);
    if (this.videoStreamId < 0) throw new Error("Failed to connect Video stream");
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
                    LoggerClientStream.error('Parse video config failed:', e);
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

    const res = libscrcpy.nativeStartStreams(
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
