# 余音 · Reverb

> 余音绕梁，隽永悠长。 · *Every echo lingers.*

一款轻量、古风质感的 Android 播客客户端。水墨底 + 青瓷 + 梁金配色，图标以「金色横梁 + 环绕向上的声波」诠释「余音绕梁」。

---

## 播客源方案（默认 + 多重兜底，全部免费、版权安全）

播客的本质是 **RSS 订阅源 + enclosure 音频直链**。余音的取源遵循「发现走目录、播放回 RSS」的正规路径：

> **全链路零配置**：打开即用，无需登录、无需任何 API Key，用户没有任何使用成本或限制。

| 层级 | 来源 | 说明 | 成本 |
|------|------|------|------|
| **默认** | **Apple iTunes Search API** | `search?media=podcast` 检索直接返回 `feedUrl`；`lookup?id=` 取详情。全球稳定、中文覆盖好。 | 免费、无需 Key |
| 兜底① | **fyyd.de 搜索 API** | 公开播客搜索，`data[].xmlURL` 即 RSS。无需 Key、无需登录。 | 免费 |
| 兜底② | **gpodder.net 搜索 API** | 公开播客目录，返回 feed url。无需 Key、无需登录。 | 免费 |
| 兜底③ | **RSS 直连 / OPML 导入** | 用户直接粘贴 feed 地址（输入框自动识别 http/https），或从其他客户端导出的 OPML 批量导入。 | 免费 |
| 播放核心 | **发布方 RSS 的 enclosure 原始直链** | 无论从哪发现节目，播放时都回到发布方 RSS，由 ExoPlayer 直接流式拉取原始音频。 | 免费 |

> 为什么不用需要 Key 的目录（如 PodcastIndex）或自建代理服务？——Key 会带来配置负担且易被限流，自建服务会引入托管成本、维护与单点故障，均与「零成本、无限制、打开即用」相悖。上述全部源都是公开、免鉴权的，无需任何后端。

### 关于 getpodcast.xyz
该站点（及同类下载器）本质也是「目录检索 → 解析 RSS → 取 enclosure 直链」这套模型，只是多了一层第三方 Web 中继——会带来可用性风险与潜在 ToS 问题。余音选择**直接对接 Apple / PodcastIndex / RSS**，更稳、更可控。

### 版权与成本
- **不转存、不代理、不抓取音频**：只流式播放发布方自己的 CDN 直链，这正是所有正规播客客户端的做法，是播客内容被设计出来的消费方式，**版权干净**。
- **仅使用免费、公开、面向客户端开放的接口**（Apple 免 Key，PodcastIndex 免费 Key），**运行成本为 0**。
- 未做任何付费墙内容抓取。

---

## 技术架构

- **UI**：Jetpack Compose + Material3（Compose BOM 2024.06），单 Activity + Navigation Compose。
- **播放**：Media3（ExoPlayer + MediaSessionService），后台播放、媒体通知、锁屏控制。
- **网络**：OkHttp；JSON 用内置 `org.json`，RSS/OPML 用内置 `XmlPullParser`——**零额外解析依赖**。
- **持久化**：订阅以 JSON 存于应用私有目录，**不引入数据库**，构建更稳。
- **依赖注入**：手写 `AppContainer`，避免 DI 框架带来的构建复杂度。

```
data/
  model/        Podcast、Episode、FeedResult
  remote/       ITunesSource(默认) · PodcastIndexSource(兜底) · RssParser · OpmlSupport · PodcastRepository(编排/降级)
  local/        SubscriptionStore(JSON 持久化)
playback/       PlaybackService(MediaSessionService) · PlayerController(门面/StateFlow)
ui/             ReverbRoot(导航) · theme/ · components/ · screens/(Discover/Library/PodcastDetail/Player) · ViewModels
```

## 构建

```bash
# JDK 17 + Android SDK（platform 34, build-tools 34）
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./gradlew :app:assembleDebug
```

产物：`app/build/outputs/apk/debug/app-debug.apk`

安装到设备：`adb install -r app/build/outputs/apk/debug/app-debug.apk`

## 配置项
- 版本：minSdk 26 / targetSdk 34 / compileSdk 34
- 无需任何配置或密钥：所有播客源均为公开、免鉴权接口。
