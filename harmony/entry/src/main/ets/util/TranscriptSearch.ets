import { TranscribedSegment } from '../model/Models';

/**
 * 逐字稿的全文搜索:找出**哪些句子**命中了,以及每句里**哪些区间**要贴底色。
 *
 * 与 Android `util/TranscriptSearch.kt`、macOS `Data/TranscriptSearch.swift` 同一套口径 ——
 * 区间是**字符下标**,渲染侧按它切片,不做二次查找。
 * 为什么区间要一次算完:当前句的逐字高亮每 80ms 重渲一次(见 `TranscriptPane`),
 * 那句里的匹配位置不能每次重扫 —— 这是硬规矩 6 在这条链路上的具体形状。
 *
 * ArkTS 没有 `ignoreCase` 的 `indexOf`,只能先把两边折成小写再找;折出来的下标与
 * 原文同长(不涉及土耳其语 İ 那种会改变长度的折叠),因此可以直接切原文。
 */
export class SearchRange {
  start: number;
  end: number;

  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }
}

export class SearchHit {
  index: number;              // 句子下标
  ranges: SearchRange[];      // 该句内要贴底色的区间

  constructor(index: number, ranges: SearchRange[]) {
    this.index = index;
    this.ranges = ranges;
  }
}

export class SearchResult {
  hits: SearchHit[] = [];
  rangesByIndex: Map<number, SearchRange[]> = new Map<number, SearchRange[]>();

  isEmpty(): boolean {
    return this.hits.length === 0;
  }
}

export class TranscriptSearch {
  /** `query` 由调用方 `trim()` 过;空串直接返回空结果 —— 空白查询不该把整篇涂亮。 */
  static find(segments: TranscribedSegment[], query: string): SearchResult {
    const out = new SearchResult();
    if (query.length === 0 || segments.length === 0) return out;
    for (let i = 0; i < segments.length; i++) {
      const found = TranscriptSearch.rangesIn(segments[i].text, query);
      if (found.length > 0) {
        out.hits.push(new SearchHit(i, found));
        out.rangesByIndex.set(i, found);
      }
    }
    return out;
  }

  /** 一句里的所有命中区间。从上一处之后继续找,单字符查询在长句里也不会退化成平方级。 */
  static rangesIn(text: string, query: string): SearchRange[] {
    const out: SearchRange[] = [];
    if (text.length === 0 || query.length === 0) return out;
    const hay = text.toLowerCase();
    const needle = query.toLowerCase();
    if (needle.length === 0) return out;
    let from = 0;
    while (from < hay.length) {
      const at = hay.indexOf(needle, from);
      if (at < 0) break;
      const end = Math.min(at + needle.length, text.length);
      if (end > at) out.push(new SearchRange(at, end));
      from = end > at ? end : at + 1;
    }
    return out;
  }
}
