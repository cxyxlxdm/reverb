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
| M1 | **清空二次确认**(待播队列 / 播放历史) | `QueueScreen.kt` 清空走确认框、`LibraryScreen.kt` 历史同款(文案共用 `confirm_clear_history`) | `QueuePage.ets` / `LibraryPage.ets` 同口径 | **已对齐(2026-10-25)**:`UI/QueueView.swift` 的原「直连 `player.clearQueue()`」改成 `.confirmationDialog`(正文照抄 `confirm_clear_queue`「将清空待播队列中的全部单集，无法恢复。」),`UI/LibraryView.swift` 历史那颗同样补框(正文 `confirm_clear_history`)。简中串在代码里,另 4 套 `.strings` 已补 `清空播放队列?` / `清空播放历史?` 与两条正文 —— ⚠️ **一帧没跑过**:`swift build -c release` exit 0 只证类型,弹框的实际弹出/取消路径待桌面运行验收 | 已完成(代码侧) |
| M2 | **导出备份的分区勾选** | `BackupManager` + `BackupSectionDialog`(用户自己勾分区) | `BackupSectionDialog.ets` 同构 | **已对齐(2026-10-25)**:新增 `ExportSheet`(全勾初值、复选框、空选集禁用确认),与恢复弹窗同版式;确认后先收 sheet 再弹 `NSSavePanel`,避免保存面板被 sheet 压住。⚠️ 一帧未跑 | 已完成(代码侧) |
| M3 | **备份缺三键**:`allowCellularDownload` / `updatesEnabled` / `categoryOrder` | `BackupManager.kt` 的 SettingsPayload 带这三项 | `CategoryStore.ets` 有分类排序 | **已对齐(2026-10-25,按"原样带过去"口径)**:`SettingsPayload` 补三格,`SettingsStore` 各存一份 —— 桌面没有蜂窝、没有常驻巡检,那两格**不在本端生效**,只保证「手机 → Mac → 手机」往返不丢设置;`categoryOrder` 自 M12 起在本端**真的读写**(排序界面),恢复时的空数组守卫见 M12 行。分类顺序存的是 key(`recommend`/`news`…,与语种无关),跨语言恢复也对得上 | 已完成(代码侧) |
| M4 | **点封面/头像直达这一集的频道页** | `coverChannelJump()`(`ui/components/Components.kt:194`)+ 列表行与迷你条两处挂载 + `LocalOpenPodcastChannel` 注入;频道详情页自己关掉这一门 | `Components.ets` 的 `coverTakesTap()` / `coverTaken()` / `coverPlain()` 三颗 + `MiniPlayerBar.ets` 的 `canJumpChannel()` | **已对齐(2026-10-25,代码侧)**:新增 `UI/Theme.swift:237 Episode.channelRef`(`feedUrl` 为空返回 nil —— 与 Android 同一条门,别把空串塞进路由)与 `Theme.swift:252 EpisodeArtworkLink`(用 `NavigationLink(value:)` —— 根 `RootView` 已注册 `Podcast.self` 的 destination,任何一层的列表都能直接压栈,不必把 path 透传);单集行封面默认换成它(`Theme.swift:316`),于是**发现页 / 最新 / 收藏 / 下载 / 历史 / 批注**的封面都可点。频道页自己传 `coverOpensChannel: false`(`PodcastDetailView.swift:67`,否则点一下在栈上再压一份同一个频道 —— 同 Android「本页关掉这一门」);选择模式下也关掉(那一格点击归属勾选)。底部播放条把封面从「开播放页」那颗按钮里拆成单独一颗(`NowPlayingBar.swift:57`),队列 sheet 因为自带私有 `NavigationStack` 且缺 `listenStats` / 下载两套环境对象,改走回调交回根视图(`QueueView.swift:8,28`,先 dismiss 再推栈)。⚠️ **一帧没跑过**:`swift build -c release` exit 0 只证类型;`onTapGesture` 与 `NavigationLink` 的手势仲裁(**H187** 提醒的那条)只有桌面运行验收能定 | 已完成(代码侧) |
| M5 | **多选批量加入待播**(追更 / 收藏 / 下载 / 历史 / **频道页**五栏) | `PlayerController.kt:245 enqueueAll` + `enqueuePicked` / `SELECTION_BAR_SLOT` / `EpisodeBatchBar`(`Components.kt:909/917/933`) | `PlayerController.ets enqueueAll` + `Components.ets` 的 `enqueuePicked` / `batchEnqueueAndToast` / `EpisodeBatchBar` | **已对齐(2026-10-25,代码侧)**:`Playback/PlayerController.swift:481 enqueueAll(_:) -> Int` —— 一次去重 + 一次 `updateNavFlags`,**返回真正加进去的条数**(与 Android 同口径,不循环单条 `enqueue`);入口是工具栏的「选择」模式(`UI/Theme.swift:431 EpisodeBatchToolbar`:已选 n / 全选 / 加入待播 / 完成),**桌面不做手机那条长按悬浮条**。范围:追更 / 收藏 / 下载 / 历史(`UI/InboxView.swift:13` 与 `UI/LibraryView.swift:35,178` 各持一份 `EpisodeSelection`,后者切段时清空 —— 否则 id 会跨列串味)与频道页(`PodcastDetailView.swift:125` 自持一份)。选择态下行尾的播放 / 下载 / 右键菜单全部让位(`Theme.swift:316` 一带 + `episodeContextMenu(enabled:)`),封面改画勾;结果用顶部 `TopToast`(`Theme.swift:458`)说一句,`added == 0` 时说「所选都已在待播里」而不是「已加入 0 集」。简中串在代码里,另 4 套 `.strings` 已补 8 个键。⚠️ **一帧没跑过**:类型通过 ≠ 选择态视觉与去重路径验过 | 已完成(代码侧) |
| M6 | **追更独立入口 + 音阁「待播」段** | 底部三格 发现 / 追更 / 音阁(`ReverbRoot.kt`),音阁六段含「待播」 | 同三格(`Index.ets`),`LibraryPage.ets` 的「待播」段与独立队列页**共用同一个 body** | **已对齐(2026-10-25,代码侧)**:顶部三格换成 发现 / 追更 / 音阁(`RootView.swift:8-11`,分段定宽 300 —— 法语标签最长,会不会截断只有把界面跑起来才看得见);新顶层页 `UI/InboxView.swift`(`RootView.swift:27` 接 `.inbox`),工具栏手动刷新 + 选择模式;音阁六段改成 订阅 / 收藏 / 下载 / **待播** / 历史 / 批注(`UI/LibraryView.swift:9-17`)。待播段与队列 sheet **共用同一个 body**:抽成 `QueueList`(`UI/QueueView.swift:8`),sheet(`QueueView.swift:82`,标题也统一成「待播」)只多传一个「点封面回根栈」的回调 —— 根栈里走 `NavigationLink`、sheet 里交给根视图(它自带的私有 `NavigationStack` 没有 `Podcast` destination)。清空那颗挂在待播段工具栏(`LibraryView.swift:159`,二次确认见 M1)。`"最新"` / `"播放队列"` / `"清空播放队列"` 等 5 个不再使用的键已删,新增 5 个键 × 4 套 `.strings`。⚠️ **一帧没跑过**:`swift build -c release` exit 0 只证类型;法语下的分段条宽度、切 tab 时列表保位都待桌面运行验收 | 已完成(代码侧) |
| M7 | **播放态跨启动保留**(`playback_state.json`:队列 + 正在播哪一集 + 进度) | `PlaybackStateStore.kt`(刻意**不去抖**) | `PlaybackStateStore.ets` 同构 | **已对齐(2026-10-25,代码侧)**:新增 `Data/PlaybackStateStore.swift` —— 文件名 / `version` / 六个顶层键(`version` `listTag` `contextIndex` `context` `upNext` `current`)与两端逐字段一致,`CONTEXT_HALF=40` / `UP_NEXT_CAP=300` / 列表条目去掉简介只留 `current` 带(`PlaybackStateStore.swift:37,39,144`)。**同步写**,不走 `AppSupport.save` 那条去抖(去抖的代价正是"进程被杀丢掉最后一次",而这条要治的就是它)。接点:`PlayerController.swift:218 bindState` / `:226 persistState`(电台期间只落 upNext、`current=nil`,与两端同理由)/ `:241 restoreState`(**恢复现场不恢复意图**:预载暂停态、进度线按历史画、`updateNavFlags` 就地刷一次,否则重启后上下集按钮灰着)/ `:414 playEpisode` 多一个 `autoplay` 参数,换集即落盘;改队列的七处(入队 / 批量 / 下一个播放 / 移出 / 重排 / 清空 / 队列起播)各落一次。`AppEnvironment.swift:34-42` 在依赖都绑好(历史、下载源)之后恢复。⚠️ **一帧没跑过**:`swift build -c release` exit 0 只证类型;落盘/读回/跨端格式用 `/tmp` 沙箱把头两个文件拉出来跑过 19 条断言(窗口 81@40、读 Android 那份时下标自我纠正、version>1 作废、upNext 截 300;阳性对照把 `contextHalf` 改成 30 → exit 1),但"重启后播放条出不出、预载出声不出声"只有桌面运行验收能定 | 已完成(代码侧) |
| M8 | **音频离线缓存**(播过即缓存整集 + 字节预算 LRU,选源次序 下载 > 缓存 > 流式) | `playback/AudioCacheManager.kt`,接入 `PlayerController.kt:659-672` | `AudioCacheManager.ets`(预算 300 MB) | **已对齐(2026-10-25,代码侧)**:新增 `Data/AudioCacheStore.swift`(账本 `audio_cache.json` / `version=1` / `NSLock`,字段与两端同名)与 `Playback/AudioCacheManager.swift` —— 三条不变式逐条照搬:① 写完才认账(`:143` `HTTP.session.download` 先落系统临时文件 → `:168` rename 成 `.part` → `:175` 正式名,**先落名再记账**);② 单飞、最新优先(`:77` 取消上一个、`:160`/`:169` 落名前后各比对一次认领);③ 300 MB 预算 + 按 `lastAccess` 的 LRU(`:22` 预算、`:194 evict`)。文件名 `ca_<FNV-1a 64 位><扩展名>`(`:261`),扩展名按 URL 猜 m4a/aac/ogg/wav,其余 mp3。接点:`AppEnvironment.swift:20` 建实例、`:41` 绑进播放器;选源次序改成 下载 > 缓存 > 流式(`PlayerController.swift:460-469`,日志里记 `源=`),`localURL` **只在文件真存在且非空时**返回(`:50`),流式起播后 `:473` 排一次整集落盘。**不走计费闸门**,理由写在类头(桌面没有蜂窝基带;只给音频缓存单独加一道看不见的闸门,症状会比问题难查)。与 `DownloadManager` 完全分开:不同目录、不同账本,「清空下载」删不到这里。⚠️ **一帧没跑过**:`swift build -c release` exit 0 + `tools/cache-probe/run.sh` 36 条断言(pass=36 fail=0,含阳性对照)只覆盖落盘/读回/预算与 `.part`,**"播放中真的从本地起播"只有桌面运行验收能定** | 已完成(代码侧) |
| M9 | **封面图片磁盘缓存 + 设置页「清除缓存」这一格** | 复用 Coil 磁盘缓存,设置页两条口径分开(清除缓存 / 清除下载) | 自研 `ArtworkCache.ets`(20 MB) | **已对齐(2026-10-25,代码侧)**:① 新增 `Data/ArtworkCache.swift`(actor):`art_<FNV-1a 64 位><扩展名>`、20 MB 预算(`:24`)、按 mtime 淘汰(**不按访问时间** —— 每屏几十张都 touch 一次等于给滚动加一轮 IO,硬规矩 6)、最多 4 张并发(`:27`,FIFO 信号量)、失败冷却 60 秒(`:31`)、**没有账本文件**(文件名由 URL 算得出,目录本身就是账);落盘前用 ImageIO 校验宽高(`:283 decodable`),坏图不落盘。`UI/Theme.swift:160` 的 `RemoteImage` 改走它,不再是 `URLSession.shared` 那个既不计数也清不掉的 URLCache。② `PopularCacheStore.swift:36 clear` / `:48 sizeBytes` 与 `FeedCacheStore.clear()`(写空字典走同一条去抖通道,否则 0.4 秒后旧快照原地复活)补齐,`PodcastRepository.swift:28 cacheSizeBytes` / `:34 clearCaches` 合成一份;`TranscriptStore.swift:194 clearAll`(先抬代号再删文件)+ `:213 diskUsageBytes`。③ 设置页「存储」段首行 `UI/SettingsView.swift:176` 是「清除缓存」,右侧字节数(`:379` 四路求和:榜单/频道、逐字稿、音频、封面;重算时机见 H215),`:285` 二次确认,正文与 Android `confirm_clear_cache` 同一句;下载那一行原地不动(两条口径分开)。简中串在代码里,另 4 套 `.strings` 各补 6 个键(`plutil -lint` 四份全过)。⚠️ **一帧没跑过**:`tools/cache-probe/run.sh` 覆盖「坏图被拒」「`.part` 不计」「clear 后目录空」「清榜单不碰无关文件」等 36 条断言;**设置页那一行在任何屏幕上都没打开过** | 已完成(代码侧) |
| M10 | **读发布方提供的逐字稿**(RSS `transcript` 标签 / JSON·SRT·VTT) | `RssParser.kt:130-137,170-171,229` | `RssParser.ets:66-68` + `net/TranscriptFetcher.ets` | **已对齐(2026-10-25,代码侧)**:① 解析层 `Data/RssParser.swift:167-175` 认 `podcast:transcript`,按 json 3 / vtt 2 / srt 1 取最优(不是取第一条),落 `Episode.transcriptUrl` / `transcriptType`(`Data/Models.swift:31,34`);`Episode` 的自定义 `init(from:)` 把新键解成空串,旧历史 / 下载 / 备份文件照旧可读(H86)。② 取稿与解析新增 `Data/TranscriptFetcher.swift`(8 MB 上限、**先嗅探内容再看声明 type**、VTT/SRT/JSON 三种时间轴、`NOTE` 块与说话人标签剔除)与 `Data/TranscriptLines.swift`(分句阈值/碎片合并逐条照 Android,同一份稿三端行数才对得上,H150)。③ `Data/TranscriptStore.swift:153 runAny` **先官方稿、失败回退本机识别**;官方稿在 `:163` 过一遍 `TranscriptFormat.monotonic`(硬规矩 10)后写进同一份 `version=2` 缓存;`:125 localASRAvailable` 只在回退时挡 macOS 26 —— **官方稿在 14/15 上就能看**(13 没有轮播,整条 UI 不出现)。④ 页面:`UI/TranscriptPage.swift:72,94` 有「正在获取…」与两种起始文案(官方稿说「查看逐字稿」,本机识别说「生成转录」);`UI/PlayerView.swift:69` 的轮播显隐补 `|| !ep.transcriptUrl.isEmpty`(官方稿不该要求打开本机识别)。五语文案:3 个新键 × 4 套 `.lproj`,按 Android 渲染值对译。⚠️ **一帧没跑过**:`swift build -c release` exit 0 + `/tmp` 探针 55 条断言(阳性对照 exit 1)只覆盖解析与断句;官方稿页面、回退顺序、轮播显隐都待桌面运行验收;`.lproj` 不进包内 grep,包内验证等批次末 `./package.sh` | 已完成(代码侧) |
| M11 | **关于页 + 开源许可页 + 法定展示信息的出口** | `AboutScreen.kt` + `LicensesScreen.kt`(备案号在这里显示,资源键 `beian_number`)、同意页 `privacy_consent_*` 三串 | `AboutPage.ets` + `LicensesPage.ets`(同名键 `beian_number`,空值就不渲染整行),base 那份含 `privacy`/`备案` **10 处** | **已对齐(2026-10-25,代码侧)**:三处出口都补上了。① **首次同意门**:`UI/PrivacyConsentView.swift:70 PrivacyGate` 包住 `RootView`(`ReverbApp.swift:14`),未同意时 `RootView` **一次都不构建**,发现页那些联网 `.task` 也就发不出去;接受的是**版本号**而非布尔(`Data/Stores.swift:312 privacyVersion = 2`,与 Android `PRIVACY_VERSION` 同数、两边一起 +1),「不同意」走 `NSApp.terminate(nil)`(与两端"直接退出"同口径)。② **关于页** `UI/AboutView.swift:39`:名称 / 口号 / 版本(现读 `CFBundleShortVersionString`)/ 备案号 + 三段正文;备案号取的是**已下发的号**(`AboutView.swift:15`,与手机五语资源同一个值),**空串则整行不渲染**(硬规矩 13)。③ **许可页** `AboutView.swift:142`:只列 Apple 框架(SwiftUI/AppKit/AVFoundation/Speech/URLSession)与三个公开目录 + 发布方 RSS —— **订阅提醒、官网 OPML 两样不列**(桌面没有,宁可少写;播放缓存 M8 已补,关于页那一行照列;发布方逐字稿已随 M10 落地,它走发布方自己的主机,与 RSS/音频同一条,不新增来源)。设置页新增「关于」段(`UI/SettingsView.swift:229`):关于余音 / 隐私政策(系统浏览器打开 `https://cxyxl.cn/reverb/privacy.html`,不内置 WebView)/ 开源许可 / 版本。文案:简中在代码里当默认串,另 4 套 `.lproj` 各补 **44 个键** —— `plutil -lint` 四份全过,四份键集与顺序逐键相同,且 44 个键全部能在 `macos/Sources` 里找到原文。⚠️ **一帧没跑过**:同意门、关于页、许可页、设置页那四行都只到 `swift build -c release` exit 0;`.lproj` 由 `package.sh:59` 拷进 .app(SwiftPM 不处理它),所以本轮的键表验证是 `plutil` + 键集比对,不是包内 grep | 已完成(代码侧) |
| M12 | **发现页分类排序** | `CategoryStore.kt`(SharedPreferences `category_order`,存 key 序列,`\u0001` 分隔) | `CategoryStore.ets`(Prefs 里的 JSON 数组) | **已对齐(2026-10-25,代码侧)**:不新开 store —— 复用已有的 `SettingsStore.categoryOrder`(`Data/Stores.swift:300`,UserDefaults `category_order`;备份早就带这一格)。排序语义逐条照 Android `loadOrdered()` / 鸿蒙 `ordered()`:`UI/DiscoverView.swift:44 ordered(by:)` —— 空数组 = 原序、表里已不存在的 key 丢掉、新增分类挂末尾、全丢光回退原序。形态按桌面改:`DiscoverView.swift:248` 分类下拉末尾一颗「自定义分类排序…」→ `:109` 的 sheet,`CategoryOrderSheet`(`:425`)用 List 拖动行(`.onMove`)+ 每行上/下箭头(`.borderless`,两端 disabled,带 `help` 与无障碍标签;桌面没有长按手势,箭头给键盘与读屏留一条路),草稿态只在点「完成」时落盘、取消全丢,空表不落盘(与两端 `saveOrder` 的早退同一条)。恢复备份也照这条语义:`BackupManager.swift:212` 加了 `!v.isEmpty` —— 空表示"那份备份从没排过",不是"恢复默认序",否则拿一台没排过序的手机备份恢复会抹掉本机顺序。简中串在代码里,另 4 套 `.strings` 补 5 个键(菜单项带省略号、弹窗标题不带,macOS HIG),`plutil -lint` 四份全过、键集同为 276。⚠️ **一帧没跑过**:`swift build -c release` exit 0 只证类型;sheet 的开合、拖动、箭头与落盘都待桌面运行验收 | 已完成(代码侧) |

## 二、口径漂移(两端与 macOS **都有**,但数值/形态不同)

| # | 项 | 两端 | macOS | 要不要动 |
|---|---|---|---|---|
| D1 | 地区列表 | 12 项(`harmony/.../model/Genres.ets:109 REGIONS` 数过) | **已对齐(2026-10-25,代码侧)**:`UI/SettingsView.swift:32-36` 12 项,码与顺序同 `REGION_OPTIONS` / `REGIONS`(自动 cn hk tw us jp kr gb sg au ca de);四个新键(新加坡/澳大利亚/加拿大/德国)补进 4 套 `.lproj`(繁中按 Android 用「澳洲」),`plutil -lint` 四份全过、每份新键各 1 处 | 已完成(代码侧);⚠️ 下拉里 12 项没在屏幕上数过 |
| D2 | 字号 | 4 档离散 | **已对齐(2026-10-25,代码侧)**:界面**保留连续滑杆**(0.85–1.30、step 0.05,桌面上更合理),只在备份边界做换算 —— `Data/BackupManager.swift:34-49` 的 `[0.85,1.0,1.15,1.3]` 与 Android `FONT_SCALES` / 鸿蒙 `Theme.ets` 逐项相同、同一条「严格小于才换档」的取近规则;导出写 `fontScale` + `fontIndex` 两键(`:108`),恢复**倍率优先、缺失才退下标**(`:194`),越界下标夹到端点。12 条断言跑过,阳性对照(把 `<` 改 `<=`)⇒ 平局那条 exit 1 | 已完成(代码侧);⚠️ 没有用真备份做跨端往返 |
| D3 | 追更落盘条数 | 300(`InboxStore.ets:36 PERSIST_MAX`,装机实测 333,160 B) | **已对齐(2026-10-25,代码侧)**:`Data/InboxStore.swift:25 persistMax = 300`,并删掉 `maxCount = 100` / `perFeedCap = 12` 两道截断 —— **内存留全量、落盘只落排序后的前缀 300**(理由写在那一行:冷启动秒显 + JSON 体量),`loadAll` 也不再按源截断。排序与两端同一条 `sortedStable`(日期倒序、同值按 id 升序),日期解析结果按 id 缓存在 `keys`、比较器里不重复解析(硬规矩 6) | 已完成(代码侧) |
| D4 | 音阁段名 | 订阅 / 收藏 / 下载 / 待播 / 历史 / 批注 | **已对齐(2026-10-25,代码侧)**:同 M6,`UI/LibraryView.swift:9-17`(段的 `rawValue` 即显示名,`"最新"` 那个键随之删掉) | 已完成(代码侧) |
| D5 | 逐字稿取字方向 | 优先发布方稿,本机 ASR 兜底(Android 只有一份包,两个分发处都带引擎 —— H205) | **已对齐(2026-10-25,代码侧)**:`Data/TranscriptStore.swift:156` 先取官方稿,`:171` 取不到才回退;`:174` 的回退点才要求 macOS 26 | 已完成(代码侧) |
| D6 | 日志分区四行的顺序 | 已定序 | **已对齐(2026-10-25,代码侧)**:`UI/SettingsView.swift:212-226` 改成 分享日志 → 发送日志到开发者邮箱 → 导出日志… → 清空日志,与 Android `SettingsScreen.kt:341-350`、鸿蒙 `SettingsPage.ets:257-261` 同序;体积那一行仍留在分区首行(它不是这四行之一) | 已完成(代码侧);⚠️ 一帧没跑 |
| D7 | **单集菜单里「标记为已播完」的给法** | 2026-10-17 起:**正向那颗在所有单集列表都不给**,只有 `音阁 · 历史` 的已播完行给反向「标记为未播完」(它是发现页「继续收听」横条唯一的回程)。落点:`Components.kt` 的 `onTogglePlayed` / `Components.ets` 的 `showPlayedToggle` 注释里那条规则 | **已对齐(2026-10-25,代码侧)**:`UI/Theme.swift:527-590` 不再按 `played` 换文案,改成两颗显式可选回调且**文案写死**。正向 `onMarkPlayed` 只剩发现页「继续收听」卡(`UI/DiscoverView.swift:140-146`,与 Android 那张卡自己的菜单同口径);反向 `onMarkUnplayed` 只在 `音阁 · 历史` 的**已播完**行(`UI/LibraryView.swift:272-279,303-306`)。频道页/追更/收藏/下载/搜索 5 个调用点两颗都不传。`Stores.swift:159` 的"没历史条目就 return"保持原样 —— 正是它让浏览列那颗变成空操作 | 已完成(代码侧);⚠️ 一帧没跑过,右键菜单没在任何列打开过 |

## 三、**不该移植**的项(平台限制或形态不同,列在这里是为了别下次再盘一遍)

| 项 | 为什么不 |
|---|---|
| 真实频谱(`FEATURES.md:405`) | 桌面没有对应的渲染需求与性能上下文 |
| 后台更新巡检 | Android 靠 WorkManager、鸿蒙靠长时任务;**macOS 没有对等的、且用户会在 Dock 里等它** —— 前台 `taskGroup` 轮询够用 |
| 系统级备份白名单 | `FEATURES.md:321` 那条描述的是 Android/鸿蒙的机制,桌面走 `Application Support` 目录本身 |
| 「仅蜂窝下载」闸门 | Mac 无蜂窝基带。⚠️ 但 **M3 的备份键里有 `allowCellularDownload`** —— 移植备份时要决定这一项在桌面是"删掉"还是"恒为允许",别默默带过去 |
| 悬浮玻璃底栏 / 播放条收束成胶囊 | 桌面形态是顶部工具栏 + 常驻底部播放条,那两套手机侧形态(#165/#167 那条线)不适配 |

## 四、实施顺序(2026-10-25 已全部落地,下面留作当时的判断依据)

> **这一节的任务已经做完**:M1–M12 / D1–D7 全部按此顺序落地,并出了 `dist/余音-Reverb-1.0.6-universal.dmg`。
> **但"落地"只到编译 + 探针 + 解包断言这一层 —— 界面与行为一帧都没跑过**,剩余验收清单在
> `docs/ROADMAP.md` 三-A「macOS 1.0.6 这一批」那一行。下面每一行里那些"移植前先读 H187 / 按批量版写 / 五语是 4 套 `.strings`"
> 的判断仍然成立,留着是为了同一类改动再做时不重踩。
> ⚠️ **本节开头那句"桌面在本机只能做到类型检查差分 / 界面必须在那台构建机上验"已经作废** ——
> 10-24 傍晚起本机就能 `./package.sh`(见 `AGENTS.md`),要跑的只是运行验收,不需要另一台机器。

**原则**:先做"改了会谎报自述"和"合规没有出口"的,再做"手机新能力",最后做"重资源管线"。

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

> **2026-10-25 傍晚起,本表"⚠️ 一帧没跑过"那批尾巴分两档了** —— 哪些已经在屏幕上读过、读到的数是多少,**写在下面第六节,逐条以那一节为准**;这一节以下与第四节里"一帧没跑过"的措辞若与第六节冲突,是它过期。

## 五、本表**没有覆盖**什么

- ~~**没跑过任何 macOS 产物**,所以"现状"列全是**源码层判断**~~ ⇒ **2026-10-25:产物已出且解包验收过**(1.0.6 universal dmg),
  但**没跑起来过** —— 所以"现状"列里凡写着「已对齐」的,含义是"代码侧对齐 + 编译通过 + 断言通过",**不是"界面上验过"**。
  某条能力可能由 SwiftUI 默认行为提供而不写在源码里(例如 M9 的图片缓存就是靠 `URLCache` 的默认行为)—— 这类仍要跑起来才能定案。
- 表里凡是写「**0**」的那几格都跟着**处理量**(文件数与字节数),这是本仓库的通用验收口径:
  声明"有"和声明"没有"两侧都要跑 grep,而「扫不到」必须先证明扫描跑过。中文串按 `LC_ALL=C grep -a` 搜原始字节。
- **没做逐项的三端字段级 diff**(比如同一功能的默认值是否一致),只盘了"有没有这段实现"。
- 未打开读过的文件:`macos/Sources/Reverb/Data/{AppleChartsSource,GpodderSource,ITunesSource,FyydSource,PopularCacheStore,ListenStatsStore,DownloadManager}.swift` 与 `UI/{FootprintView,ListenStatsView,ShareCards}.swift` 只按需要略读,不构成"这些模块没问题"的结论。
- **电台(播客 RSS 之外的音频电台)** 三端都没做(`ROADMAP.md` A 段末尾),不在本表。
- 本表的 Android / 鸿蒙落点是**本轮工作区状态**(那 14 个 harmony 文件尚未提交),提交后再引用行号才稳定。

---

## 六、运行侧证据(2026-10-25 傍晚,本机 `.app` = `dist/余音-Reverb-1.0.6-universal.dmg` @15:50)

**这一节只回答一个问题**:上面每一行末尾那句「⚠️ 一帧没跑过」现在还成立吗。
**逐条读数、时间戳与判据原文在 `docs/ROADMAP.md` 三-A「macOS 1.0.6 这一批」那一行**,这里不复制一遍。
取证通道三条:辅助功能(`AXUIElement`,自建 `/tmp/axtool` + `/tmp/axpress`)、`screencapture` 像素读数、
App 日志与 `~/Library/Application Support/Reverb/` 下的 JSON 现读。

| 项 | 屏幕上读到了吗 | 一句话判据(详版见 ROADMAP 那一行) |
|---|---|---|
| M1 清空二次确认 | ◐ 半条 | 历史那颗按下弹「清空播放历史?」确认框、**取消不删**(`history.json` 前后同为 8 条);**确认那半条故意没点** —— 会连真实收听记录一起清,本端没有还原入口 |
| M2 导出分区勾选 | ✅ | 单分区导出两份(`分区=[subscriptions]` / `[settings]`),落盘 JSON 的键集只有勾的那一区 |
| M3 备份三键 | ✅(随 M2/M12 一起) | `categoryOrder` 在恢复路径上被读回并守空数组;另两键在桌面不生效,只验了"带着走" |
| M4 封面进频道页 | ✅ | 点封面压栈到频道页、`返回` 可退;播放条那颗独立封面钮与列表行分开 |
| M5 批量入队 | ✅ | 日志 `[UI] 批量加入待播 列=频道 … 选中=2 新增=2`(17:30:47),去重按"新增"计 |
| M6 追更第三格 + 音阁待播段 | ✅ | 顶部三格与音阁六段的 AX 读数都在(18:2x),切段正常 |
| M7 播放态跨启动 | ✅ | 两次冷启动(15:50:59 / 17:03:00)`启动读回播放态 cur=… ctx=41@0` 后紧接同一 id 起播到 `readyToPlay` |
| M8 音频缓存 | ◐ 半条 | 写入与命中有日志有文件(`cache start/done` + `audio_cache/ca_*` + 选源 `源=缓存`);**300 MB 满后 LRU 淘汰、断网冷启动两条没造** |
| M9 封面缓存 + 清除缓存 | ◐ 半条 | `本地封面 55 张 5627KB` 装载 + `cached art_*.jpg` 落盘 + `clearAll` 按下去;**淘汰与两口径互不影响没验**,另见 H215 那处界面缺陷(10-26 已改码,运行未验) |
| M10 发布方逐字稿 | ✅ 双向 | 正向:第三页出现 → 取到官方稿 4 句并渲染高亮;阴性:关掉本机识别后无稿集只剩 2 页;**阳性:同状态下有稿集仍 3 页且照样取到稿** ⇒ `PlayerView.swift:69` 那条 `||` 成立 |
| M11 关于页 / 许可页 / 同意门 | ◐ | 关于页与许可页在屏幕上打开过;同意门以 `privacy_version=2` 落 UserDefaults 为凭,**没有重弹一遍**(要删那个键);五语只看了 zh 与 fr |
| M12 分类排序 | ✅ | sheet 开合、箭头与拖动各动一次、`完成` 落盘 / `取消` 丢弃 / 重启读回;**恢复侧阴性对照做了**(三份空 `categoryOrder` 夹具连恢三次,本机序不动) |
| D1 地区 12 项 | ✗ **仍只有代码侧** | SwiftUI Picker 的 `NSMenu` 项取不到(`AXMenuItem` 两次 0 条,而同一工具在播放模式那颗取到 2 条 ⇒ 是取不到,不是没有) |
| D2 字号换算 | ◐ | 备份边界的 12 条断言是主机侧;真备份跨端往返没做 |
| D3 追更落盘 300 条 | ✗ **且日志里那批不是证据** | 08:16 那批 `upNext=300` / `ctx=81@40` 是 `PlaybackStateStore` 主机探针的合成夹具(`tag='inbox'`/`fav`/`probe-tag`),**与追更落盘无关**;造它要 >300 条真实追更,本机订阅现为 0 |
| D4 音阁段名 | ✅ | 六段渲染即读数 |
| D5 逐字稿取字方向 | ✅ | 随 M10:先官方稿,`用官方稿 4 句` 那条日志就是走的第一支 |
| D6 日志四行顺序 | ✅ | AX 坐标序:分享日志 1246 → 发送邮箱 1285 → 导出日志… 1324 → 清空日志 1364 |
| D7 菜单里那颗的给法 | ✅ | 右键菜单截图逐列看过:正向只剩发现页那张卡、反向只在历史已播完行 |

**这一轮顺带发现的一处界面缺陷已改码(10-26),但运行侧没验**:设置页「清除缓存」右侧的字节数与「日志」那一格
原先只在 `.onAppear` 与清除之后各算一次,而 SwiftUI 的 `Settings` 窗口是**隐藏、不销毁** ——
所以一次运行里第二次 ⌘, 打开,两个数还停在第一次那一刻(取证时读到过一个不再变化的 572 KB,差点判成「清除没生效」)。
现在挂在 `controlActiveState` 上,窗口每次重新成为关键窗口就重算,**没有加定时器**(硬规矩 6)。
现象/根因/取舍与**复跑 A/B 的完整形状**记在 **H215**;10-26 晚间准备跑那轮 A/B 时屏幕进入锁定态,
而解锁按固定边界归维护者本人 ⇒ **这一条的状态是"只过到 `swift build -c release` exit 0"**。
⚠️ 它动了 `Sources/`,所以 `dist/` 那份 15:50 的 1.0.6 dmg 现在比源码旧,发版前必须按硬规矩 20 重打(本轮按"先不发布"没打)。
