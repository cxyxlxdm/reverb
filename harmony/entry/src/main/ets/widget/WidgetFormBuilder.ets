import formBindingData from '@ohos.app.form.formBindingData';
import fs from '@ohos.file.fs';
import { JsonFile } from '../store/JsonFile';
import { ArtworkCache } from '../store/ArtworkCache';
import { ConfigKeys, WidgetFormData, WidgetFormFields } from './WidgetFormData';
import { Log } from '../util/Logger';

/**
 * 一次构建的产物。
 *
 * `data` 交给 formProvider;`fd` 是 `formImages` 里那张封面的文件句柄 —— 系统要**异步**去读它,
 * 所以**不能**在 build 里随手关掉,只能等 `updateForm` 回包之后再 `release()`。
 * 不关的话:卡片每 20 秒更新一次、每次都新开一个 fd,一两个小时后就把进程的 fd 表耗光。
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
  static build(dim: string, dark: boolean): WidgetBuilt {
    const snap = WidgetFormData.read();
    const f: WidgetFormFields = WidgetFormData.fields(snap, dim, dark);
    const obj: Record<string, Object> = {};
    obj[ConfigKeys.LABEL] = f.label;
    obj[ConfigKeys.TITLE] = f.title;
    obj[ConfigKeys.PODCAST] = f.podcast;
    obj[ConfigKeys.TIME] = f.time;
    obj[ConfigKeys.PERCENT] = f.percent;
    obj[ConfigKeys.HAS_PROGRESS] = f.hasProgress;
    obj[ConfigKeys.EMPTY] = f.empty;
    obj[ConfigKeys.DIM] = f.dim;
    obj[ConfigKeys.DARK] = f.dark;
    obj[ConfigKeys.ART] = '';
    const fd = WidgetFormBuilder.openArt(f.artUrl);
    if (fd >= 0) {
      obj[ConfigKeys.ART] = ConfigKeys.ART_KEY;
      const images: Record<string, Object> = {};
      images[ConfigKeys.ART_KEY] = fd;
      obj['formImages'] = images;
    }
    const built = new WidgetBuilt(formBindingData.createFormBindingData(obj));
    built.fd = fd;
    return built;
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
