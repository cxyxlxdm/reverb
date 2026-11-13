import type common from '@ohos.app.ability.common';
import socket from '@ohos.net.socket';
import mdns from '@ohos.net.mdns';
import connection from '@ohos.net.connection';
import util from '@ohos.util';
import { AppContainer } from '../AppContainer';
import { Log } from '../util/Logger';
import { LanSyncCrypto } from './LanSyncCrypto';
import { LanSyncChannel, LanSyncException, LanSyncFail, FrameSender } from './LanSyncWire';
import { LanSyncSession, LanSyncStage, LanSyncResult, LanSyncUiBridge } from './LanSyncSession';
import { LanSyncIdentity, LanSyncMaterial } from './LanSyncIdentity';
import { LanSyncMerge } from './LanSyncMerge';

/** 手动输入的连接目标。 */
export class LanSyncTarget {
  host: string;
  port: number;

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }
}

/** 发现到的一台设备。`name` 优先取 TXT 里的设备名,拿不到才退回服务名。 */
export class LanSyncPeer {
  name: string;
  host: string;
  port: number;
  serviceName: string;

  constructor(name: string, host: string, port: number, serviceName: string) {
    this.name = name;
    this.host = host;
    this.port = port;
    this.serviceName = serviceName;
  }

  address(): string {
    return `${this.host}:${this.port}`;
  }
}

/** 会话 → 界面的两条回调。写成类是为了过 ArkTS 的 `arkts-no-untyped-obj-literals`。 */
class LanSyncBridgeImpl implements LanSyncUiBridge {
  private onConfirm: (peerName: string, code: string) => Promise<boolean>;
  private onStage: (peerName: string, stage: LanSyncStage, percent: number) => void;

  constructor(onConfirm: (peerName: string, code: string) => Promise<boolean>,
              onStage: (peerName: string, stage: LanSyncStage, percent: number) => void) {
    this.onConfirm = onConfirm;
    this.onStage = onStage;
  }

  confirm(peerName: string, code: string): Promise<boolean> {
    return this.onConfirm(peerName, code);
  }

  stage(peerName: string, stage: LanSyncStage, percent: number): void {
    this.onStage(peerName, stage, percent);
  }
}

export enum LanSyncPhase {
  IDLE = 0,
  LISTENING = 1,
  CONNECTING = 2,
  CONFIRM = 3,
  SYNCING = 4,
  DONE = 5,
  FAILED = 6
}

/** 界面只读这一份快照;每次变化都换一个新对象,靠整值赋值触发重渲(硬规矩 7 的用法)。 */
export class LanSyncViewState {
  phase: LanSyncPhase = LanSyncPhase.IDLE;
  ownName: string = '';
  addresses: string[] = [];
  peers: LanSyncPeer[] = [];
  target: string = '';
  peerName: string = '';
  code: string = '';
  stage: LanSyncStage = LanSyncStage.RECEIVING;
  percent: number = 0;
  result: LanSyncResult | null = null;
  fail: LanSyncFail | null = null;
  detail: string = '';
}

/**
 * 局域网同步的总控(鸿蒙版)。一台设备上**同时**做服务端和客户端。
 *
 * 与 Android `LanSyncController` 同一套协议(端口 47820、mDNS 服务类型 `_reverb._tcp`、
 * TXT 键 `nm` 放设备名、手动 `host:port` 兜底)。这不是"文件互传",是**双向合并**:
 * 任何一端发起,双方最终都拿到并集,所以界面上只需要"在任意一台设备上点对方"。
 *
 * 生命周期跟对话框绑定:`start()` 打开,关掉对话框 `stop()` —— 不在后台常驻监听
 * (用户明确说过 P0 不做锁屏/后台自动接力;这也避开厂商对后台网络的限制)。
 *
 * 并发只有一条:**同一时刻只跑一个会话**。两端同时点对方时会各失败一次(对端已在忙),
 * 界面上提示"只在一台设备上点连接",重试即可 —— 比两端各跑两个会话、弹两次配对码清楚。
 *
 * ⚠️ 鸿蒙的 socket 是**事件回调**,没有阻塞读。攒帧由 [LanSyncChannel] 负责;本类只做
 * "把连接接进来 / 接到对方 / 把状态写给界面"。
 */
export class LanSyncController {
  private ctx: common.UIAbilityContext;
  private app: AppContainer;
  private onState: (s: LanSyncViewState) => void;
  private identity: LanSyncIdentity = new LanSyncIdentity();

  private state: LanSyncViewState = new LanSyncViewState();
  private material: LanSyncMaterial | null = null;
  private server: socket.TCPSocketServer | null = null;
  private discovery: mdns.DiscoveryService | null = null;
  private localService: mdns.LocalServiceInfo | null = null;
  private channel: LanSyncChannel | null = null;
  private confirmWaiter: ((ok: boolean) => void) | null = null;

  private running: boolean = false;
  private stopping: boolean = false;
  private busy: boolean = false;
  private port: number = 0;
  private peers: LanSyncPeer[] = [];
  private runToken: number = 0;
  private ownServiceName: string = '';

  constructor(ctx: common.UIAbilityContext, app: AppContainer, onState: (s: LanSyncViewState) => void) {
    this.ctx = ctx;
    this.app = app;
    this.onState = onState;
  }

  /** 当前状态(刚构造时给界面一个初始值)。 */
  snapshot(): LanSyncViewState {
    return this.state;
  }

  /** 打开面板:绑端口 + 广播 + 开始发现。可重复调用。 */
  async start(): Promise<void> {
    if (this.running) return;
    this.running = true;
    this.stopping = false;
    const token = ++this.runToken;
    try {
      const m = await this.identity.material();
      this.material = m;
      // `start()` 是异步铺开的,对话框可能在它铺完之前就被关掉。每过一个 await 点确认一次:
      // 号变了就把刚拿到的东西自己收掉,否则会留下一个没人认领的监听 / 广播。
      if (token !== this.runToken) return;
      this.ownServiceName = `Reverb-${m.deviceId.substring(0, 8)}`;
      await this.refreshAddresses();
      if (token !== this.runToken) return;
      this.bindServer();
      if (token !== this.runToken) {
        this.closeServer();
        return;
      }
      this.startDiscovery();
      this.peers = [];
      this.state = this.freshListening(m.name);
      this.onState(this.state);
      Log.i('LanSync', `开始监听 port=${this.port} name=${m.name} id=${m.deviceId}`);
    } catch (e) {
      if (!this.stopping) {
        this.fail(null, LanSyncFail.IO, `本机监听启动失败:${(e as Error).message}`);
      }
    }
  }

  /** 关闭面板:停服务、停发现、断开当前会话。 */
  stop(): void {
    this.stopping = true;
    this.running = false;
    this.runToken++;
    this.closeServer();
    this.stopDiscovery();
    this.channel = null;
    this.busy = false;
    const w = this.confirmWaiter;
    this.confirmWaiter = null;
    if (w !== null) w(false);
    this.peers = [];
    this.state = new LanSyncViewState();
    this.onState(this.state);
    Log.i('LanSync', '已停止监听');
  }

  /** 人眼比对之后的唯一出口。拒绝时两端都会看到"已取消"。 */
  confirm(accept: boolean): void {
    const w = this.confirmWaiter;
    this.confirmWaiter = null;
    if (w !== null) w(accept);
  }

  /**
   * 手动连接。接受 `192.168.1.5:47820` / `192.168.1.5`(默认端口)两种写法。
   * 和自动发现挤在同一个面板里,用户直接照抄对方屏幕上那行地址即可。
   */
  async connectTo(raw: string): Promise<void> {
    const target = LanSyncController.parseTarget(raw);
    if (target === null) {
      this.fail(null, LanSyncFail.CONNECT, `地址格式不对:${raw}`);
      return;
    }
    if (this.busy) {
      this.fail(null, LanSyncFail.CONNECT, '已有一次同步在跑');
      return;
    }
    const host = target.host;
    const port = target.port;
    this.state = this.copyListening();
    this.state.phase = LanSyncPhase.CONNECTING;
    this.state.target = `${host}:${port}`;
    this.onState(this.state);
    const token = this.runToken;
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance();
      const raw0 = tcp;
      await raw0.bind({ address: '0.0.0.0', port: 0, family: 1 });
      if (token !== this.runToken) {
        await raw0.close();
        return;
      }
      await raw0.connect({ address: { address: host, port: port, family: 1 }, timeout: 6000 });
      const sender: FrameSender = async (bytes: Uint8Array): Promise<void> => {
        const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        await raw0.send({ data: buf as ArrayBuffer });
      };
      const ch = new LanSyncChannel(sender);
      raw0.on('message', (info: socket.SocketMessageInfo) => {
        ch.onData(info.message);
      });
      raw0.on('error', (err: Object) => {
        const e = err as Error;
        ch.onClosed(LanSyncFail.IO, e.message);
      });
      this.channel = ch;
      await this.runSession(ch, true, async (): Promise<void> => {
        await raw0.close().catch((e: Error) => Log.w('LanSync', `关闭 client 失败:${e.message}`));
      });
    } catch (e) {
      if (!this.stopping) {
        const err = e as Error;
        Log.w('LanSync', `连接 ${host}:${port} 失败:${err.message}`);
        this.fail(null, LanSyncFail.CONNECT, err.message);
      }
      if (tcp !== null) tcp.close().catch((x: Error) => Log.w('LanSync', `关闭 client 失败:${x.message}`));
    }
  }

  // ---- 内部 ----

  private bindServer(): void {
    const srv = socket.constructTCPSocketServerInstance();
    srv.on('connect', (conn: socket.TCPSocketConnection) => {
      if (this.busy) {
        Log.w('LanSync', '已有会话,拒绝新连接');
        conn.close().catch((e: Error) => Log.w('LanSync', `关闭多余连接失败:${e.message}`));
        return;
      }
      const sender: FrameSender = async (bytes: Uint8Array): Promise<void> => {
        const buf = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        await conn.send({ data: buf as ArrayBuffer });
      };
      const ch = new LanSyncChannel(sender);
      conn.on('message', (info: socket.SocketMessageInfo) => {
        ch.onData(info.message);
      });
      conn.on('close', () => {
        ch.onClosed(LanSyncFail.IO, '对端已断开');
      });
      conn.on('error', (err: Object) => {
        const e = err as Error;
        ch.onClosed(LanSyncFail.IO, e.message);
      });
      this.channel = ch;
      this.runSession(ch, false, async (): Promise<void> => {
        await conn.close().catch((e: Error) => Log.w('LanSync', `关闭连接失败:${e.message}`));
      });
    });
    srv.on('error', (err: Object) => {
      const e = err as Error;
      Log.w('LanSync', `服务端错误:${e.message}`);
    });
    this.server = srv;
    this.listenOn(srv, LanSyncController.DEFAULT_PORT);
  }

  /**
   * 先试固定端口,再让系统分配。
   *
   * 鸿蒙文档说"bind 失败时系统随机分配端口",但那是**同一个 listen 调用内部**的行为 ——
   * 我们不能假设它一定发生,所以显式再试一次 `port: 0`,然后从 `getLocalAddress` 读回真实端口。
   * 端口会被写进广播,所以必须等 listen 完成之后再 advertise。
   */
  private listenOn(srv: socket.TCPSocketServer, port: number): void {
    srv.listen({ address: '0.0.0.0', port: port, family: 1 }).then(async () => {
      const addr = await srv.getLocalAddress();
      this.port = addr.port === undefined ? port : addr.port;
      if (this.stopping || !this.running) return;
      const m = this.material;
      if (m !== null) {
        this.advertise(m);
        this.state = this.freshListening(m.name);
        this.onState(this.state);
      }
      Log.i('LanSync', `监听成功 port=${this.port}`);
    }).catch((e: Error) => {
      if (port !== 0) {
        Log.w('LanSync', `绑定端口 ${port} 失败(${e.message}),改用系统分配`);
        this.listenOn(srv, 0);
      } else {
        this.fail(null, LanSyncFail.IO, `端口绑定失败:${e.message}`);
      }
    });
  }

  private advertise(m: LanSyncMaterial): void {
    if (this.port === 0) return;
    this.stopAdvertising();
    const attrs: mdns.ServiceAttribute[] = [{
      key: 'nm',
      value: LanSyncController.utf8Array(m.name.substring(0, 32))
    }];
    const info: mdns.LocalServiceInfo = {
      serviceType: LanSyncController.SERVICE_TYPE,
      serviceName: this.ownServiceName,
      port: this.port,
      serviceAttribute: attrs
    };
    this.localService = info;
    mdns.addLocalService(this.ctx, info).then(() => {
      Log.i('LanSync', `已广播 ${this.ownServiceName} 端口=${this.port}`);
    }).catch((e: Error) => {
      // 广播失败不影响手动地址;面板上一直写着本机地址。
      Log.w('LanSync', `广播失败(手动输入地址仍可用):${e.message}`);
    });
  }

  private stopAdvertising(): void {
    const info = this.localService;
    this.localService = null;
    if (info === null) return;
    mdns.removeLocalService(this.ctx, info).catch((e: Error) => {
      Log.w('LanSync', `撤销广播失败:${e.message}`);
    });
  }

  private startDiscovery(): void {
    if (this.discovery !== null) return;
    const d = mdns.createDiscoveryService(this.ctx, LanSyncController.SERVICE_TYPE);
    this.discovery = d;
    d.on('serviceFound', (info: mdns.LocalServiceInfo) => {
      if (info.serviceName === this.ownServiceName) return;
      mdns.resolveLocalService(this.ctx, info).then((resolved: mdns.LocalServiceInfo) => {
        const host = resolved.host;
        if (host === undefined || host.address === undefined || host.address.length === 0) return;
        const port = resolved.port === undefined ? LanSyncController.DEFAULT_PORT : resolved.port;
        const name = LanSyncController.nameFromAttributes(resolved.serviceAttribute, resolved.serviceName);
        this.mergePeer(new LanSyncPeer(name, host.address, port, resolved.serviceName));
      }).catch((e: Error) => {
        Log.w('LanSync', `解析服务失败(手动输入地址仍可用):${e.message}`);
      });
    });
    d.on('serviceLost', (info: mdns.LocalServiceInfo) => {
      this.peers = this.peers.filter((p: LanSyncPeer) => p.serviceName !== info.serviceName);
      this.publishPeers();
    });
    d.startSearchingMDNS();
  }

  private stopDiscovery(): void {
    const d = this.discovery;
    this.discovery = null;
    if (d === null) return;
    try {
      d.stopSearchingMDNS();
    } catch (e) {
      Log.w('LanSync', `停止发现失败:${(e as Error).message}`);
    }
  }

  private mergePeer(p: LanSyncPeer): void {
    let hit = false;
    for (let i = 0; i < this.peers.length; i++) {
      if (this.peers[i].serviceName === p.serviceName) {
        this.peers[i] = p;
        hit = true;
        break;
      }
    }
    if (!hit) this.peers.push(p);
    Log.i('LanSync', `发现 ${p.name}@${p.address()}`);
    this.publishPeers();
  }

  private publishPeers(): void {
    if (this.state.phase !== LanSyncPhase.LISTENING) return;
    this.state = this.copyListening();
    this.onState(this.state);
  }

  private freshListening(name: string): LanSyncViewState {
    const s = new LanSyncViewState();
    s.phase = LanSyncPhase.LISTENING;
    s.ownName = name;
    s.addresses = this.localAddresses();
    s.peers = this.peers.slice(0);
    return s;
  }

  private copyListening(): LanSyncViewState {
    return this.freshListening(this.state.ownName);
  }

  private async runSession(ch: LanSyncChannel, initiator: boolean, close: () => Promise<void>): Promise<void> {
    const m = this.material;
    if (m === null) {
      this.fail(null, LanSyncFail.IO, '本机身份未就绪');
      await close();
      return;
    }
    this.busy = true;
    this.stopping = false;
    // 桥用**类**而不是对象字面量:ArkTS 的 `arkts-no-untyped-obj-literals` 不接受
    // 「接口 + 字面量」这种形状(接口本身不够,它要的是显式声明的类)。
    const bridge = new LanSyncBridgeImpl(
      (peerName: string, code: string): Promise<boolean> => {
        return new Promise<boolean>((resolve) => {
          this.confirmWaiter = resolve;
          const s = new LanSyncViewState();
          s.phase = LanSyncPhase.CONFIRM;
          s.ownName = m.name;
          s.addresses = this.localAddresses();
          s.peers = this.peers.slice(0);
          s.peerName = peerName;
          s.code = code;
          this.state = s;
          this.onState(this.state);
        });
      },
      (peerName: string, stage: LanSyncStage, percent: number): void => {
        const s = new LanSyncViewState();
        s.phase = LanSyncPhase.SYNCING;
        s.ownName = m.name;
        s.addresses = this.localAddresses();
        s.peers = this.peers.slice(0);
        s.peerName = peerName;
        s.stage = stage;
        s.percent = Math.max(0, Math.min(100, percent));
        this.state = s;
        this.onState(this.state);
      }
    );
    const session = new LanSyncSession(
      m, ch, initiator, bridge,
      (): Promise<string> => LanSyncMerge.build(this.app),
      (json: string): Promise<Int32Array> => LanSyncMerge.apply(this.app, json)
    );
    try {
      const result = await session.run();
      this.state = new LanSyncViewState();
      this.state.phase = LanSyncPhase.DONE;
      this.state.ownName = m.name;
      this.state.addresses = this.localAddresses();
      this.state.peers = this.peers.slice(0);
      this.state.result = result;
      this.onState(this.state);
    } catch (e) {
      if (!this.stopping) {
        if (e instanceof LanSyncException) {
          Log.w('LanSync', `会话结束 ${e.fail}:${e.message}`);
          this.state = new LanSyncViewState();
          this.state.phase = LanSyncPhase.FAILED;
          this.state.ownName = m.name;
          this.state.addresses = this.localAddresses();
          this.state.peers = this.peers.slice(0);
          this.state.fail = e.fail;
          this.state.detail = e.message;
          this.onState(this.state);
        } else {
          Log.e('LanSync', `会话异常:${(e as Error).message}`);
          this.fail(null, LanSyncFail.IO, (e as Error).message);
        }
      }
    } finally {
      this.busy = false;
      this.channel = null;
      const w = this.confirmWaiter;
      this.confirmWaiter = null;
      if (w !== null) w(false);
      await close();
    }
  }

  private closeServer(): void {
    const srv = this.server;
    this.server = null;
    if (srv === null) return;
    srv.close().catch((e: Error) => Log.w('LanSync', `关闭监听失败:${e.message}`));
    this.stopAdvertising();
  }

  private fail(peer: string | null, fail: LanSyncFail, detail: string): void {
    Log.w('LanSync', `失败 ${fail}:${detail}`);
    this.state = new LanSyncViewState();
    this.state.phase = LanSyncPhase.FAILED;
    this.state.ownName = this.material === null ? '' : this.material.name;
    this.state.addresses = this.localAddresses();
    this.state.peers = this.peers.slice(0);
    this.state.peerName = peer === null ? '' : peer;
    this.state.fail = fail;
    this.state.detail = detail;
    this.onState(this.state);
  }

  /** 本机 Wi-Fi 上的 IPv4 地址(只要私网段)。没有地址时返回空表,界面提示检查 Wi-Fi。 */
  private localAddresses(): string[] {
    if (this.port === 0) return [];
    const out: string[] = [];
    // getConnectionProperties 是异步的,而这个方法在多个同步回调里用 —— 这里用**上一次**
    // 拉到的缓存(见 refreshAddresses),拿不到就退空表;地址只用于展示与手动输入,
    // 变了最多是提示旧一秒,不影响连接。
    for (let i = 0; i < this.cachedAddresses.length; i++) {
      out.push(`${this.cachedAddresses[i]}:${this.port}`);
    }
    return out;
  }

  private cachedAddresses: string[] = [];

  /** 拉一次本机私网 IPv4。start() 里调用;地址变化时刷新面板。 */
  private async refreshAddresses(): Promise<void> {
    try {
      const net = await connection.getDefaultNet();
      const props = await connection.getConnectionProperties(net);
      const list: string[] = [];
      for (let i = 0; i < props.linkAddresses.length; i++) {
        const a = props.linkAddresses[i].address;
        if (a.family !== 1 || !LanSyncController.isPrivateV4(a.address)) continue;
        if (list.indexOf(a.address) < 0) list.push(a.address);
      }
      this.cachedAddresses = list;
    } catch (e) {
      Log.w('LanSync', `读取本机地址失败:${(e as Error).message}`);
    }
  }

  private static isPrivateV4(ip: string): boolean {
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    const m = /^172\.(\d{1,3})\./.exec(ip);
    if (m !== null) {
      const n = Number.parseInt(m[1], 10);
      return n >= 16 && n <= 31;
    }
    return false;
  }

  private static parseTarget(raw: string): LanSyncTarget | null {
    let text = raw.trim();
    if (text.startsWith('http://')) text = text.substring(7);
    if (text.startsWith('https://')) text = text.substring(8);
    if (text.endsWith('/')) text = text.substring(0, text.length - 1);
    if (text.length === 0) return null;
    const colon = text.lastIndexOf(':');
    if (colon > 0 && text.split(':').length === 2) {
      const host = text.substring(0, colon).trim();
      const port = Number.parseInt(text.substring(colon + 1).trim(), 10);
      if (host.length === 0 || Number.isNaN(port) || port < 1 || port > 65535) return null;
      return new LanSyncTarget(host, port);
    }
    // 多个冒号 = IPv6 字面量。P0 不支持(地址栏提示照抄 IPv4 那行)。
    if (text.indexOf(':') >= 0) return null;
    return new LanSyncTarget(text, LanSyncController.DEFAULT_PORT);
  }

  private static utf8Array(text: string): number[] {
    const bytes = new util.TextEncoder().encodeInto(text);
    const out: number[] = [];
    for (let i = 0; i < bytes.length; i++) out.push(bytes[i]);
    return out;
  }

  private static nameFromAttributes(attrs: mdns.ServiceAttribute[] | undefined, fallback: string): string {
    if (attrs === undefined || attrs === null) return fallback;
    for (let i = 0; i < attrs.length; i++) {
      if (attrs[i].key !== 'nm') continue;
      const raw = attrs[i].value;
      if (raw === undefined || raw === null || raw.length === 0) continue;
      const bytes = new Uint8Array(raw.length);
      for (let j = 0; j < raw.length; j++) bytes[j] = raw[j];
      const text = new util.TextDecoder('utf-8').decodeToString(bytes).trim();
      if (text.length > 0) return text;
    }
    return fallback;
  }

  private static readonly DEFAULT_PORT: number = 47820;
  private static readonly SERVICE_TYPE: string = '_reverb._tcp';
}
