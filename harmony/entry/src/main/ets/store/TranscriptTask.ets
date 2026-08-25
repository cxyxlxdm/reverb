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
 * 读一份缓存并解析。**只认 `complete = true` 且版本不低于 minVersion 的**。
 * 旧口径的稿在这里就地删掉 —— 留着只会让下一次又读一遍(见 H60:
 * 时间轴算法改过之后,旧稿会照旧口径显示,"修了等于没修")。
 */
@Concurrent
export async function loadTranscriptCacheConcurrent(path: string, minVersion: number): Promise<TranscriptCacheOut> {
  const empty: TranscriptCacheOut = { segments: [], stale: false };
  try {
    if (!await fs.access(path)) return empty;
    const text = await fs.readText(path);
    const root = JSON.parse(text) as Record<string, Object>;
    if (J.num(root, 'complete') === 0 && root['complete'] !== true) return empty;
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

/// 序列化并写一份缓存。返回是否成功(失败只记日志,不影响内存态)。
@Concurrent
export async function saveTranscriptCacheConcurrent(
  path: string, localeId: string, complete: boolean, version: number, segs: TranscribedSegment[]
): Promise<boolean> {
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
      'segments': arr
    };
    file = await fs.open(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    await fs.write(file.fd, JSON.stringify(root));
    return true;
  } catch (e) {
    Log.w('Transcript', `缓存写失败:${(e as Error).message}`);
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
