import { ErrorEvent, MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

// Scanner module interface for native calls
interface ScannerModule {
  pushVideoStreamData: (id: number, data: ArrayBuffer, pts: number, flags: number) => number;
}

// Declare scanner as global
declare const scanner: ScannerModule;

// Worker message type
interface WorkerMessage {
  type: string;
  streamProcessorId?: number;
  data?: ArrayBuffer;
  pts?: number;
  flags?: number;
}

// Frame queue item interface
interface FrameItem {
  data: ArrayBuffer;
  pts: number;
  flags: number;
}

// Worker response message interface
interface WorkerResponse {
  type: string;
  message?: string;
}

// Worker state
let streamProcessorId: number = 0;
let isRunning: boolean = false;
let isPaused: boolean = false;
let frameQueue: Array<FrameItem> = [];
const MAX_QUEUE_SIZE: number = 100;

/**
 * Push frame to C++ stream processor
 */
function pushFrame(data: ArrayBuffer, pts: number, flags: number): number {
  try {
    const pushResult: number = scanner.pushVideoStreamData(streamProcessorId, data, pts, flags);
    if (pushResult === 0) {
      return 0;
    } else if (pushResult === -2) {
      // Ring buffer full - queue for retry
      if (frameQueue.length < MAX_QUEUE_SIZE) {
        const item: FrameItem = { data: data, pts: pts, flags: flags };
        frameQueue.push(item);
      }
      return -2;
    }
    return pushResult;
  } catch (err) {
    return -1;
  }
}

/**
 * Process queued frames
 */
async function processQueue(): Promise<void> {
  if (isPaused || !isRunning) return;

  while (frameQueue.length > 0 && isRunning && !isPaused) {
    const item: FrameItem | undefined = frameQueue.shift();
    if (!item) break;

    // Small delay between retries
    await sleep(1);

    if (!isRunning || isPaused) break;

    const result: number = pushFrame(item.data, item.pts, item.flags);
    if (result === -2 && frameQueue.length >= MAX_QUEUE_SIZE) {
      frameQueue = [];
    }
  }
}

/**
 * Sleep helper
 */
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

/**
 * Main worker loop for retry processing
 */
async function runRetryLoop(): Promise<void> {
  while (isRunning) {
    if (!isPaused && frameQueue.length > 0) {
      await processQueue();
    }
    await sleep(5);
  }
}

/**
 * Defines the event handler to be called when the worker thread receives a message sent by the host thread.
 * The event handler is executed in the worker thread.
 */
workerPort.onmessage = (event: MessageEvents): void => {
  const msg: WorkerMessage = event.data as WorkerMessage;
  const type: string = msg.type;

  switch (type) {
    case 'init':
      streamProcessorId = msg.streamProcessorId ?? 0;
      workerPort.postMessage({ type: 'ready' });
      break;

    case 'start':
      isRunning = true;
      isPaused = false;
      frameQueue = [];
      runRetryLoop();
      break;

    case 'stop':
      isRunning = false;
      isPaused = false;
      frameQueue = [];
      workerPort.postMessage({ type: 'stopped' });
      break;

    case 'pause':
      isPaused = true;
      break;

    case 'resume':
      isPaused = false;
      break;

    case 'push':
      if (!isRunning || isPaused) return;

      if (msg.data) {
        const pts: number = msg.pts ?? 0;
        const flags: number = msg.flags ?? 0;
        pushFrame(msg.data, pts, flags);
      }
      break;
  }
};

/**
 * Defines the event handler to be called when the worker receives a message that cannot be deserialized.
 */
workerPort.onmessageerror = (event: MessageEvents): void => {
  const response: WorkerResponse = { type: 'error', message: 'Message deserialization failed' };
  workerPort.postMessage(response);
};

/**
 * Defines the event handler to be called when an exception occurs during worker execution.
 */
workerPort.onerror = (event: ErrorEvent): void => {
  const response: WorkerResponse = { type: 'error', message: event.message ?? 'Unknown error' };
  workerPort.postMessage(response);
};
