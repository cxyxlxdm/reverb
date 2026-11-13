import { Episode, TranscribedSegment } from '../model/Models';

/**
 * 把逐字稿拼成可以交给系统分享的两种文本:纯文本 / Markdown。
 *
 * 与 Android `util/TranscriptExport.kt`、macOS `Data/TranscriptExport.swift` **逐字节一致** ——
 * 同一个用户在两台设备上导同一集,拿到的文件应该能互相 diff,而不是三种排版。
 *
 * 每句都带时间轴(`[12:03]`),它是点一下就能跳回去的位置;去掉时间戳的"干净版"
 * 离开 App 之后没有任何用处。时间戳位数按**整篇时长**定:一小时以内 `12:03`,
 * 超过一小时才 `1:12:03` —— 逐句各判会让同一份文件混排两种形状。
 */
export enum TranscriptFormat {
  Text,
  Markdown
}

export class TranscriptExport {
  static readonly HOUR_MS: number = 3600000;
  private static readonly MAX_NAME_CHARS: number = 80;
  private static readonly INVALID_CHARS: RegExp = /[\\/:*?"<>|\u0000-\u001F\u007F]/g;
  private static readonly WHITESPACE: RegExp = /\s+/g;

  static build(episode: Episode, segments: TranscribedSegment[], format: TranscriptFormat): string {
    const last = segments.length > 0 ? segments[segments.length - 1] : null;
    const withHours = (last === null ? 0 : last.endMs) >= TranscriptExport.HOUR_MS;
    let title = TranscriptExport.oneLine(episode.title);
    if (title.length === 0) title = 'Transcript';
    const channel = TranscriptExport.oneLine(episode.podcastTitle);
    const lines: string[] = [];
    if (format === TranscriptFormat.Text) {
      lines.push(title);
      if (channel.length > 0) lines.push(channel);
      lines.push('');
      for (const seg of segments) {
        lines.push('[' + TranscriptExport.stamp(seg.startMs, withHours) + '] ' + TranscriptExport.oneLine(seg.text));
      }
    } else {
      lines.push('# ' + title);
      lines.push('');
      if (channel.length > 0) {
        lines.push('_' + channel + '_');
        lines.push('');
      }
      for (const seg of segments) {
        lines.push('- [' + TranscriptExport.stamp(seg.startMs, withHours) + '] ' + TranscriptExport.oneLine(seg.text));
      }
    }
    return lines.join('\n') + '\n';
  }

  /** `12:03` 或 `1:12:03`;负数按 0 处理(时间轴上游保证过,但导出不该被脏数据带崩)。 */
  static stamp(ms: number, withHours: boolean): string {
    const total = Math.floor(Math.max(ms, 0) / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const mm = m < 10 ? '0' + m.toString() : m.toString();
    const ss = s < 10 ? '0' + s.toString() : s.toString();
    return withHours ? h.toString() + ':' + mm + ':' + ss : m.toString() + ':' + ss;
  }

  /**
   * 分享到别的 App 的文件名。去掉路径分隔符与控制字符 —— 一集标题里出现 `/` 或换行
   * 并不罕见,原样落盘会多一层目录或直接抛异常。
   */
  static fileName(episode: Episode, format: TranscriptFormat): string {
    let base = TranscriptExport.oneLine(episode.title).replace(TranscriptExport.INVALID_CHARS, ' ').trim();
    if (base.length > TranscriptExport.MAX_NAME_CHARS) base = base.substring(0, TranscriptExport.MAX_NAME_CHARS).trim();
    if (base.length === 0) base = 'transcript';
    return base + '.' + (format === TranscriptFormat.Text ? 'txt' : 'md');
  }

  /** 一行化:带换行的文本会把纯文本行拆散、把 Markdown 列表打断,在这一道收口。 */
  private static oneLine(s: string): string {
    return s.replace(TranscriptExport.WHITESPACE, ' ').trim();
  }
}
