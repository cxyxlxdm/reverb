import fs from '@ohos.file.fs';
import { Episode } from '../model/Models';
import { JsonFile } from './JsonFile';
import { Codec } from './Codec';
import { J } from '../net/Http';
import { Log } from '../util/Logger';

export interface DownloadedEpisode {
  episode: Episode;
  localPath: string;
}

/// 已下载单集清单。加载时**校验文件仍存在**,不存在则跳过(用户可能手动清理过)。
@Observed
export class DownloadStore {
  downloads: DownloadedEpisode[] = [];
  private static FILE = 'downloads.json';

  load(): void {
    const arr = JsonFile.readArray(DownloadStore.FILE);
    const out: DownloadedEpisode[] = [];
    for (let i = 0; i < arr.length; i++) {
      const o = J.asObj(arr[i]);
      if (o === null) continue;
      const path = J.str(o, 'localPath');
      if (path.length === 0) continue;
      let exists = false;
      try {
        exists = fs.accessSync(path);
      } catch (e) {
        exists = false;
      }
      if (!exists) continue;   // 文件没了就当没下载过
      out.push({ episode: Codec.episodeFromJson(J.obj(o, 'episode')), localPath: path });
    }
    this.downloads = out;
    Log.i('Store', `下载加载 ${out.length} 集`);
  }

  contains(id: string): boolean {
    return this.downloads.some((d: DownloadedEpisode) => d.episode.id === id);
  }

  pathOf(id: string): string | null {
    const d = this.downloads.find((x: DownloadedEpisode) => x.episode.id === id);
    return d === undefined ? null : d.localPath;
  }

  add(e: Episode, localPath: string): void {
    if (this.contains(e.id)) return;
    this.downloads = this.downloads.concat([{ episode: e, localPath: localPath }]);
    this.persist();
  }

  remove(id: string): void {
    this.downloads = this.downloads.filter((d: DownloadedEpisode) => d.episode.id !== id);
    this.persist();
  }

  clearAll(): void {
    this.downloads = [];
    this.persist();
  }

  private persist(): void {
    const arr: Object[] = [];
    for (let i = 0; i < this.downloads.length; i++) {
      arr.push({
        'episode': Codec.episodeToJson(this.downloads[i].episode),
        'localPath': this.downloads[i].localPath
      } as Record<string, Object>);
    }
    JsonFile.writeJson(DownloadStore.FILE, arr);
  }
}
