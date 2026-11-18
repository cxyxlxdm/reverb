import util from '@ohos.util';
import { Log } from '../util/Logger';
import { LanSyncCrypto } from './LanSyncCrypto';
import { LanSyncChannel, LanSyncException, LanSyncFail, LanSyncWire } from './LanSyncWire';
import type { LanSyncMaterial } from './LanSyncIdentity';

/** 同步中的阶段。UI 只按阶段换一句文案,不解析协议。 */
export enum LanSyncStage {
  SENDING = 0,
  RECEIVING = 1,
  MERGING = 2
}

/** 一次同步的**增量**读数。`total` 为 0 时界面上不该出现"新增 0 · 0 · 0"。 */
export class LanSyncResult {
  peerName: string = '';
  subscriptions: number = 0;
  favorites: number = 0;
  stamps: number = 0;
  notes: number = 0;
  history: number = 0;
  stats: number = 0;

  total(): number {
    return this.subscriptions + this.favorites + this.stamps + this.notes + this.history + this.stats;
  }
}

/** 会话与界面之间的桥。确认码必须由**人**比对,不能自动确认 —— 否则加密只挡了路人。 */
export interface LanSyncUiBridge {
  confirm(peerName: string, code: string): Promise<boolean>;
  stage(peerName: string, stage: LanSyncStage, percent: number): void;
}

/**
 * 一次完整的配对 + 合并会话。**两端跑的是同一份代码,只有 initiator 一个布尔量的差别**:
 *
 * ```text
 * 双方:  hello(明文, 公钥 + nonce)
 * 双方:  各自算共享密钥 / 会话密钥 / 六位配对码 → 人眼比对
 * 双方:  confirm(密封)          ← 能解开对方的 confirm 就证明会话密钥一致
 * 发起方: request               → 应方把自己的快照分成块发过来
 * 发起方: 并入 → 把**合并后的全集**发回应方
 * 应方:  并入 → ack
 * ```
 *
 * 第二程发"合并后的全集"而不是"我这边新增的那部分":全集天然幂等,而且不需要跟踪
 * "上次同步到哪"(P0 没有同步游标)。代价是多传一遍数据 —— 局域网里可以接受。
 *
 * 快照的"怎么取、怎么并"由调用方注入,本类只管传输:这样协议本身与备份格式解耦。
 * 整份快照先算 SHA-256 再校验,半截数据不会进 `apply`。
 */
export class LanSyncSession {
  private identity: LanSyncMaterial;
  private channel: LanSyncChannel;
  private initiator: boolean;
  private ui: LanSyncUiBridge;
  private buildSnapshot: () => Promise<string>;
  private applySnapshot: (json: string) => Promise<Int32Array>;

  private peerName: string = '设备';
  private shared: Uint8Array = new Uint8Array(0);

  /**
   * 对端是否声明支持「同步之后的播放交接」(`hello.live`)。
   *
   * 这是**加时赛**不是新协议:老版本没有这个键,读到 false 就不进交接,
   * 也就不用担心把一条老版本的会话拖在一个永远等不到帧的读上。
   */
  peerSupportsLive: boolean = false;

  constructor(
    identity: LanSyncMaterial,
    channel: LanSyncChannel,
    initiator: boolean,
    ui: LanSyncUiBridge,
    buildSnapshot: () => Promise<string>,
    applySnapshot: (json: string) => Promise<Int32Array>
  ) {
    this.identity = identity;
    this.channel = channel;
    this.initiator = initiator;
    this.ui = ui;
    this.buildSnapshot = buildSnapshot;
    this.applySnapshot = applySnapshot;
  }

  async run(): Promise<LanSyncResult> {
    await this.greet();
    const code = await LanSyncCrypto.sasCode(this.shared);
    Log.i('LanSync.Session', `配对开始 peer=${this.peerName} initiator=${this.initiator} code=${code}`);
    const accepted = await this.ui.confirm(this.peerName, code);
    if (!accepted) {
      const cancel: Record<string, Object> = {};
      cancel['t'] = 'cancel';
      await this.channel.send(cancel).catch((e: Error) => {
        Log.w('LanSync.Session', `发取消帧失败:${e.message}`);
      });
      throw new LanSyncException(LanSyncFail.CANCELLED, '本机取消');
    }
    const confirm: Record<string, Object> = {};
    confirm['t'] = 'confirm';
    await this.channel.send(confirm);
    await this.expect('confirm');

    const result = this.initiator ? await this.runInitiator() : await this.runResponder();
    Log.i(
      'LanSync.Session',
      `同步完成 peer=${this.peerName} added subs=${result.subscriptions} favs=${result.favorites} ` +
        `stamps=${result.stamps} notes=${result.notes} history=${result.history} stats=${result.stats}`
    );
    return result;
  }

  private sessionKeyCache: Uint8Array = new Uint8Array(0);

  private async greet(): Promise<void> {
    const nonce = LanSyncCrypto.randomBytes(16);
    // **每次会话现生成一对临时密钥**(H278)。曾经直接拿身份里的长期密钥做 ECDH,
    // 于是同一对设备每轮配对码都一样、也没有前向保密 —— 与注释和文档的承诺相反。
    const ephemeral = await LanSyncCrypto.generateKeyPair();
    const hello: Record<string, Object> = {};
    hello['t'] = 'hello';
    hello['v'] = LanSyncWire.VERSION;
    hello['id'] = this.identity.deviceId;
    hello['name'] = this.identity.name;
    hello['pub'] = LanSyncCrypto.base64(LanSyncCrypto.encodePublicKey(ephemeral.pubKey));
    hello['nonce'] = LanSyncCrypto.base64(nonce);
    // 交接是同步之后的**加时赛**:同一把会话密钥、同一条 TCP。
    // 老版本忽略这个键,同步完就断开;我们这边读到 false 就不进读循环。
    hello['live'] = true;
    await this.channel.sendPlain(JSON.stringify(hello));

    const text = await this.channel.receivePlain(LanSyncSession.HANDSHAKE_TIMEOUT_MS);
    const remote = JSON.parse(text) as Record<string, Object>;
    if (remote['t'] !== 'hello') {
      throw new LanSyncException(LanSyncFail.PROTOCOL, '对方第一帧不是 hello');
    }
    if (remote['v'] !== LanSyncWire.VERSION) {
      throw new LanSyncException(LanSyncFail.VERSION, `对方协议版本 ${remote['v']}`);
    }
    // 发现层有时会看见自己(名字冲突时系统还会把服务名改掉,按名字排不掉),按设备 id 再挡一次。
    if (remote['id'] === this.identity.deviceId) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, '对端就是本机');
    }
    const peerPub = LanSyncCrypto.unbase64(remote['pub'] as string);
    if (peerPub.length !== LanSyncCrypto.PUBLIC_KEY_BYTES) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, `对方公钥长度 ${peerPub.length}`);
    }
    const peerNonce = LanSyncCrypto.unbase64(remote['nonce'] as string);
    if (peerNonce.length !== 16) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, `对方 nonce 长度 ${peerNonce.length}`);
    }
    const clientNonce = this.initiator ? nonce : peerNonce;
    const serverNonce = this.initiator ? peerNonce : nonce;
    this.shared = await LanSyncCrypto.sharedSecret(ephemeral.priKey, peerPub);
    this.sessionKeyCache = await LanSyncCrypto.sessionKey(this.shared, clientNonce, serverNonce);
    // 密钥在 hello 之后立刻装上:后续 confirm / request / 快照全部是密封帧。
    // 放在人眼比对**之前**是对的 —— Android 也是先装密钥再弹配对码,配对码只是
    // "两边算出来的同一个密钥"的证明,不参与加解密本身。
    this.channel.useKey(this.sessionKeyCache);
    this.peerSupportsLive = remote['live'] === true;
    const rawName = remote['name'] as string;
    const trimmed = rawName === undefined || rawName === null ? '' : rawName.trim();
    this.peerName = trimmed.length > 0 ? trimmed.substring(0, 64) : '设备';
  }

  private async runInitiator(): Promise<LanSyncResult> {
    const request: Record<string, Object> = {};
    request['t'] = 'request';
    await this.channel.send(request);
    this.ui.stage(this.peerName, LanSyncStage.RECEIVING, 0);
    const remote = await this.receiveSnapshot();
    this.ui.stage(this.peerName, LanSyncStage.MERGING, 0);
    const added = await this.applySnapshot(remote);
    this.ui.stage(this.peerName, LanSyncStage.SENDING, 0);
    await this.sendSnapshot();
    await this.expect('ack');
    return this.result(added);
  }

  private async runResponder(): Promise<LanSyncResult> {
    await this.expect('request');
    await this.sendSnapshot();
    this.ui.stage(this.peerName, LanSyncStage.RECEIVING, 0);
    const merged = await this.receiveSnapshot();
    this.ui.stage(this.peerName, LanSyncStage.MERGING, 0);
    const added = await this.applySnapshot(merged);
    const ack: Record<string, Object> = {};
    ack['t'] = 'ack';
    await this.channel.send(ack);
    return this.result(added);
  }

  private async sendSnapshot(): Promise<void> {
    const text = await this.buildSnapshot();
    const bytes = new util.TextEncoder().encodeInto(text);
    if (bytes.length > LanSyncWire.MAX_SNAPSHOT) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, `本机快照 ${bytes.length} 字节,超过上限`);
    }
    const chunks = Math.max(1, Math.ceil(bytes.length / LanSyncWire.CHUNK_BYTES));
    const digest = await LanSyncCrypto.sha256(bytes);
    const offer: Record<string, Object> = {};
    offer['t'] = 'offer';
    offer['size'] = bytes.length;
    offer['chunks'] = chunks;
    offer['sha256'] = LanSyncCrypto.base64(digest);
    await this.channel.send(offer);
    for (let i = 0; i < chunks; i++) {
      const from = i * LanSyncWire.CHUNK_BYTES;
      const to = Math.min(bytes.length, from + LanSyncWire.CHUNK_BYTES);
      const frame: Record<string, Object> = {};
      frame['t'] = 'chunk';
      frame['i'] = i;
      frame['d'] = LanSyncCrypto.base64(bytes.slice(from, to));
      await this.channel.send(frame);
      if (i % LanSyncSession.PROGRESS_EVERY === 0) {
        this.ui.stage(this.peerName, LanSyncStage.SENDING, Math.floor((i + 1) * 100 / chunks));
      }
    }
  }

  private async receiveSnapshot(): Promise<string> {
    const offer = await this.expect('offer');
    const size = offer['size'] as number;
    const chunks = offer['chunks'] as number;
    if (typeof size !== 'number' || size < 0 || size > LanSyncWire.MAX_SNAPSHOT) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, `对方快照大小 ${size} 不合法`);
    }
    if (typeof chunks !== 'number' || chunks < 1 || chunks > Math.ceil(LanSyncWire.MAX_SNAPSHOT / LanSyncWire.CHUNK_BYTES)) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, `对方分块数 ${chunks} 不合法`);
    }
    const parts: Uint8Array[] = [];
    let total = 0;
    for (let i = 0; i < chunks; i++) {
      const frame = await this.expect('chunk');
      if (frame['i'] !== i) {
        throw new LanSyncException(LanSyncFail.PROTOCOL, `分块顺序错乱:期待 ${i},收到 ${frame['i']}`);
      }
      const data = LanSyncCrypto.unbase64(frame['d'] as string);
      parts.push(data);
      total += data.length;
      if (total > LanSyncWire.MAX_SNAPSHOT) {
        throw new LanSyncException(LanSyncFail.PROTOCOL, '对方发来的数据超过上限');
      }
      if (i % LanSyncSession.PROGRESS_EVERY === 0) {
        this.ui.stage(this.peerName, LanSyncStage.RECEIVING, Math.floor((i + 1) * 100 / chunks));
      }
    }
    if (total !== size) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, `收到 ${total} 字节,对方声明 ${size}`);
    }
    const all = new Uint8Array(total);
    let offset = 0;
    for (let i = 0; i < parts.length; i++) {
      all.set(parts[i], offset);
      offset += parts[i].length;
    }
    const expected = LanSyncCrypto.unbase64(offer['sha256'] as string);
    const actual = await LanSyncCrypto.sha256(all);
    if (!LanSyncCrypto.constantTimeEquals(expected, actual)) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, '快照校验值不一致');
    }
    return new util.TextDecoder('utf-8').decodeToString(all);
  }

  private async expect(type: string): Promise<Record<string, Object>> {
    const frame = await this.channel.receive(LanSyncSession.TIMEOUT_MS);
    const t = frame['t'] as string;
    if (t === 'cancel') throw new LanSyncException(LanSyncFail.PEER_CANCELLED, '对端取消');
    if (t !== type) throw new LanSyncException(LanSyncFail.PROTOCOL, `期待 ${type},收到 ${t}`);
    return frame;
  }

  private result(added: Int32Array): LanSyncResult {
    const r = new LanSyncResult();
    r.peerName = this.peerName;
    r.subscriptions = added[0];
    r.favorites = added[1];
    r.stamps = added[2];
    r.notes = added[3];
    r.history = added[4];
    r.stats = added[5];
    return r;
  }

  private static readonly HANDSHAKE_TIMEOUT_MS: number = 15_000;
  private static readonly TIMEOUT_MS: number = 30_000;
  private static readonly PROGRESS_EVERY: number = 8;
}
