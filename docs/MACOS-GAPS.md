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
| M3 | **备份缺三键**:`allowCellularDownload` / `updatesEnabled` / `categoryOrder` | `BackupManager.kt` 的 SettingsPayload 带这三项 | `CategoryStore.ets` 有分类排序 | **已对齐(2026-10-25,按"原样带过去"口径)**:`SettingsPayload` 补三格,`SettingsStore` 各存一份 —— 桌面没有蜂窝、没有常驻巡检、分类顺序仍是编译期常量,所以这三格**不在本端生效**,只保证「手机 → Mac → 手机」往返不丢设置。`categoryOrder` 按字符串数组原样存取(分类标签是各端本地化串,跨语种恢复时可能对不上,留给 M12 一并处理) | 已完成(代码侧) |
| M4 | **点封面/头像直达这一集的频道页** | `coverChannelJump()`(`ui/components/Components.kt:194`)+ 列表行与迷你条两处挂载 + `LocalOpenPodcastChannel` 注入;频道详情页自己关掉这一门 | `Components.ets` 的 `coverTakesTap()` / `coverTaken()` / `coverPlain()` 三颗 + `MiniPlayerBar.ets` 的 `canJumpChannel()` | **已对齐(2026-10-25,代码侧)**:新增 `UI/Theme.swift:237 Episode.channelRef`(`feedUrl` 为空返回 nil —— 与 Android 同一条门,别把空串塞进路由)与 `Theme.swift:252 EpisodeArtworkLink`(用 `NavigationLink(value:)` —— 根 `RootView` 已注册 `Podcast.self` 的 destination,任何一层的列表都能直接压栈,不必把 path 透传);单集行封面默认换成它(`Theme.swift:316`),于是**发现页 / 最新 / 收藏 / 下载 / 历史 / 批注**的封面都可点。频道页自己传 `coverOpensChannel: false`(`PodcastDetailView.swift:67`,否则点一下在栈上再压一份同一个频道 —— 同 Android「本页关掉这一门」);选择模式下也关掉(那一格点击归属勾选)。底部播放条把封面从「开播放页」那颗按钮里拆成单独一颗(`NowPlayingBar.swift:57`),队列 sheet 因为自带私有 `NavigationStack` 且缺 `listenStats` / 下载两套环境对象,改走回调交回根视图(`QueueView.swift:8,28`,先 dismiss 再推栈)。⚠️ **一帧没跑过**:`swift build -c release` exit 0 只证类型;`onTapGesture` 与 `NavigationLink` 的手势仲裁(**H187** 提醒的那条)只有桌面运行验收能定 | 已完成(代码侧) |
| M5 | **多选批量加入待播**(追更 / 收藏 / 下载 / 历史 / **频道页**五栏) | `PlayerController.kt:245 enqueueAll` + `enqueuePicked` / `SELECTION_BAR_SLOT` / `EpisodeBatchBar`(`Components.kt:909/917/933`) | `PlayerController.ets enqueueAll` + `Components.ets` 的 `enqueuePicked` / `batchEnqueueAndToast` / `EpisodeBatchBar` | **已对齐(2026-10-25,代码侧)**:`Playback/PlayerController.swift:481 enqueueAll(_:) -> Int` —— 一次去重 + 一次 `updateNavFlags`,**返回真正加进去的条数**(与 Android 同口径,不循环单条 `enqueue`);入口是工具栏的「选择」模式(`UI/Theme.swift:431 EpisodeBatchToolbar`:已选 n / 全选 / 加入待播 / 完成),**桌面不做手机那条长按悬浮条**。范围:追更 / 收藏 / 下载 / 历史(`UI/InboxView.swift:13` 与 `UI/LibraryView.swift:35,178` 各持一份 `EpisodeSelection`,后者切段时清空 —— 否则 id 会跨列串味)与频道页(`PodcastDetailView.swift:125` 自持一份)。选择态下行尾的播放 / 下载 / 右键菜单全部让位(`Theme.swift:316` 一带 + `episodeContextMenu(enabled:)`),封面改画勾;结果用顶部 `TopToast`(`Theme.swift:458`)说一句,`added == 0` 时说「所选都已在待播里」而不是「已加入 0 集」。简中串在代码里,另 4 套 `.strings` 已补 8 个键。⚠️ **一帧没跑过**:类型通过 ≠ 选择态视觉与去重路径验过 | 已完成(代码侧) |
| M6 | **追更独立入口 + 音阁「待播」段** | 底部三格 发现 / 追更 / 音阁(`ReverbRoot.kt`),音阁六段含「待播」 | 同三格(`Index.ets`),`LibraryPage.ets` 的「待播」段与独立队列页**共用同一个 body** | **已对齐(2026-10-25,代码侧)**:顶部三格换成 发现 / 追更 / 音阁(`RootView.swift:8-11`,分段定宽 300 —— 法语标签最长,会不会截断只有把界面跑起来才看得见);新顶层页 `UI/InboxView.swift`(`RootView.swift:27` 接 `.inbox`),工具栏手动刷新 + 选择模式;音阁六段改成 订阅 / 收藏 / 下载 / **待播** / 历史 / 批注(`UI/LibraryView.swift:9-17`)。待播段与队列 sheet **共用同一个 body**:抽成 `QueueList`(`UI/QueueView.swift:8`),sheet(`QueueView.swift:82`,标题也统一成「待播」)只多传一个「点封面回根栈」的回调 —— 根栈里走 `NavigationLink`、sheet 里交给根视图(它自带的私有 `NavigationStack` 没有 `Podcast` destination)。清空那颗挂在待播段工具栏(`LibraryView.swift:159`,二次确认见 M1)。`"最新"` / `"播放队列"` / `"清空播放队列"` 等 5 个不再使用的键已删,新增 5 个键 × 4 套 `.strings`。⚠️ **一帧没跑过**:`swift build -c release` exit 0 只证类型;法语下的分段条宽度、切 tab 时列表保位都待桌面运行验收 | 已完成(代码侧) |
| M7 | **播放态跨启动保留**(`playback_state.json`:队列 + 正在播哪一集 + 进度) | `PlaybackStateStore.kt`(刻意**不去抖**) | `PlaybackStateStore.ets` 同构 | **已对齐(2026-10-25,代码侧)**:新增 `Data/PlaybackStateStore.swift` —— 文件名 / `version` / 六个顶层键(`version` `listTag` `contextIndex` `context` `upNext` `current`)与两端逐字段一致,`CONTEXT_HALF=40` / `UP_NEXT_CAP=300` / 列表条目去掉简介只留 `current` 带(`PlaybackStateStore.swift:37,39,144`)。**同步写**,不走 `AppSupport.save` 那条去抖(去抖的代价正是"进程被杀丢掉最后一次",而这条要治的就是它)。接点:`PlayerController.swift:218 bindState` / `:226 persistState`(电台期间只落 upNext、`current=nil`,与两端同理由)/ `:241 restoreState`(**恢复现场不恢复意图**:预载暂停态、进度线按历史画、`updateNavFlags` 就地刷一次,否则重启后上下集按钮灰着)/ `:414 playEpisode` 多一个 `autoplay` 参数,换集即落盘;改队列的七处(入队 / 批量 / 下一个播放 / 移出 / 重排 / 清空 / 队列起播)各落一次。`AppEnvironment.swift:34-42` 在依赖都绑好(历史、下载源)之后恢复。⚠️ **一帧没跑过**:`swift build -c release` exit 0 只证类型;落盘/读回/跨端格式用 `/tmp` 沙箱把头两个文件拉出来跑过 19 条断言(窗口 81@40、读 Android 那份时下标自我纠正、version>1 作废、upNext 截 300;阳性对照把 `contextHalf` 改成 30 → exit 1),但"重启后播放条出不出、预载出声不出声"只有桌面运行验收能定 | 已完成(代码侧) |
| M8 | **音频离线缓存**(播过即缓存整集 + 字节预算 LRU,选源次序 下载 > 缓存 > 流式) | `playback/AudioCacheManager.kt`,接入 `PlayerController.kt:659-672` | `AudioCacheManager.ets`(预算 300 MB) | **零实现**:选源只看下载那一份(`PlayerController.swift:91,379` 附近) | 高(且这是 #161 那轮手机侧刚验完的能力,口径要照搬) |
| M9 | **封面图片磁盘缓存 + 设置页「清除缓存」这一格** | 复用 Coil 磁盘缓存,设置页两条口径分开(清除缓存 / 清除下载) | 自研 `ArtworkCache.ets`(20 MB) | **只靠 URLSession 默认 URLCache**(`UI/Theme.swift:134-135` 注释自己写了),无预算、无 LRU、不计入体积;`FeedCacheStore.swift:12-14` 的注释更是明说 `sizeBytes()` / `clear()` **「没有接进 macOS 设置页」** ⇒ 「清除缓存」这一格在桌面**整块缺失** | 中 |
| M10 | **读发布方提供的逐字稿**(RSS `transcript` 标签 / JSON·SRT·VTT) | `RssParser.kt:130-137,170-171,229` | `RssParser.ets:66-68` + `net/TranscriptFetcher.ets` | **解析层一条都没有**:`Data/RssParser.swift`、`Data/Models.swift` 里没有 transcript 字段。桌面只有本机 `SpeechAnalyzer`(`Data/Transcriber.swift`)⇒ 与鸿蒙那套「只读发布方稿、不做本机识别」的口径**在桌面上无从对齐**(Android 侧合并 flavor 后不再有这样一档,一份包两种都有 —— H205) | 中-高(三端取字口径见 `docs/TRANSCRIPT.md`;缓存 version 已有 `TranscriptStore.swift:10`) |
| M11 | **关于页 + 开源许可页 + 法定展示信息的出口** | `AboutScreen.kt` + `LicensesScreen.kt`(备案号在这里显示,资源键 `beian_number`)、同意页 `privacy_consent_*` 三串 | `AboutPage.ets` + `LicensesPage.ets`(同名键 `beian_number`,空值就不渲染整行),base 那份含 `privacy`/`备案` **10 处** | **两个视图都不存在**(`UI/` 下只有 13 个视图,`ls` 数过),而且**桌面端没有任何隐私/备案的对外文案**:38 个 `.swift`(314,475 B)里 `隐私/备案/privacy` 只命中 **2 处**,都在注释(`Data/Log.swift:110`、`Data/PodcastRepository.swift:30`,内容是"隐私政策承诺日志不记搜索词"的**引用**,不是给用户看的句子);4 份 `.strings`(共 35,541 B)里这三个词 **各 0**。**设置页连版本号都不显示** —— `CFBundleShortVersionString` 全仓只出现在导出日志那封邮件的正文里(`UI/SettingsView.swift:369`) | 中(**这是合规缺口,不只是"页面缺失"**:手机的三处出口 —— 首次同意页、关于页备案号、许可清单 —— 桌面一个都没有。备案号在 Mac 端要不要展示是**产品与法务口径问题,先问再写**(`AGENTS.md` 硬规矩 13:预写的是格式不是值) |
| M12 | **发现页分类排序** | `CategoryStore.kt` | `CategoryStore.ets`(#86 那轮从 Android 移植过来) | 无 CategoryStore,分类顺序固定 | 低 |

## 二、口径漂移(两端与 macOS **都有**,但数值/形态不同)

| # | 项 | 两端 | macOS | 要不要动 |
|---|---|---|---|---|
| D1 | 地区列表 | 12 项(`harmony/.../model/Genres.ets:109 REGIONS` 数过) | **已对齐(2026-10-25,代码侧)**:`UI/SettingsView.swift:32-36` 12 项,码与顺序同 `REGION_OPTIONS` / `REGIONS`(自动 cn hk tw us jp kr gb sg au ca de);四个新键(新加坡/澳大利亚/加拿大/德国)补进 4 套 `.lproj`(繁中按 Android 用「澳洲」),`plutil -lint` 四份全过、每份新键各 1 处 | 已完成(代码侧);⚠️ 下拉里 12 项没在屏幕上数过 |
| D2 | 字号 | 4 档离散 | **已对齐(2026-10-25,代码侧)**:界面**保留连续滑杆**(0.85–1.30、step 0.05,桌面上更合理),只在备份边界做换算 —— `Data/BackupManager.swift:34-49` 的 `[0.85,1.0,1.15,1.3]` 与 Android `FONT_SCALES` / 鸿蒙 `Theme.ets` 逐项相同、同一条「严格小于才换档」的取近规则;导出写 `fontScale` + `fontIndex` 两键(`:108`),恢复**倍率优先、缺失才退下标**(`:194`),越界下标夹到端点。12 条断言跑过,阳性对照(把 `<` 改 `<=`)⇒ 平局那条 exit 1 | 已完成(代码侧);⚠️ 没有用真备份做跨端往返 |
| D3 | 追更落盘条数 | 300(`InboxStore.ets:36 PERSIST_MAX`,装机实测 333,160 B) | **已对齐(2026-10-25,代码侧)**:`Data/InboxStore.swift:25 persistMax = 300`,并删掉 `maxCount = 100` / `perFeedCap = 12` 两道截断 —— **内存留全量、落盘只落排序后的前缀 300**(理由写在那一行:冷启动秒显 + JSON 体量),`loadAll` 也不再按源截断。排序与两端同一条 `sortedStable`(日期倒序、同值按 id 升序),日期解析结果按 id 缓存在 `keys`、比较器里不重复解析(硬规矩 6) | 已完成(代码侧) |
| D4 | 音阁段名 | 订阅 / 收藏 / 下载 / 待播 / 历史 / 批注 | **已对齐(2026-10-25,代码侧)**:同 M6,`UI/LibraryView.swift:9-17`(段的 `rawValue` 即显示名,`"最新"` 那个键随之删掉) | 已完成(代码侧) |
| D5 | 逐字稿取字方向 | 优先发布方稿,本机 ASR 兜底(Android 只有一份包,两个分发处都带引擎 —— H205) | **只有本机 ASR** | 跟 M10 一起解 |
| D6 | 日志分区四行的顺序 | 已定序 | **已对齐(2026-10-25,代码侧)**:`UI/SettingsView.swift:173-196` 改成 分享日志 → 发送日志到开发者邮箱 → 导出日志… → 清空日志,与 Android `SettingsScreen.kt:341-350`、鸿蒙 `SettingsPage.ets:257-261` 同序;体积那一行仍留在分区首行(它不是这四行之一) | 已完成(代码侧);⚠️ 一帧没跑 |
| D7 | **单集菜单里「标记为已播完」的给法** | 2026-10-17 起:**正向那颗在所有单集列表都不给**,只有 `音阁 · 历史` 的已播完行给反向「标记为未播完」(它是发现页「继续收听」横条唯一的回程)。落点:`Components.kt` 的 `onTogglePlayed` / `Components.ets` 的 `showPlayedToggle` 注释里那条规则 | **已对齐(2026-10-25,代码侧)**:`UI/Theme.swift:527-590` 不再按 `played` 换文案,改成两颗显式可选回调且**文案写死**。正向 `onMarkPlayed` 只剩发现页「继续收听」卡(`UI/DiscoverView.swift:140-146`,与 Android 那张卡自己的菜单同口径);反向 `onMarkUnplayed` 只在 `音阁 · 历史` 的**已播完**行(`UI/LibraryView.swift:272-279,303-306`)。频道页/追更/收藏/下载/搜索 5 个调用点两颗都不传。`Stores.swift:159` 的"没历史条目就 return"保持原样 —— 正是它让浏览列那颗变成空操作 | 已完成(代码侧);⚠️ 一帧没跑过,右键菜单没在任何列打开过 |

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
