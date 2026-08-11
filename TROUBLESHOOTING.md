# 余音 · Reverb 踩坑与性能优化记录

> 开发过程中遇到的 **bug** 与 **性能问题** 全量归档,含**现场 / 根因 / 解法 / 涉及文件 / 教训**。
> 供日后查阅与复盘,避免重复踩坑。

## 维护约定(重要)

- **何时更新**:每解决一个 bug 或性能问题,**提交前把它补进本文件**(和代码改动同一次提交)。
- **写什么**:
  - **现场**——可复现的表现(用户看到 / 触发条件)。
  - **根因**——真正的原因,而非表面症状。
  - **解法**——关键改动、涉及文件与行为;有取舍要写清。
  - **教训 / 规律**——可迁移到别处的经验(能写就写)。
- **分平台**:分 `通用`、`Android`、`macOS`、`鸿蒙` 四节。**日后再新增平台(如 iOS / Windows),照此追加一节**,并把跨端共性问题沉淀到「通用」。
- **编号**:每节内递增编号(G/A/M…),新问题**追加到对应小节末尾**,不复用旧号。
- **不虚构**:只记真实发生并已定位的问题;假 bug(误操作 / 环境问题)也值得记,但要标注清楚。

---

## 通用(跨端共性)

### G1. 列表无谓闪动:不稳定排序触发 diff 重排

- **现场**:「最新」列表每次刷新后条目上下跳动 / 闪烁,内容其实没变。
- **根因**:按 `pubDate` 排序,但**相同日期的条目相对次序不定**(unstable sort)。上层用「内容相等」去重驱动 UI(Kotlin `StateFlow` 的 `distinctUntilChanged`、SwiftUI 的列表 diff)。内容一样但**顺序抖动**,被判定为「变了」→ 重新发射 / 重排 → 肉眼可见的闪动。
- **解法**:排序追加**稳定次级键**(`id`),形成全序:
  - Android:`sortedWith(compareByDescending<Episode> { parsePubMillis(it.pubDate) }.thenBy { it.id })`(`InboxStore.kt`)
  - macOS:同理,主键日期、次键 id。
- **教训 / 规律**:凡是驱动 diff 的列表,排序必须是**确定的全序**。别让「看不见的次序抖动」变成「看得见的闪动」。

### G2. 收件箱刷新范式:原子替换 + 失败不清空

- **现场**:多源增量刷新时列表反复重排;某个源抓取失败会把**已有内容清空**成白屏。
- **根因**:逐源「边拉边发」导致中间态频繁变动;失败分支直接写入空列表。
- **解法**(Android / macOS 的 `InboxStore` 同一套思路):
  - 有缓存时**不逐源刷 UI**,全部合并完成后**一次原子替换**:`if (latest.isNotEmpty() || !hasCache) value = latest`。
  - **失败不写空**——保留旧内容,宁可陈旧也不白屏。
  - **冷启动(无缓存)才逐源刷**,让用户尽快看到第一批内容。
- **教训 / 规律**:异步聚合多个数据源时,把「过程」和「结果」分开——过程别频繁抖动 UI,结果一次性落定;失败是「保持现状」,不是「清空」。

### G3. 累计计数器 + 备份「合并」= 重复统计(设计缺陷)

- **现场**:新增「按频道累计收听时长」后,备份/恢复走的是全局「合并语义」。若把累计时长也按合并=**相加**处理:第一次跨设备恢复能正确把两台时长加起来,但**同一份备份重复恢复就会反复累加**,数字越滚越大。
- **根因**:**累计计数器天生不满足幂等**。`订阅/收藏/印记` 是集合(按 id 去重,合并幂等),`历史` 是按 `updatedAt` 取新者(幂等),但「累计时长」是个单调增长的标量——两个标量无论取和还是取新,都无法同时满足「跨设备要汇总」与「重复恢复不重复计」这两个要求。取和会重复计;取 max 又会把另一台**自己新听的内容丢掉**。
- **解法**:改为**按设备分账**(等价 **G-Counter CRDT**)。
  - 每个频道不再存一个总数,而存 `perDevice: {设备ID → 毫秒}`;设备ID 是首次生成后固定的安装标识(macOS 存 `UserDefaults["device_id"]`,Android 存 `reverb_settings` 的 `device_id`)。
  - **本机只累加自己名下那一格**;展示值 `listenedMs` = **各设备之和**。
  - 备份恢复的合并规则 = **按设备逐格取 max**(`ListenStatsStore.merge`),**绝不跨设备相加**。
  - 旧格式(扁平 `listenedMs`)兼容:本地文件迁移时归入本机名下;来自旧备份的扁平值归入稳定的伪设备键 `legacy:<频道键>`,避免与本机数相加出错。
- **为什么同时满足三条**:不同设备是不同的格子,故跨设备恢复**自然汇总**;同一设备的两个数值只是**同一个单调计数器的两次读数**,取 max = 取较新读数,既**不重复计**也**不丢数据**——某台自己新听的时长记在它自己的格子里,别人的备份里那格更旧,max 会保留本地较大值。
- **验证**(推演已跑通,六例全过):A=10h、B 全新 → 恢复得 15h(B 又听 5h 新内容)→ **重复恢复仍 15h** → A 再听 3h 后恢复得 18h → 反向恢复两机均 18h → 再双向重复恢复稳定不变。
- **教训 / 规律**:**要合并的数据,先问它是不是幂等的**。集合用「按 id 并集」、状态用「按时间戳取新」、**计数器必须按来源分账再求和(CRDT 思路)**——把一个全局标量拆成「每来源一格」,合并就从「危险的相加」变成「安全的逐格取 max」。同理适用于任何未来要跨设备同步的累计量(播放次数、下载流量等)。

### G4. 分账下的「历史估算种子」仍会跨设备翻倍

- **现场**:G3 的分账修好后仍有一个漏洞——首启用历史估算的种子若**记在本机格**:A、B 两台都从**同一份历史**(历史本身也在备份里、会被合并)各自种子 10h,互相恢复后按设备相加 = **20h**,而真实只有 10h。选择性恢复(只勾「历史」不勾「收听时长」)会稳定触发。
- **根因**:种子不是「本设备的独立贡献」,而是**对同一份共享数据的估算**。把估算记进"本设备"这一格,就被 G3 的「不同设备相加」规则当成了独立贡献。
- **解法**:种子改记到**所有设备共用的固定格** `seed`(macOS `ListenStatsStore.seedKey` / Android `SEED_KEY`),合并时对该格取 max ⇒ 取较大的估算值,不再翻倍;真实播放仍各记在自己设备格里,该加的照加。
- **验证**:修复前两机种子互相恢复 = 20h(✗);修复后 = 10h(✓);且「种子 10h + B 新听 5h + A 新听 3h = 18h」、重复恢复稳定 18h。
- **取舍**:两台设备在启用本功能**之前**听的是**完全不同**的旧内容时,取 max 会偏保守(少算)。宁可少算估算值,也不虚增。
- **教训 / 规律**:分账 CRDT 里,**"格子"的语义必须是"独立贡献源"**。任何"对共享数据的推算/估算"都该放进一个共享格并用 max 收敛,而不是伪装成某个设备的贡献。

---

## Android

### A1. 下拉刷新灰色圆圈常驻不消失 / 上滑后无法再下拉

- **现场**:「最新」tab 下拉刷新,灰色 loading 圆圈**不消失、常驻**在顶部;而且**先往上滑一下,就再也拉不动**。
- **根因**:
  1. 刷新容器最外层 `Box` **缺 `.clipToBounds()`**——静止态的 `PullToRefreshContainer` 指示器越界露在顶部(同项目「发现」页 `DiscoverScreen` 有这层裁剪,`InboxScreen` 漏了)。**这是圆圈常驻的根因。**
  2. 指示器结束依赖 `fetch.await()`,要等**整套多源刷新(~8s)全部完成**才 `endRefresh()`,期间圆圈一直转。
  3. 增量发布时列表 collapse 会**推动下拉偏移量**,导致上滑后手势状态错乱。
- **解法**(`ui/screens/InboxScreen.kt`、`data/local/InboxStore.kt`):
  - `Box` 加 `.clipToBounds()`(裁掉静止态越界露出的指示器)。
  - **刷新与指示器解耦**:`rememberCoroutineScope` 里 `launch` 后台刷新,**不等全量完成**;`delay(600)` 后立即 `pullState.endRefresh()` 收起圆圈。
  - 增量发布加 `hasCache` 守卫,有缓存就不再逐源 collapse。
- **教训 / 规律**:遇到「同一交互在别处正常、这里不对」,**优先照抄本项目已工作的实现**(这里就是「发现」页的下拉刷新),比从头调快得多。指示器的显隐**不该和数据加载时长强耦合**。

### A2. 「改了却连最新都没了」——debug/release 双包混淆(假 bug)

- **现场**:装上新 release 包后,「最新」列表空了,一度以为是回归 bug。
- **根因**:手机上**同时并存**旧的 `com.yuyin.reverb.debug`(debug 带 `.debug` 后缀)与 release `com.yuyin.reverb`——**它们是两个独立可安装的应用**。用户打开的是**旧的 debug 包**,自然看不到新改动。
- **解法**:确认「正在装 / 正在打开」的是同一个 `applicationId`;用 `adb` 明确重装 release 包并打开它。
- **教训 / 规律**:排障第一步先确认**「在测的就是刚构建的那个包」**。Android 的 `applicationId` 后缀(debug/release)会造成同机多个同名图标,极易张冠李戴。

> 备注:A1 之外,「最新」在覆盖安装后的「长时间 loading + 闪动」由 A1(指示器解耦)+ G1(稳定排序)共同解决,非独立问题。

---

## macOS

### 一、Bug

#### M1. 「最新」tab 每次切换都重载 + 条目跳动

- **现场**:每次切到「最新」分段都**重新加载**,列表条目上下跳。
- **根因**:切换即无条件重拉;叠加 G1 的不稳定排序。
- **解法**(`Data/InboxStore.swift`):加 `refreshIfStale` + `loadedSignature`(内容签名相同则不重新发射),避免切走切回反复重拉;配合 G1 稳定排序、G2 原子替换 / 不清空。

#### M2. 冷启动封面空白

- **现场**:冷启动时部分封面加载不出来,留白。
- **根因**:`AsyncImage` **偶发加载失败且不重试**(冷启动网络栈未热)。
- **解法**(`UI/Theme.swift`):自建 `RemoteImage`——走 `URLSession.shared` 的内存 / 磁盘缓存(重开即命中),失败按 **0.4s 退避重试至多 3 次**;`.task(id: url)` 换集时**先清空旧图**,避免残留上一集封面。
- **教训 / 规律**:系统 `AsyncImage` 没有重试策略,对弱网 / 冷启动不友好;需要稳态封面就自建带缓存+重试的加载器。

#### M3. 首次启动出现蓝色焦点环

- **现场**:首启时某控件被自动聚焦,出现一圈蓝色键盘焦点环。
- **根因**:macOS 默认给首个可聚焦控件加焦点环。
- **解法**(`UI/Theme.swift`):`.focusEffectDisabled()`(macOS 14+)封装为 `noFocusRing()`,按需施加。

#### M4. 睡眠唤醒后播放加载失败、静默卡死

- **现场**:合盖唤醒后点播放,加载失败且**无任何反馈**,一直卡住。
- **根因**:唤醒后网络栈短暂异常,`AVPlayerItem` 进入 `.failed` 状态却无处理,静默卡死。
- **解法**(`Playback/PlayerController.swift`):观察 `item.publisher(for: \.status)`,`.failed` 时**自动重试 3 次(退避 0.8s)**;仍失败给出**可见提示 + 手动「重试」按钮**。
- **教训 / 规律**:网络类加载一定要观察失败态并给用户出口,别让失败变成「转圈到天荒地老」。

#### M5. shownote 简介丢失换行、糊成一坨

- **现场**:播放页「简介」把所有换行 / 段落丢掉,连成一大段。
- **根因**:`Fmt.plainText` 把**所有 `\s+`(含 `\n`)collapse 成单个空格**,连段落结构一起抹平。
- **解法**(`UI/Theme.swift` 的 `Fmt.plainText`):**先**把 `<br>` 与块级标签(`p/div/li/ul/ol/h1-6/tr/blockquote/section`)转成 `\n`,**再**去其余标签;之后只压缩行内空白 `[ \t]+`、`" *\n *"→"\n"`、`\n{3,}→\n\n`,**保留换行结构**。
- **教训 / 规律**:清洗 HTML 文本时,「去标签」和「压空白」的**顺序**很关键——先把结构性标签转成换行,再压空白,别一上来 `\s+→空格` 把段落也吃掉。

#### M6. 播放页不出现「转录」页

- **现场**:播放页轮播里没有「转录」页。
- **根因**:`transcriptionEnabled` 设置项默认 `false`,用户没手动开。
- **解法**(`Data/Stores.swift` `SettingsStore`):默认值改为 `true`(init 读取 + didSet 落 UserDefaults 一并配好)。

#### M7. 中/英手动切换导致缓存失效、反复重转

- **现场**:转录页带「中文 / English」手动切换;**中→英→中**每次都重新下载语言模型、重跑转录,**完全没缓存**。
- **根因**:手动 toggle 改变 `localeId` → **改变缓存 key** → 每次都 miss;而一段音频通常**只有一种语言**,本就不该让用户手动切。
- **解法**(`UI/TranscriptPage.swift`、`Data/TranscriptStore.swift`):**去掉手动切换**,转录语言**固定按应用界面语言映射**(`zh-Hans→zh-CN` 等),缓存 key 稳定;每单集 × 每语言一份 JSON 缓存,命中**秒显**、不重转。
- **教训 / 规律**:缓存 key 要绑定**稳定、语义正确**的维度。别把「本不该由用户频繁改的东西」做成开关,既是坏设计也毁缓存。

#### M8. Swift 6 并发告警(NSLock / 捕获可变 buffer)

- **现场**:`TranscriptStore` 用 `NSLock` + 闭包捕获可变 buffer,触发 Swift 6 并发告警。
- **根因**:跨并发闭包共享可变状态。
- **解法**:`Transcriber` 改为 **`AsyncThrowingStream`**,在 **MainActor 上顺序消费**事件,天然无锁、顺序有保证,告警消失。
- **教训 / 规律**:Swift 6 下,与其用锁保护共享可变状态,不如用 `AsyncStream` + 单一 actor 顺序消费,把并发「串行化」掉。

#### M9. `onChange(of:initial:_:)` 在旧系统不可用

- **现场**:编译报新版 `onChange` 签名不可用。
- **根因**:该签名要求 macOS 14+。
- **解法**:用 `@available(macOS 14, *)` 门控 `TranscriptPage`(其容器本就从 14+ 实例化)。

#### M10. 新增 `@Published` 属性忘了在 `init` 初始化

- **现场**:编译错误——存储属性未初始化。
- **根因**:`SettingsStore` 加了 `transcriptionEnabled` 但 `init` 里漏了赋值。
- **解法**:`init` 补 `transcriptionEnabled = d.object(forKey: "transcription_enabled") as? Bool ?? true`。
- **教训 / 规律**:给非可选存储属性的 class 加成员,**别忘了 init 里配一行**;Swift 不会自动给非可选属性兜默认值。

#### M11. SourceKit 跨文件「Cannot find type」误报

- **现场**:编辑器 / 诊断持续报 `AppEnvironment` / `Episode` / `TranscribedSegment` 等**找不到类型**,跨文件飘红,但实际能编译。
- **根因**:SwiftPM 单 target 下 **SourceKit 索引的假阳性**(同 target 内跨文件类型解析偶发失效)。
- **解法**:**以 `swift build -c release` 为准**——只要 `Build complete!` 且 0 error / 0 warning,就是真没问题,忽略这类飘红。
- **教训 / 规律**:编辑器诊断 ≠ 编译结果。命令行构建才是唯一事实来源,别被 IDE 飘红带偏去「修」不存在的问题。

#### M12. 词级卡拉OK仍「一段一段」高亮

- **现场**:开启词级同步后,播放时高亮**还是整句一起亮**,没有逐字推进的打字机感。
- **根因**:
  1. 播放进度 `positionMs` 由 `AVPlayer` 的 periodic time observer **每 0.5s 才更新一次**(`PlayerController.swift:60`)——天然「半秒一跳」。
  2. 词级高亮**只作用于当前整句**;而**中文一句常是单个 run**(无空格分词),导致 `words` 为 `nil` 或整句是一坨,视觉上=整句高亮。
- **解法**(`UI/TranscriptPage.swift` 的 `KaraokeLine`):
  - 用 `TimelineView(.animation)` 在两次进度采样间**逐帧外推**平滑毫秒(`anchorMs + 已过时间 × 倍速`,**封顶到本句 `endMs`** 防抢跑)。
  - 预铺**「每字符时间线」**:有词级时间→按每个词的 `[start,end]` 线性分摊到词内字符;**无词级时间(老缓存 / 整句)→整句 `[start,end]` 均分到字符**——因此老缓存也能逐字亮。
  - **只有当前一行**逐帧刷新,其余行静态;暂停时按锚点静态显示。
- **取舍**:逐字节奏是**按时间线性推**,非逐音素对齐;整句均分时匀速铺字,语速起伏处会略快略慢,但整体跟随对。
- **教训 / 规律**:粗粒度的时间源(0.5s 采样)可以在客户端**逐帧外推**成平滑动画;缺细粒度数据(词级时间)时,用**线性插值兜底**也能得到连续观感。

### 二、性能

#### P1. 进入播放详情页卡 + 横滑卡:高频 TimelineView 常驻叠加

- **现场**:点进播放详情页明显卡顿,左右横滑也卡。
- **根因**:两个高频 `TimelineView` **同时常驻**——
  - `InkWave` 水墨波纹(`Canvas` + `.blur(radius:6)`,30fps;**blur 每帧强制离屏合成**,很贵);
  - `KaraokeLine` 当前句(60fps),而且**转录页在后台不可见时仍在空跑**;
  - 三页轮播常驻,**横滑时三页一起渲染**;
  - 剪藏 PNG(`ImageRenderer` 主线程同步)在 `.task` 里**阻塞开场动画**。
- **解法**(`UI/PlayerView.swift`、`UI/TranscriptPage.swift`):
  - **按当前页门控高频动画**:波纹仅在**第 0 页可见且播放时**流动(帧率 30→24fps);卡拉OK逐帧刷新仅在**转录页 `active` 且播放时**启用,否则静态显示。
  - 剪藏 PNG 渲染**延后 0.35s**,让开场 / 横滑动画先跑完再渲染。
- **教训 / 规律**:**不可见的动画必须停**;同一时刻尽量**只跑一个高频 `TimelineView`**;**动画层上叠 blur 极贵**(每帧离屏合成),能避则避、能降频则降频;主线程同步渲染(`ImageRenderer`)要延后,别挡首帧。

#### P2. 横滑仍卡 + 开场卡一两秒:shownote 长文本全量布局

- **现场**:P1 之后横滑仍有顿挫;点进详情页要**卡一两秒**才弹出。
- **根因**:
  1. `Fmt.plainText(ep.description)` 那串**正则写在 `body` 里,每次渲染都重跑**,横滑反复触发。
  2. `.fixedSize(horizontal:false, vertical:true)` 迫使**整段长简介一次性全量布局**(TextKit 同步排完所有行);分页 `LazyHStack` **预建相邻的简介页**时就触发这次全量排版 → 开场 1-2s 卡顿。
- **解法**(`UI/PlayerView.swift` 的 `showNotePage`):
  - 解析移到 `.task(id: ep.id)` **按集缓存**(`noteParagraphs`/`noteForEpisode`),不随横滑重跑正则。
  - 长文**按段落拆进 `LazyVStack`**,**只对可见段落布局**,去掉 `fixedSize`。
- **取舍**:跨段落的连续框选会**断在段边界**(段内正常),换来长文流畅滚动与秒开。
- **教训 / 规律**:**昂贵的纯计算(正则 / 解析)别放在 `body`**,移到 `.task`/`onChange` 按 key 缓存;**超长文本用 `Lazy` 容器分块**,避免 `fixedSize` 触发一次性全量布局。

---

## 鸿蒙(HarmonyOS NEXT / ArkTS)

> 环境:DevEco Studio 6.0.2、SDK HarmonyOS 6.0.2(API 22);真机 BRA-AL00 / HarmonyOS 6.1.0.135(API 24)。

### H1. hvigor 报「工程结构与配置需升级」

- **现场**:全新手写的工程,`hvigorw assembleHap` 直接失败:`00303024 The project structure and configuration need to be upgraded before use.`,提示用 DevEco 的迁移工具。
- **根因**:`ValidateUtil.modelVersionCheck()` 要求 **`modelVersion` 同时出现在 `hvigor/hvigor-config.json5` 与根 `oh-package.json5` 两处且完全相等**;缺任意一处即报此错(错误信息完全没提这点)。版本还必须落在 `[MINIMUM_MODEL_VERSION, CURRENT_MODEL_VERSION]`(本机为 5.0.0 ~ 6.0.2)。
- **解法**:两处都写 `"modelVersion": "6.0.2"`。
- **教训 / 规律**:遇到语义含糊的工具链报错,**直接去插件里搜错误码**(`hvigor-logger/res/error/*.json` 拿到符号名,再全局搜该符号名找到校验函数),比照文档猜快得多。

### H2. ArkTS 只编译「可达」文件,未引用的模块完全不参与类型检查

- **现场**:写完整个数据层(RSS 解析、四路取源、Repository、6 个 Store)后 `hvigorw assembleHap` **构建成功、0 错 0 警**——但这些文件当时还没被任何页面 import。
- **根因**:ArkTS 编译器从入口页面出发按依赖图编译,**未被引用的 .ets 根本不进编译单元**,自然也不做类型检查。于是"构建通过"是假的。
- **解法**:建立引用点(接入 `AppContainer` 并被 `Index.ets` import)后再构建;并用 `strings entry/build/default/intermediates/loader_out/default/ets/modules.abc | grep <符号>` **验证目标模块确实被编进字节码**。
- **教训 / 规律**:分层开发时别攒着一大堆未接入的文件——**每写完一层就接上引用点再构建**,否则错误会积压到最后集中爆发。

### H3. 页头压住状态栏(全屏布局下安全区避让失效)

- **现场**:M1 时页头正常;M3 把外层换成 `Navigation` 后,「发现」标题直接压在状态栏时间上。
- **根因**:`EntryAbility` 里设了 `setWindowLayoutFullScreen(true)`,内容延伸到状态栏下;原先靠内层 `Column` 的 `.expandSafeArea(...)` 生效,套上 `Navigation` 后该修饰符不再作用于最外层。
- **解法**:主动读避让区并作内边距——`window.getLastWindow()` → `getWindowAvoidArea(TYPE_SYSTEM / TYPE_NAVIGATION_INDICATOR)`,用 `UIContext.px2vp()` 换算后 `padding({top, bottom})`;tab 外壳与每个 `NavDestination` 都要加。实测 top≈32.9vp、bottom=28vp。
- **注意**:`getContext()` 已废弃,API 12+ 用 `this.getUIContext().getHostContext()`;`px2vp` 不要用 `.bind()`(会产生隐式 any,触发 `arkts-no-any-unknown`)。

### H4. 长时任务报 9800005「bgMode is invalid」,后台播放会被回收

- **现场**:播放正常,但 `backgroundTaskManager.startBackgroundRunning(...)` 持续失败:`9800005 Continuous Task verification failed. The bgMode is invalid.`,且因每 0.5s 同步一次状态而**刷屏重试**。
- **根因**:两点——(1) 必须在 `module.json5` 的 ability 里声明 `"backgroundModes": ["audioPlayback"]`(合法值见 SDK `toolchains/modulecheck/module.json` 的枚举),仅代码申请无效;(2) 用枚举版 `BackgroundMode.AUDIO_PLAYBACK` 与新版校验不匹配。
- **解法**:module.json5 补 `backgroundModes`,并改用**字符串模式版** `startBackgroundRunning(ctx, ['audioPlayback'], wantAgent)`;同时加 `bgFailed` 守卫,失败后不再每 tick 重试。
- **教训 / 规律**:鸿蒙的后台能力是「清单声明 + 运行时申请」双重门,少一半就失败。另外**任何放在 0.5s tick 链路上的失败分支都要加"只试一次"守卫**,否则日志与耗电一起失控。

### H5. 迷你播放条在全屏详情页消失

- **现场**:开始播放后回到频道详情页,底部迷你条不见了。
- **根因**:迷你条只挂在 tab 外壳里,而频道详情是覆盖其上的 `NavDestination`,外壳被整体遮住。
- **解法**:详情页的 `NavDestination` 内部也挂一份迷你条(与 Android「全屏详情页保留迷你条、隐藏 tab 栏」的设计一致)。

### H6. `@Builder` 的值参数是一次性的,状态变化后不重新求值

- **现场**:设置页切成「深色 · 水墨」,主题**确实即时生效**(整页变色),但「主题」那一行右侧显示的值仍是「跟随系统」。
- **根因**:`@Builder choiceRow(title, options, selected: number, ...)` 里 `selected` 是**按值传入**的参数;ArkUI 的 @Builder 值参数**不参与状态追踪**,组件重渲时不会重新求值,于是显示值定格在首次渲染。
- **解法**:改为传**闭包** `selectedOf: () => number`,在 builder 内部调用求值(闭包每次重渲都会重新执行)。
- **教训 / 规律**:ArkUI 里 `@Builder` 想拿到会变的值,要么**传闭包/按引用 `$$`**,要么在 builder 内部直接读状态——**不要按值传**。同类坑:`@Prop` 会更新(组件属性),`@Builder` 值参数不会,两者容易混淆。

### H7. 被重入拒绝的刷新把 loading 提前关掉

- **现场**:进音阁时「最新」聚合被触发两次,第二次被重入守卫拒绝,却把转圈标志置为 false——下拉刷新的圈提前消失,而真正的刷新还在跑。
- **根因**:loading 标志放在**页面**的本地状态里,由调用方设置;而"是否真的在刷"只有 store 自己知道。
- **解法**:让 store 自己持有 `refreshing` 标志(`InboxStore.refreshing`),UI 只读不写。
- **教训 / 规律**:**异步任务的进行态应由持有该任务的一方拥有**,调用方只订阅。与 Android 侧「指示器不该和数据加载时长强耦合」(A1)是同一个道理的另一面。
