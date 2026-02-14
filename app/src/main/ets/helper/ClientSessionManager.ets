/*
 * ClientSessionManager.ets
 * 
 * Manages the active native client session to ensure proper cleanup.
 * Prevents multiple sessions from running simultaneously and provides a global cleanup mechanism.
 */

import { NativeStreamClient } from '../client/tools/NativeStreamClient';
import { LoggerClientSession } from './Logger';

export class ClientSessionManager {
  private static instance: ClientSessionManager;
  private currentClient?: NativeStreamClient;

  private constructor() {}

  public static getInstance(): ClientSessionManager {
    if (!ClientSessionManager.instance) {
      ClientSessionManager.instance = new ClientSessionManager();
    }
    return ClientSessionManager.instance;
  }

  // Register a new client, stopping any existing one first
  public register(client: NativeStreamClient): void {
    if (this.currentClient && this.currentClient !== client) {
      LoggerClientSession.warn('[ClientSessionManager] Stopping previous client before registering new one');
      this.stopAll();
    }
    this.currentClient = client;
    LoggerClientSession.info('[ClientSessionManager] Client registered');
  }

  // Unregister a client (usually called when it stops itself normally)
  public unregister(client: NativeStreamClient): void {
    if (this.currentClient === client) {
      this.currentClient = undefined;
      LoggerClientSession.info('[ClientSessionManager] Client unregistered');
    }
  }

  // Force stop the current client
  public stopAll(): void {
    if (this.currentClient) {
      LoggerClientSession.info('[ClientSessionManager] Stopping active client session...');
      try {
        this.currentClient.stop();
      } catch (e) {
        LoggerClientSession.error('[ClientSessionManager] Error stopping client:', e);
      }
      this.currentClient = undefined;
    }
  }

  // Check if there is an active session
  public hasActiveSession(): boolean {
    return !!this.currentClient;
  }
}
