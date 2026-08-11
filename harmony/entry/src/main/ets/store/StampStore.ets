import { JsonFile } from './JsonFile';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

/// 一枚听觉印记:为某一集盖下的水墨印章(印字 + 单集信息 + 时间)。
export interface Stamp {
  episodeId: string;
  seal: string;          // 印章字,如 喜/暖/燃/惊/思/悟/悲/怒/疲
  title: string;
  podcastTitle: string;
  createdAt: number;     // 毫秒时间戳
}

/// 听觉印记:每集最多一枚,最近置顶。
@Observed
export class StampStore {
  stamps: Stamp[] = [];
  private static FILE = 'stamps.json';

  load(): void {
    const arr = JsonFile.readArray(StampStore.FILE);
    const out: Stamp[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const id = J.str(o, 'episodeId');
      if (id.length === 0) continue;
      out.push({
        episodeId: id,
        seal: J.str(o, 'seal'),
        title: J.str(o, 'title'),
        podcastTitle: J.str(o, 'podcastTitle'),
        createdAt: J.num(o, 'createdAt')
      });
    }
    this.stamps = out;
    Log.i('Store', `印记加载 ${out.length} 枚`);
  }

  sealFor(episodeId: string): string {
    const s = this.stamps.find((x: Stamp) => x.episodeId === episodeId);
    return s === undefined ? '' : s.seal;
  }

  /// 盖章 / 改章:替换同集旧章并置顶。
  set(episodeId: string, seal: string, title: string, podcastTitle: string): void {
    const rest = this.stamps.filter((x: Stamp) => x.episodeId !== episodeId);
    const fresh: Stamp = {
      episodeId: episodeId, seal: seal, title: title,
      podcastTitle: podcastTitle, createdAt: Date.now()
    };
    this.stamps = [fresh].concat(rest);
    Log.i('Store', `盖印记 "${seal}" id=${episodeId}`);
    this.persist();
  }

  remove(episodeId: string): void {
    this.stamps = this.stamps.filter((x: Stamp) => x.episodeId !== episodeId);
    this.persist();
  }

  private persist(): void {
    const arr: Object[] = [];
    for (let i = 0; i < this.stamps.length; i++) {
      const s = this.stamps[i];
      arr.push({
        'episodeId': s.episodeId, 'seal': s.seal, 'title': s.title,
        'podcastTitle': s.podcastTitle, 'createdAt': s.createdAt
      } as Record<string, Object>);
    }
    JsonFile.writeJson(StampStore.FILE, arr);
  }
}

/// 9 枚情绪印章:以 Ekman 基本情绪为骨架,换掉听播客用不上的「惧/厌」。
export interface SealOption {
  seal: string;
  label: string;
}

export const SEALS: SealOption[] = [
  { seal: '喜', label: '开心' }, { seal: '暖', label: '治愈' }, { seal: '燃', label: '热血' },
  { seal: '惊', label: '震撼' }, { seal: '思', label: '沉思' }, { seal: '悟', label: '领悟' },
  { seal: '悲', label: '难过' }, { seal: '怒', label: '愤怒' }, { seal: '疲', label: '疲惫' }
];
