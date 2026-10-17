# macOS 缺口清单 —— Android 与鸿蒙已实现、桌面端还没有的东西

**这份文档只管一件事**:逐条列出「手机端两端已经做了、macOS 没做或口径不同」的功能,
每条带**代码落点**(所以它不会随记忆漂移)与**成本判断**,作为排期的输入。

- 基线:2026-10-16 的工作区(`feat/offline-cache`)。**表里的 macOS 行号是这一轮逐个 open 读过之后写的**;
  Android / 鸿蒙一侧**尽量写符号名而不是行号** —— 行号会漂,符号名能被 grep 到。
- 判据来源是**读代码**,不是运行产物。本机跑不了 macOS 的构建与运行验收(原因见 `AGENTS.md` 常用命令一节那个 ⚠️ 块),
  所以本表**没有一条是"在 Mac 上验证过现状"的** —— 它陈述的是"源码里有没有这段实现"。
- 每补完一项,把那一行的「macOS 现状」改成「已做 + 落点」,并按 `AGENTS.md` 硬规矩 5 同步自述五件套;
  **不要删行**,删了就看不出当年为什么这么排。

---

## 一、能力级缺口(两端有、macOS 没有)

| # | 功能 | Android 落点 | 鸿蒙落点 | macOS 现状 | 成本 |
|---|---|---|---|---|---|
| M1 | **清空二次确认**(待播队列 / 播放历史) | `QueueScreen.kt` 清空走确认框、`LibraryScreen.kt` 历史同款(文案共用 `confirm_clear_history`) | `QueuePage.ets` / `LibraryPage.ets` 同口径 | **直连不确认**:`UI/QueueView.swift:56` 直接 `player.clearQueue()`、`UI/LibraryView.swift:134` 直接 `env.history.clear()`。只有删单集(`QueueView.swift:80` 附近)与删批注有框 | 低(两处 `.confirmationDialog`) |
| M2 | **导出备份的分区勾选** | `BackupManager` + `BackupSectionDialog`(用户自己勾分区) | `BackupSectionDialog.ets` 同构 | **写死全量**:`UI/SettingsView.swift:272` 一句 `Set(BackupManager.Section.allCases)`,没有勾选界面 | 低-中(补一个 sheet) |
| M3 | **备份缺三键**:`allowCellularDownload` / `updatesEnabled` / `categoryOrder` | `BackupManager.kt` 的 SettingsPayload 带这三项 | `CategoryStore.ets` 有分类排序 | **自己的注释承认缺**:`Data/BackupManager.swift:29-33`。于是「跨端互通」在桌面这一侧少三格,恢复进手机会丢这三项设置 | 低(但**要先决定蜂窝那项在 Mac 上对应什么**,Mac 无蜂窝基带) |
| M4 | **点封面/头像直达这一集的频道页** | `coverChannelJump()`(`ui/components/Components.kt:194`)+ 列表行与迷你条两处挂载 + `LocalOpenPodcastChannel` 注入;频道详情页自己关掉这一门 | `Components.ets` 的 `coverTakesTap()` / `coverTaken()` / `coverPlain()` 三颗 + `MiniPlayerBar.ets` 的 `canJumpChannel()` | **完全没有**:`UI/NowPlayingBar.swift:54-56` 那颗封面按钮的动作是 `showPlayer = true`(开播放页),`UI/QueueView.swift:20` 的封面纯展示。唯一的等价入口是播放页顶上那行频道名(`PlayerView.swift` 里) | 中(桌面要有"往导航栈推一档"的入口,而 `PodcastDetailView` 现在怎么被推入要先摸清) |
| M5 | **多选批量加入待播**(追更 / 收藏 / 下载 / 历史 / **频道页**五栏) | `PlayerController.kt:245 enqueueAll` + `enqueuePicked` / `SELECTION_BAR_SLOT` / `EpisodeBatchBar`(`Components.kt:909/917/933`) | `PlayerController.ets enqueueAll` + `Components.ets` 的 `enqueuePicked` / `batchEnqueueAndToast` / `EpisodeBatchBar` | **只有单条**:`Playback/PlayerController.swift:458 enqueue`;右键菜单 `UI/Theme.swift:349-371` 三颗(下一个播放 / 加入队列 / 标记已播完)**没有「多选」** | 中(桌面形态不是长按菜单:应走**框选 / ⌘ 点选 + 右键菜单一项「加入待播」**,而不是把手机那条悬浮条照搬) |
| M6 | **追更独立入口 + 音阁「待播」段** | 底部三格 发现 / 追更 / 音阁(`ReverbRoot.kt`),音阁六段含「待播」 | 同三格(`Index.ets`),`LibraryPage.ets` 的「待播」段与独立队列页**共用同一个 body** | **两格**:`RootView.swift:6-8` 只有 发现 / 音阁;六段是 订阅 / **最新** / 收藏 / 下载 / 历史 / 批注(`UI/LibraryView.swift:8-15`,仍叫「最新」且没有「待播」)。**队列入口只有底部播放条那颗 list.bullet** | 中(工具栏分段加一格 + 段序号契约要跟着改,见 FEATURES.md 那条「新段加在末尾」) |
| M7 | **播放态跨启动保留**(`playback_state.json`:队列 + 正在播哪一集 + 进度) | `PlaybackStateStore.kt`(刻意**不去抖**) | `PlaybackStateStore.ets` 同构 | **全仓 grep 无** `playback_state` / `persistState` —— 冷启动后队列与「正在播哪一集」全丢,底部播放条整条不出现(手机上这曾是"回播放页的唯一入口丢了",见 H129) | 中(桌面文件位置用 `Application Support`;格式要与两端**互通**,字段命名照 `docs/ARCHITECTURE.md`) |
| M8 | **音频离线缓存**(播过即缓存整集 + 字节预算 LRU,选源次序 下载 > 缓存 > 流式) | `playback/AudioCacheManager.kt`,接入 `PlayerController.kt:659-672` | `AudioCacheManager.ets`(预算 300 MB) | **零实现**:选源只看下载那一份(`PlayerController.swift:91,379` 附近) | 高(且这是 #161 那轮手机侧刚验完的能力,口径要照搬) |
| M9 | **封面图片磁盘缓存 + 设置页「清除缓存」这一格** | 复用 Coil 磁盘缓存,设置页两条口径分开(清除缓存 / 清除下载) | 自研 `ArtworkCache.ets`(20 MB) | **只靠 URLSession 默认 URLCache**(`UI/Theme.swift:134-135` 注释自己写了),无预算、无 LRU、不计入体积;`FeedCacheStore.swift:12-14` 的注释更是明说 `sizeBytes()` / `clear()` **「没有接进 macOS 设置页」** ⇒ 「清除缓存」这一格在桌面**整块缺失** | 中 |
| M10 | **读发布方提供的逐字稿**(RSS `transcript` 标签 / JSON·SRT·VTT) | `RssParser.kt:130-137,170-171,229` | `RssParser.ets:66-68` + `net/TranscriptFetcher.ets` | **解析层一条都没有**:`Data/RssParser.swift`、`Data/Models.swift` 里没有 transcript 字段。桌面只有本机 `SpeechAnalyzer`(`Data/Transcriber.swift`)⇒ 与商店渠道/鸿蒙那套「只读发布方稿、不做本机识别」的降级路径**在桌面上无从对齐** | 中-高(三端取字口径见 `docs/TRANSCRIPT.md`;缓存 version 已有 `TranscriptStore.swift:10`) |
| M11 | **关于页 + 开源许可页 + 法定展示信息的出口** | `AboutScreen.kt` + `LicensesScreen.kt`(备案号在这里显示,资源键 `beian_number`)、同意页 `privacy_consent_*` 三串 | `AboutPage.ets` + `LicensesPage.ets`(同名键 `beian_number`,空值就不渲染整行),base 那份含 `privacy`/`备案` **10 处** | **两个视图都不存在**(`UI/` 下只有 13 个视图,`ls` 数过),而且**桌面端没有任何隐私/备案的对外文案**:38 个 `.swift`(314,475 B)里 `隐私/备案/privacy` 只命中 **2 处**,都在注释(`Data/Log.swift:110`、`Data/PodcastRepository.swift:30`,内容是"隐私政策承诺日志不记搜索词"的**引用**,不是给用户看的句子);4 份 `.strings`(共 35,541 B)里这三个词 **各 0**。**设置页连版本号都不显示** —— `CFBundleShortVersionString` 全仓只出现在导出日志那封邮件的正文里(`UI/SettingsView.swift:369`) | 中(**这是合规缺口,不只是"页面缺失"**:手机的三处出口 —— 首次同意页、关于页备案号、许可清单 —— 桌面一个都没有。备案号在 Mac 端要不要展示是**产品与法务口径问题,先问再写**(`AGENTS.md` 硬规矩 13:预写的是格式不是值) |
| M12 | **发现页分类排序** | `CategoryStore.kt` | `CategoryStore.ets`(#86 那轮从 Android 移植过来) | 无 CategoryStore,分类顺序固定 | 低 |

## 二、口径漂移(两端与 macOS **都有**,但数值/形态不同)

| # | 项 | 两端 | macOS | 要不要动 |
|---|---|---|---|---|
| D1 | 地区列表 | 12 项(`harmony/.../model/Genres.ets:109 REGIONS` 数过) | **8 项**(`UI/SettingsView.swift:29-31`) | 要 —— 少的那几项是"目录按地区取哪一份",影响可见内容 |
| D2 | 字号 | 4 档离散 | **连续滑杆 0.85–1.30、step 0.05**(`SettingsView.swift:91`) | 建议**保留滑杆**(桌面是更合理的形态),但备份里存的值要与两端的档位口径互通,别出现"手机导到 Mac 字号变成 0" |
| D3 | 追更落盘条数 | 300(`InboxStore.ets:36 PERSIST_MAX`,装机实测 333,160 B) | **`maxCount = 100` + `perFeedCap = 12`**(`Data/InboxStore.swift:19,21`) | 要 —— 2026-10-10 那次"整栏都能翻"的改动没跟到桌面 |
| D4 | 音阁段名 | 订阅 / 收藏 / 下载 / 待播 / 历史 / 批注 | 订阅 / **最新** / 收藏 / 下载 / 历史 / 批注 | 跟 M6 一起改 |
| D5 | 逐字稿取字方向 | 优先发布方稿,本机 ASR 只在自分发 Android | **只有本机 ASR** | 跟 M10 一起解 |
| D6 | 日志分区四行的顺序 | 已定序 | 不同序 | 低优先,但**跨端恢复备份时会表现为"顺序不一样"**,值得一次对齐 |

## 三、**不该移植**的项(平台限制或形态不同,列在这里是为了别下次再盘一遍)

| 项 | 为什么不 |
|---|---|
| 真实频谱(`FEATURES.md:405`) | 桌面没有对应的渲染需求与性能上下文 |
| 后台更新巡检 | Android 靠 WorkManager、鸿蒙靠长时任务;**macOS 没有对等的、且用户会在 Dock 里等它** —— 前台 `taskGroup` 轮询够用 |
| 系统级备份白名单 | `FEATURES.md:321` 那条描述的是 Android/鸿蒙的机制,桌面走 `Application Support` 目录本身 |
| 「仅蜂窝下载」闸门 | Mac 无蜂窝基带。⚠️ 但 **M3 的备份键里有 `allowCellularDownload`** —— 移植备份时要决定这一项在桌面是"删掉"还是"恒为允许",别默默带过去 |
| 悬浮玻璃底栏 / 播放条收束成胶囊 | 桌面形态是顶部工具栏 + 常驻底部播放条,那两套手机侧形态(#165/#167 那条线)不适配 |

## 四、建议实施顺序

**原则**:先做"改了会谎报自述"和"合规没有出口"的,再做"手机新能力",最后做"重资源管线"。
每批的验收方式写在行末 —— 桌面**在本机只能做到类型检查差分**(AGENTS.md 里那条判据:改前改后**都跑到 0 错误** + 阳性对照),
**界面与行为必须在那台装了完整 Xcode 的构建机上跑 `./package.sh` 之后验收**(见 #59)。

1. **M1 清空二次确认** —— 半天。这是"一键清光用户数据没有找回办法",在所有缺口里唯一属于**数据安全**。
2. **M2 + M3 备份的分区勾选与三键** —— 一天。跨端互通是当前承诺(硬规矩:备份格式互通),现在这份承诺在桌面是**残缺的**。
3. **M4 封面 → 频道页** —— 一到两天。⚠️ 移植前先读 **H187**:接管与不接管在 ArkUI 是"两棵树",在 SwiftUI 又不同(`onTapGesture` 的手势仲裁要自己实测一次),**别照抄任何一端的写法**。
4. **M6 追更第三格 + 待播段** —— 一到两天(导航与段序号契约改动面大,先做)。
5. **M5 批量加入待播** —— 两天。**直接按批量版写**(H186 留的话):桌面也要有 `enqueueAll` 一次去重、一次落盘,不要循环单条 `enqueue`。
6. **D3 追更条数 300** —— 半小时,和 M6 同批。
7. **M11 关于页 + 许可页** —— 一到两天,**成本主要不在视图**:五语口径意味着代码里写默认串(简中)+ `macos/Localization/{en,es,fr,zh-Hant}.lproj` **4 套 `.strings`** 才凑齐五个语种(硬规矩 5 的 macOS 形态,别按"找 5 个文件"去数)。
8. **M7 播放态跨启动** —— 两天。格式与两端逐字段对齐,不然 M2 的互通承诺会在这里破。
9. **M10 发布方稿解析** —— 三到四天(解析 + 三端分句口径 + `TranscriptStore` version 门要动,见 `docs/TRANSCRIPT.md`)。
10. **M8 音频缓存 + M9 封面磁盘缓存 + 设置页「清除缓存」格** —— 一周级,放最后:这三条互相牵制(体积统计口径、两条清除入口互不越界),而手机侧 #161 的验收刚跑完,口径还热。

## 五、本表**没有覆盖**什么

- **没跑过任何 macOS 产物**,所以"现状"列全是**源码层判断**。某条能力可能由 SwiftUI 默认行为提供而不写在源码里(例如 M9 的图片缓存就是靠 `URLCache` 的默认行为)—— 这类要在构建机上实测才能定案。
- 表里凡是写「**0**」的那几格都跟着**处理量**(文件数与字节数),这是本仓库的通用验收口径:
  声明"有"和声明"没有"两侧都要跑 grep,而「扫不到」必须先证明扫描跑过。中文串按 `LC_ALL=C grep -a` 搜原始字节。
- **没做逐项的三端字段级 diff**(比如同一功能的默认值是否一致),只盘了"有没有这段实现"。
- 未打开读过的文件:`macos/Sources/Reverb/Data/{AppleChartsSource,GpodderSource,ITunesSource,FyydSource,PopularCacheStore,ListenStatsStore,DownloadManager}.swift` 与 `UI/{FootprintView,ListenStatsView,ShareCards}.swift` 只按需要略读,不构成"这些模块没问题"的结论。
- **电台(播客 RSS 之外的音频电台)** 三端都没做(`ROADMAP.md` A 段末尾),不在本表。
- 本表的 Android / 鸿蒙落点是**本轮工作区状态**(那 14 个 harmony 文件尚未提交),提交后再引用行号才稳定。
