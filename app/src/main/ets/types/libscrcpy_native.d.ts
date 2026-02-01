declare module 'libscrcpy_native.so' {
    // Audio decoder (legacy mode)
    export function createAudioDecoder(): number;
    export function initAudioDecoder(id: number, codecType: string, sampleRate: number, channelCount: number): number;
    export function startAudioDecoder(id: number): number;
    export function pushAudioData(id: number, data: ArrayBuffer, pts: number): number;
    export function releaseAudioDecoder(id: number): void;

    // Video decoder (legacy mode)
    export function createVideoDecoder(): number;
    export function initVideoDecoder(id: number, codecType: string, surfaceId: string, width: number, height: number): number;
    export function startVideoDecoder(id: number): number;
    export function pushVideoData(id: number, data: ArrayBuffer, pts: number): number;
    export function releaseVideoDecoder(id: number): void;

    // Video stream processor (stream mode)
    export function createVideoStreamProcessor(decoderId: number, codecType: string): number;
    export function startVideoStreamProcessor(processorId: number): number;
    export function pushVideoStreamData(processorId: number, data: ArrayBuffer, pts: number, flags: number): number;
    export function releaseVideoStreamProcessor(processorId: number): void;

    // Audio stream processor (stream mode)
    export function createAudioStreamProcessor(decoderId: number, codecType: string, sampleRate: number, channelCount: number): number;
    export function startAudioStreamProcessor(processorId: number): number;
    export function pushAudioStreamData(processorId: number, data: ArrayBuffer, pts: number): number;
    export function releaseAudioStreamProcessor(processorId: number): void;
}
