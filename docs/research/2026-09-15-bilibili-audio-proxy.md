# B 站视频转播客(RSS / App 收听)—— 方案调研

> **状态:已拍板并开工(1.0.6)。走的是「App 内直连」,不建任何后端。**
> 2026-10-18 登记时判「撞约束一,默认不做」(任务 #205);2026-10-28 实测复核后整体翻面,
> 因为**建 Worker 这个结论本身是为一个不存在的问题付代价**——详见下面「实测复核」。
> **原文照抄在「调研原文」分隔线之后;本节是提炼出来的可执行结论。**
> 来源:`~/Desktop/B站视频转播客方案调研.md`(6,053 B,mtime 2026-10-17 17:21,文内调研日期 2026-09-15)。

## 一句话结论

**做,但不建后端。** 由每个用户的设备直连 B 站公开接口取音频轨 ——
零后端、零账号、零云同步照旧,`docs/PRIVACY.md` 第 75 行那句已发布的承诺
(「不转存或代理节目内容 … 直接访问发布方或托管方提供的原始地址」)**依然成立**,只需在主机表里加三个域。
附件的 Cloudflare Worker 方案被否:**大陆可达性、共享出口 IP 的风控劣势、开发者成为内容传播方**,
三条加起来比它解决的问题更贵。

## 实测复核(2026-10-28,匿名请求,无 Cookie 无 wbi 签名)

附件的技术前提有六条不成立、一条写反、两条漏掉。这些数字是拍板依据,复验时直接重跑即可。

| 附件断言 | 实测 |
|---|---|
| 搜索需 wbi 签名 | `x/web-interface/wbi/search/type?search_type=video` → `code 0`,`numResults 1000`,`numPages 50`,**免签也过** |
| playurl 需 wbi + `buvid3` | `x/player/playurl?fnval=16` → `code 0`,给 3 条音轨 |
| 匿名只有默认码率 | 30216(43.9 kbps)/ 30232(102.9 kbps)/ 30280(203.8 kbps)三档齐全,`audio/mp4` `mp4a.40.2` |
| 直链「几小时」过期 | `deadline` = 请求时刻 **+2.0 小时**(逐秒核过两次) |
| 需要 Referer 才能拉流 | `Range: bytes=0-2047` → **206**,带不带 Referer 都是 206 |
| App 端不直连是为了 CORS / Referer | 原生 App 没有 CORS;Referer 也不需要 |
| `GET /videos/:uid` 是最轻的端点 | **写反了**:`x/space/wbi/arc/search` → `-352 风控校验失败`;legacy 版第 6 次起 `-799 请求过于频繁`,无 Referer 直接 HTTP **412** |

| 附件没提 | 后果 |
|---|---|
| 音频 CDN 一半是 PCDN | 同一份 playurl 里 `audio[0]` 的 `baseUrl` 拿 Range 直接 **503**,而 `audio[1]`/`audio[2]` 正常 206。**必须做 baseUrl + backupUrl 回退**(每条音轨带两条备份,实测全 206) |
| `*.workers.dev` 在大陆的可达性 | 境内长期不稳定;换自定义域名要备案。选它的理由是「免费」,代价是打不开 |

## 已拍口径(2026-10-28)

1. **离线下载对 B 站集置灰**(那是把整段视频音频长期留在盘上);**自动缓存保留**(与浏览器缓存同性质,且撑着现有播放性能设计)。
2. **商店/官网对外文案不出现「B 站」**,写「粘贴视频链接,直接听音频」;应用内可以明写。
3. **范围 = P0 + P1**(粘链接单集 + 关键词搜单集);**P2「订阅 UP 主」不做** —— 它是唯一要跟风控对抗的部分,直接砍掉。

## 实施形状

伪协议把 B 站内容塞进现有 `Podcast` / `Episode` 模型,白拿订阅列表、频道页、待播、历史、播放条、播放态持久化:

```
Podcast.feedUrl  = bilibili://space/<mid>
Episode.audioUrl = bilibili://audio/<bvid>/<cid>    ← 播放前解析成真直链
```

`Episode.audioUrl` 现有约定是「发布方原始直链、播放时直接流式拉取」,而 B 站直链只有 2 小时寿命 ——
**所以必须加一层播放时解析**,这是本方案唯一真正的架构改动。解析结果只在内存缓存(TTL 90 分钟),不落盘。

| 期 | 内容 | 依赖 | 状态 |
|---|---|---|---|
| P0 | 粘 BV 号 / 完整 URL / `b23.tv` 短链 → 当一集或一个多分P节目播放 | `x/web-interface/view` + `x/player/playurl` | 1.0.6 |
| P1 | 关键词搜单集 | `x/web-interface/wbi/search/type` | 1.0.6 |
| ~~P2~~ | ~~订阅 UP 主~~ | ~~`x/space/*/arc/search`~~ | **不做** |

**闸门口径**:B 站**搜索属于动态目录**,与 iTunes/fyyd/gpodder 同口径受 `BuildConfig.CATALOG` 管;
**粘链接不属于目录发现,不受闸**。降级档出包时 `api.bilibili.com` 的搜索路径必须归 0,粘链接那条可以留。

## 合规与风险

- **仅限个人收听**;不生成、不提供可二次分发的 feed。下载功能已对此源关闭。
- B 站接口非官方开放,**风控升级就可能整体失效**。降级要求:失败只退化为「这一集暂时取不到」,
  不能崩、不能拖垮其它源;失效时靠发版修,这正是直连方案接受的代价。
- `docs/PRIVACY.md` 需在主机表补 `api.bilibili.com` / `*.hdslb.com` / `*.bilivideo.com`,
  并升 `PRIVACY_VERSION`;第 75 行的承诺文字本身不用改。

---

> ⚠️ **以下原文照抄,未改动 —— 但它的技术结论已被上面「实测复核」推翻,只作为推理过程留档。**
> 具体地:原文第二节的 Worker 端点表、wbi 签名必要性、码率限制三处**不要照做**;
> 第五节的七条实施清单(Cloudflare 账号 / Worker / KV / PWA / 部署)**全部作废**——
> 本方案一个后端都不建。读原文时请把它当成「当时为什么得出那个结论」的证据,不是待办。

## 调研原文(照抄,未改动)

# B 站视频转播客（RSS / App 收听）方案调研

> 调研日期：2026-09-15
> 需求：将 B 站视频提取为音频收听；希望在手机 App 里搜索 UP 主名字 / 视频关键字 → 列出最新节目 → 直接播放；部署成本尽量为 0。

## 结论摘要

- B 站**官方不提供 RSS**（不同于 YouTube），需要第三方工具或自建转换服务。
- 现成开源工具都需要**自托管服务器 + 对象存储**，成本和运维偏高。
- 推荐方案：**Cloudflare Workers（免费）+ 薄前端 App**，0 元、无需自备服务器、不存储音频文件。
- 播放链路的核心设计：RSS/App 的音频地址指向**自己的代理端点**，播放时实时获取 B 站带签名的音频直链（直链有时效，不能长期写死）。

---

## 一、现成开源方案（均需自托管）

| 项目 | 能力 | 依赖 / 代价 |
|---|---|---|
| [pigeon-pod](https://github.com/aizhimou/pigeon-pod) | 订阅 YouTube / Bilibili（UP 主 / 合集 / 单视频），提取音频生成播客 RSS | 自托管，Docker 或 Java 17+ + yt-dlp |
| [bilibili-to-podcast](https://github.com/TangMisaka23001/bilibili-to-podcast) | B 站**合集/系列** → 播客 RSS，提取音频 | 需配置 `sources.json` + Cloudflare R2 等对象存储转存音频 |
| [RSSHub](https://docs.rsshub.app) | 通用订阅流，有 B 站 UP 主投稿、合集等路由 | 输出的是**视频链接，非音频 enclosure**，无法直接当播客听，只适合做中间层 |

**共同短板**：需要一台常开机器（NAS/VPS），首次回溯历史视频存储量大；R2/存储配置繁琐。对"想低成本、按需搜索收听"的场景过重。

> 省事替代：很多 B 站播客节目同时上架了小宇宙 / Apple Podcasts，先搜节目名可能无需任何自建。

---

## 二、推荐方案：Cloudflare Workers（0 成本）

### 2.1 架构

```
手机 App（搜索框 + 结果列表 + 播放器）
        │  调用
        ▼
Cloudflare Worker（免费）
  ├─ GET /search?kw=      → 代理 B 站搜索（UP主 / 视频关键字）
  ├─ GET /videos/:uid     → UP 主最新投稿列表
  ├─ GET /audio/:bvid     → playurl 拿音频直链 → 302 重定向给播放器
  └─ GET /feed/:uid       → 生成标准播客 RSS（可选，供泛用播客客户端订阅）
```

- 播放器（AVPlayer / ExoPlayer / `<audio>`）直接播 `/audio/:bvid`。
- Worker **不存储任何音频文件**，因此不需要 R2 / OSS。
- RSS 模式下，`enclosure` 填 `/audio/:bvid` 而非 B 站直链。

### 2.2 关键技术点

1. **音频直链时效性（核心）**
   B 站 playurl 返回的音频流 URL 带签名，几小时后过期，不能写死进 RSS。解法：播放请求到达时实时调用 playurl 取新直链，302 重定向给播放器；直链可在 KV 里短 TTL（如 1 小时）缓存。

2. **风控：buvid3 + wbi 签名**
   - B 站 API 有基础风控：请求需带 `buvid3` Cookie（可先 GET bilibili.com 获取并复用，KV 持久化）。
   - 搜索、playurl 接口需要 **wbi 签名**（`w_rid` + `wts`，对参数按规则排序后 MD5，算法公开，Worker 内可实现）。
   - 风控统一在 Worker 处理，App 端不直连 B 站（同时解决 CORS / Referer 问题）。
   - 个人低频使用 + KV 缓存搜索结果，基本不会触发 -412。

3. **码率与登录**
   匿名可取默认码率音频流；高码率需登录 Cookie（SESSDATA）。可选配置项。

4. **Vercel vs Cloudflare**
   | | Cloudflare Workers（免费） | Vercel Hobby |
   |---|---|---|
   | 限制口径 | CPU 时间 10ms/请求 + 10 万请求/天 | 函数墙钟时长 10~60s |
   | 音频流式播放 | 无超时问题，且免费版不收带宽费 | 长音频易被函数超时打断 |
   | 结论 | **选它** | 不适合 |

### 2.3 成本评估（个人使用）

- Workers 免费额度：100,000 请求/天，完全覆盖（听一集约几十个 Range 请求 + 搜索几个请求）。
- KV 免费额度：10 万读/天、1000 写/天，够缓存投稿列表、搜索结果、buvid3。
- 总成本：**0 元**，仅需注册 Cloudflare 账号 + `wrangler` 部署。

---

## 三、App 形态：建议两步走

| 方案 | 成本 | 体验 |
|---|---|---|
| **PWA**（网页添加到主屏幕） | 单页应用，Cloudflare Pages 免费托管 | 搜索/列表/播放齐全，iOS 锁屏控制可用；通知栏控制、离线下载略弱 |
| **原生壳**（SwiftUI，或 Capacitor 包 PWA） | 需真机安装（自用可 Xcode 免费签名 / Android 直接装 apk） | 完整原生播放体验 |

建议：**先做 PWA 验证全链路**（搜索 → 列表 → 播放），体验不够再把同一套前端包原生壳——Worker 与 API 零改动。PWA 的播放器页面直接用 `<audio>` 元素即可。

---

## 四、合规与风险提醒

- 仅限个人收听；**不要把生成的 RSS / feed 二次分发**（涉及音频内容的传播权）。
- B 站接口非官方开放，存在风控升级导致失效的可能；重要路径要留降级（如搜索失败时手动填 UID）。
- 不落盘音频文件，进一步降低存储与版权敏感度。

---

## 五、后续实施清单（未开始）

1. [ ] Cloudflare 账号 + `wrangler` 本地环境
2. [ ] Worker 骨架：`/search`、`/videos/:uid`、`/audio/:bvid`、`/feed/:uid` 四个端点
3. [ ] 风控模块：buvid3 获取与 KV 复用、wbi 签名实现
4. [ ] KV 缓存：投稿列表（较长 TTL）、音频直链（短 TTL）、搜索结果
5. [ ] PWA 单页前端：搜索页 / 节目列表 / 播放器页
6. [ ] 部署到 Cloudflare Pages，手机添加到主屏幕实测
7. [ ] （可选）SESSDATA 高码率支持；（可选）原生壳

---

## 参考链接

- pigeon-pod：https://github.com/aizhimou/pigeon-pod
- bilibili-to-podcast：https://github.com/TangMisaka23001/bilibili-to-podcast
- 知乎：如何用泛用型播客客户端订阅 bilibili 的节目：https://www.zhihu.com/question/408474173/answer/1392095155
- RSSHub 文档：https://docs.rsshub.app
