import formBindingData from '@ohos.app.form.formBindingData';
import fs from '@ohos.file.fs';
import { JsonFile } from '../store/JsonFile';
import { ArtworkCache } from '../store/ArtworkCache';
import { ConfigKeys, WidgetFormData, WidgetFormFields } from './WidgetFormData';
import { WidgetRuntime } from './WidgetRuntime';
import { Log } from '../util/Logger';

/**
 * 一次构建的产物。
 *
 * `data` 交给 formProvider;`fd` 是 `formImages` 里那张封面的文件句柄 —— 系统要**异步**去读它,
 * 所以**不能**在 build 里随手关掉,只能等 `updateForm` 回包之后再 `release()`。
 * 不关的话:卡片每 5 秒更新一次、每次都新开一个 fd,一两个小时后就把进程的 fd 表耗光。
 */
export class WidgetBuilt {
  readonly data: formBindingData.FormBindingData;
  fd: number = -1;
  private closed: boolean = false;

  constructor(data: formBindingData.FormBindingData) {
    this.data = data;
  }

  release(): void {
    if (this.closed || this.fd < 0) return;
    this.closed = true;
    try {
      fs.closeSync(this.fd);
    } catch (e) {
      Log.w('Widget', `封面句柄关闭失败 ${(e as Error).message}`);
    }
    this.fd = -1;
  }
}

/**
 * 拼一份卡片数据。FormExtensionAbility 与 App 内的 `WidgetUpdater` 共用这一段 ——
 * 两个进程都按同一份口径读盘、同一个字段名输出,避免"定时刷新画出来的和 App 推的不一样"。
 *
 * 调用前的要求:
 *  - `JsonFile.init` 已跑过(两份 JSON 的底座);
 *  - 在**扩展进程**里还要 `L.init(this.context)`,否则文案会退化成键名(UI 进程早就初始化过)。
 *
 * **图片必须走 `formImages`**:卡片渲染在桌面进程里,`file://` 沙箱路径它读不到。
 * 封面优先用 App 已经落好的 `artwork_cache/` 那一份,没有就把 `art` 传空串,卡片退回应用图标。
 */
export class WidgetFormBuilder {
  static build(dim: string, dark: boolean, forceImage: boolean = false): WidgetBuilt {
    const snap = WidgetFormData.read();
    const f: WidgetFormFields = WidgetFormData.fields(snap, dim, dark);
    const obj: Record<string, Object> = {};
    obj[ConfigKeys.TITLE] = f.title;
    obj[ConfigKeys.PODCAST] = f.podcast;
    obj[ConfigKeys.TIME] = f.time;
    obj[ConfigKeys.PERCENT] = f.percent;
    obj[ConfigKeys.HAS_PROGRESS] = f.hasProgress;
    obj[ConfigKeys.EMPTY] = f.empty;
    obj[ConfigKeys.DIM] = f.dim;
    obj[ConfigKeys.DARK] = f.dark;
    obj[ConfigKeys.PLAYING] = WidgetRuntime.readPlaying();
    obj[ConfigKeys.ART] = '';
    let fd = -1;
    if (f.artUrl.length > 0) {
      /**
       * 卡片侧是 `Image('memory://' + 键)`。**两件事都不能省**,它们是同一个 bug 的两面(见 H266):
       *  - 少了 `memory://` 前缀,卡片会把它当成资源路径去解析,结果是一张都不显示;
       *  - 键必须跟着封面走:系统的 Image 只按传进去的字符串判断要不要重绘,
       *    同一个键第二次送来直接复用上一张,换集之后封面永远停在旧的那张。
       *
       * 但键**由封面地址算出来**(`keyFor`),同一张封面在两个进程、两次启动之间都是同一个键。
       * 早先键里带时间戳,每 5 秒一推、每按一次键都让桌面重新解码一遍封面,
       * 视觉上整张卡闪一下(用户原话「点播放按钮,整个组件都在动」,2026-11-12)。
       *
       * **只在必须的时候才带 `formImages`**:这一进程还没送过这个键、封面换了、或表单刚创建。
       * 其余更新只送同一个 `memory://` 键,卡片直接复用已有解码结果 —— 进度刷新与按键反馈
       * 不再牵动封面。`updateForm` 是增量合并,不带的字段保持原值。
       */
      const key = WidgetFormBuilder.keyFor(f.artUrl);
      obj[ConfigKeys.ART] = `memory://${key}`;
      if (forceImage || key !== WidgetFormBuilder.lastSentKey) {
        fd = WidgetFormBuilder.openArt(f.artUrl);
        if (fd >= 0) {
          const images: Record<string, Object> = {};
          images[key] = fd;
          obj['formImages'] = images;
          WidgetFormBuilder.lastSentKey = key;
          // 只在真的送图时打一条:5 秒一次的进度更新不该刷屏,而"换集/进程重启后送了一次"
          // 正是排障时要确认的那件事(2026-11-12 用这条日志验过按键不再牵动封面)。
          Log.i('Widget', `封面数据送出 key=${key}`);
        } else {
          // 本地缓存里没有这一张:请缓存层去下一份,下一次刷新(5 秒后 / 下一次状态变化)就能用上。
          // 只对 UI 进程有效 —— 扩展进程没有 init 过 ArtworkCache,`ensure` 会立刻返回。
          WidgetFormBuilder.lastSentKey = '';
          ArtworkCache.get().ensure(f.artUrl, null);
        }
      }
    } else {
      // 没有封面(空态 / 还没缓存到):清掉"已送过"的记录,下次有了才会真的带图。
      WidgetFormBuilder.lastSentKey = '';
    }
    const built = new WidgetBuilt(formBindingData.createFormBindingData(obj));
    built.fd = fd;
    return built;
  }

  /**
   * 上一次**真的把图片数据送出去**的键。
   *
   * 为什么不是"上次算出来的键":键现在由地址决定、天然稳定,但图片数据是不是已经在
   * 桌面进程里,只有"本进程送过没有"知道。进程刚起来时这里是空串 ⇒ 第一轮必然带图,
   * 之后同一张封面就不再重复解码。
   */
  private static lastSentKey: string = '';

  /**
   * 封面地址 → 图片键。**纯函数**:同一个地址永远得到同一个键。
   *
   * 为什么不用时间戳/序号:卡片有两条更新路径(UI 进程的 `WidgetUpdater` 与扩展进程的
   * `onUpdateForm`),带序号的键两边的"当前键"迟早不一致 —— 一边送 A、另一边按 B 复用,
   * 封面会时有时无。由地址算出来的键两边天然一致,也不会把别的集的封面串过来。
   *
   * 形状是 `art_<hash>_<长度>`:只含小写字母/数字/下划线且以字母开头 —— 图片键的命名
   * 要求是这一组,写错不报错,只会静默不显示。
   * djb2 变体算 32 位,拼上长度让碰撞概率再低一档;碰撞的唯一后果是复用了一张旧封面。
   */
  private static keyFor(url: string): string {
    let h = 5381;
    for (let i = 0; i < url.length; i++) {
      h = (((h << 5) + h) ^ url.charCodeAt(i)) >>> 0;
    }
    return `art_${h.toString(36)}_${url.length}`;
  }

  /// 返回封面文件的 fd,没有缓存就 -1(调用方据此决定是否带 formImages)。
  private static openArt(url: string): number {
    if (url.length === 0) return -1;
    try {
      const path = ArtworkCache.pathFor(JsonFile.root(), url);
      if (!fs.accessSync(path)) return -1;
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      return file.fd;
    } catch (e) {
      Log.w('Widget', `封面打开失败 ${(e as Error).message}`);
      return -1;
    }
  }
}
