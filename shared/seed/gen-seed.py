#!/usr/bin/env python3
"""
生成内置精选订阅清单(种子清单)。

用途:三端「发现」页在**磁盘缓存为空**时(首次安装、清过缓存、或全程无网)回退展示这份
内置清单,让首屏不是空白。联网后 refreshPopular 拿到真榜单即覆盖,种子不再参与展示。

数据来源与 App 运行时**完全一致** —— Apple 官方榜单 + iTunes lookup 换 feedUrl:
  综合榜  https://rss.marketingtools.apple.com/api/v2/{region}/podcasts/top/{n}/podcasts.json
  分类榜  https://itunes.apple.com/{region}/rss/toppodcasts/limit={n}/genre={id}/json
  换详情  https://itunes.apple.com/lookup?id=...&entity=podcast&country={region}
所以这份清单是「榜单快照」,不是人工挑的私货,重跑脚本即可刷新。

用法:
    python3 gen-seed.py              # 重新抓取,覆盖 seed_podcasts.json
    python3 gen-seed.py --check      # 只校验现有清单的 feedUrl 是否仍可访问,不改文件

抓完记得跑 ./sync.sh 把清单分发到三端资源目录。
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

UA = "Reverb/1.0 (podcast client; seed generator)"
TIMEOUT = 20

# 只种子化「发现」页前几个分类 —— 首屏能横滑到的那几屏。genreId 0 = 综合推荐。
# 与 Android DISCOVER_CATEGORIES / 鸿蒙 Genres 的 genreId 保持一致。
LISTS = [
    (0, "recommend"),
    (1489, "news"),
    (1321, "business"),
    (1318, "tech"),
    (1324, "culture"),
    (1533, "knowledge"),
]

# 种子只覆盖两个区:中文区用 cn,其余一律用 us(见各端 SeedCatalog 的 region 回退规则)。
# 12 个区全打进包里没必要 —— 它只是"没网时别白屏"的兜底。
REGIONS = ["cn", "us"]

PER_LIST = 12          # 每个榜单取前 N 条(过滤掉付费/无 feedUrl 之后)
FETCH_LIMIT = 40       # 榜单多取一些,给过滤留余量

# 与 Android Genres.kt / 鸿蒙 Genres.ets 同一套归一化,保证种子里的 genre 值和线上数据同构
GENRE_GROUPS = {
    "arts": ["arts", "design", "fashion & beauty", "food", "performing arts", "visual arts", "books"],
    "business": ["business", "careers", "entrepreneurship", "investing", "management", "marketing",
                 "non-profit", "business news"],
    "comedy": ["comedy", "comedy interviews", "improv", "stand-up", "comedy fiction"],
    "education": ["education", "courses", "how to", "language learning", "self-improvement"],
    "fiction": ["fiction", "drama", "science fiction"],
    "government": ["government"],
    "health": ["health & fitness", "health", "fitness", "medicine", "mental health", "nutrition",
               "alternative health", "sexuality"],
    "history": ["history"],
    "kids": ["kids & family", "parenting", "pets & animals", "stories for kids", "education for kids"],
    "leisure": ["leisure", "animation & manga", "automotive", "aviation", "crafts", "games", "hobbies",
                "home & garden", "video games"],
    "music": ["music", "music commentary", "music history", "music interviews"],
    "news": ["news", "daily news", "entertainment news", "news commentary", "politics", "sports news",
             "tech news"],
    "religion": ["religion & spirituality", "buddhism", "christianity", "hinduism", "islam", "judaism",
                 "religion", "spirituality"],
    "science": ["science", "astronomy", "chemistry", "earth sciences", "life sciences", "mathematics",
                "natural sciences", "nature", "physics", "social sciences"],
    "society": ["society & culture", "culture", "documentary", "personal journals", "philosophy",
                "places & travel", "relationships"],
    "sports": ["sports", "baseball", "basketball", "cricket", "fantasy sports", "football", "golf",
               "hockey", "rugby", "running", "soccer", "swimming", "tennis", "volleyball", "wilderness",
               "wrestling"],
    "tech": ["technology"],
    "truecrime": ["true crime"],
    "tv": ["tv & film", "after shows", "film history", "film interviews", "film reviews", "tv reviews"],
}
GENRE_KEY = {raw: key for key, raws in GENRE_GROUPS.items() for raw in raws}

# cn 区 lookup 回来的 primaryGenreName 是**中文**("艺术"/"喜剧"/"创业"…),不在上面的英文表里。
# 各端 Genres 都带一份中文兼容表,这里必须同步 —— 否则种子里存 "艺术"、联网刷新后存 "arts",
# 同一个频道在种子态和刷新态显示的分类不一样。表外的词各端都原样保留,此处行为一致。
GENRE_KEY.update({
    "艺术": "arts", "商业": "business", "喜剧": "comedy", "教育": "education",
    "小说": "fiction", "时政": "government", "历史": "history", "健康": "health",
    "亲子": "kids", "休闲": "leisure", "音乐": "music", "新闻": "news",
    "宗教": "religion", "知识": "science", "文化": "society", "体育": "sports",
    "科技": "tech", "犯罪纪实": "truecrime", "影视": "tv",
})

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "seed_podcasts.json")


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.read().decode("utf-8", "replace")
    except Exception as e:
        print(f"    ! 请求失败 {e} <- {url}", file=sys.stderr)
        return None


def chart_ids(region, genre_id):
    """取榜单里的节目 id。综合榜与分类榜是两套不同的 JSON 结构。"""
    if genre_id == 0:
        url = f"https://rss.marketingtools.apple.com/api/v2/{region}/podcasts/top/{FETCH_LIMIT}/podcasts.json"
        body = get(url)
        if not body:
            return []
        try:
            results = json.loads(body)["feed"]["results"]
            return [r["id"] for r in results if r.get("id")]
        except Exception:
            return []
    url = f"https://itunes.apple.com/{region}/rss/toppodcasts/limit={FETCH_LIMIT}/genre={genre_id}/json"
    body = get(url)
    if not body:
        return []
    try:
        entries = json.loads(body)["feed"]["entry"]
        return [e["id"]["attributes"]["im:id"] for e in entries
                if e.get("id", {}).get("attributes", {}).get("im:id")]
    except Exception:
        return []


def lookup(ids, region):
    """批量换 feedUrl / 高清封面 / 作者 / 分类,字段映射与 ITunesSource.parsePodcasts 一致。"""
    if not ids:
        return []
    url = f"https://itunes.apple.com/lookup?id={','.join(ids)}&entity=podcast&country={region}"
    body = get(url)
    if not body:
        return []
    try:
        results = json.loads(body).get("results", [])
    except Exception:
        return []
    out = []
    for o in results:
        feed = (o.get("feedUrl") or "").strip()
        if not feed:
            continue
        # 付费节目分集多为会员专享、拉不到直链,种子清单里直接排除:
        # 兜底内容点开就播不了,比空白更糟
        if (o.get("collectionPrice") or 0) > 0 or (o.get("trackPrice") or 0) > 0:
            continue
        raw_genre = (o.get("primaryGenreName") or "").strip()
        out.append({
            "id": str(o.get("collectionId") or feed),
            "title": (o.get("collectionName") or o.get("trackName") or "").strip(),
            "author": (o.get("artistName") or "").strip(),
            "artworkUrl": (o.get("artworkUrl600") or o.get("artworkUrl100") or "").strip(),
            "feedUrl": feed,
            "genre": GENRE_KEY.get(raw_genre.lower(), raw_genre),
        })
    return out


def build(previous):
    """
    抓取全部榜单。**某个榜单抓空时保留 previous 里的旧数据** ——
    Apple 的榜单接口偶发返回空(实测 us 综合榜就空过一次),
    若直接覆盖,产出的清单会静默少一整个分类,而脚本照样打印成功。
    """
    catalog = {}
    for region in REGIONS:
        for genre_id, name in LISTS:
            ids = chart_ids(region, genre_id)
            print(f"  {region}/{name}(genre={genre_id}): 榜单 {len(ids)} 条", end="")
            # lookup 一次最多接受的 id 数有限,分批;顺序即榜单排名,保持不变
            picked = []
            for i in range(0, len(ids), 20):
                picked.extend(lookup(ids[i:i + 20], region))
                if len(picked) >= PER_LIST:
                    break
                time.sleep(0.2)
            # lookup 返回顺序不保证与请求顺序一致,按榜单排名重排
            rank = {v: i for i, v in enumerate(ids)}
            picked.sort(key=lambda p: rank.get(p["id"], 9999))
            picked = picked[:PER_LIST]
            key = f"{region}:{genre_id}"
            if picked:
                print(f" → 可用 {len(picked)} 条")
                catalog[key] = picked
            elif previous.get(key):
                print(f" → 抓空,保留上一版 {len(previous[key])} 条")
                catalog[key] = previous[key]
            else:
                print(" → 抓空,且无旧数据可留")
            time.sleep(0.3)
    return catalog


# 受限网络(公司代理/沙箱出网白名单)拦下来时的响应特征。
# 这类结果**不能判成源失效** —— 踩过一次:13 个 feedUrl 被代理挡了 403,
# 差点当成死链把节目从清单里删掉。
BLOCK_MARKERS = ("不在安全策略", "not allowed by", "blocked by", "proxy")


def check(path, prune=False):
    """
    校验清单里的 feedUrl。结果分三类,不把「查不到」当成「失效」:
      ok       2xx/3xx,确认活着
      limited  连不上或被代理拦(无法判定)—— 换一个没有出网限制的网络再跑
      dead     明确 404/410,基本可以认定失效,该重抓了
    prune=True 时把 dead 的条目从文件里删掉(limited 的一律保留)。
    """
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    seen = {}
    for key, entries in data["lists"].items():
        for e in entries:
            seen.setdefault(e["feedUrl"], []).append(f"{key}/{e['title']}")

    ok, limited, dead = [], [], []
    print(f"共 {len(seen)} 个去重后的 feedUrl,开始校验…")
    for i, (url, where) in enumerate(sorted(seen.items()), 1):
        verdict = _probe(url)
        {"ok": ok, "limited": limited, "dead": dead}[verdict].append((url, where[0]))
        print(f"\r  {i}/{len(seen)}  可访问 {len(ok)} / 受限 {len(limited)} / 失效 {len(dead)}",
              end="", flush=True)
    print()

    if limited:
        print(f"\n⚠ {len(limited)} 个无法判定(网络受限,非源失效):")
        for url, where in limited:
            print(f"    {where}\n      {url}")
    if dead:
        print(f"\n✗ {len(dead)} 个确认失效(404/410),建议重跑生成:")
        for url, where in dead:
            print(f"    {where}\n      {url}")
    if not dead:
        print(f"\n✓ 无确认失效项(可访问 {len(ok)},受限 {len(limited)})")

    if prune and dead:
        bad = {url for url, _ in dead}
        removed = 0
        for key in list(data["lists"].keys()):
            kept = [e for e in data["lists"][key] if e["feedUrl"] not in bad]
            removed += len(data["lists"][key]) - len(kept)
            if kept:
                data["lists"][key] = kept
            else:
                del data["lists"][key]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1, sort_keys=True)
            f.write("\n")
        print(f"\n✓ 已剔除 {removed} 条确认失效项,剩 {sum(len(v) for v in data['lists'].values())} 条")

    return 1 if dead else 0


def _probe(url):
    """HEAD 优先,不支持 HEAD 的源退回 GET 只读一小段。返回 ok / limited / dead。"""
    for method in ("HEAD", "GET"):
        req = urllib.request.Request(url, headers={"User-Agent": UA}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                r.read(512)
                return "ok" if 200 <= r.status < 400 else "limited"
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return "dead"
            body = ""
            try:
                body = e.read(512).decode("utf-8", "replace")
            except Exception:
                pass
            if any(m in body for m in BLOCK_MARKERS):
                return "limited"
            if method == "GET":            # 405/403 等,HEAD 不行就试 GET,都不行算受限
                return "limited"
        except Exception:
            if method == "GET":            # 超时 / DNS / 连接被拒,一律算受限
                return "limited"
    return "limited"


# 推荐订阅 OPML 的产出位置与规模。
# 为什么是 OPML 而不是打进安装包:应用市场的合规口径把「内置内容目录 / 分类浏览 / 内容推荐」
# 判定为提供视听节目服务(需前置审批),而「用户自行添加 RSS 源」的纯工具不需要。
# 因此清单**移出安装包、挂到官网**,App 内只保留一个「导入推荐订阅」的动作,
# 不在应用内渲染任何可浏览的节目目录。
OPML_OUT = os.path.join(HERE, "..", "..", "reverb", "recommended.opml")
OPML_COUNT = 15          # 一次性导入的订阅数。太多会让用户的订阅页一上来就爆
OPML_PER_GENRE = 2       # 每个分类最多取几条,保证口味有跨度


def build_opml(path_out, catalog):
    """从种子清单挑一批跨分类的节目,生成 OPML 2.0。"""
    picked, seen = [], set()
    # 先按分类各取 OPML_PER_GENRE 条,再用综合榜补足到 OPML_COUNT
    order = [f"cn:{g}" for g, _ in LISTS if g != 0] + ["cn:0"]
    for key in order:
        entries = catalog.get(key, [])
        quota = OPML_PER_GENRE if key != "cn:0" else OPML_COUNT
        taken = 0
        for e in entries:
            if len(picked) >= OPML_COUNT or taken >= quota:
                break
            if e["feedUrl"] in seen or not e["title"]:
                continue
            seen.add(e["feedUrl"])
            picked.append(e)
            taken += 1
        if len(picked) >= OPML_COUNT:
            break

    def esc(s):
        return (s.replace("&", "&amp;").replace("<", "&lt;")
                 .replace(">", "&gt;").replace('"', "&quot;"))

    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<opml version="2.0">', "  <head>",
             "    <title>余音 Reverb 推荐订阅</title>",
             f"    <dateCreated>{time.strftime('%Y-%m-%d')}</dateCreated>", "  </head>", "  <body>"]
    for e in picked:
        t = esc(e["title"])
        lines.append(f'    <outline type="rss" text="{t}" title="{t}" xmlUrl="{esc(e["feedUrl"])}"/>')
    lines += ["  </body>", "</opml>", ""]

    path_out = os.path.abspath(path_out)
    os.makedirs(os.path.dirname(path_out), exist_ok=True)
    with open(path_out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"\n✓ {path_out}")
    print(f"  {len(picked)} 条订阅:{'、'.join(e['title'] for e in picked)}")
    print("  这份文件要上传到官网,URL 与 App 内的 recommended_opml_url 必须一致")
    return len(picked)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验现有清单的 feedUrl,不重新抓取")
    ap.add_argument("--opml", action="store_true",
                    help="只从现有清单生成官网用的 recommended.opml,不重新抓取")
    ap.add_argument("--prune", action="store_true",
                    help="校验后剔除**确认失效**(404/410)的条目;受限/无法判定的一律保留")
    args = ap.parse_args()

    if args.check or args.prune:
        code = check(OUT, prune=args.prune)
        sys.exit(0 if args.prune else code)

    if args.opml:
        with open(OUT, encoding="utf-8") as f:
            build_opml(OPML_OUT, json.load(f)["lists"])
        sys.exit(0)

    print("▸ 抓取 Apple 榜单快照")
    previous = {}
    if os.path.exists(OUT):
        try:
            with open(OUT, encoding="utf-8") as f:
                previous = json.load(f).get("lists", {})
        except Exception:
            pass
    catalog = build(previous)
    total = sum(len(v) for v in catalog.values())
    if total == 0:
        print("✗ 一条都没抓到,不覆盖现有文件", file=sys.stderr)
        sys.exit(1)

    # 榜单数少于预期即提示 —— 静默产出一份不全的清单比报错更糟
    expected = len(REGIONS) * len(LISTS)
    if len(catalog) < expected:
        missing = sorted({f"{r}:{g}" for r in REGIONS for g, _ in LISTS} - set(catalog))
        print(f"\n⚠ 只有 {len(catalog)}/{expected} 个榜单,缺:{', '.join(missing)}", file=sys.stderr)

    doc = {
        # 明确标注这是快照 —— UI 上也据此显示「内置精选」而不是「每日热门」
        "note": "Apple Podcasts 榜单快照,作为无网络时的兜底清单。由 shared/seed/gen-seed.py 生成。",
        "generatedAt": time.strftime("%Y-%m-%d"),
        "lists": catalog,
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    size = os.path.getsize(OUT)
    print(f"\n✓ {OUT}")
    print(f"  {len(catalog)} 个榜单 / {total} 条 / {size // 1024} KB")
    print("  接着跑 ./sync.sh 分发到三端")


if __name__ == "__main__":
    main()
