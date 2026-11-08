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
倍速 / 快进快退 / 睡眠定时 / 播放模式 / 自动续播、单集下载、逐字稿(iOS 26 本机离线转写 + 发布方逐字稿)、
节目笔记、听觉印记、收听统计、B 站视频与直播流、收藏/历史/待播/批注、备份与 OPML、隐私同意门、
主题与语言(5 语种)。

**没有**:

- **应用内更新** —— App Store/TestFlight 自己管;其余各端那种「查 GitHub Releases」在这里没有意义。
- **投播** —— 其余各端也没有,不在这一版。
- **桌面式三格外壳** —— iOS 用系统 TabView(触屏 + 安全区)。

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
中文关键词没法用 `simctl`/`adb` 注入,这条是 H241 的验收入口)。Release / TestFlight 包里没有这段。

```bash
cd ios
xcrun simctl boot "iPhone 17"                       # 已装的 iOS 27.2 运行时
xcodebuild -project Reverb.xcodeproj -scheme Reverb -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/SimDerived CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted build/SimDerived/Build/Products/Debug-iphonesimulator/Reverb.app
# 免点击过隐私门(等价于点「同意并继续」)
xcrun simctl spawn booted defaults write com.yuyin.reverb privacy_version -int 4
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
**没验过的**:订阅刷新(定时)、逐字稿(需 iOS 26 语音模型)、
下载、备份导出、后台巡检与本地通知、相册保存、邮件草稿 —— 模拟器只覆盖到
首启 / 首页 / 追更 / 音阁 / 播放 / 设置页渲染。

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
- 限制:本机数据容器里 `订阅=0 历史=3`,所以追更列表只能看空态;
  「音阁 → 历史 → 多选」那一屏**没截到**(抓图时手机已回锁屏),多选浮条仍未取证。

⚠️ **两个「看起来应该能自动」但实际不行的通道**,别重试:
① 直接往应用容器的 `Library/Preferences/com.yuyin.reverb.plist` 写 `privacy_version=4`
**会被 cfprefsd 缓存挡住**(文件读出来是新值,界面仍停在同意页);
② `devicectl … launch -- -privacy_version 4` 也不足以过门(参数域对 `as? Int` 的取值不可靠)。
所以首启那一下必须人点一次 —— 点过之后不再需要。

---

## 本机现状(2026-11-02,别当成"已验证")

| 项 | 状态 |
|---|---|
| Debug / Release 编译 | ✅ 均 exit 0 |
| `./build-ios.sh` 编译门 | ✅ exit 0,六条判据全过(处理量由脚本自己打印) |
| 签名身份 | ✅ 已建 `Apple Development: ailurus@foxmail.com (ACYBTV5UFW)`;Team = `J4YCBW8ZG7`(**免费 Personal Team**);`DEVELOPMENT_TEAM` 仍不写进工程,只走命令行 |
| archive / export / upload | ❌ 仍未跑过。**免费 Personal Team 拿不到分发描述文件**,`--export` / `--upload` 要 Apple Developer Program 会员(`--archive` 也没试过) |
| iOS 模拟器运行时 | ✅ 已装 iOS 27.2;iPhone 17 模拟器上跑过(见上节) |
| 真机 | ✅ iPhone 16 Pro(`00008140-000425693A7B001C`)`pairingState=paired`;Debug 与 Release 都装过、都能启动 |
| 界面与播放实跑 | ✅ 真机:首启隐私门 / 四个 tab 标题行 / 首页网络榜单 / 播放页 / 迷你播放条 / 后台音频(进度持续推进);**2026-11-04 功能对齐后**在模拟器复跑:追更真实列表 / 音阁订阅列表 / 设置四行新控件 / 播放页下载胶囊;同日**真机**复跑:设置三段 / 追更与音阁空态 / 英文界面 / 权限说明本地化 / 后台音频 / 冷启动暂停态时长(H247) |
| 仍未验 | ◐ 订阅刷新(定时)、逐字稿(需 iOS 26 语音模型)、下载、备份导出、锁屏与控制中心信息(真机没看)、**2026-11-04 新增能力的运行侧**:后台巡检与本地通知(BGTask 需真机跨 6 小时)、通知权限拒绝分支、相册保存、邮件草稿、蜂窝闸门(要在真机上切 Wi-Fi / 蜂窝);「音阁 → 历史 → 多选」浮条**未截图取证** |

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