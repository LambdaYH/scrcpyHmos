export const createDecoder: () => number;
export const initDecoder: (decoderId: number, useH265: boolean, surfaceId: string, width: number, height: number) => number;
export const startDecoder: (decoderId: number) => number;
export const pushData: (decoderId: number, data: ArrayBuffer, pts: number) => number;
export const releaseDecoder: (decoderId: number) => void;

// Video Decoder API
export const createVideoDecoder: () => number;
export const initVideoDecoder: (decoderId: number, codecType: string, surfaceId: string, width: number, height: number) => number;
export const startVideoDecoder: (decoderId: number) => number;
export const pushVideoData: (decoderId: number, data: ArrayBuffer, pts: number, flags?: number) => number;
export const releaseVideoDecoder: (decoderId: number) => void;

// Audio Decoder API
export const createAudioDecoder: () => number;
export const initAudioDecoder: (decoderId: number, codecType: string, sampleRate: number, channelCount: number) => number;
export const startAudioDecoder: (decoderId: number) => number;
export const pushAudioData: (decoderId: number, data: ArrayBuffer, pts: number) => number;
export const releaseAudioDecoder: (decoderId: number) => void;

// Video Stream Processor API
export const createVideoStreamProcessor: (decoderId: number, codecType: string) => number;
export const startVideoStreamProcessor: (processorId: number) => number;
export const pushVideoStreamData: (processorId: number, data: ArrayBuffer, pts: number, flags?: number) => number;
export const releaseVideoStreamProcessor: (processorId: number) => void;

// Audio Stream Processor API
export const createAudioStreamProcessor: (decoderId: number, codecType: string, sampleRate: number, channelCount: number) => number;
export const startAudioStreamProcessor: (processorId: number) => number;
export const pushAudioStreamData: (processorId: number, data: ArrayBuffer, pts: number) => number;
export const releaseAudioStreamProcessor: (processorId: number) => void;

// Native Buffer Pool API
export const allocNativeBuffer: (size: number) => ArrayBuffer | undefined;
export const releaseNativeBuffer: (buffer: ArrayBuffer) => void;
export const destroyBufferPool: () => void;
