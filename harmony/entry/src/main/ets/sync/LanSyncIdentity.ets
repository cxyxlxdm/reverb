import deviceInfo from '@ohos.deviceInfo';
import { JsonFile } from '../store/JsonFile';
import { J } from '../net/Http';
import { LanSyncCrypto } from './LanSyncCrypto';
import { Log } from '../util/Logger';

/**
 * 本机在局域网里的**长期身份**:只有一串设备 id 与显示名。
 *
 * 与 Android `sync/LanSyncIdentity.kt` 同一份 `lan_sync.json` 格式(version/deviceId/
 * name/createdAt)。文件**只在应用私有目录**,不进备份(备份分区是白名单)。
 *
 * ⚠️ **这里不存密钥**。旧版本曾把一对长期 P-256 密钥也写进来并直接拿去做 ECDH,
 * 结果同一对设备每次配对的六位码都一样、也没有前向保密(H278):注释与文档都写着
 * "每次配对临时 ECDH",实现却把长期钥当了会话钥。现在密钥对在**每次会话里现生成**
 * (见 `LanSyncSession.greet`),身份只负责"我是谁"。
 *
 * 为什么要稳定身份:设备 id 跟服务名(服务名叫 `Reverb-<id 前 8 位>`)与去重判据挂钩,
 * 每次打开同步都换一个名字,对端列表里会出现一串"幽灵设备"。
 */
export interface LanSyncMaterial {
  deviceId: string;
  name: string;
  createdAt: number;
}

export class LanSyncIdentity {
  private static readonly FILE: string = 'lan_sync.json';
  private static readonly VERSION: number = 1;

  private cached: LanSyncMaterial | null = null;
  private loading: Promise<LanSyncMaterial> | null = null;

  /** 首次访问时才读盘/生成。 */
  async material(): Promise<LanSyncMaterial> {
    if (this.cached !== null) return this.cached;
    if (this.loading !== null) return await this.loading;
    this.loading = this.loadOrCreate();
    try {
      const m = await this.loading;
      this.cached = m;
      return m;
    } finally {
      this.loading = null;
    }
  }

  private async loadOrCreate(): Promise<LanSyncMaterial> {
    const existing = await this.read();
    if (existing !== null) return existing;
    const material: LanSyncMaterial = {
      deviceId: LanSyncCrypto.randomHex(8),
      name: LanSyncIdentity.defaultName(),
      createdAt: Date.now()
    };
    this.persist(material);
    Log.i('LanSync', `生成新的同步身份 id=${material.deviceId} name=${material.name}`);
    return material;
  }

  private async read(): Promise<LanSyncMaterial | null> {
    const o = JsonFile.readObject(LanSyncIdentity.FILE);
    if (o === null) return null;
    try {
      if (J.num(o, 'version') !== LanSyncIdentity.VERSION) return null;
      const id = J.str(o, 'deviceId');
      if (id.length !== 16) return null;
      return {
        deviceId: id,
        name: J.str(o, 'name').length > 0 ? J.str(o, 'name') : LanSyncIdentity.defaultName(),
        createdAt: J.num(o, 'createdAt')
      } as LanSyncMaterial;
    } catch (e) {
      // 读坏就重建 —— 身份里只有展示用的名字与去重用的 id,没有不可再生的东西。
      // 旧文件里多出来的 publicKey/privateKey 会被忽略(不读也不删,下次 persist 时自然消失)。
      Log.w('LanSync', `lan_sync.json 读取失败,重建身份:${(e as Error).message}`);
      return null;
    }
  }

  private persist(m: LanSyncMaterial): void {
    const o: Record<string, Object> = {};
    o['version'] = LanSyncIdentity.VERSION;
    o['deviceId'] = m.deviceId;
    o['name'] = m.name;
    o['createdAt'] = m.createdAt;
    JsonFile.writeJson(LanSyncIdentity.FILE, o);
  }

  private static defaultName(): string {
    try {
      const n = deviceInfo.marketName;
      if (n !== undefined && n !== null && n.length > 0) return n;
    } catch (e) {
      Log.w('LanSync', `取设备名失败:${(e as Error).message}`);
    }
    return 'HarmonyOS';
  }
}
