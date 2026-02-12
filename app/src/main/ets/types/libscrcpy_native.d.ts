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

    // Native Buffer Pool
    export function allocNativeBuffer(size: number): ArrayBuffer | undefined;
    export function releaseNativeBuffer(buffer: ArrayBuffer): void;
    export function destroyBufferPool(): void;
}
