import util from '@ohos.util';
import { LanSyncCrypto } from './LanSyncCrypto';

/** 同步失败的可展示分类。界面把它映射成文案,不把异常原文直接摆给用户。 */
export enum LanSyncFail {
  CONNECT = 0,
  VERSION = 1,
  PROTOCOL = 2,
  DECRYPT = 3,
  IO = 4,
  CANCELLED = 5,
  PEER_CANCELLED = 6
}

export class LanSyncException extends Error {
  fail: LanSyncFail;

  constructor(fail: LanSyncFail, message: string) {
    super(message);
    this.fail = fail;
    this.name = 'LanSyncException';
  }
}

/** 帧协议常量。与 Android `LanSyncWire` / Apple 共享层**逐字节一致**。 */
export class LanSyncWire {
  static readonly VERSION: number = 1;
  static readonly MAX_FRAME: number = 8 * 1024 * 1024;
  static readonly CHUNK_BYTES: number = 256 * 1024;
  static readonly MAX_SNAPSHOT: number = 64 * 1024 * 1024;
}

export type FrameSender = (bytes: Uint8Array) => Promise<void>;

/**
 * 一条已经建立的 TCP 连接上的帧读写。
 *
 * 每一帧 = **4 字节大端长度** + UTF-8 JSON。长度前缀而不是换行分隔:密文里什么字节
 * 都可能出现(包括 0x0A),文本分隔线在加密层就不成立。
 *
 * 鸿蒙的 socket 是事件回调,**不会替我们攒包** —— TCP 一次 `message` 可能给半帧、也可能
 * 给三帧。所以这里自己维护一个缓冲区与一个等待队列:数据到了就 `pump()`,读的一方
 * 只 `await nextFrame()`。这是本文件全部存在的理由(Android 那边是 `DataInputStream.readFully`)。
 *
 * 密钥只在 hello 之后装进来。**装进来之后就不允许再出现明文帧** —— 否则中间人可以诱导
 * 某一端退回明文;这条判据放在 [receive] 里,不靠调用方自觉。
 */
export class LanSyncChannel {
  private sender: FrameSender;
  private buf: Uint8Array = new Uint8Array(0);
  private frames: Uint8Array[] = [];
  private waiters: ((f: Uint8Array | null) => void)[] = [];
  private failure: LanSyncFail | null = null;
  private key: Uint8Array | null = null;

  constructor(sender: FrameSender) {
    this.sender = sender;
  }

  useKey(key: Uint8Array): void {
    this.key = key;
  }

  /** socket 的 `message` 回调直接接这里。 */
  onData(data: ArrayBuffer): void {
    const chunk = new Uint8Array(data);
    const merged = new Uint8Array(this.buf.length + chunk.length);
    merged.set(this.buf, 0);
    merged.set(chunk, this.buf.length);
    this.buf = merged;
    this.pump();
  }

  /** 对端关闭或 socket 报错。挂着的读端立刻拿到 null,不靠超时。 */
  onClosed(fail: LanSyncFail, detail: string): void {
    if (this.failure === null) this.failure = fail;
    this.buf = new Uint8Array(0);
    const ws = this.waiters;
    this.waiters = [];
    for (let i = 0; i < ws.length; i++) ws[i](null);
    if (detail.length > 0) return;
  }

  private pump(): void {
    while (this.waiters.length > 0 && this.buf.length >= 4) {
      const size = ((this.buf[0] << 24) | (this.buf[1] << 16) | (this.buf[2] << 8) | this.buf[3]) >>> 0;
      if (size <= 0 || size > LanSyncWire.MAX_FRAME) {
        this.onClosed(LanSyncFail.PROTOCOL, `对端声明了非法帧长 ${size}`);
        return;
      }
      if (this.buf.length < 4 + size) return;
      const frame = this.buf.slice(4, 4 + size);
      this.buf = this.buf.slice(4 + size);
      const w = this.waiters.shift();
      if (w !== undefined) w(frame);
    }
  }

  private nextFrame(timeoutMs: number): Promise<Uint8Array> {
    if (this.frames.length > 0) {
      const f = this.frames.shift();
      if (f !== undefined) return Promise.resolve(f);
    }
    if (this.failure !== null) {
      return Promise.reject(new LanSyncException(this.failure, '连接已结束'));
    }
    return new Promise<Uint8Array>((resolve, reject) => {
      let settled = false;
      let timer = -1;
      const done = (f: Uint8Array | null): void => {
        if (settled) return;
        settled = true;
        if (timer >= 0) clearTimeout(timer);
        if (f === null) {
          reject(new LanSyncException(this.failure === null ? LanSyncFail.IO : this.failure, '连接已结束'));
        } else {
          resolve(f);
        }
      };
      this.waiters.push(done);
      // `timeoutMs <= 0` = 不设超时。交接通道(同步完成之后)只有心跳,对端暂停时可能
      // 长时间不说话,30 秒那条同步期超时会把一条好连接判成"网络中断" —— 与 Android
      // `socket.soTimeout = 0` 同一个口径。连接真正断开时由 `onClosed` 唤醒。
      if (timeoutMs > 0) {
        timer = setTimeout(() => {
          // 超时后把自己从队列里摘掉,否则下一次 pump 会唤醒一个已经 reject 的等待者。
          const i = this.waiters.indexOf(done);
          if (i >= 0) this.waiters.splice(i, 1);
          done(null);
        }, timeoutMs);
      }
      // 数据可能刚好在入队前到齐
      this.pump();
    });
  }

  async sendPlain(text: string): Promise<void> {
    const body = new util.TextEncoder().encodeInto(text);
    const frame = new Uint8Array(4 + body.length);
    frame[0] = (body.length >>> 24) & 0xff;
    frame[1] = (body.length >>> 16) & 0xff;
    frame[2] = (body.length >>> 8) & 0xff;
    frame[3] = body.length & 0xff;
    frame.set(body, 4);
    await this.sender(frame);
  }

  async receivePlain(timeoutMs: number): Promise<string> {
    const frame = await this.nextFrame(timeoutMs);
    return new util.TextDecoder('utf-8').decodeToString(frame);
  }

  async send(obj: Record<string, Object>): Promise<void> {
    const k = this.key;
    if (k === null) throw new LanSyncException(LanSyncFail.PROTOCOL, '还没建立密钥就发了加密帧');
    const nonce = LanSyncCrypto.randomBytes(LanSyncCrypto.NONCE_BYTES);
    const plain = new util.TextEncoder().encodeInto(JSON.stringify(obj));
    const sealed = await LanSyncCrypto.encrypt(k, nonce, plain);
    const envelope: Record<string, Object> = {};
    envelope['n'] = LanSyncCrypto.base64(nonce);
    envelope['c'] = LanSyncCrypto.base64(sealed);
    await this.sendPlain(JSON.stringify(envelope));
  }

  async receive(timeoutMs: number): Promise<Record<string, Object>> {
    const k = this.key;
    if (k === null) throw new LanSyncException(LanSyncFail.PROTOCOL, '还没建立密钥就收到了加密帧');
    const text = await this.receivePlain(timeoutMs);
    const envelope = JSON.parse(text) as Record<string, Object>;
    if (envelope['n'] === undefined || envelope['c'] === undefined) {
      throw new LanSyncException(LanSyncFail.PROTOCOL, '加密阶段收到了明文帧');
    }
    const nonce = LanSyncCrypto.unbase64(envelope['n'] as string);
    const body = LanSyncCrypto.unbase64(envelope['c'] as string);
    let plain: Uint8Array;
    try {
      plain = await LanSyncCrypto.decrypt(k, nonce, body);
    } catch (e) {
      throw new LanSyncException(LanSyncFail.DECRYPT, '密文校验失败');
    }
    return JSON.parse(new util.TextDecoder('utf-8').decodeToString(plain)) as Record<string, Object>;
  }

  /** 连接已被对端关闭?给会话层判断"错误是不是因为对面先走了"。 */
  isClosed(): boolean {
    return this.failure !== null;
  }
}
