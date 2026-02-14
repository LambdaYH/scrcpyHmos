export const adbCreate: (ip: string, port: number) => number;
export const adbConnect: (adbId: number, pubKeyPath: string, priKeyPath: string) => number;
export const adbRunCmd: (adbId: number, cmd: string) => string;
export const adbPushFile: (adbId: number, data: ArrayBuffer, remotePath: string) => void;
export const adbTcpForward: (adbId: number, port: number) => number;
export const adbLocalSocketForward: (adbId: number, socketName: string) => number;
export const adbGetShell: (adbId: number) => number;
export const adbRestartOnTcpip: (adbId: number, port: number) => string;
export const adbIsStreamClosed: (adbId: number, streamId: number) => boolean;
export const adbIsConnected: (adbId: number) => boolean;
export const nativeStartStreams: (
    adbId: number,
    videoStreamId: number,
    audioStreamId: number,
    controlStreamId: number,
    surfaceId: string,
    videoWidth: number,
    videoHeight: number,
    audioSampleRate: number,
    audioChannelCount: number,
    cb: (type: string, data: string) => void
) => number;
export const nativeStopStreams: () => void;
export const nativeSendControl: (data: ArrayBuffer) => void;
export const adbClose: (adbId: number) => void;
export const adbStreamRead: (adbId: number, streamId: number, size: number) => ArrayBuffer;
export const adbStreamWrite: (adbId: number, streamId: number, data: ArrayBuffer) => void;
export const destroyBufferPool: () => void;
export const createVideoDecoder: () => number;
export const initVideoDecoder: (id: number, type: string, surface: string, width: number, height: number) => number;
export const startVideoDecoder: (id: number) => number;
export const pushVideoData: (id: number, data: ArrayBuffer, pts: number, flags: number) => number;
