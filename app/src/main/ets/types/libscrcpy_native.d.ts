declare module 'libscrcpy_native.so' {
    // Audio decoder
    export function createAudioDecoder(): number;
    export function initAudioDecoder(id: number, codecType: string, sampleRate: number, channelCount: number): number;
    export function startAudioDecoder(id: number): number;
    export function pushAudioData(id: number, data: ArrayBuffer, pts: number): number;
    export function releaseAudioDecoder(id: number): void;

    // Video decoder
    export function createVideoDecoder(): number;
    export function initVideoDecoder(id: number, codecType: string, surfaceId: string, width: number, height: number): number;
    export function startVideoDecoder(id: number): number;
    export function pushVideoData(id: number, data: ArrayBuffer, pts: number, flags?: number): number;
    export function releaseVideoDecoder(id: number): void;



    // ADB Module
    export function adbCreate(ip: string, port: number): number;
    export function adbConnect(adbId: number, pubKeyPath: string, priKeyPath: string): number;
    export function adbRunCmd(adbId: number, cmd: string): string;
    export function adbPushFile(adbId: number, data: ArrayBuffer, remotePath: string): void;
    export function adbTcpForward(adbId: number, port: number): number;
    export function adbLocalSocketForward(adbId: number, socketName: string): number;
    export function adbGetShell(adbId: number): number;
    export function adbRestartOnTcpip(adbId: number, port: number): string;
    export function adbStreamRead(adbId: number, streamId: number, size: number): ArrayBuffer;
    export function adbStreamWrite(adbId: number, streamId: number, data: ArrayBuffer): void;
    export function adbStreamClose(adbId: number, streamId: number): void;
    export function adbIsStreamClosed(adbId: number, streamId: number): boolean;
    export function adbClose(adbId: number): void;
    export function adbGenerateKeyPair(pubKeyPath: string, priKeyPath: string): number;
    export function adbIsConnected(adbId: number): boolean;

    // Stream Manager
    export function nativeStartStreams(
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
    export function nativeStopStreams(): void;
    export function nativeSendControl(data: ArrayBuffer): void;
}
