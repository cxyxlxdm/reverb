import cryptoFramework from '@ohos.security.cryptoFramework';
import deviceInfo from '@ohos.deviceInfo';
import { JsonFile } from '../store/JsonFile';
import { J } from '../net/Http';
import { LanSyncCrypto } from './LanSyncCrypto';
import { Log } from '../util/Logger';

/**
 * 本机在局域网里的**长期身份**:一串设备 id + 一对 P-256 密钥。
 *
 * 与 Android `sync/LanSyncIdentity.kt` 同一份 `lan_sync.json` 格式(version/deviceId/
 * name/publicKey/privateKey/createdAt)。文件**只在应用私有目录**,不进备份(备份分区是白名单),
 * 换机后重新生成即可 —— 每次配对都重新做 ECDH,前向保密不依赖这把长期钥。
 *
 * 为什么要稳定身份:设备 id 跟服务名(服务名叫 `Reverb-<id 前 8 位>`)与去重判据挂钩,
 * 每次打开同步都换一个名字,对端列表里会出现一串"幽灵设备"。
 */
export interface LanSyncMaterial {
  deviceId: string;
  name: string;
  publicKey: Uint8Array;
  privateKey: cryptoFramework.PriKey;
  createdAt: number;
}

export class LanSyncIdentity {
  private static readonly FILE: string = 'lan_sync.json';
  private static readonly VERSION: number = 1;

  private cached: LanSyncMaterial | null = null;
  private loading: Promise<LanSyncMaterial> | null = null;

  /** 首次访问时才读盘/生成 —— 应用启动不该为这个功能付一次 EC 密钥生成。 */
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
    const keyPair = await LanSyncCrypto.generateKeyPair();
    const material: LanSyncMaterial = {
      deviceId: LanSyncCrypto.randomHex(8),
      name: LanSyncIdentity.defaultName(),
      publicKey: LanSyncCrypto.encodePublicKey(keyPair.pubKey),
      privateKey: keyPair.priKey,
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
      const publicKey = LanSyncCrypto.unbase64(J.str(o, 'publicKey'));
      const privateKey = await LanSyncCrypto.decodePrivateKey(
        LanSyncCrypto.unbase64(J.str(o, 'privateKey')));
      if (id.length !== 16 || publicKey.length !== LanSyncCrypto.PUBLIC_KEY_BYTES) return null;
      return {
        deviceId: id,
        name: J.str(o, 'name').length > 0 ? J.str(o, 'name') : LanSyncIdentity.defaultName(),
        publicKey: publicKey,
        privateKey: privateKey,
        createdAt: J.num(o, 'createdAt')
      } as LanSyncMaterial;
    } catch (e) {
      // 读坏不等于"没有身份",但这里**只能重建** —— 私钥丢了没有任何别处能补。
      // 代价是旧的配对记录失效;P0 不持久化配对记录,所以影响只到下一次配对。
      Log.w('LanSync', `lan_sync.json 读取失败,重建身份:${(e as Error).message}`);
      return null;
    }
  }

  private persist(m: LanSyncMaterial): void {
    const o: Record<string, Object> = {};
    o['version'] = LanSyncIdentity.VERSION;
    o['deviceId'] = m.deviceId;
    o['name'] = m.name;
    o['publicKey'] = LanSyncCrypto.base64(m.publicKey);
    o['privateKey'] = LanSyncCrypto.base64(LanSyncCrypto.encodePrivateKey(m.privateKey));
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
