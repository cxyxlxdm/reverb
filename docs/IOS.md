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
  GUID 与版本号由工程设置注入,不要手改。

---

## 这一版有什么 / 没有什么

**有**:四格(发现 / 追更 / 音阁 / 设置)、频道详情与订阅、播放页、后台播放 + 锁屏遥控、
**主屏「继续收听」小组件**(WidgetKit,见下一节)、
倍速 / 快进快退 / 睡眠定时 / 播放模式 / 自动续播、单集下载、逐字稿(iOS 26 本机离线转写 + 发布方逐字稿)、
节目笔记、听觉印记、收听统计、B 站视频与直播流、收藏/历史/待播/批注、备份与 OPML、隐私同意门、
主题与语言(5 语种)。

**没有**:

- **应用内更新** —— App Store/TestFlight 自己管;其余各端那种「查 GitHub Releases」在这里没有意义。
- **投播** —— 其余各端也没有,不在这一版。
- **桌面式三格外壳** —— iOS 用系统 TabView(触屏 + 安全区)。

---

## 主屏小组件(WidgetKit)

- **target**:`ReverbWidget`(`.appex`,嵌入 App 的 `PlugIns/`)。`ios/ReverbWidget/Info.plist` 的
  `NSExtensionPointIdentifier = com.apple.widgetkit-extension`;三档尺寸 `.systemSmall/.systemMedium/.systemLarge`。
- **状态契约只有一份**:`../macos/Sources/WidgetContract/WidgetState.swift`,iOS 两个 target 与 macOS 的 SwiftPM target 编译同一文件
  (改字段要四端一起想;`public init()` 必须写在类型体里,见 H252)。
- **共享数据用 App Group `group.com.yuyin.reverb`**:App 侧 `Reverb/App/WidgetBridge.swift` 写 `widget_state.json` + 压缩后的封面,
  扩展只读。两份 entitlements(`ios/Reverb.entitlements`、`ios/ReverbWidget/ReverbWidget.entitlements`)都已接入工程。
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

**验收状态(2026-11-09)**:编译门 exit 0;模拟器上扩展能被系统登记,App Group 容器与
`widget_state.json` 都真实落盘(见上一条的读数),bundle 内 appex 结构与断言一致。
**没验过**:主屏上把卡片加出来看渲染、点卡片后播放页是否弹出(`simctl openurl` 会弹系统确认框,
需要人点一下);真机 / TestFlight 的 App Group 受付费会员限制,签名结果未实测。

---

## 版本号

| 位置 | 字段 | 当前 |
|---|---|---|
| `ios/Reverb.xcodeproj/project.pbxproj` | `MARKETING_VERSION` | 1.0.7 |
| 同上 | `CURRENT_PROJECT_VERSION` | 1 |

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
DEVELOPMENT_TEAM=XXXXXXXXXX ./build-ios.sh --export    # → dist/reverb-ios-1.0.7-1.ipa
BUILD_NUMBER=2 DEVELOPMENT_TEAM=XXXXXXXXXX \
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
# 免点击过隐私门(等价于点「同意并继续」)。**要写当前 privacyVersion**,1.0.7 是 5;
# 走 cfprefsd,和直接改 plist 不是一回事(见本节末尾那条警告)。
xcrun simctl spawn booted defaults write com.yuyin.reverb privacy_version -int 5
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
(朋友圈海报、401 弹框、双击回顶、继续收听卡片)—— 模拟器没有注入手段,WDA 在真机上也没装上。

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

## 本机现状(2026-11-02,别当成"已验证")

| 项 | 状态 |
|---|---|
| Debug / Release 编译 | ✅ 均 exit 0 |
| `./build-ios.sh` 编译门 | ✅ exit 0,六条判据全过(处理量由脚本自己打印) |
| 签名身份 | ✅ 已建 `Apple Development: ailurus@foxmail.com (ACYBTV5UFW)`;Team = `J4YCBW8ZG7`(**免费 Personal Team**);`DEVELOPMENT_TEAM` 仍不写进工程,只走命令行 |
| archive / export / upload | ❌ 仍未跑过。**免费 Personal Team 拿不到分发描述文件**,`--export` / `--upload` 要 Apple Developer Program 会员(`--archive` 也没试过) |
| iOS 模拟器运行时 | ✅ 已装 iOS 27.2;iPhone 17 模拟器上跑过(见上节) |
| 真机 | ✅ iPhone 16 Pro(`00008140-000425693A7B001C`)`pairingState=paired`;Debug 与 Release 都装过、都能启动。**2026-11-09**:1.0.7(1) 在机上,截图与 App 日志都取得到;但重新拉起被 `FBSOpenApplicationErrorDomain error 3` 拒(当时锁屏;免费 7 天描述文件 11-02 装、可能到期),WDA runner 仍 `host_command_failed` ⇒ 点击类验收仍缺 |
| 界面与播放实跑 | ✅ 真机:首启隐私门 / 四个 tab 标题行 / 首页网络榜单 / 播放页 / 迷你播放条 / 后台音频(进度持续推进);**2026-11-04 功能对齐后**在模拟器复跑:追更真实列表 / 音阁订阅列表 / 设置四行新控件 / 播放页下载胶囊;同日**真机**复跑:设置三段 / 追更与音阁空态 / 英文界面 / 权限说明本地化 / 后台音频 / 冷启动暂停态时长(H247);**11-08 真机**补验音阁历史多选浮条;**11-09 模拟器**补验 B 站过滤读数、直播流结果行与播放页直播态(无进度条 / 无倍速 / 上下集置灰)、直播不记历史 |
| 仍未验 | ◐ 订阅刷新(定时)、逐字稿(需 iOS 26 语音模型)、下载、备份导出、锁屏与控制中心信息(真机没看)、**2026-11-04 新增能力的运行侧**:后台巡检与本地通知(BGTask 需真机跨 6 小时)、通知权限拒绝分支、相册保存、邮件草稿、蜂窝闸门(要在真机上切 Wi-Fi / 蜂窝);**2026-11-09 补记**:401 弹框、朋友圈海报生成、双击回顶、追更自动回顶、继续收听卡片点开,在 iOS 上**仍没有任何运行时读数**(模拟器无点击注入、真机 WDA 装不上);直播流的 UI 已由模拟器补上,**出声**仍只有真机可证(模拟器这一轮连内置引导音频都加载失败,见 §3) |

**所以 TestFlight 链接目前还不可用**:缺的是 **Apple Developer Program 会员**(现在登录的是免费
Personal Team,7 天有效的开发描述文件只够装自己的机器),不是代码。付费后按上节四条命令走。

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
| `ios/Reverb/App/RootView.swift` | 四格 Tab + 迷你播放条 + 全屏播放页 |
| `ios/Reverb/App/ReverbApp.swift` | 启动、隐私门、后台落盘 flush |
| `ios/Reverb/UI/*` | 各页面(触屏形态) |
| `macos/Sources/Reverb/Data`、`Playback` | 与 macOS 共用的数据/播放层 |
| `docs/FEATURES.md` | 功能矩阵(平台差异以这里为准) |
| `docs/TROUBLESHOOTING.md` H240 | pbxproj 本地化路径的坑 |