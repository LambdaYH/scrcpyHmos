declare module 'libscrcpy_native.so' {
    // Audio decoder
    export function createAudioDecoder(): number;
    export function initAudioDecoder(id: number, codecType: string, sampleRate: number, channelCount: number): number;
    export function startAudioDecoder(id: number): number;
    export function releaseAudioDecoder(id: number): void;

    // Video decoder
    export function createVideoDecoder(): number;
    export function initVideoDecoder(id: number, codecType: string, surfaceId: string, width: number, height: number): number;
    export function startVideoDecoder(id: number): number;
    export function releaseVideoDecoder(id: number): void;

    // Video stream processor
    export function createVideoStreamProcessor(decoderId: number, codecType: string): number;
    export function startVideoStreamProcessor(processorId: number): number;
    export function pushVideoStreamData(processorId: number, data: ArrayBuffer, pts: number, flags: number): number;
    export function releaseVideoStreamProcessor(processorId: number): void;

    // Audio stream processor
    export function createAudioStreamProcessor(decoderId: number, codecType: string, sampleRate: number, channelCount: number): number;
    export function startAudioStreamProcessor(processorId: number): number;
    export function pushAudioStreamData(processorId: number, data: ArrayBuffer, pts: number): number;
    export function releaseAudioStreamProcessor(processorId: number): void;
}
