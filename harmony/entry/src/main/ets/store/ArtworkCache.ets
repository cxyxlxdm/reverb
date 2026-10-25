import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import image from '@ohos.multimedia.image';
import fileUri from '@ohos.file.fileuri';
import { Log } from '../util/Logger';

/// 一条本地图片缓存的内存条目(只在本进程生命周期内存在)
interface Entry {
  size: number;
  mtime: number;
  uri: string;
  /**
   * 这个文件是为**哪个 URL** 下的;`''` = 不知道(本次启动由 `scan()` 从目录里认回来的)。
   * 只为 低·族A 的回验而存在(见 `uriFor`),不落盘 —— 本类刻意**没有账本文件**(见类注释),
   * 为一个哈希回验引入第四种持久化数据不值得。
   */
  url: string;
}

/**
 * 封面的磁盘缓存 `filesDir/artwork_cache/`。
 *
 * 为什么必须自研:ArkUI 的 `Image(url)` 没有可依赖的离线磁盘缓存 —— 本端此前所有封面都是
 * 直连 URL(全项目 11 处都经由 `Widgets.ets` 的 Artwork / SquareArtwork 两个组件),
 * 于是「断网后已加载过的列表」文字还在、图片全空。Android 端由 Coil 的磁盘缓存天然覆盖,
 * 这一端没有对应库(也不引第三方 SDK),所以自己落一份文件。
 *
 * **没有账本文件**:文件名由 URL 哈希直接算得出,目录本身就是账。这样做的收益是
 * 不存在「账上有、文件没落地」这一类 bug(音频那边有账本是因为要按集数做预算淘汰、
 * 要记 lastAccess 做 LRU;图片不需要这两个信息,就别引入第三种不一致)。
 *
 * 淘汰按**下载时间(mtime)**而不是访问时间:图片是可重取的小对象,淘汰只影响"再看一遍时
 * 要不要联网",不值得为它在渲染路径上写盘(硬规矩 6)。
 *
 * 与音频不同,**不走蜂窝闸门**:一封面几十 KB,而 Android 端 Coil 的缓存同样不因计费网络
 * 而停写 —— 两端在这条上是刻意一致的。
 */
export class ArtworkCache {
  /** 封面缓存预算。按 30 KB/张算约容 700 张,足够覆盖"最近翻过的所有频道"。 */
  private static readonly BUDGET_BYTES = 20 * 1024 * 1024;
  /// 同时在飞的封面下载上限(见 pump)
  private static readonly MAX_CONCURRENT = 4;

  private static inst: ArtworkCache | null = null;
  static get(): ArtworkCache {
    if (ArtworkCache.inst === null) ArtworkCache.inst = new ArtworkCache();
    return ArtworkCache.inst;
  }

  private dir = '';
  /// 文件名 → 内存条目(存在性判据)。界面每次都查这张表,所以**不能有同步 IO**。
  private entries: Map<string, Entry> = new Map();
  private pending: Set<string> = new Set();
  /// 待办队列 [文件名, URL];并发上限见 pump()。
  private queue: string[][] = [];
  private active = 0;
  /**
   * 失败冷却表 文件名 → 失败时刻(ms)。
   *
   * 为什么必须有:断网浏览正是要支持的场景 —— 一屏 30 张封面全 miss,每张都要试一次连接、
   * 等一次超时。没有这张表,用户把列表滚下去再滚回来,就又是一整轮 30 次注定失败的请求,
   * 还把真正要看的图挤在队列后面。设了冷却又不能没有出口,所以它是**有时限的**:
   * 过 [RETRY_MS] 允许再试,网络恢复后不需要重启应用就能补齐。
   */
  private failedAt: Map<string, number> = new Map();
  private static readonly RETRY_MS = 60000;
  /**
   * 清理代号:每清一次 +1。在飞的下载落盘前要比对它,不一致就丢弃。
   *
   * 没有这一格的后果是「清除缓存」这个按钮**看起来没生效**:按下时正好有几张封面在传,
   * 它们会在目录清空之后把文件 rename 回来,设置页上那个字节数当场又变成非 0。
   * 与 `AudioCacheManager` 那边比对 `inFlightId` 是同一个形状。
   */
  private gen = 0;
  /// 落盘成功后要通知的等待者(封面组件进来时 url 还没缓存,写好得让它换成本地源)
  private waiters: Map<string, Array<(uri: string) => void>> = new Map();
  private total = 0;

  init(filesDir: string): void {
    this.dir = `${filesDir}/artwork_cache`;
    try {
      if (!fs.accessSync(this.dir)) fs.mkdirSync(this.dir);
    } catch (e) {
      Log.w('Artwork', `创建目录失败 ${(e as Error).message}`);
    }
    this.scan();
  }

  /// 已有本地副本时返回可直接交给 `Image()` 的沙箱 uri,否则 null。
  /**
   * 命中时做一次 **url 回验**(见 REVIEW-2026-10-25 低·族A ②):文件名是 url 的 int32 哈希,
   * 两个不同 url 撞名时会互相顶掉,症状是「A 频道显示 B 频道的封面」。本类没有账本文件,
   * 所以只有**本次进程下过的**那些知道自己是为什么 url 落的盘(`scan()` 认回来的 url 为空,
   * 无从证伪,只能照旧接受 —— 这是"不引入第四份持久化数据"的代价,写在 `Entry.url` 上)。
   * 回验不过就按未命中处理:返回 null,让调用方去 `ensure()` 重新下一份正确的覆盖回来,能自愈。
   */
  uriFor(url: string): string | null {
    if (url.length === 0 || this.dir.length === 0) return null;
    const e = this.entries.get(ArtworkCache.nameOf(url));
    if (e === undefined) return null;
    if (e.url.length > 0 && e.url !== url) {
      Log.w('Artwork', `封面缓存 url 不符,判为未命中(哈希撞名)—— 见 REVIEW-2026-10-25 低·族A`);
      return null;
    }
    return e.uri;
  }

  /**
   * 请缓存这一张(幂等;已在缓存 / 已在队 / 目录没就绪都直接返回)。
   * [onReady] 在本次落盘成功时回调,供封面组件把源换成本地 uri。
   *
   * **一律排队,最多同时 [MAX_CONCURRENT] 张**:一屏宫格能出现 30 张以上没缓存过的封面,
   * 若每个组件各自直接开流,同一瞬间就是 30 条并发下载 —— 带宽和 fd 都吃紧,而首屏要的这些
   * 图反而被自己挤慢。
   */
  ensure(url: string, onReady: ((uri: string) => void) | null): void {
    if (url.length === 0 || this.dir.length === 0) return;
    const name = ArtworkCache.nameOf(url);
    const have = this.entries.get(name);
    // 与 `uriFor` 同一道回验(低·族A ②):这里如果只判"名字在不在",撞名时会把别人的封面
    // 直接回调给组件,那条路径比 uriFor 更隐蔽(它在下载完成时也会走)。
    // 判为不可用就走下面的重新下载 —— 覆盖写回同一个文件名,并把 entry.url 改成正确的 url,自愈。
    if (have !== undefined && (have.url.length === 0 || have.url === url)) {
      if (onReady !== null) onReady(have.uri);
      return;
    }
    const failed = this.failedAt.get(name);
    if (failed !== undefined && Date.now() - failed < ArtworkCache.RETRY_MS) return;
    if (onReady !== null) {
      const list = this.waiters.get(name);
      if (list === undefined) this.waiters.set(name, [onReady]);
      else list.push(onReady);
    }
    if (this.pending.has(name)) return;
    this.pending.add(name);
    this.queue.push([name, url]);
    this.pump();
  }

  private pump(): void {
    while (this.active < ArtworkCache.MAX_CONCURRENT && this.queue.length > 0) {
      const job = this.queue.shift();
      if (job === undefined) break;
      const name = job[0];
      const url = job[1];
      this.active++;
      this.fetch(url, name).then((ok: number) => {
        this.active--;
        this.pending.delete(name);
        // 2 = 被「清除缓存」拦下的,不记失败(那次传输本身是好的,只是落盘时机不对)
        if (ok !== 0) {
          if (ok === 1) this.failWaiters(name);
          else this.waiters.delete(name);
          this.pump();
          return;
        }
        const uri = fileUri.getUriFromPath(`${this.dir}/${name}`);
        const st = this.statQuiet(`${this.dir}/${name}`);
        // 覆盖同一个文件名时先把旧尺寸从预算里扣掉,否则 total 只会单调变大、把没占空间的
        // 文件算成占过(撞名重下这条路会反复走到,见 uriFor 的回验)。
        const prev = this.entries.get(name);
        if (prev !== undefined) this.total -= prev.size;
        this.entries.set(name, { size: st[0], mtime: st[1], uri: uri, url: url });
        this.total += st[0];
        this.failedAt.delete(name);
        const ws = this.waiters.get(name);
        this.waiters.delete(name);
        if (ws !== undefined) {
          for (let i = 0; i < ws.length; i++) ws[i](uri);
        }
        if (this.total > ArtworkCache.BUDGET_BYTES) this.evict();
        this.pump();
      }).catch((err: Error) => {
        this.active--;
        this.pending.delete(name);
        this.failWaiters(name);
        Log.w('Artwork', `缓存失败 ${err.message}`);
        this.pump();
      });
    }
  }

  /// 「清除缓存」用:整目录清空 + 内存表作废(队列里没开始的那些也别再跑)。
  async clearAll(): Promise<void> {
    this.gen++;
    this.entries.clear();
    this.waiters.clear();
    this.failedAt.clear();
    this.queue = [];
    this.total = 0;
    // **不清 pending**:里面是正在传输的那些,它们会在 rename 前被 gen 拦下。
    // 清了反而让同一个 URL 被再排一份,两份写同一个 `.part`。
    if (this.dir.length === 0) return;
    try {
      const names = await fs.listFile(this.dir);
      for (let i = 0; i < names.length; i++) {
        try {
          await fs.unlink(`${this.dir}/${names[i]}`);
        } catch (e) {
          // 忽略
        }
      }
      Log.i('Artwork', `清空 ${names.length} 个文件`);
    } catch (e) {
      Log.w('Artwork', `清目录失败 ${(e as Error).message}`);
    }
  }

  count(): number {
    return this.entries.size;
  }

  usageBytes(): number {
    return this.total;
  }

  /** 启动时扫一次目录把已有副本装进内存表(异步,不在启动路径上;晚到只是首屏走远程)。 */
  private async scan(): Promise<void> {
    if (this.dir.length === 0) return;
    try {
      const names = await fs.listFile(this.dir);
      let sum = 0;
      for (let i = 0; i < names.length; i++) {
        const p = `${this.dir}/${names[i]}`;
        try {
          const st = await fs.stat(p);
          if (st.size <= 0) {
            await fs.unlink(p);
            continue;
          }
          sum += st.size;
          // url 记空:目录本身就是账,扫回来的文件无从知道它是为哪个 url 下的(见 Entry.url),
          // 所以这一类条目在 `uriFor` 的回验里按"不能证伪就算可用"处理。
          this.entries.set(names[i], { size: st.size, mtime: st.mtime, uri: fileUri.getUriFromPath(p), url: '' });
        } catch (e) {
          // 单个文件读不到就跳过
        }
      }
      this.total = sum;
      Log.i('Artwork', `本地封面 ${this.entries.size} 张 ${Math.round(sum / 1024)}KB`);
      if (sum > ArtworkCache.BUDGET_BYTES) this.evict();
    } catch (e) {
      Log.w('Artwork', `扫描失败 ${(e as Error).message}`);
    }
  }

  /** 0 = 落盘成功;1 = 这次没成;2 = 中途被「清除缓存」作废(别记进失败冷却)。 */
  private async fetch(url: string, name: string): Promise<number> {
    const target = `${this.dir}/${name}`;
    const part = `${target}.part`;
    const req = http.createHttp();
    const myGen = this.gen;
    let file: fs.File | null = null;
    try {
      file = await fs.open(part, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const fd = file.fd;
      let chain: Promise<void> = Promise.resolve();
      let written = 0;
      let writeFailed = '';
      req.on('dataReceive', (chunk: ArrayBuffer) => {
        chain = chain.then((): Promise<void> => {
          if (writeFailed.length > 0) return Promise.resolve();
          return fs.write(fd, chunk).then((n: number) => { written += n; })
            .catch((err: Error) => { writeFailed = err.message; });
        });
      });
      const code = await req.requestInStream(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Reverb/1.0 (HarmonyOS podcast client)' },
        connectTimeout: 10000,
        readTimeout: 20000
      });
      await chain;
      await fs.close(file);
      file = null;
      if (code !== 200 || writeFailed.length > 0 || written === 0) {
        await this.unlinkQuiet(part);
        return 1;
      }
      // **验一遍能解码才认**:文件名里的扩展名是从 URL 猜的,而 CDN 常把 webp 挂在 .jpg 上。
      // 猜错的后果不是"缓存没用上"而是**界面从此显示一张空白**(本地源被 ArkUI 判成坏图),
      // 比没有缓存更糟。所以这里用图片头判断一次,判不过就删掉、继续用远程源。
      if (!await this.decodable(part)) {
        Log.w('Artwork', `解码校验未过,丢弃 ${name}`);
        await this.unlinkQuiet(part);
        return 1;
      }
      // 传输期间用户按了「清除缓存」:目录已经空了,这张不能再 rename 回去(见 gen)
      if (myGen !== this.gen) {
        await this.unlinkQuiet(part);
        return 2;
      }
      await this.unlinkQuiet(target);
      await fs.rename(part, target);
      return 0;
    } catch (e) {
      if (file !== null) {
        try {
          await fs.close(file);
        } catch (e2) {
          // 忽略
        }
      }
      await this.unlinkQuiet(part);
      return 1;
    } finally {
      try {
        req.off('dataReceive');
        req.destroy();
      } catch (e3) {
        // 忽略
      }
    }
  }

  private async decodable(path: string): Promise<boolean> {
    let src: image.ImageSource | null = null;
    try {
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        src = image.createImageSource(f.fd);
        const info = await src.getImageInfo();
        return info.size.width > 0 && info.size.height > 0;
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      return false;
    } finally {
      if (src !== null) {
        try {
          await src.release();
        } catch (e2) {
          // 忽略
        }
      }
    }
  }

  private async evict(): Promise<void> {
    // 按 mtime 从旧到新删。当前正要显示的那张是最新的,排在末尾;预算(20MB)远大于单张封面,
    // 正常路径删到低于预算就停,轮不到它。
    const keys: string[] = [];
    this.entries.forEach((v: Entry, k: string) => { keys.push(k); });
    keys.sort((a: string, b: string): number => {
      const ea = this.entries.get(a);
      const eb = this.entries.get(b);
      return (ea === undefined ? 0 : ea.mtime) - (eb === undefined ? 0 : eb.mtime);
    });
    for (let i = 0; i < keys.length && this.total > ArtworkCache.BUDGET_BYTES; i++) {
      const e = this.entries.get(keys[i]);
      if (e === undefined) continue;
      await this.unlinkQuiet(`${this.dir}/${keys[i]}`);
      this.entries.delete(keys[i]);
      this.total -= e.size;
    }
    Log.i('Artwork', `预算淘汰后 ${this.entries.size} 张 ${Math.round(this.total / 1024)}KB`);
  }

  /// 这一张没取成:丢掉等待者并记下时刻,让 [RETRY_MS] 内的重复请求直接跳过(见 failedAt)。
  private failWaiters(name: string): void {
    this.waiters.delete(name);
    this.failedAt.set(name, Date.now());
  }

  /// [size, mtime];拿不到就报 (0, 0) —— 大小为 0 不占预算,mtime 排最旧会被下一轮淘汰优先清掉。
  private statQuiet(p: string): number[] {
    try {
      const st = fs.statSync(p);
      return [st.size, st.mtime];
    } catch (e) {
      return [0, 0];
    }
  }

  private async unlinkQuiet(p: string): Promise<void> {
    try {
      if (await fs.access(p)) await fs.unlink(p);
    } catch (e) {
      // 忽略
    }
  }

  /// 文件名:art_<url 简易哈希><从 URL 猜的扩展名>。扩展名只是给解码器一个提示,
  /// 真判据是上面那次 decodable(URL 无后缀时统一按 .jpg 命名)。
  /**
   * 哈希是 int32,**不是唯一键**(见 REVIEW-2026-10-25 低·族A)。撞名的后果是两张封面互相顶掉,
   * 所以这里只做两件小事、不改哈希本体:
   *  ① 种子放**串长**:原先 h 从 0 起,长度信息第一轮就被 `|0` 绕掉,长短不同的 url 更容易同余;
   *  ② 命中路径按 url 回验(见 `uriFor` / `ensure`),不符就重下、覆盖回来。
   * **刻意不给撞名换后缀**(与 ca_/dl_ 不同):本类没有账本,文件名本身就是唯一的查找路径,
   * 换了名老文件就再也算不出来 —— 它既不会被 `uriFor` 命中,也只能等预算淘汰慢慢清掉。
   * 加长种子同样让**装机时已在盘上的旧命名**算不出来,表现是"首屏封面重新拉一次",
   * 旧文件由 mtime 淘汰收尾;图片是可重取的小对象,这一笔换"不再串图"是划算的。
   * Android 侧这一族由另一个代理同步加长;缓存文件名**不是三端互通格式**,不要求两端逐字节相同。
   */
  private static nameOf(url: string): string {
    let h = url.length;
    for (let i = 0; i < url.length; i++) {
      h = (h * 31 + url.charCodeAt(i)) | 0;
    }
    const base = `art_${h < 0 ? `n${-h}` : `${h}`}`;
    const lower = url.toLowerCase();
    if (lower.indexOf('.png') >= 0) return `${base}.png`;
    if (lower.indexOf('.webp') >= 0) return `${base}.webp`;
    if (lower.indexOf('.gif') >= 0) return `${base}.gif`;
    if (lower.indexOf('.avif') >= 0) return `${base}.avif`;
    return `${base}.jpg`;
  }
}
