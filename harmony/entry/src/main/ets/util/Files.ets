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

/// 文档选择/保存(备份导出导入、OPML、日志导出都走这里)。
/// 用系统文件选择器,**不申请任何存储权限**——用户选到哪就写到哪。
export class Files {
  /**
   * 唤起系统分享面板分享一段文本(设置页「分享日志」用)。
   *
   * Android 侧是「分享日志」+「发送日志到开发者邮箱」两条,因为 Android 要靠显式的
   * ACTION_SEND / mailto Intent 分别处理;鸿蒙的系统分享面板本身就把邮件、即时通讯、
   * 存文件等去向都列在一起 —— **平台原生做法是一条**,故这里合成一项。
   */
  static async shareText(ctx: common.UIAbilityContext, title: string, text: string): Promise<boolean> {
    try {
      const data = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content: text,
        title: title
      });
      await new systemShare.ShareController(data).show(ctx, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
      Log.i('Files', '已唤起系统分享面板');
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

  /// 让用户选一个保存位置并写入文本。返回是否成功。
  static async saveText(ctx: common.UIAbilityContext, suggestName: string, text: string): Promise<boolean> {
    try {
      const p = new picker.DocumentViewPicker(ctx);
      const uris = await p.save({ newFileNames: [suggestName] });
      if (uris.length === 0) {
        Log.i('Files', '用户取消保存');
        return false;
      }
      // 异步写:备份文件可达几 MB,同步写会卡住 UI 线程(见 H65)
      const f = await fs.open(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      await fs.write(f.fd, text);
      await fs.close(f);
      Log.i('Files', `已保存 ${suggestName}`);
      return true;
    } catch (e) {
      Log.e('Files', `保存失败 ${(e as Error).message}`);
      return false;
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
