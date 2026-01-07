import preferences from '@ohos.data.preferences';
import { Device } from '../entity/Device';

// 数据持久化管理
export class PreferencesHelper {
  private static instance: PreferencesHelper;
  private preferences?: preferences.Preferences;
  private devicesList: Device[] = [];
  
  private constructor() {}
  
  static getInstance(): PreferencesHelper {
    if (!PreferencesHelper.instance) {
      PreferencesHelper.instance = new PreferencesHelper();
    }
    return PreferencesHelper.instance;
  }
  
  async init(context: Context): Promise<void> {
    try {
      this.preferences = await preferences.getPreferences(context, 'device_prefs');
      await this.loadDevices();
    } catch (err) {
      console.error('PreferencesHelper init failed:', err);
    }
  }
  
  private async loadDevices(): Promise<void> {
    try {
      if (!this.preferences) return;
      
      const devicesStr = await this.preferences.get('devices', '[]') as string;
      const devicesData: Device[] = this.parseDevices(devicesStr);
      
      this.devicesList = devicesData.map((data: Device) => {
        const device = new Device(data.uuid, data.type);
        this.assignDeviceData(device, data);
        return device;
      });
    } catch (err) {
      console.error('Load devices failed:', err);
      this.devicesList = [];
    }
  }
  
  private parseDevices(jsonStr: string): Device[] {
    try {
      return JSON.parse(jsonStr) as Device[];
    } catch (e) {
      return [];
    }
  }
  
  private assignDeviceData(target: Device, source: Device): void {
    target.uuid = source.uuid;
    target.name = source.name;
    target.address = source.address;
    target.adbPort = source.adbPort ?? 5555;
    target.serverPort = source.serverPort ?? 12580;
    target.type = source.type ?? Device.TYPE_NETWORK;
    target.customResolutionOnConnect = source.customResolutionOnConnect ?? false;
    target.customResolutionWidth = source.customResolutionWidth ?? 1920;
    target.customResolutionHeight = source.customResolutionHeight ?? 1080;
    target.wakeOnConnect = source.wakeOnConnect ?? true;  // 默认唤醒
    target.lightOffOnConnect = source.lightOffOnConnect ?? false;
    target.changeToFullOnConnect = source.changeToFullOnConnect ?? false;
    target.keepAwake = source.keepAwake ?? true;  // 默认保持唤醒
    target.changeResolutionOnRunning = source.changeResolutionOnRunning ?? false;
    target.listenClipOnRunning = source.listenClipOnRunning ?? true;
    target.lockOnClose = source.lockOnClose ?? false;
    target.lightOnClose = source.lightOnClose ?? false;
    target.reconnectOnClose = source.reconnectOnClose ?? false;
    target.isAudio = source.isAudio ?? true;
    target.maxSize = source.maxSize ?? 1920;
    target.maxFps = source.maxFps ?? 60;
    target.maxVideoBit = source.maxVideoBit ?? 4;
    target.useH265 = source.useH265 ?? true;
    target.connectOnStart = source.connectOnStart ?? false;
  }
  
  async saveDevices(): Promise<void> {
    try {
      if (!this.preferences) return;
      
      const devicesStr = JSON.stringify(this.devicesList);
      await this.preferences.put('devices', devicesStr);
      await this.preferences.flush();
    } catch (err) {
      console.error('Save devices failed:', err);
    }
  }
  
  getDevicesList(): Device[] {
    return this.devicesList;
  }
  
  async insert(device: Device): Promise<void> {
    this.devicesList.push(device);
    await this.saveDevices();
  }
  
  async update(device: Device): Promise<void> {
    const index = this.devicesList.findIndex(d => d.uuid === device.uuid);
    if (index !== -1) {
      this.devicesList[index] = device;
      await this.saveDevices();
    }
  }
  
  async delete(uuid: string): Promise<void> {
    this.devicesList = this.devicesList.filter(d => d.uuid !== uuid);
    await this.saveDevices();
  }
  
  getByUUID(uuid: string): Device | null {
    return this.devicesList.find(d => d.uuid === uuid) || null;
  }
}
