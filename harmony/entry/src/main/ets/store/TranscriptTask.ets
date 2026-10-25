import fs from '@ohos.file.fs';
import { TranscribedSegment, TranscribedWord } from '../model/Models';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/**
 * 逐字稿缓存的读写 —— 放在 **TaskPool 子线程**里做。
 *
 * 为什么:这是本应用会写的**最大一份 JSON**。真机验过的那一集是 1345 句 / 10245 条
 * 词级条目,文件接近 1 MB;原先 `readTextSync` + `JSON.parse` + 一万多个对象的构造
 * (以及写回时的 `JSON.stringify` + `writeSync`)全在 UI 线程上,
 * 打开逐字稿页与转写完成时各卡一次(同 H65:ArkTS 没有协程,同步就是占调用线程)。
 *
 * Android 侧本来就在 `Dispatchers.Default` 的协程里做同一件事,不受影响。
 *
 * 约定:参数与返回值都必须可序列化 —— 传路径与纯数据,不传类实例、不传函数。
 */

/// 读缓存的产出。`stale` 表示"文件在,但口径旧",调用方据此提示重转。
export interface TranscriptCacheOut {
  segments: TranscribedSegment[];
  stale: boolean;
}

/**
 * 读一份缓存并解析。**只认 `complete = true`、版本不低于 minVersion、且归属是 `expectId` 的**。
 * 旧口径的稿在这里就地删掉 —— 留着只会让下一次又读一遍(见 H60:
 * 时间轴算法改过之后,旧稿会照旧口径显示,"修了等于没修")。
 *
 * `expectId` 是**归属校验**(见 REVIEW-2026-10-25 低·族 A 末尾):文件名是 `sanitize(id)` 来的,
 * 非字母数字一律折成 `_`,所以 `abc:def` 与 `abc_def` 会写进同一个文件 ——
 * 不校验归属就是甲集显示乙集的稿,而界面看起来完全正常。缺这个字段的旧缓存照认
 * (判它们不匹配等于把全部历史稿一次作废,收益只有"更严格")。
 */
@Concurrent
export async function loadTranscriptCacheConcurrent(path: string, minVersion: number, expectId: string): Promise<TranscriptCacheOut> {
  const empty: TranscriptCacheOut = { segments: [], stale: false };
  try {
    if (!await fs.access(path)) return empty;
    const text = await fs.readText(path);
    const root = JSON.parse(text) as Record<string, Object>;
    if (J.num(root, 'complete') === 0 && root['complete'] !== true) return empty;
    const owner = J.str(root, 'episodeId');
    if (owner.length > 0 && owner !== expectId) {
      Log.w('Transcript', `缓存归属不符(文件名撞车),当作没有:期望 ${expectId} 实为 ${owner}`);
      return empty;
    }
    const ver = J.num(root, 'version');
    if (ver < minVersion) {
      try {
        await fs.unlink(path);
      } catch (e) {
        // 删不掉也无妨,下次照样不认
      }
      const stale: TranscriptCacheOut = { segments: [], stale: true };
      return stale;
    }
    const arr = J.arr(root, 'segments');
    const out: TranscribedSegment[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const wordsRaw = J.arr(o, 'words');
      const words: TranscribedWord[] = [];
      for (let k = 0; k < wordsRaw.length; k++) {
        const w = J.asObj(wordsRaw[k]);
        if (w === null) continue;
        words.push({
          text: J.str(w, 'text'),
          startMs: J.num(w, 'startMs'),
          endMs: J.num(w, 'endMs')
        } as TranscribedWord);
      }
      out.push({
        text: J.str(o, 'text'),
        startMs: J.num(o, 'startMs'),
        endMs: J.num(o, 'endMs'),
        words: words
      } as TranscribedSegment);
    }
    const hit: TranscriptCacheOut = { segments: out, stale: false };
    return hit;
  } catch (e) {
    Log.w('Transcript', `缓存读坏了,当作没有:${(e as Error).message}`);
    return empty;
  }
}

/**
 * 序列化并写一份缓存。返回是否成功(失败只记日志,不影响内存态)。
 *
 * **原子写**(临时文件 → fsync → rename),见 REVIEW-2026-10-25 高-3(B 项)。
 * 原先是 `open(target, TRUNC)` + `write` —— 进程死在写窗口内就留下一份半截逐字稿,
 * 下一次读它解析失败、当"没有稿"。这一份是**可重生**的(坏了重转即可),不像订阅那样是
 * 用户资产,所以这里只补原子性,不套 JsonFile 那套 `.corrupt-*` 留证。
 *
 * 临时文件名不带 pid:这份缓存一个文件只有一个写者(每集一份,taskpool 里串行到同一个
 * path 的概率极小),而且真撞上就是"重转一次"的代价。
 */
@Concurrent
export async function saveTranscriptCacheConcurrent(
  path: string, localeId: string, complete: boolean, version: number, episodeId: string,
  segs: TranscribedSegment[]
): Promise<boolean> {
  const tmp = `${path}.tmp`;
  let file: fs.File | null = null;
  try {
    const arr: Object[] = [];
    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      const o: Record<string, Object> = {
        'text': s.text, 'startMs': s.startMs, 'endMs': s.endMs
      };
      if (s.words.length > 0) {
        const wa: Object[] = [];
        for (let k = 0; k < s.words.length; k++) {
          const w = s.words[k];
          wa.push({ 'text': w.text, 'startMs': w.startMs, 'endMs': w.endMs } as Record<string, Object>);
        }
        o['words'] = wa;
      }
      arr.push(o);
    }
    const root: Record<string, Object> = {
      'localeId': localeId,
      'complete': complete,
      'version': version,
      // 归属自证:文件名 sanitize(id) 会把 `:` 与 `_` 折成同一个字符,读侧要靠这一句分辨是谁的稿
      // (见 loadTranscriptCacheConcurrent 的注释与 REVIEW-2026-10-25 低·族 A 末尾)。
      'episodeId': episodeId,
      'segments': arr
    };
    file = await fs.open(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    await fs.write(file.fd, JSON.stringify(root));
    await fs.fsync(file.fd);
    await fs.close(file);
    file = null;
    try {
      await fs.rename(tmp, path);
    } catch (e) {
      // 目标已存在时 rename 是否覆盖,本端 SDK 的声明里同时列了 13900015 File exists,
      // 不敢只赌它成立 —— 退路是先删后 rename(结论与 JsonFile.replaceAsync 一致)。
      try {
        if (await fs.access(path)) await fs.unlink(path);
      } catch (e2) {
        // 忽略
      }
      await fs.rename(tmp, path);
    }
    return true;
  } catch (e) {
    Log.w('Transcript', `缓存写失败:${(e as Error).message}`);
    try {
      if (await fs.access(tmp)) await fs.unlink(tmp);
    } catch (e3) {
      // 忽略
    }
    return false;
  } finally {
    if (file !== null) {
      try {
        await fs.close(file);
      } catch (e) {
        // 忽略
      }
    }
  }
}
