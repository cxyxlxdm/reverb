# iOS 端

> 2026-11-02 新增的第四个原生端。分发方式:**TestFlight**(暂不上架 App Store)。
> 本页写「怎么在 iOS 上干活」;功能口径以 `docs/FEATURES.md` 为准。

---

## 为什么现在有 iOS(一条边界变更)

项目此前的记录是「只有三端,**没有 iOS 客户端也没有计划**」(2026-10-24 用户明确)。
2026-11-02 用户改了范围:做 iOS 版,先通过 TestFlight 给其他人装。那条旧边界到此作废,
`AGENTS.md`、`README.md`、`docs/FEATURES.md` 与 `docs/PRIVACY.md` 都已同步。

「上架 App Store」**不在这一轮**。TestFlight 本身仍是 Apple 的分发渠道,需要 Apple Developer
Program 会员与签名,但**不需要走 App Store 审核**(外部测试员另有一次 Beta App Review,见下)。

---

## 代码怎么复用

iOS 与 macOS 共用同一套数据与播放层,**不复制文件**:

| 复用方式 | 文件 |
|---|---|
| iOS target 直接编译(macOS 的源文件) | `macos/Sources/Reverb/Data/*.swift`、`macos/Sources/Reverb/Playback/PlayerController.swift`、`macos/Sources/Reverb/Playback/AudioCacheManager.swift` |
| iOS 自己的入口与界面 | `ios/Reverb/App/`(入口、依赖容器、根导航)、`ios/Reverb/UI/`(触屏页面) |
| 两端同形的资源 | `ios/Resources/`(种子清单、引导音频;规范副本在 `shared/`,由 `sync.sh` 分发) |

两端差异全部收在共享文件的 `#if os(iOS)` 里,不另起一份:

- `PlayerController`:**AVAudioSession**。`.playback` + `.spokenAudio` 让静音键拨下也出声,
  也是 Info.plist 里 `UIBackgroundModes=audio` 真正生效的前提;来电/闹钟打断时记住播放意图,
  系统说「可以恢复」才恢复。macOS 没有会话概念,这一整段只在 iOS 编译。
- `Transcriber` / `TranscriptStore`:`@available(iOS 26, *)` 与 `@available(macOS 26, *)`
  必须分开写。写成 `@available(macOS 26, *)` 时 iOS 侧会被理解成「任意版本都可用」,
  而 SpeechAnalyzer 其实要 iOS 26。
- 落盘文件与备份格式本来就是四端同一份(订阅/历史/下载/批注/播放态…都是同名 JSON)。
- `AppSupport.excludeFromBackup(_:)`:**只在 iOS 生效**(macOS 是空实现)。iCloud/电脑备份默认
  覆盖整个 Application Support,所以大块可再生数据要逐项打排除标记 —— 音频下载目录、
  音频缓存及其账本、封面、逐字稿、榜单缓存、播放态快照与日志;备份里只留清单与元数据。
  新增落盘目录时**也要加这一句**,否则它会悄悄进入用户的 iCloud 备份。

**改了共享的 `Data/` 或 `Playback/`,两端都要过编译门**:
macOS 用 `swift build -c release`(或 typecheck 差分),iOS 用 `ios/build-ios.sh`。
只验一头等于没验另一头。

---

## 工程结构

- 工程:`ios/Reverb.xcodeproj`;scheme `Reverb`;bundle id `com.yuyin.reverb`;最低 iOS 17.0。
- `ios/Reverb/**` 用 Xcode 的 **synchronized root group**(objectVersion 77):
  新增界面文件直接丢进目录即可,**不用手改 pbxproj**。
- 共享源文件是**显式** `PBXFileReference`,指向 `../macos/Sources/...`:
  新增共享文件要同时加进 macOS target 与 iOS target。
- 本地化:`ios/Localization/{en,es,fr,zh-Hant}.lproj`,**简中是基础语言**
  (代码里的键名就是简体中文原文),所以只有 4 套 —— 与 macOS 同形。
  新增文案 = 改代码默认串 + 4 个 `.strings`,加起来才是五个语种。
  ⚠️ **这是独立于 `macos/Localization` 的第二份副本**(pbxproj 路径相对 group 基准 `ios/`);
  改桌面那份不会进 iOS 包,两份要一起改。2026-11-04 两份已合并过一次,机制与踩坑见 H246。
  权限弹窗的说明文字不在这里,而是每套 `.lproj` 里的 **`InfoPlist.strings`**
  (键 `NSPhotoLibraryAddUsageDescription` / `NSSpeechRecognitionUsageDescription`);
  它是显式引用 + `PBXVariantGroup`,**新加 `.lproj` 文件不会自动进包** —— 光写文件不改 pbxproj 是静默无效。
  `build-ios.sh` 的验收段现在要求 4 套里都有这份且两个键都非空。
- `Info.plist`:后台音频、后台刷新任务标识、出口合规声明、竖屏(iPhone)/四向(iPad)、
  离线语音识别与相册(仅添加)用途说明(简中基准;其余语种走 `InfoPlist.strings`)。
  局域网同步另需 `NSLocalNetworkUsageDescription` 与 `NSBonjourServices`(`_reverb._tcp`);
  首次打开该页面时由系统询问本地网络权限,**拒绝后该功能不可用**(包括手动输入地址)。
  GUID 与版本号由工程设置注入,不要手改。

---

## 这一版有什么 / 没有什么

**有**:五格(发现 / 电台 / 追更 / 音阁 / 设置)、频道详情与订阅、播放页、后台播放 + 锁屏遥控、
**直播电台**(自建电台账本 + `radio-browser.info` 目录检索 + 随包精选)与 **AirPlay 投播**(系统 `AVRoutePickerView`)、
**主屏「继续收听」小组件**(WidgetKit,见下一节)、**锁屏 / 灵动岛的实时活动**(Live Activity,见再下一节)、
倍速 / 快进快退 / 睡眠定时 / 播放模式 / 自动续播、单集下载、逐字稿(iOS 26 本机离线转写 + 发布方逐字稿)、
节目笔记、听觉印记、收听统计、B 站视频与直播流、收藏/历史/待播/批注、备份与 OPML、隐私同意门、
主题与语言(5 语种)。

**没有**:

- **应用内更新** —— App Store/TestFlight 自己管;其余各端那种「查 GitHub Releases」在这里没有意义。
- **桌面式三格外壳** —— iOS 用系统 TabView(触屏 + 安全区)。

---

## 主屏小组件(WidgetKit)

- **target**:`ReverbWidget`(`.appex`,嵌入 App 的 `PlugIns/`)。`ios/ReverbWidget/Info.plist` 的
  `NSExtensionPointIdentifier = com.apple.widgetkit-extension`;三档尺寸 `.systemSmall/.systemMedium/.systemLarge`。
- **状态契约只有一份**:`../macos/Sources/WidgetContract/WidgetState.swift`,iOS 两个 target 与 macOS 的 SwiftPM target 编译同一文件
  (改字段要四端一起想;`public init()` 必须写在类型体里,见 H252)。
- **共享数据用 App Group `group.com.yuyin.reverb`**:App 侧 `Reverb/App/WidgetBridge.swift` 写 `widget_state.json` + 压缩后的封面,
  扩展只读。两份 entitlements(`ios/Reverb.entitlements`、`ios/ReverbWidget/ReverbWidget.entitlements`)都已接入工程。
  写盘节奏与另三端一致:播放中约 5 秒一次,一次性事件延迟 0.7 秒(等历史那条去抖写落盘),
  内容与上次逐字节相同就跳过;`percent` 是一位小数(0.1% 步进),另有 `playing` 供按键翻面。
- **卡片上的播放控制**:三档尺寸都带 上一集 / 播放暂停 / 下一集(iOS 17 起)。小卡把播放键压在封面上,
  中卡控制行靠左,大卡控制行居中。按钮用 `ReverbWidgetControlIntent`(`AudioPlaybackIntent`,
  与 macOS 共用 `macos/Sources/WidgetContract/WidgetControlIntent.swift`),动作经
  `WidgetCommandCenter.handler` 交回 App 执行 —— **不打开界面**;未同意隐私时直接丢弃。
  新文件同时编进 App 与扩展两个 target(pbxproj 显式引用,漏一处会编不过或运行时不响应)。
- ⚠️ **App Group 在真机签名上要付费 Apple Developer Program 的 profile**;模拟器不校验这项 entitlement。
  2026-11-09 在 iPad Pro 13-inch (M5) 模拟器上实测(adhoc 安装、`TeamIdentifier=not set`):
  `simctl listapps` 能看到 `group.com.yuyin.reverb` 的容器映射,App 真的写出了
  `widget_state.json`(211 B,内容含 `余音使用引导 / 0:00 / 0:32`、`empty:false`)。
  **免费 Personal Team 装真机 / TestFlight 时预计拿不到这项能力(未实测签名结果)**;
  代码里缺容器时只记一行 `[Widget] 没有 App Group 容器,卡片只能显示空态(免费团队签名没有这项能力)`,
  卡片退回空态、App 照常可用。
- **点击**:卡片 `.widgetURL(reverb://player?id=<episodeId>)`。App 侧的 `.onOpenURL` 挂在**同意门外面**
  (`ReverbApp` 的外层视图),收到的 URL 先进 `DeepLinkInbox`;`RootView` 就绪后再取走并装载成暂停态、
  开播放页。**不能只挂在 `RootView` 上** —— 首次启动未同意时它不存在,卡片那一次会被丢掉(macOS 上
  实际踩过,见 H249)。
  注意用 `simctl openurl` 验时,iOS 会弹系统确认「在"余音"中打开?」—— 那是跨 App 打开的统一提示,**卡片点击不弹**,
  但也意味着这一步的自动化需要有人在模拟器上点一下。
- **编译门已覆盖扩展**:`build-ios.sh` 现在断言 `PlugIns/ReverbWidget.appex` 存在、扩展点正确、版本/构建号与主包一致、
  4 套 `.lproj` 都能 lint 且含画廊文案(见脚本 `5b` 段)。

**验收状态(2026-11-12)**:编译门 exit 0;模拟器(iPhone 17 / iOS 27.2)App Group 容器与
`widget_state.json` 真实落盘。2026-11-12 用一条 25.1% 的历史夹具实测,文件内容为
`percent:25.1` / `time:"4:11 / 16:41"` / `playing:false`,封面副本 `widget_art.jpg` 70,520 B;
空态文件里没有 `label` 字段(契约已删)。Mac 13 上 `swift build --product ReverbWidget` exit 0。
**没验过**:主屏上把卡片加出来看渲染与按控制键(本机没有 Simulator 图形界面,加卡片需要人点一下);
点卡片后播放页是否弹出(`simctl openurl` 会弹系统确认框,需要人点一下);
真机 / TestFlight 的 App Group 受付费会员限制,签名结果未实测。

---

## 锁屏 / 灵动岛实时活动(Live Activity,1.0.8)

- **只在这台设备真的在播时起**;暂停保留 15 分钟(`staleDate`),换集先撤旧再起新,
  没有当前集就撤下。**同一时刻只允许一条**,避免锁屏叠两张。
- **契约在共享层**:`../macos/Sources/WidgetContract/PlaybackActivity.swift`(`PlaybackActivityAttributes`
  + `LiveActivityIntent` 控制意图),App 与扩展编译同一份(与小组件同一种做法)。
- **扩展 UI**:`ios/ReverbWidget/PlaybackLiveActivity.swift`,锁屏行 + 灵动岛三形态
  (compactLeading 波形 / compactTrailing 倒计时进度圈 / minimal)。控制键(播放暂停、上一集、下一集)
  走 `LiveActivityIntent`,由 `WidgetCommandCenter` 交回 App,不打开界面。
- **进度用绝对时间锚点外推**:`ProgressView(timerInterval:)` / `Text(timerInterval:)` 按
  `anchor - position/rate` 算区间,App 被挂起时系统自己走;**稳态播放 0 次 update**,
  只有暂停 / 续播 / 拖动 / 换集 / 换主题才写一次。⚠️ 判「是不是用户拖了进度」时
  **`positionMs` 是毫秒、`dt` 是秒**,外推要乘 1000 —— 少了它不会崩,只会让每 5 秒那拍
  都被判成 seek(2026-11-15 实测过,见 H283)。
- **不依赖 App Group**:主屏卡片读组容器,锁屏 / 灵动岛不走。`WidgetBridge.flush()` 里
  `PlaybackLiveActivityBridge.sync` 必须在「容器存在吗」那道判据**之前**调用 ——
  免费团队签名拿不到组容器时,卡片退空态,锁屏/灵动岛仍应工作(顺序写反过一次,
  见 H283)。
- **`ios/Info.plist` 必须有 `NSSupportsLiveActivities=true`**。缺这个键时 `Activity.request`
  不抛错、活动就是不出现;`build-ios.sh` 的编译门已断言这一项(第 2b 条)。
- **验收状态(2026-11-15)**:编译门 exit 0(8 条判据全过);模拟器(iPhone 17 / iOS 27.2,
  adhoc、无 App Group)实跑:日志 `[LiveActivity] 已开始`;SpringBoard 注册了活动
  (`ActivityID`, platter target `com.yuyin.reverb`);chronod 拉起扩展进程,渲染器对
  `listItem`(锁屏)、`dynamicIsland-compactLeading / compactMinimal / expanded` 三形态都报 `LIVE`,
  expanded 视图边界 374 × 99.3;稳态播放 25 秒内 `Activity did update` = **0 次**;
  播放结束来一拍(带 `staleDate`);换集时「已结束:换集」+「已开始」各一条。
  **没验过**:锁屏/灵动岛的实际观感(本机没有 Simulator 图形界面,`simctl io screenshot`
  不合成 SystemAperture 那层),按钮点按(需要人点),真机(签名被 `No Accounts` 挡住,见「本机现状」)。

---

## 版本号

| 位置 | 字段 | 当前 |
|---|---|---|
| `ios/Reverb.xcodeproj/project.pbxproj` | `MARKETING_VERSION` | 1.0.8 |
| 同上 | `CURRENT_PROJECT_VERSION` | 2 |

**TestFlight 每上传一次,构建号必须比上一次大**(版本名可以不变,同号会被拒)。
改工程里的 `CURRENT_PROJECT_VERSION`,或只对这一轮覆盖:

```bash
BUILD_NUMBER=2 DEVELOPMENT_TEAM=XXXXXXXXXX ./build-ios.sh --upload
```

版本名要跟其余各端节奏走时,Android / 鸿蒙 / macOS 三处之外**再改这一处**(共四处手改);
`ios/Info.plist` 里是 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`,不要写死。

---

## 构建与验收

### 1. 编译门(本机可跑,不需要任何证书)

```bash
cd ios && ./build-ios.sh
```

它先 `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`,再对产物当场断言(硬规矩 1):

| 判据 | 期望 |
|---|---|
| 版本 / 构建号 | 与工程设置一致(不从 Info.plist 反推) |
| 最低系统 | 17.0 |
| `UIBackgroundModes` | 含 `audio` |
| `CFBundleLocalizations` | **集合相等**:zh-Hans + 4 个 `.lproj` |
| 4 套 `.strings` | 非空且 `plutil -lint` 过 |
| `seed_podcasts.json` / `guide_intro.m4a` | 都在且非空 |
| 应用图标 | `AppIcon60x60@2x.png` 已编译进包 |
| 二进制架构 | 含 arm64、**不含 x86_64**(设备包) |

产物在 `ios/build/`(不入库),脚本会打印处理量(文件数 / KB)。

### 2. 归档 / 导出 / 上传(需要签名)

```bash
cd ios
DEVELOPMENT_TEAM=XXXXXXXXXX ./build-ios.sh --archive   # → build/Reverb.xcarchive
DEVELOPMENT_TEAM=XXXXXXXXXX ./build-ios.sh --export    # → dist/reverb-ios-1.0.8-2.ipa
BUILD_NUMBER=3 DEVELOPMENT_TEAM=XXXXXXXXXX \
  ASC_KEY_ID=... ASC_ISSUER_ID=... ./build-ios.sh --upload
```

- **签名材料只读**:Team 从环境变量传入,不写进工程文件;脚本不碰任何证书/口令。
- 上传凭据二选一:
  1. **App Store Connect API Key**:`ASC_KEY_ID` + `ASC_ISSUER_ID`,
     私钥 `AuthKey_<KEY_ID>.p8` 放到 altool 会找的位置
     (`./private_keys/`、`~/private_keys/`、`~/.appstoreconnect/private_keys/`)。
  2. **Apple ID**:`ASC_USERNAME` + `ASC_PASSWORD`(**专用密码**,不是账号密码)。
- 导出用 `method=app-store-connect`(Xcode 26+ 的名字;更老的 Xcode 叫 `app-store`)。
- 上传前先 `altool --validate-app`,过了才 `--upload-app`。
- 发布物落 `ios/dist/reverb-ios-<版本>-<构建号>.ipa`,文件名纯 ASCII
  (GitHub 会删掉非 ASCII 资产名,见 H230);`dist/` 不入库。

---

## TestFlight 前置条件与流程

这些是**账号侧**的事,代码再对也绕不过去:

1. **Apple Developer Program** 会员(个人或公司,年费;免费 Apple ID 不能传 TestFlight)。
2. **App Store Connect 里建 App 记录**:bundle id 必须是 `com.yuyin.reverb`
   (与工程一致;如果这个 id 已经在别处注册过,就别重复建,直接用那条记录)。
3. **Xcode 登录同一账号**(Settings → Accounts),或提供上节的 API Key;
   自动签名要能拿到开发/分发描述文件。
4. `--upload` 成功后,到 **App Store Connect → TestFlight** 等处理(通常几分钟到半小时)。
5. **内部测试员**:同一 App Store Connect 团队、最多 100 人,**不需要审核**,处理完即可装。
6. **外部测试员**:第一次**必须过一次 Beta App Review**(通常 1–2 天);
   之后同一 App 的后续构建一般不再逐版审。最多 10 000 人,可用公开链接。
7. 每个构建 **90 天后过期**;过期前要重新上传。
8. 首次测试需要填 TestFlight 测试信息(测试重点、联系邮箱)与**隐私政策 URL**
   —— 本项目的地址是 `https://cxyxl.cn/reverb/privacy.html`,必须公网可达。
9. **出口合规**:`Info.plist` 已声明 `ITSAppUsesNonExemptEncryption=false`
   (只用系统 HTTPS,不含自定义加密),上传时不再逐次询问。
10. iOS 26 的离线转写要 `NSSpeechRecognitionUsageDescription`(已写)。
    TestFlight 包同样会读这条;用户拒绝只影响逐字稿,不影响播放。

### 3. 模拟器验收(2026-11-02 实测通过)

Xcode 27 不再带 `Simulator.app`(只有 `DeviceHub.app`),命令行也没有点击注入,
所以 Debug 版留了几个**仅 Debug 编译**的启动参数:`-autoplay-guide`(播放内置引导音频)、
`-start-tab <discover|inbox|library|settings>`、`-open-player`、`-search <关键词>`(发现页启动即搜索,
中文关键词没法用 `simctl`/`adb` 注入,这条是 H241 的验收入口)、`-play-live <流地址>`(2026-11-09 新增:
直播流要「点一下结果行」才开播,这里直接走 `LiveStream.resolve` → `playQueue`,验播放页的直播态)。
Release / TestFlight 包里没有这段。

```bash
cd ios
xcrun simctl boot "iPhone 17"                       # 已装的 iOS 27.2 运行时
xcodebuild -project Reverb.xcodeproj -scheme Reverb -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/SimDerived CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted build/SimDerived/Build/Products/Debug-iphonesimulator/Reverb.app
# 免点击过隐私门(等价于点「同意并继续」)。**要写当前 privacyVersion**,1.0.8 开发中是 6;
# 走 cfprefsd,和直接改 plist 不是一回事(见本节末尾那条警告)。
xcrun simctl spawn booted defaults write com.yuyin.reverb privacy_version -int 6
xcrun simctl launch booted com.yuyin.reverb -autoplay-guide -open-player
xcrun simctl io booted screenshot /tmp/ios-player.png
# 退后台:改成前台打开「设置」,再看日志里的音频队列仍在推进
xcrun simctl launch booted com.apple.Preferences
xcrun simctl spawn booted log show --last 12s --style compact \
  --predicate 'process == "Reverb" AND eventMessage CONTAINS "enqueueing"'
```

实跑读数:首启隐私门正常;同意后首页能拉到榜单与封面;播放页 0:03/0:32、暂停键为播放态;
切到「设置」App 后音频队列继续入队(`howFarAhead` 前进),锁屏信息由
`MPNowPlayingInfoCenter` 持续更新。2026-11-04 补测 B 站搜索相关度过滤:`-search 学习资料`
启动后日志为 `[Bilibili] search count=6 dropped_irrelevant=11`(规则与逐条读数见 H241)。
**2026-11-04 再跑一轮(功能对齐后)**:向模拟器容器的 `Application Support/Reverb/subscriptions.json`
写入 4 档种子订阅后,追更页能拉到真实单集(封面 / 标题 / 频道 / 日期 / 时长 / 播放钮)、
音阁「订阅」列表与播放页动作行均正常;设置页「字号 / 听觉足迹 / 仅在 Wi-Fi 下载 / 订阅更新提醒」
四行渲染正常(修掉了两处 tint 视觉问题,见 H242、H243)。

**2026-11-09 1.0.7 补验(同一台 iPhone 17 模拟器)**:

- **B 站标题强相关过滤**:`-search 学习资料` → `[Bilibili] search count=7 dropped_irrelevant=10`
  (与鸿蒙同一天、同关键词的读数一致;规则见 H241)。界面「节目 · 来自 Apple」正常,关键词留在搜索框。
- **直播流 A 档**:`-search <流地址>` 出「直播流」结果行(title 取 `icy-name`,没有则退回主机名,
  标签写「直播」);用新增的 `-play-live <流地址>` 走与用户粘贴**完全相同**的
  `LiveStream.resolve` → `playQueue`,播放页读数为:红点「直播中」、**无进度条**、**无倍速菜单**、
  上一集/下一集置灰。数据侧:`history.json` 仍为 1 条、前后未变,且不含 `live:` 前缀;
  `playback_state.json` 不存在(直播那一路 `save(current: nil…)` 直接走 `clear()`)⇒
  「不记历史 / 不落播放态」两条闸都生效。
- **阴性对照**:`-search https://www.example.com/` → `[Live] 不是直播流 code=206 type=text/html`,
  界面是「没有找到」而不是直播结果。
- ⚠️ **这一轮模拟器的媒体层放不出声,别把它算成直播链路的问题**:同一次会话里连内置引导音频
  (`-autoplay-guide` → `file://…/guide_intro.m4a`)都 `AVPlayerItem failed`:
  `AVFoundationErrorDomain -11800`,底层 `NSOSStatusErrorDomain -12746`;
  CNR HLS / 蜻蜓 MP3 / FIP MP3 三路报同一个码。非直播播放页(引导音频)同时有 0:00/0:32 进度条、
  30 秒按钮与 1× 倍速 ⇒ **两套布局按 `isLive` 正确分叉,但「能出声」仍只有真机可证**。

**没验过的**:订阅刷新(定时)、逐字稿(需 iOS 26 语音模型)、
下载、备份导出、后台巡检与本地通知、相册保存、邮件草稿,以及所有**需要点击**的入口
(朋友圈海报、双击回顶、继续收听卡片)—— 模拟器没有注入手段,WDA 在真机上也没装上。
401 弹框 2026-11-10 已用「本地 Basic 认证源 + `-search <url>`」在模拟器验到,见下面这一段。

**2026-11-10 1.0.7 模拟器补验(收尾;仍是同一台 iPhone 17 / iOS 27.2)**:

- **B 站过滤的正样本与来源角标**:`-search 罗翔说刑法` → `[Bilibili] search count=17 dropped_irrelevant=2`,
  命中 17 条全是视频,界面「单集」逐行带「B 站」角标与频道名;`学习资料` 那轮为
  `count=8 dropped_irrelevant=9`(读数随对方搜索结果浮动,判据是 `dropped_irrelevant` 非 0 + 行内角标)。
- **新增 `-search-episodes`(仅 Debug)**:单集行在搜索结果首屏之下,模拟器没有触摸注入滚不到;
  这条参数让搜索完成后自动 `scrollTo` 到「单集」那一节。没有它截不到上面那两张图;Release 包里不存在。
- **私有订阅源 401**:起一个本机 `127.0.0.1:8765` 的 Basic 认证源(无凭据回 401 + `WWW-Authenticate`)。
  `-search http://127.0.0.1:8765/feed.xml` → 弹出 `FeedAuthSheet`(「需要用户名和密码」/ 取消 / 保存并重试,
  正文写明凭据只留本机、不进备份、不随订阅导出)。
  这一轮**抓出一个真 bug**:修复前同一操作只得到「没有找到」—— iOS 的直播探针那一支提前 `return`,
  把 RSS / 视频链接两条路一起吞了(见 H256)。修复后读数为 `[Repo] search` → `feed 需要认证 failed=false`。
- **凭据留存**:带内联凭据的地址 `-search http://reverb:secret@127.0.0.1:8765/feed.xml` →
  `[RSS] fetch "私有源验收" → 1 单集`、`[FeedAuth] save`,界面「节目 · 来自 RSS」;**重启后**不带凭据再搜同一地址,
  启动日志 `[FeedAuth] 装载 1 条源凭据`、`[RSS] fetch` 直接成功(服务端记录一次 401 后 200)⇒ 跨启动留存。
  弹框里的「保存并重试」要打字,模拟器没有键盘注入,**这一半靠内联凭据 + 重启来证**。
- **直播流入口(搜索框那条路)**:`-search http://ngcdn001.cnr.cn/live/zgzs/index.m3u8` →
  `[Live] 直播流确认 type=application/vnd.apple.mpegurl hls=true`,界面「直播流」段一条结果 +
  「不记录播放进度,也不能快进或回看」。截图里还抓到一个视觉 bug:这一行同时传了来源标签与 `isLive` 角标,
  并排出两颗一模一样的「直播」,已改成只留后者。
- 媒体层仍放不出声(同 11-09 那一条,`-11800 / -12746`),所以**「出声」与「点结果行开播」只有真机能证**;
  本轮改完已重跑 `./build-ios.sh` 编译门 exit 0,七条判据全过(Release 不受 Debug 钩子影响)。

iOS 备份排除项也可以在模拟器数据容器里直接验:

```bash
C=$(xcrun simctl get_app_container booted com.yuyin.reverb data)
xattr -p com.apple.metadata:com_apple_backup_excludeItem \
  "$C/Library/Application Support/Reverb/popular_cn_default.json"  # → com.apple.MobileBackup
```

### 4. 真机验收(2026-11-02 深夜实测)

真机的点击注入仍然缺(WDA Runner 装机三次都是 `host_command_failed`),所以**逐页取证靠同一组
Debug 启动参数**;唯一需要人手的一步是首启隐私门的「同意并继续」(点一次,之后本机记住)。

```bash
# 1) 先用同一份源码出 Debug 包(签名团队走命令行,不写进工程)
cd ios
xcodebuild -project Reverb.xcodeproj -scheme Reverb -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/ios-debug-dd -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=J4YCBW8ZG7 build
xcrun devicectl device install app --device <UDID> \
  /tmp/ios-debug-dd/Build/Products/Debug-iphoneos/Reverb.app
# 2) 逐页截图(-start-tab / -open-player / -autoplay-guide 只在 Debug 编译)
xcrun devicectl device process launch --device <UDID> --terminate-existing \
  com.yuyin.reverb -- -start-tab inbox
xcrun devicectl device capture screenshot --device <UDID> --destination /tmp/inbox.png
# 3) 后台播放:前台切到「设置」→ 等 14 秒 → 把 Reverb 拉回前台,看进度是否前进、PID 是否不变
xcrun devicectl device process launch --device <UDID> com.apple.Preferences
xcrun devicectl device process launch --device <UDID> com.yuyin.reverb
# 4) 验完把 Release 包装回去(用户日常用的是它)
xcodebuild … -configuration Release … && xcrun devicectl device install app …
```

实测读数(iPhone 16 Pro / iOS 27.2):四个 tab 的标题都在工具栏一行(发现/追更/音阁各有
右侧图标,设置页无图标);首页能从网络拉到「每日热门」与封面;播放页 0:04/0:32 为播放态;
切后台 14 秒后回到前台进度走到 0:31、PID 不变 ⇒ **后台音频在真机上仍推进**;迷你播放条正常。

**2026-11-04 真机复跑(功能对齐那一轮之后,同一台机器)**:

- 启动先报 `FBSOpenApplicationErrorDomain error 3` +「无法验证 App…需要互联网连接」。
  手机当时不在网;恢复网络后**仍然拒**,证书有效期、描述文件、开发者模式逐条查过都没问题,
  最后是**信任记录**丢了 —— 到「设置 → 通用 → VPN与设备管理」里重新信任才起来。
  所以这条报错**不要先按"重新签名"处理**,按 网络 → 信任 → 描述文件 的顺序排。
- 四个 tab、设置页(外观 / 内容 / 播放三段 + 日志 / 关于)、追更与音阁空态、
  播放页(含离线下载胶囊)逐屏看过;切英文(`-AppleLanguages '(en)'`)后新文案与
  **权限弹窗说明**(`InfoPlist.strings`)都是英文,没有再回落成简中。
- 后台音频复测:前台切到「设置」再拉回,进度 0:03 → 0:22,PID 不变。
- 冷启动恢复成暂停态时发现播放页总时长 `0:00`、滑杆满格,已修并在真机复验为 `0:11 / 26:23`
  (根因与判据见 `docs/TROUBLESHOOTING.md` **H247**)。
- 应用日志 `Library/Application Support/Reverb/Logs/reverb.log` 当天 68923 B / 797 行,
  按 `grep -c ' [EW] '` **0 命中**(扫之前先打印了量,见硬规矩 1)。
- 限制:本机数据容器里 `订阅=0 历史=3`,所以追更列表只能看空态。
- **2026-11-08 补验多选**:音阁 → 历史 → 长按单集进多选,勾两条后浮条读数为「已选 2」,
  两条标题转强调色、封面角标打勾,第三条保持未选;浮条的 全选 / 加入待播 / 退出 三钮都在,
  底部浮条停在标签栏之上不互相遮挡。

**2026-11-09 1.0.7 取证(同一台机器;WDA 仍未装上)**:

- 机上装的是分支包 `com.yuyin.reverb 1.0.7 (1)`(`devicectl device info apps` 可读);
  `devicectl device capture screenshot` 能出 1206×2622 的 PNG ⇒ **WDA 不可用也能做静态取证**。
  当晚 23:08 的截图里发现页已是 1.0.7 的悬浮四格栏 + 圆角搜索框。
- 应用日志也不依赖界面:
  ```bash
  xcrun devicectl device info files --device <UDID> --domain-type appDataContainer \
    --domain-identifier com.yuyin.reverb --subdirectory "Library/Application Support/Reverb/Logs"
  xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
    --domain-identifier com.yuyin.reverb \
    --source "Library/Application Support/Reverb/Logs/reverb.log" --destination /tmp/ios_reverb.log
  ```
  当晚拉到 96 242 B(最后一条 22:46):`refreshPopular region=cn → 27 频道`、
  `Artwork cached …` 都在,说明应用此前确实在这台机器上跑过。
- **23:20 重新拉起被拒**:`devicectl … process launch --terminate-existing com.yuyin.reverb
  -- -start-tab settings` 返回 `FBSOpenApplicationErrorDomain error 3` +
  「invalid code signature, inadequate entitlements or its profile has not been explicitly trusted」。
  当时手机已自动锁屏(`lockState passcodeRequired=true`)。按 11-04 那条顺序排:
  **网络 → 信任记录 → 描述文件**;免费 Personal Team 的描述文件只有 7 天(11-02 首次安装),
  这次也可能是到期。重新签装要人先解锁,再走
  `xcodebuild … Debug … -allowProvisioningUpdates DEVELOPMENT_TEAM=J4YCBW8ZG7 build`
  → `devicectl device install app …`。
- WDA runner 仍不可用:最近一次 `ios_install_runner`(`retry_reason=facts_rechecked`)仍为
  `host_command_failed`、`installed=false`。所以 401 弹框、海报生成、双击回顶、追更自动回顶、
  卡片点开这些**需要点击的项,真机上仍未验**;直播流的 UI 当晚已在模拟器补上(结果行 +
  播放页直播态 + 不记历史,见 §3),但**出声**仍要等真机解锁后再验。

⚠️ **两个「看起来应该能自动」但实际不行的通道**,别重试:
① 直接往应用容器的 `Library/Preferences/com.yuyin.reverb.plist` 写 `privacy_version`
**会被 cfprefsd 缓存挡住**(文件读出来是新值,界面仍停在同意页);
② `devicectl … launch -- -privacy_version 4` 也不足以过门(参数域对 `as? Int` 的取值不可靠)。
所以首启那一下必须人点一次 —— 点过之后不再需要。
**模拟器另有一条能走通的**:`xcrun simctl spawn booted defaults write com.yuyin.reverb
privacy_version -int <当前版本>` 走的是 cfprefsd,2026-11-09 实测可用(当时版本 5);
上面 ① 的问题是「写文件」而不是 defaultsd,两者别混为一谈。

---

## 本机现状(2026-11-24,历史读数保留日期)

| 项 | 状态 |
|---|---|
| Debug / Release 编译 | ✅ 均 exit 0 |
| `./build-ios.sh` 编译门 | ✅ exit 0,八条判据全过(处理量由脚本自己打印;2026-11-15 加第 2b 条 `NSSupportsLiveActivities=true` 后复跑仍全过) |
| 签名身份 | ✅ 已建 `Apple Development: ailurus@foxmail.com (ACYBTV5UFW)`;Team = `J4YCBW8ZG7`(**免费 Personal Team**);`DEVELOPMENT_TEAM` 仍不写进工程,只走命令行 |
| archive / export / upload | ❌ 仍未跑通。**免费 Personal Team 拿不到分发描述文件**,`--export` / `--upload` 要 Apple Developer Program 会员。**2026-11-24 复测 1.1.0**:`--export` 与手工 development 导出分别撞到 `No Accounts` / App Group 描述文件不匹配,以及 Xcode managed profile 不能按 manual profile 导出;TestFlight 前置条件未变 |
| 1.1.0 开发签名 IPA | ◐ `ios/dist/reverb-ios-1.1.0-4-development-signed.ipa`,3,291,567 B / 10:08:40,sha256 `983344f1cde568e8e3c758ff0a71797d52b037155a0734cbaaed1cd019f86105`。主 app 与 widget 都嵌入开发描述文件,`codesign --verify --deep --strict` 通过;只登记 1 台设备,描述文件 2026-11-30 到期。它是 Release 构建,但**不是 App Store / TestFlight 包**,按本轮维护者要求可作为明确标注的 GitHub 资产 |
| iOS 模拟器运行时 | ✅ 已装 iOS 27.2;iPhone 17 模拟器上跑过(见上节) |
| 真机 | ✅ iPhone 16 Pro(`00008140-000425693A7B001C`)`pairingState=paired`;Debug 与 Release 都装过、都能启动。**2026-11-09**:1.0.7(1) 在机上,截图与 App 日志都取得到;但重新拉起被 `FBSOpenApplicationErrorDomain error 3` 拒(当时锁屏;免费 7 天描述文件 11-02 装、可能到期),WDA runner 仍 `host_command_failed` ⇒ 点击类验收仍缺 |
| 界面与播放实跑 | ✅ 真机:首启隐私门 / 四个 tab 标题行 / 首页网络榜单 / 播放页 / 迷你播放条 / 后台音频(进度持续推进);**2026-11-04 功能对齐后**在模拟器复跑:追更真实列表 / 音阁订阅列表 / 设置四行新控件 / 播放页下载胶囊;同日**真机**复跑:设置三段 / 追更与音阁空态 / 英文界面 / 权限说明本地化 / 后台音频 / 冷启动暂停态时长(H247);**11-08 真机**补验音阁历史多选浮条;**11-09 模拟器**补验 B 站过滤读数、直播流结果行与播放页直播态(无进度条 / 无倍速 / 上下集置灰)、直播不记历史;**2026-11-15 模拟器**内置引导音频与远程 mp3 都能 `readyToPlay` 并出声(此前那轮 `-12746` 是模拟器媒体服务卡死,重启设备即恢复) |
| 锁屏 / 灵动岛实时活动 | ◐ 2026-11-15 编译门 + 模拟器系统侧实跑:活动注册、扩展被 chronod 拉起、锁屏与灵动岛三形态都 `LIVE`、稳态 0 次 update、结束/换集各一拍。**没看实际画面、没点过键**(本机无 Simulator 图形界面),真机未跑(见下行) |
| 真机签名重装(1.0.8) | ❌ **2026-11-15 复跑被签名挡住**:`xcodebuild … -allowProvisioningUpdates DEVELOPMENT_TEAM=J4YCBW8ZG7 build` → exit 65,报 `No Accounts: Add a new account in Accounts settings.` 与 `No profiles for 'com.yuyin.reverb'` / `'com.yuyin.reverb.widget'`。机上现有的仍是较早安装的那份,**不代表当前源码**;要让真机跑上本轮代码,先由维护者在 Xcode 登录任意 Apple 账号 |
| 局域网同步 | ◐ 三端编译门与共享层单测通过(KAT、回环握手);**2026-11-11 用探针补了跨端协议互通** —— Android 真机与 Apple 共享层双向各一次,SAS 一致、订阅导入与去重成立;当晚又用**真实 Wi-Fi** 由 Mac 直连手机(手动地址、无端口转发)跑了两轮,配对码一致、订阅导入、二次同步去重成立;**2026-11-12 补了删除墓碑**(共享层 `Sync/LanSyncTombstones.swift`,随快照传 `tombstones` 段),iOS 编译门 7 条全过、`swift test` 61 条 0 失败;**iOS 面板、mDNS 发现仍未跑**(模拟器无点击注入、真机 WDA 装不上),Apple 侧跑的是探针而不是 App 面板 |
| 仍未验 | ◐ 订阅刷新(定时)、逐字稿(需 iOS 26 语音模型)、下载、备份导出、锁屏与控制中心信息(真机没看)、**2026-11-04 新增能力的运行侧**:后台巡检与本地通知(BGTask 需真机跨 6 小时)、通知权限拒绝分支、相册保存、邮件草稿、蜂窝闸门(要在真机上切 Wi-Fi / 蜂窝);**2026-11-09 补记**:401 弹框、朋友圈海报生成、双击回顶、追更自动回顶、继续收听卡片点开,在 iOS 上**仍没有任何运行时读数**(模拟器无点击注入、真机 WDA 装不上);直播流的 UI 已由模拟器补上,**出声**仍只有真机可证(11-09 那轮模拟器连内置引导音频都加载失败,11-15 重启模拟器后已能出声,见上一行) |

**所以 TestFlight 链接目前还不可用**:缺的是 **Apple Developer Program 会员**。现有免费
Personal Team 的开发描述文件只够装登记的机器,不是分发描述文件;付费后按上节四条命令走。

**2026-11-10 的归档包**:`./build-ios.sh` 的编译门仍然 exit 0(七条判据全过),但归档走不通,
于是把编译产物直接打成 `ios/dist/reverb-ios-1.0.7-1-unsigned.ipa`(2,623,640 B,
sha256 `ec57dc9f…856483f61`)。**它没有签名** —— `codesign -dv Payload/Reverb.app` 报
`code object is not signed at all`,装不上真机,只用于归档与包内结构校验(解包核过:1.0.7(1) /
arm64 / 4 套 `.lproj` / `UIBackgroundModes` 含 audio / `ReverbWidget.appex` 在位)。
这份 ipa 与 Android apk、macOS dmg 一起挂在公开仓 `cxyxlxdm/revert-cast` 的 `1.0.7` release 上,
release 正文与公开仓 README 都写明了「不能直接安装」。
**要换成能装的**:在 Xcode 里登录 Apple 账号(任一个人 Team 即可)→ 确认
`security find-identity -v -p codesigning` 能列出开发证书 → `DEVELOPMENT_TEAM=J4YCBW8ZG7
./build-ios.sh --archive`,再决定是走 `--export` 还是 TestFlight。

**2026-11-13 的归档包(1.0.8)**:`./build-ios.sh` 编译门 exit 0、七条判据全过;
归档依然走不通(同一个原因:`--archive` 要签名,本机没有可用描述文件),于是照 1.0.7 的做法
把编译产物打成 `ios/dist/reverb-ios-1.0.8-2-unsigned.ipa`。
**同样没有签名**(`codesign -dv` 报 `code object is not signed at all`,包内也没有
`embedded.mobileprovision`),装不上真机,只用于归档与结构校验 —— 解包核过:1.0.8(2) / arm64 /
4 套 `.lproj` / `UIBackgroundModes` 含 audio / `ReverbWidget.appex` 在位。
⚠️ **这个文件名同一天出现过两份字节**:ECDH 修复前那版 **2,910,794 B / `d3f2d4c1…`**,
修复后重打(21:34:40,四端同批)是 **2,911,408 B / `388cbc34…`**,现存 `dist/` 里是后者。
构建号没变(2),所以**认文件请认 sha256,别认名字**;要传给 TestFlight 的话构建号还得再往上加。
**要换成能装的**,步骤同上(先让 Xcode 登录账号)。

**2026-11-24 的 1.1.0 开发签名包**:`./build-ios.sh --verify` 的产物判据全过,但标准
`--export` 仍因免费团队没有分发描述文件而失败;手工 development 导出也遇到
`Provisioning profile ... is Xcode managed, but signing settings require a manually managed profile.`。
最终没有改工程签名材料,而是从已验证的 Release app 复制 bundle,嵌入现有主 app 与 widget
开发描述文件,按描述文件 Entitlements 先签 widget 再签主 app,输出
`ios/dist/reverb-ios-1.1.0-4-development-signed.ipa`(3,291,567 B / 10:08:40,
sha256 `983344f1cde568e8e3c758ff0a71797d52b037155a0734cbaaed1cd019f86105`)。
`codesign --verify --deep --strict` 通过,两个 `embedded.mobileprovision` 都在;
主 app / widget 描述文件分别于 2026-11-30 12:10:04 / 12:10:07 到期,只登记 1 台设备。
**它能装到已登记测试机,但不是 App Store / TestFlight 包**;本轮按维护者要求作为明确标注的
GitHub 资产,不能据此宣布 TestFlight 已打通。

---

## 排障

- `CopyStringsFile ... input not found`,随后跟一个没头没尾的 `Ld __preview.dylib failed`
  ⇒ pbxproj 里本地化文件路径少写了 `Localization/`。**后者是前者引发的并行任务取消**,
  别去查链接器。见 `docs/TROUBLESHOOTING.md` **H240**。
- `No signing certificate "iOS Development" found` / `No profiles for 'com.yuyin.reverb' were found`
  ⇒ 账号未登录 / Team 不对;不是脚本或代码问题。
- `No simulator runtime` ⇒ `xcodebuild -downloadPlatform iOS`(8 GB 以上,本机实测要等)。
- `devicectl` 里能看到真机但 `pairingState=unsupported`
  ⇒ 这台 Mac 与手机还没建立信任:先在 Xcode → Window → Devices 里配对并确认手机上的「信任」。
  **未签名包仍然装不上**,配对只解决"看得见"。
- TestFlight 报「Missing compliance」⇒ 检查上传包里的 `ITSAppUsesNonExemptEncryption`;
  正常应为 `false`。若被改掉,上传后要逐次在 App Store Connect 回答问题。

---

## 代码与文档落点

| 位置 | 作用 |
|---|---|
| `ios/build-ios.sh` | 编译门 / 归档 / 导出 / 上传 |
| `ios/Reverb/App/AppEnvironment.swift` | 依赖容器(仓库、各 store、播放器) |
| `ios/Reverb/App/RootView.swift` | 五格 Tab(发现 / 电台 / 追更 / 音阁 / 设置)+ 迷你播放条 + 全屏播放页 |
| `ios/Reverb/App/ReverbApp.swift` | 启动、隐私门、后台落盘 flush |
| `ios/Reverb/UI/*` | 各页面(触屏形态) |
| `macos/Sources/Reverb/Data`、`Playback` | 与 macOS 共用的数据/播放层 |
| `docs/FEATURES.md` | 功能矩阵(平台差异以这里为准) |
| `docs/TROUBLESHOOTING.md` H240 | pbxproj 本地化路径的坑 |