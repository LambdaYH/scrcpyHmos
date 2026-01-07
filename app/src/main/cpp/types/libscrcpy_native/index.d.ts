export const createDecoder: () => number;
export const initDecoder: (decoderId: number, useH265: boolean, surfaceId: string, width: number, height: number) => number;
export const startDecoder: (decoderId: number) => number;
export const pushData: (decoderId: number, data: ArrayBuffer, pts: number) => number;
export const releaseDecoder: (decoderId: number) => void;
