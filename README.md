# 余音 · Reverb

> 余音绕梁，隽永悠长。 · *Every echo lingers.*

一款轻量的多端播客客户端，四个原生端：**Android**(Kotlin / Compose)、**HarmonyOS**(ArkTS / ArkUI)、**macOS**(Swift / SwiftUI)、**iOS**(Swift / SwiftUI)。水墨底 + 青瓷 + 梁金配色，图标以「金色横梁 + 环绕向上的声波」诠释「余音绕梁」。

> iOS 版 2026-11-02 加入，先走 **TestFlight** 分发（暂不上架 App Store），与 macOS 共用同一套数据 / 播放层。
> 构建命令、TestFlight 前置条件与本机现状见 `docs/IOS.md`。

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
| 播放核心 | **发布方 RSS 的 enclosure 原始直链** | 无论从哪发现节目，播放时都回到发布方 RSS，由各端系统播放器直接流式拉取原始音频。 | 免费 |

> 为什么不用需要 Key 的目录（如 PodcastIndex）或自建代理服务？——Key 会带来配置负担且易被限流，自建服务会引入托管成本、维护与单点故障，均与「零成本、无限制、打开即用」相悖。上述全部源都是公开、免鉴权的，无需任何后端。

> **上表当前适用于三个端。** Android 只有一份安装包(2026-10-18 合并了原先的两个 flavor,见 H205),
> 它同时交大陆应用市场与 GitHub Releases;鸿蒙端只有商店渠道。两端都已具备在线分类榜、
> 节目 + 单集关键词检索、随机 / 情境电台。内置 `seed_podcasts.json` 只随 Android 那份包与 macOS 走,
> **鸿蒙包里仍没有它**,首启内容靠在线榜单。若合规要求按纯 RSS 工具口径降级,再移除目录实现(见 H70)。
> 见 `docs/FEATURES.md`「渠道差异」。

### 关于 getpodcast.xyz
该站点（及同类下载器）本质也是「目录检索 → 解析 RSS → 取 enclosure 直链」这套模型，只是多了一层第三方 Web 中继——会带来可用性风险与潜在 ToS 问题。余音选择**直接对接 Apple / fyyd / gpodder / RSS**，更稳、更可控。

### 版权与成本
- **不转存、不代理、不抓取音频**：只流式播放发布方自己的 CDN 直链，这正是所有正规播客客户端的做法，是播客内容被设计出来的消费方式，**版权干净**。
- **仅使用免费、公开、面向客户端开放的接口**（全部免 Key、免登录、免鉴权），**运行成本为 0**。
- 未做任何付费墙内容抓取。

---

## 技术架构 · Android

> 各端的分层、播放链路、渠道隔离与 native 模块见 `docs/ARCHITECTURE.md`，本节只是 Android 侧的速览。

- **UI**：Jetpack Compose + Material3（Compose BOM 2024.06），单 Activity + Navigation Compose。
- **播放**：Media3 1.3.1（ExoPlayer + MediaSessionService），后台播放、媒体通知、锁屏控制。
- **网络**：OkHttp；JSON 用内置 `org.json`，RSS/OPML 用内置 `XmlPullParser`——**零额外解析依赖**。
- **持久化**：一组 JSON 文件存于应用私有目录，**不引入数据库**，构建更稳。
- **依赖注入**：手写 `AppContainer`，避免 DI 框架带来的构建复杂度。

```
data/
  model/        Podcast、Episode、FeedResult
  remote/       ITunesSource(检索) · AppleChartsSource(热榜) · FyydSource · GpodderSource(兜底) ·
                RssParser · OpmlSupport · TranscriptFetcher · PodcastRepository(编排/降级)
  local/        SubscriptionStore / HistoryStore / InboxStore / ListenStatsStore /
                TranscriptStore / BackupManager … 各功能域一个 JSON store
playback/       PlaybackService(MediaSessionService) · PlayerController(门面/StateFlow)
ui/             ReverbRoot(导航) · theme/ · components/ · screens/ · share/(剪藏与足迹海报) · ViewModels
update/         WorkManager 订阅更新巡检 + 新集通知
```

## 仓库结构

- `android/` — Android 版(Kotlin / Jetpack Compose)
- `harmony/` — HarmonyOS 版(ArkTS / ArkUI)
- `macos/` — macOS 版(Swift / SwiftUI)
- `ios/` — iOS 版(Swift / SwiftUI,与 macOS 共用 `Data` / `Playback`;分发走 TestFlight)
- `docs/PRODUCT.md` — **功能介绍**(面向使用者与评审:每个功能是什么、怎么用、各端之间有何不同)
- `docs/FEATURES.md` — **功能清单**(开发用矩阵,逐项标注平台差异;需要精确对照时以这份为准)
- `docs/ARCHITECTURE.md` — **核心技术实现**(分层、播放链路、持久化、渠道隔离、native 模块、性能规律)
- `docs/HISTORY.md` — **开发历程**(顺序与因果,以及哪里返了工)
- `docs/ROADMAP.md` — **进度、遗留问题与演进方向**(各端到哪一步、哪些路径还没验过、以后可能往哪走)
- `docs/TRANSCRIPT.md` — 逐字稿 / 语音转文字的实现与取舍(含鸿蒙接入 sherpa-onnx 的落地记录)
- `docs/IOS.md` — **iOS 端**:与 macOS 的共享层、工程结构、编译门、TestFlight 前置条件与流程、本机现状
- `docs/TROUBLESHOOTING.md` — 踩坑记录:现象、根因、修法、可复用的规律
- `docs/PRIVACY.md` — 隐私政策(与 `site/reverb/privacy.html` 必须同步)
- `CHANGELOG.md` — 更新日志(面向使用者的版本变更记录)
- `docs/LOCAL-ASSETS.md` — **本地资产与换机迁移**(哪些东西不在 git 里、换一台电脑怎么完整重建)

> 分发登记材料与**发布运营物料**(发布文案、上传图标、商店截图、物料包)
> **不入版本控制**,只留在本地(硬规矩 19)。
> 清单与换机流程见 `docs/LOCAL-ASSETS.md`;渠道合规口径见 `docs/FEATURES.md`「渠道差异」
> 与 H70。
- `AGENTS.md` — **在本仓库工作的约定**(环境准备、构建命令、硬规矩、版本与发版、验证方式、代码与提交风格);`CLAUDE.md` 是指向它的薄指针

> `docs/PRODUCT.md` 与 `docs/FEATURES.md` 是同一件事的两种粒度:前者叙述、后者矩阵。
> 功能有变动时**两份都要改** —— 这个项目已经因为"功能改了自述没改"栽过一轮(见 `docs/HISTORY.md` 阶段七)。

## 构建

完整命令（含渠道解包核对、ASR 产物）见 `AGENTS.md`「常用命令」。

**Android** —— JDK（language level 17）+ Android SDK（platform 34, build-tools 34）

```bash
cd android
export JAVA_HOME=/Users/cxyxl/Library/Java/JavaVirtualMachines/jdk-21.0.12.1+1.jdk/Contents/Home   # 绝对路径,原因见下方说明
./tools/build-asr.sh                # 备齐离线识别的模型/词表/jar/两个 .so(不入版本管理,缺了打包会报错)
./build-release.sh                  # 唯一那份 → dist/reverb.apk(1.0.8 起约 270 MB,含 239 MB 语音模型;同时交大陆应用市场与 GitHub Releases)
                                    # 2026-10-18 合并 flavor 后没有 `--store` 了(见 H205)
./gradlew :app:assembleDebug        # 只要一个能装的 debug 包
```

> ⚠️ **别用 `$(/usr/libexec/java_home -v 17)` 要 JDK**（10-24 在新机实测：它**忽略版本参数**，
> 返回当前注册的最新 JVM 并 exit 0 —— `-v 99` 给的是同一个串，所以它既不是"找到 17"也不是"没找到"）。
> 旧机（macOS 12 / 用户 `liang`）上它返回空，症状是"Gradle 报找不到 Java"；新机（Apple Silicon / 用户 `cxyxl`）
> 上它静默给 21，症状变成"要 17 拿到 21 而且退出码是 0"。**两次都不是版本校验。**
> 本机只有 Temurin 21，而项目要的是 **language level 17**（`build.gradle` 里钉的
> `VERSION_17` / `jvmTarget '17'`）而不是 JDK 17 这个运行时，用它出包实测全绿
> （编译门 + `build-release.sh` + 解包审计 6/6 PASS，见 `docs/TROUBLESHOOTING.md` H208）。
> 认版本用 `java_home -V`（大写，列出全部）或 `"$JAVA_HOME/bin/java" -version`。
> 换机器时上面那串绝对路径必变 —— 环境清单与一分钟自检见 `AGENTS.md`「环境准备」。

**HarmonyOS** —— DevEco Studio 的 SDK 与 hvigor

```bash
cd harmony
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
./build-release.sh                  # → dist/reverb.app + reverb-symbol.zip
```

**macOS** —— 无需 Xcode GUI

```bash
cd macos
./package.sh                        # swift build → 组装 .app → ad-hoc 签名 → 打 dmg
```

产物:`macos/dist/余音-Reverb-<版本>-universal.dmg`(架构标记由脚本推导;`macos/build/` 里只是中间产物)

**iOS** —— Xcode 27 / iOS SDK 27;编译门不需要证书,TestFlight 需要 Apple Developer Program

```bash
cd ios
./build-ios.sh                      # 编译 + 产物验收(不需要签名)
DEVELOPMENT_TEAM=XXXXXXXXXX ./build-ios.sh --export   # → dist/reverb-ios-<版本>-<构建号>.ipa
BUILD_NUMBER=2 DEVELOPMENT_TEAM=XXXXXXXXXX \
  ASC_KEY_ID=… ASC_ISSUER_ID=… ./build-ios.sh --upload # → TestFlight
```

签名团队与上传凭据只从环境变量读,不写进工程文件;完整前置条件(账号、App Store Connect 记录、
内部 / 外部测试员差异)见 `docs/IOS.md`。

## 配置项
- Android：minSdk 26 / targetSdk 34 / compileSdk 34
- 无需任何配置或密钥：所有播客源均为公开、免鉴权接口。
