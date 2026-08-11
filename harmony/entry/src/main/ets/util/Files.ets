import { picker } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import type common from '@ohos.app.ability.common';
import { Log } from './Logger';

/// 文档选择/保存(备份导出导入、OPML、日志导出都走这里)。
/// 用系统文件选择器,**不申请任何存储权限**——用户选到哪就写到哪。
export class Files {
  /// 让用户选一个保存位置并写入文本。返回是否成功。
  static async saveText(ctx: common.UIAbilityContext, suggestName: string, text: string): Promise<boolean> {
    try {
      const p = new picker.DocumentViewPicker(ctx);
      const uris = await p.save({ newFileNames: [suggestName] });
      if (uris.length === 0) {
        Log.i('Files', '用户取消保存');
        return false;
      }
      const f = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
      Log.i('Files', `已保存 ${suggestName}`);
      return true;
    } catch (e) {
      Log.e('Files', `保存失败 ${(e as Error).message}`);
      return false;
    }
  }

  /// 让用户选一个文件并读出文本。取消或失败返回 null。
  static async pickText(ctx: common.UIAbilityContext): Promise<string | null> {
    try {
      const p = new picker.DocumentViewPicker(ctx);
      const uris = await p.select({ maxSelectNumber: 1 });
      if (uris.length === 0) return null;
      const f = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(f.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      return new util.TextDecoder().decodeToString(new Uint8Array(buf));
    } catch (e) {
      Log.e('Files', `读取失败 ${(e as Error).message}`);
      return null;
    }
  }
}
