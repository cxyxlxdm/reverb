/// 分类归一化:把 Apple/RSS 五花八门的原始分类名收敛成 19 个稳定 key。
/// 移植自 Android `data/model/Genres.kt`(macOS 侧未做归一化,以 Android 为基线)。

const GROUPS: Record<string, string[]> = {
  'arts': ['arts', 'design', 'fashion & beauty', 'food', 'performing arts', 'visual arts', 'books'],
  'business': ['business', 'careers', 'entrepreneurship', 'investing', 'management', 'marketing', 'non-profit', 'business news'],
  'comedy': ['comedy', 'comedy interviews', 'improv', 'stand-up', 'comedy fiction'],
  'education': ['education', 'courses', 'how to', 'language learning', 'self-improvement'],
  'fiction': ['fiction', 'drama', 'science fiction'],
  'government': ['government'],
  'health': ['health & fitness', 'health', 'fitness', 'medicine', 'mental health', 'nutrition', 'alternative health', 'sexuality'],
  'history': ['history'],
  'kids': ['kids & family', 'parenting', 'pets & animals', 'stories for kids', 'education for kids'],
  'leisure': ['leisure', 'animation & manga', 'automotive', 'aviation', 'crafts', 'games', 'hobbies', 'home & garden', 'video games'],
  'music': ['music', 'music commentary', 'music history', 'music interviews'],
  'news': ['news', 'daily news', 'entertainment news', 'news commentary', 'politics', 'sports news', 'tech news'],
  'religion': ['religion & spirituality', 'buddhism', 'christianity', 'hinduism', 'islam', 'judaism', 'religion', 'spirituality'],
  'science': ['science', 'astronomy', 'chemistry', 'earth sciences', 'life sciences', 'mathematics', 'natural sciences', 'nature', 'physics', 'social sciences'],
  'society': ['society & culture', 'culture', 'documentary', 'personal journals', 'philosophy', 'places & travel', 'relationships'],
  'sports': ['sports', 'baseball', 'basketball', 'cricket', 'fantasy sports', 'football', 'golf', 'hockey', 'rugby', 'running', 'soccer', 'swimming', 'tennis', 'volleyball', 'wilderness', 'wrestling'],
  'tech': ['technology'],
  'truecrime': ['true crime'],
  'tv': ['tv & film', 'after shows', 'film history', 'film interviews', 'film reviews', 'tv reviews']
};

/// 兼容旧版已存的中文标签(与 Android 一致)。
const CN_ALIAS: Record<string, string> = {
  '艺术': 'arts', '商业': 'business', '喜剧': 'comedy', '教育': 'education',
  '小说': 'fiction', '时政': 'government', '历史': 'history', '健康': 'health',
  '亲子': 'kids', '休闲': 'leisure', '音乐': 'music', '新闻': 'news',
  '宗教': 'religion', '知识': 'science', '文化': 'society', '体育': 'sports',
  '科技': 'tech', '犯罪纪实': 'truecrime', '影视': 'tv'
};

/// 原始名 → key 的扁平查找表(启动时构建一次)。
const TO_KEY: Record<string, string> = buildTable();

function buildTable(): Record<string, string> {
  const t: Record<string, string> = {};
  const keys = Object.keys(GROUPS);
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    const names = GROUPS[k];
    for (let j = 0; j < names.length; j++) t[names[j]] = k;
  }
  const cn = Object.keys(CN_ALIAS);
  for (let i = 0; i < cn.length; i++) t[cn[i]] = CN_ALIAS[cn[i]];
  return t;
}

export class Genres {
  /// 归一化;未知则原样返回(保留信息,不丢)。
  static key(raw: string): string {
    const s = raw.trim();
    if (s.length === 0) return '';
    const hit = TO_KEY[s.toLowerCase()];
    if (hit !== undefined) return hit;
    const cn = TO_KEY[s];
    return cn !== undefined ? cn : s;
  }
}

/// 发现页 19 个分类(key + Apple iTunes genreId;recommend 为综合榜无 genreId)。
/// 从 Android `ui/ViewModels.kt` 下移到数据层(它实质是数据配置,不是 UI)。
export interface DiscoverCategory {
  key: string;
  label: string;
  genreId: number;   // 0 表示无(综合榜)
}

export const DISCOVER_CATEGORIES: DiscoverCategory[] = [
  { key: 'recommend', label: '推荐', genreId: 0 },
  { key: 'news', label: '新闻', genreId: 1489 },
  { key: 'business', label: '商业', genreId: 1321 },
  { key: 'tech', label: '科技', genreId: 1318 },
  { key: 'culture', label: '文化', genreId: 1324 },
  { key: 'knowledge', label: '知识', genreId: 1533 },
  { key: 'education', label: '教育', genreId: 1304 },
  { key: 'comedy', label: '喜剧', genreId: 1303 },
  { key: 'health', label: '健康', genreId: 1512 },
  { key: 'history', label: '历史', genreId: 1487 },
  { key: 'sports', label: '体育', genreId: 1545 },
  { key: 'food', label: '美食', genreId: 1306 },
  { key: 'travel', label: '旅行', genreId: 1320 },
  { key: 'anime', label: '动漫', genreId: 1499 },
  { key: 'relationship', label: '情感', genreId: 1517 },
  { key: 'arts', label: '艺术', genreId: 1301 },
  { key: 'music', label: '音乐', genreId: 1310 },
  { key: 'kids', label: '亲子', genreId: 1305 },
  { key: 'tv', label: '影视', genreId: 1309 }
];

/// 地区选项(与 Android 的 12 项一致;"" = 自动跟随设备)。
export interface RegionOption {
  code: string;
  label: string;
}

export const REGIONS: RegionOption[] = [
  { code: '', label: '自动' },
  { code: 'cn', label: '中国大陆' },
  { code: 'hk', label: '中国香港' },
  { code: 'tw', label: '中国台湾' },
  { code: 'us', label: '美国' },
  { code: 'jp', label: '日本' },
  { code: 'kr', label: '韩国' },
  { code: 'gb', label: '英国' },
  { code: 'sg', label: '新加坡' },
  { code: 'au', label: '澳大利亚' },
  { code: 'ca', label: '加拿大' },
  { code: 'de', label: '德国' }
];
