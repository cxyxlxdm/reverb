import { picker } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { systemShare } from '@kit.ShareKit';
import fileUri from '@ohos.file.fileuri';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import type common from '@ohos.app.ability.common';
import { Log } from './Logger';

/// `Files.pickText` 的结果。三种形状:
///  - `cancelled` = 用户取消(`text` 无意义);
///  - `text.length === 0` 且未取消 = 选了但读不出来;
///  - 其余 = 拿到了内容。
/// 之所以不是 `string | null`:调用侧要能分「取消」与「失败」,否则提示会说谎。
export class PickedText {
  cancelled: boolean = false;
  text: string = '';
}

/// `Files.saveText` 的结果。与 `PickedText` 同一口径,三态而不是 boolean:
///  - `cancelled` = 用户取消(位置压根没选)—— **不是失败**,调用侧不该给任何提示;
///  - `cancelled === false && ok` = 真的写进去了;
///  - 其余 = 选了位置但写失败。
/// 为什么不能是 boolean:boolean 只有两个位置可站,取消就只能落在「失败」那一侧,
/// 于是用户按了「取消」会看到一句「操作未完成」。
export class SavedResult {
  cancelled: boolean = false;
  ok: boolean = false;
}

/// 文档选择/保存(备份导出导入、OPML、日志导出都走这里)。
/// 用系统文件选择器,**不申请任何存储权限**——用户选到哪就写到哪。
export class Files {
  /**
   * 把一段文本**落成缓存文件**后经系统分享面板分享(设置页「分享日志」「发送日志到开发者邮箱」用)。
   *
   * 为什么不直接分享字符串(本函数原先就是这么做的):Android 侧的 `shareLog` 走的是
   * `EXTRA_STREAM` + 一个真实的 `reverb-log.txt`,**收件应用拿到的是文件**;而
   * `utd.PLAIN_TEXT` + `content` 是内联文本,绝大多数即时通讯与邮件目标会**截断**长文本,
   * 文件名与扩展名也一起丢掉 —— 一份几十 KB 的运行日志正好落在被截的那一段里。
   * 改成文件之后两端同口径,而且「邮件反馈」那条本来就必须是附件。
   *
   * 与 `shareImage` 共用同一条 URI 规矩:**必须 `fileUri.getUriFromPath()`**,
   * 自己拼 `file://` + 沙箱路径的表现是面板压根不弹(见该函数的注释)。
   *
   * `title` / `description` 对应 Android 的 `EXTRA_SUBJECT` / `EXTRA_TEXT`。
   * ⚠️ `title` 在本端**不只是标签**:它同时是「另存为」的默认文件名。所以调用方要传
   * **内容的名字**(集名、日志文件名…),不能传按钮文案 —— 传「导出逐字稿」时
   * 存下来的文件就叫 `导出逐字稿.txt`,见 H263。
   * 本端**做不到**的只有收件人预填:`systemShare.SharedRecord` 没有收件人字段,
   * 分享面板也不接受"定向到邮件应用"的参数 —— 所以那条的副标题把邮箱地址写在屏上。
   */
  static async shareText(ctx: common.UIAbilityContext, title: string, fileName: string, text: string, description: string): Promise<boolean> {
    try {
      const path = `${ctx.cacheDir}/${fileName}`;
      // 异步写:日志可达几十 KB,同步写在低优先级线程上会卡住面板唤起(见 H65)
      const f = await fs.open(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      await fs.write(f.fd, text);
      await fs.close(f);
      const data = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        uri: fileUri.getUriFromPath(path),
        title: title,
        description: description
      });
      await new systemShare.ShareController(data).show(ctx, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
      Log.i('Files', `已唤起系统分享面板 ${fileName}`);
      return true;
    } catch (e) {
      Log.e('Files', `分享失败 ${(e as Error).message}`);
      return false;
    }
  }

  /**
   * 唤起系统分享面板分享一张本地图片(剪藏「分享此刻」、足迹海报用)。
   * 与 shareText 的区别只在 utd 与载荷:图片走 uri,文本走 content。
   *
   * **URI 必须用 `fileUri.getUriFromPath()` 生成**,不能自己拼 `file://` + 沙箱绝对路径:
   * 图片在应用私有目录里,别的应用没有读权限;`getUriFromPath` 产出的是带 bundle 归属的
   * 应用文件 URI,分享框架据此做临时授权。拼裸路径的表现是**面板压根不弹**(而不是报错),
   * 很容易误判成"分享 API 没生效"—— 这次就是先看到海报 PNG 已生成、才定位到是 URI 的问题。
   */
  static async shareImage(ctx: common.UIAbilityContext, title: string, pngPath: string): Promise<boolean> {
    try {
      const data = new systemShare.SharedData({
        utd: utd.UniformDataType.IMAGE,
        uri: fileUri.getUriFromPath(pngPath),
        title: title
      });
      await new systemShare.ShareController(data).show(ctx, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
      Log.i('Files', '已唤起图片分享面板');
      return true;
    } catch (e) {
      Log.e('Files', `图片分享失败 ${(e as Error).message}`);
      return false;
    }
  }

  /**
   * 让用户选一个保存位置并写入文本。
   *
   * **取消与写失败要分开标**(`SavedResult`)。本端原先返回 boolean,于是取消只能落在
   * `false` 那一侧,三个调用点各弹一句「操作未完成」;而 Android 的
   * `CreateDocument` 回调是 `if (uri != null) { … }` —— **取消时什么都不说**,
   * 只有真的写失败才给提示。这里对齐到那个口径(见 H141 装机复验)。
   */
  static async saveText(ctx: common.UIAbilityContext, suggestName: string, text: string): Promise<SavedResult> {
    const out = new SavedResult();
    try {
      const p = new picker.DocumentViewPicker(ctx);
      const uris = await p.save({ newFileNames: [suggestName] });
      if (uris.length === 0) {
        Log.i('Files', '用户取消保存');
        out.cancelled = true;
        return out;
      }
      // 异步写:备份文件可达几 MB,同步写会卡住 UI 线程(见 H65)
      const f = await fs.open(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      await fs.write(f.fd, text);
      await fs.close(f);
      Log.i('Files', `已保存 ${suggestName}`);
      out.ok = true;
      return out;
    } catch (e) {
      Log.e('Files', `保存失败 ${(e as Error).message}`);
      // cancelled 保持 false、ok 保持 false = 「选了位置但没写进去」
      return out;
    }
  }

  /**
   * 让用户选一个文件并读出文本。
   *
   * **取消与读失败要分开标**(见返回的 `PickedText`)。本端原先两条都返回 `null`,
   * 于是调用侧只能给一个提示 —— 用户只是按了「取消」也会看到「操作未完成」。
   * Android 的 `OpenDocument` 回调里 `uri == null` 是**什么都不提示**,只有读不出内容
   * 或内容不像备份才报 `backup_invalid`;这里对齐到那个口径。
   */
  static async pickText(ctx: common.UIAbilityContext): Promise<PickedText> {
    const out = new PickedText();
    try {
      const p = new picker.DocumentViewPicker(ctx);
      const uris = await p.select({ maxSelectNumber: 1 });
      if (uris.length === 0) {
        Log.i('Files', '用户取消选择');
        out.cancelled = true;
        return out;
      }
      const f = await fs.open(uris[0], fs.OpenMode.READ_ONLY);
      const stat = await fs.stat(f.fd);
      const buf = new ArrayBuffer(stat.size);
      await fs.read(f.fd, buf);
      await fs.close(f);
      out.text = new util.TextDecoder().decodeToString(new Uint8Array(buf));
      return out;
    } catch (e) {
      Log.e('Files', `读取失败 ${(e as Error).message}`);
      // cancelled 保持 false、text 保持空串 = 「选了但没读出来」
      return out;
    }
  }
}
