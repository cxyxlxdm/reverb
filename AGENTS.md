# AGENTS.md — 在本仓库工作的约定

> 给编码代理(以及第一次接手的人)看的操作手册。**内容以本文为准**;
> `CLAUDE.md` 只是指向这里的薄指针,不重复内容。
>
> 本文只写「怎么在这个仓库里干活」。产品与实现的知识在别处,见文末文档地图。

---

## 这是什么

**余音 · Reverb** —— 一款播客客户端,四个原生端:

| 目录 | 端 | 技术栈 | 分发 |
|---|---|---|---|
| `android/` | Android | Kotlin / Jetpack Compose | 大陆应用市场 + GitHub Releases |
| `harmony/` | HarmonyOS | ArkTS / ArkUI | 应用市场 |
| `macos/` | macOS | Swift / SwiftUI | 自分发(dmg) |
| `ios/` | iOS | Swift / SwiftUI | **TestFlight**(2026-11-02 新增;暂不上架 App Store) |
| `shared/` | 共享物料 | 图标、种子清单、引导音频(脚本分发到各端) | — |
| `site/` | 个人主页 + 余音官网与隐私政策页(`site/reverb/`) | 静态 HTML | — |

iOS 与 macOS **共用同一份 `Data/` + `Playback/` 源码**(路径仍是 `macos/Sources/Reverb/…`,
由 iOS target 直接编译),界面各写各的。改共享层必须两端都过编译门,见 `docs/IOS.md`。

**四条不可动摇的约束**(所有设计的上游):

1. **零后端。** 没有服务器、没有账号、没有云同步、**没有任何上传数据的代码路径**。
2. **不接任何第三方 SDK。** 系统能力不算三方。分享一律走系统分享。
3. **合规是设计输入。** 隐私同意门与功能隔离在架构层面体现,不是界面上加判断。
4. **包里有 / 没有,都必须可验证。** 声明某份包包含或不含某功能,验收方式是**解包 grep**。

Android **只维护一份包**(2026-10-18 把 `default` / `store` 两个 flavor 合并,见
`docs/TROUBLESHOOTING.md` H205):`android/dist/reverb.apk` 同时上传华为等大陆商店与
GitHub Releases 自分发。原先靠 flavor 做的功能差异,现在只剩三个编译期常量当**备用闸**
(`BuildConfig.CATALOG` / `BuildConfig.SPECTRUM` / `AsrFactory.HAS_ENGINE`),一行降到
`false` 就是那条降级档。鸿蒙只有商店渠道;macOS 自分发。口径见 `docs/FEATURES.md`「渠道差异」。

---

## 环境准备

**新机器、新会话,先确认下面这几件事** —— 它们都不在 PATH 里,也不是 `./gradlew` 会替你找的。

| 需要什么 | 本机实际位置 | 怎么验 |
|---|---|---|
| JDK(编译用) | `/Users/cxyxl/Library/Java/JavaVirtualMachines/jdk-21.0.12.1+1.jdk/Contents/Home`(Temurin 21;`java_home -V` **认得**它) | `"$JAVA_HOME/bin/java" -version` → 21.x |
| Android SDK | `android/local.properties` 的 `sdk.dir` = `/Users/cxyxl/Library/Android/sdk` | `ls "$SDK/platform-tools/adb"` |
| DevEco SDK | `/Applications/DevEco-Studio.app/Contents/sdk` | `ls $DEVECO_SDK_HOME/default/openharmony/toolchains/hdc` |
| Chrome(仅宣传片流水线) | `/Applications/Google Chrome.app` | `--headless=new` 能起 |
| **developer dir 的许可**(macOS 工具链**和 `/usr/bin/git`**都走它的 shim) | Xcode 27.1 已装(10-24),`xcode-select -p` 指向它;CLT 也还在 | `xcrun --show-sdk-path` 给得出路径才算通。**回一句 "You have not agreed to the Xcode license" 就是没通** —— 10-24 实测它 **exit 69**,这个退出码可以直接当脚本里的闸门;那时 `git` / `clang` / `swift` / `python3` 会一起失效,`command -v` 却仍然能找到它们(见 H208 教训 10)。**`macos/tools/selftest-verify.sh` 现在自带这条门**(取不到 SDK 就打印"这是环境门不是断言失败"并 exit 69);它的阳性对照不用等真坏 —— `DEVELOPER_DIR=/tmp/不存在 bash macos/tools/selftest-verify.sh` 必须给出那句话和 69 |
| iOS 工具链 | Xcode 27.2 / iOS SDK 27.2(与上面同一个 Xcode) | `xcodebuild -project ios/Reverb.xcodeproj -scheme Reverb -showBuildSettings >/dev/null` exit 0 |

⚠️ **iOS 的编译门不需要证书,TestFlight 需要**。2026-11-02 本机实测:`ios/build-ios.sh`
(不签名)exit 0、六条判据全过;当晚 Xcode 登录后建了开发证书
(`Apple Development: ailurus@foxmail.com (ACYBTV5UFW)`,Team `J4YCBW8ZG7`,**免费 Personal Team**),
iPhone 16 Pro 已配对,Debug 与 Release 都装上并跑过(四个 tab / 播放页 / 后台音频)。
但 **archive / export / upload 仍没跑通**:免费 Personal Team 拿不到分发描述文件,
TestFlight 还要求 **Apple Developer Program 会员** + App Store Connect 里有 `com.yuyin.reverb`
的 App 记录。**2026-11-10 试过一次 `--archive`**:11-02 那份开发描述文件已到期(2026-11-09 14:57:39 UTC),
Xcode 又没有任何已登录账号,直接报 `No Accounts` / `No profiles for 'com.yuyin.reverb'` ——
于是只出了编译门全过的**未签名** ipa(`ios/dist/reverb-ios-1.0.7-1-unsigned.ipa`,归档用,装不上真机)。
逐条与现状表见 `docs/IOS.md`;别把"编译过了"当成"能传 TestFlight"。

⚠️ **上面那条许可检查是 10-24 下午新加的,起因是一次看起来"仓库坏了"的假象。** 本人装完 Xcode 之后
`/usr/bin/git` 开始只回许可提示,而它是这台机器**唯一的 git**(brew 没装 git)——
症状是"git 不能用",真相是"这台机器的 git 是 Xcode 的转发器"。
**期间的绕法**:`/Library/Developer/CommandLineTools/usr/bin/git`(实测 2.54.0,与 Xcode 那份同版本),本轮文档提交就走的它;
**别把这条写进脚本** —— 同意许可后 `/usr/bin/git` 自然恢复,写进脚本就变成第二个"文档里的绝对路径"。
**(10-24 傍晚 `xcodebuild -license accept` 跑过,`/usr/bin/git` 与 `xcrun --show-sdk-path` 实测都恢复;
上面那句绕法只在当天下午那几个小时里有用,留着是为了记症状。)**

⚠️ **另两件缺件登记在 `docs/LOCAL-ASSETS.md` §四,不挡出包但挡流水线**:
`pillow`(`android/tools/glass-shot.sh` 与 `harmony/tools/glass-shot.sh` 的 heredoc 里 `from PIL import Image`)、
`numpy`(`marketing/src/score.py`)。**这两样 10-24 晚间已装**(本机装机验收那一轮顺手补的,
`python3 -c "import PIL,numpy"` 实测 exit 0 ⇒ **PIL 11.3.0 / numpy 2.0.2**,`--user` 装进当前解释器的用户目录)。
时间线记一下免得有人再去找它们:10-24 下午它们连装都装不了(`python3` 在 Xcode 许可后面),傍晚许可同意后
`python3` 恢复,但**缺件本身当时仍未变**。

⚠️ **本机没有 JDK 17 —— 但不需要它。** 2026-10-24 换机(旧机 `MacBookPro11,4` / macOS 12 / 用户 `liang`
→ 新机 Apple Silicon / macOS 27 / 用户 `cxyxl`)之后,原先写死在本文与 `README.md`、`CLAUDE.md` 里的
`/Users/liang/.java/jdk-17.0.12+7/Contents/Home` **整条路径不存在**。项目要的是 **language level 17**
(`build.gradle` 的 `sourceCompatibility/targetCompatibility = VERSION_17`;AGP 9 起内置 Kotlin 的 jvmTarget
跟随这里,不再单独写 `kotlinOptions`)。10-24 实测用 Temurin 21 出包全绿:编译门 exit 0、`build-release.sh` exit 0、
解包审计 6/6 PASS(当时 AGP 8.5.2 / Gradle wrapper 8.7 / Kotlin 1.9.24 都跑在 21 上;2026-11-15 已升到
AGP 9.5.1 / Gradle 9.9.1 / Kotlin 2.2.10,仍跑在 Temurin 21 上,见 H282)。逐条来源见 H208。

⚠️ **`java_home -v 17` 在这台机器上会给你另一个版本(10-24 实测)。** 它**忽略版本参数**、
直接返回当前注册的最新 JVM(Temurin 21)并 **exit 0**;`-v 99` 给的是同一个串。
所以 `README.md` 那条 `export JAVA_HOME=$(/usr/libexec/java_home -v 17)` 在本机**不再**像旧机那样
静默设成空值 —— 它静默设成 21。症状从"看起来像没装 JDK"变成"要 17 拿到 21 而且退出码是 0":
本仓库恰好只要求 language level 17,所以这条命令目前能用,但**它给的不是它要的**,别把它当版本校验用。
**结论:要绝对路径,并且用 `java_home -V`(大写,列出全部)或 `"$JAVA_HOME/bin/java" -version` 来认版本 ——
`-v <版本>` 在只装了一套 JVM 的机器上没有判别力。**

⚠️ **`aapt2` 不在 PATH**(只有 `adb` 在)。要读包信息就写全路径:
`"$SDK/build-tools/<ver>/aapt2" dump badging …`。
写成裸 `aapt2 … | grep -c` 时命令**根本没跑**,`grep -c` 对着空 stdin 报 **0** ——
这正是 H156 那次"两个渠道都被读成没有录音权限"的成因。期望 0 的判据先看命令自己的退出码。

**一分钟自检**(本机唯一能跑的产品级验证,2026-10-18 合并 flavor 后实测 exit 0;
2026-10-24 换机后用 Temurin 21 重跑,仍 exit 0):

```bash
cd android && export JAVA_HOME=/Users/cxyxl/Library/Java/JavaVirtualMachines/jdk-21.0.12.1+1.jdk/Contents/Home \
  && ./gradlew :app:compileReleaseKotlin -q; echo "exit=$?"
```

合并前这一条是 `compileDefaultReleaseKotlin` + `compileStoreReleaseKotlin` 两个任务;
现在只有一份 release,任务名不再有渠道前缀。

## 常用命令

### Android

```bash
cd android
./build-release.sh                 # 唯一那份 → dist/reverb.apk(1.0.8 起 ≈270 MB,含 239 MB 语音模型)
./build-release.sh --bundle          # 同上,出 .aab(H205 之后没有渠道参数了;--store 会当未知参数退出)
# 只想过编译(快):
./gradlew :app:compileReleaseKotlin -q
# 备齐离线识别的五样产物(模型 + 词表 + jar + 两个 .so;不入版本管理,缺了打包会报错退出):
./tools/build-asr.sh [--force]
adb install -r dist/reverb.apk
```

⚠️ **`./build-release.sh` 会 `rm -f` 掉 `dist/reverb.apk` 与它的 mapping 再重打** —— 在架那份的
mapping **本地只此一份**,重打前先归档(H204 踩过的同类事故,H205 又写了一遍)。

### HarmonyOS

```bash
cd harmony
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
HV=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw
# 离线识别产物(模型 228 MB + 词表;不入库,缺了打包会报错退出):
./tools/build-asr.sh [--force]          # 同机有 Android 那份时直接按 sha256 拷过来,不再下载
# debug hap(装机调试用;模型进了 rawfile 之后约 271 MB)
$HV assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
./tools/install-device.sh              # 装机一条命令:覆盖装 + 签名口径冲突识别(见 H216)
# 发布包(build-release.sh 自带 node 版本闸,≥23 会自动切 ~/Library/OpenHarmony 的 node 22,见 H216)
./build-release.sh [--fast]        # → dist/reverb.app + reverb-symbol.zip;出包前后各查一次模型在不在
```

`hdc` 在 `$DEVECO_SDK_HOME/default/openharmony/toolchains/`;本机还有一份较新的在
`~/Library/OpenHarmony/Sdk/26.0.0/toolchains/`(**两份都认得当前真机**,哪份顺手用哪份)。

⚠️ **`hdc list targets` 空但手机确实插着**(2026-10-25 实测):先用
`ioreg -p IOUSB -l | grep -A2 'HDC Device'` 看总线上有没有枚举 —— **有 "HDC Device" = 物理链路通,
卡的是授权**:看手机屏幕上的「允许 USB 调试」弹窗;没弹就去开发人员选项「撤销 USB 调试授权」
再拔插线。确认手机端「USB 连接方式」是传输文件而非仅充电。

⚠️ **装机被拒的两种签名报法不同因**(详见 `tools/install-device.sh` 头注与 H216 教训):
`9568286 provision type not same` = 机上包与本包一个 debug 一个 release 口径,互不让覆盖;
`9568448 verify app signature failed` **且机上没装** = 鸿蒙 NEXT(Mate 60 / 7.0.0.109 实测)的
签名信任边界:**hdc 侧载只认含本机 UDID 的调试 profile**,release 正式签名一律被拒(连 dist 里
在架正式包都一样),**与系统设置无关**(老系统的「纯净模式」开关在 NEXT 上不存在,别找)——
release 口径真机验收走应用市场/AGC 云真机,日常装机验证用 debug 包。

**新增 native 类型包(`.so` 的 `index.d.ts`)之后必须跑一次 `ohpm install`**,
否则类型解析成 `any`、报 `arkts-no-any-unknown`(症状很误导,见 H61)。

### macOS

```bash
cd macos
# ↓↓ 这三条在本机都跑过了(2026-10-24 傍晚,许可同意后逐条 exit 0)↓↓
swift build -c release             # 只编译
./package.sh                       # universal 编译 → .app → ad-hoc 签名 → 解包验收(断言)→ dmg 进 dist/
bash tools/selftest-verify.sh      # 验收脚本的自检:手搭假 bundle 跑正向 + 把每类失败形状逐个弄坏
                                   # (通过条数由脚本最后一行自己打印,别抄进任何文档 —— 加一道变异它就变)
```

> ⚠️ **2026-10-24 傍晚:上面这三条本机全绿了,「本机出不了 macOS 包」这句话到此作废。**
> `sudo xcodebuild -license accept` 跑过之后,shim 层恢复,三条按序重验的结果:
> ① `tools/selftest-verify.sh` exit 0;② `swift build -c release` exit 0(`Build complete! 15.46 秒`);
> ③ `./package.sh` exit 0 ⇒ `macos/dist/余音-Reverb-1.0.4-universal.dmg` **4 161 690 B** @10-24 13:39:05(`ls -lT` 现读),
> (13:39 这份是改完 `PlayerController.swift` 那条 H209 注释后**按硬规矩 20 重打**的 —— 动了 `Sources/` 就不能拿 13:28 那份说"包比码新";
> 首跑全绿那份是 13:28:50 / 4 161 692 B。现在 `-newer` 判据对 `macos/Sources` + `Localization` + `Info.plist` + `Package.swift`
> 是 **0 命中**;只有 `verify-bundle.sh` 与它的自检脚本比包晚 —— 那两条不进包,不触发重打)
> 包内二进制 9 604 048 B、`lipo -archs` = `x86_64 arm64`、4 套 `.lproj`、`codesign --verify` 过(adhoc)、
> `LSMinimumSystemVersion 13.0`。**这台机器现在就是自己的构建机** —— 旧机那四层(见下面历史块)与
> 「CLT 缺 `SwiftUIMacros`」「许可没同意」两层拦路全部消失。
> ③ 第一次跑是 **exit 1**,报的 9 条「判据词 0 命中 —— 这批改动没进包」**是判据错了,不是包缺东西**:
> 那 9 个词全是 9~15 字节的字符串字面量,而 Swift 的 `-O` 把这一档的字面量编成**两条 `movabsq` 立即数**
> (头 8 字节一条、余下字节一条),整词在二进制里不连续 ⇒ 整词 grep 恒 0。逐层排除与那两条指令的十六进制在 **H209**。
> **⚠️ 撤掉的只有"出包"这一层。** 这一轮**一帧都没跑过**:界面与自动续播那四项运行验收仍然没做
> (清单在 `docs/ROADMAP.md` 三-A),而「macOS 的运行验收固定在另一台机器」是用户 2026-09-29 定的边界 ——
> **这条边界现在要不要改,由维护者拍,别替它决定。**
>
> ⚠️ **2026-10-24 换机:下面这一整块的四层封死理由已作废,但「本机出不了包」这个结论暂时还在。**
> (▶ 从这一行往下的两块是 10-24 上午与下午的过程记录,两层拦路后来都在傍晚消失 —— **现状只看上面那块**,别把这里的"只剩一条"当今天。)
> 新机是 Apple Silicon + macOS 27,旧机那四条(tools-version 5.9 门 / SDK 13.1 天花板 /
> 系统低于 13 起不来产物 / `NavigationStack` 符号缺失)**一次全部消失** —— Swift 6.4、SDK 27,
> 产物能在这台跑。现在只剩**一条**拦路:**这台仍只装了 Command Line Tools,而 CLT 里没有
> SwiftUI 的宏插件**(`…/usr/lib/swift/host/plugins` 只有 `libObservationMacros` / `libSwiftMacros`,
> `find … -iname '*SwiftUIMacros*'` = **0**),于是 `@State` 展不开,连
> `swiftc -typecheck` 都过不去 —— 用一个 6 行的 `@State` 最小文件同样报
> `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`,
> 所以**这不是源码问题**。universal 那条照旧要完整 Xcode(`xcbuild` 只随它分发)。
> **本机现在唯一能跑的 macOS 验收 = `bash macos/tools/selftest-verify.sh`**(2026-10-24 实测 `pass=9 fail=0`)。
> **所以「原先那句『本机最强验收 = 整模块 typecheck 差分』在新机上不成立**,要它就得先装完整 Xcode;
> 装不装由维护者决定(≈15 GB + Apple ID;这台机器装得动,旧机装不动正是当初定死「另一台机器出包」的原因)。
>
> ⚠️ **2026-10-24 下午:上面那句"装不装由维护者决定"有了答案 —— 已装,但结论还没翻面。**
> `xcode-select -p` 已指向 `/Applications/Xcode.app/Contents/Developer`(Xcode 27.1 / 27A9275),
> 那条「只剩 CLT 缺 `SwiftUIMacros`」的拦路**消失了**(宏插件 5 份,含 `MacOSX.platform`;`xcbuild` 也在,
> 但落点是 `Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/Support/xcbuild`,不是 `Developer/usr/bin/`)。
> **换上来的是一条更靠前的**:Xcode 许可还没同意(`sudo xcodebuild -license accept` 没跑),
> 而 developer dir 的 **shim 层全体拒答** —— `xcrun` / `swift` / `swiftc` / `clang` / `/usr/bin/python3` /
> **`/usr/bin/git`** 只回同一句许可提示。所以**连上面那句"唯一能跑的验收 = `selftest-verify.sh`"也不成立**:
> 同日下午实测 `exit 1`、`clang x86_64 失败`(它只要 CLT 自带工具,而那些工具现在在许可后面)。
> ⇒ **这台机器目前 macOS 侧是零验收可跑**,不是"只剩 selftest"。同意许可后要依次重验三条
> —— `bash macos/tools/selftest-verify.sh`(期望 `pass=9 fail=0`)→ `swift build -c release` → `./package.sh`;
> **三条都过才有资格把「本机出不了 macOS 包」从本文撤掉**,一条没过就照原文写着。
> **▶ 这三条同日傍晚全跑过了(① exit 0 / ② exit 0 / ③ 第一次 exit 1 = 判据的错,修完 exit 0),
> 结论已按上面那块改写;`pass=9` 也随自检新增的三道配置变异一起漂了 —— 以脚本自己打印的数为准。**
> 这一段留原文是为了记"当时确实零条可跑",读的时候别当现状。
> 期间**要提交**可以用真二进制绕开:`/Library/Developer/CommandLineTools/usr/bin/git`(实测 2.54.0)——
> 它是症状的 workaround,不是长期方案,别写进脚本。逐条见 H208 修法 3-① 与教训 9~11。
>
> ⚠️ **差分到不了 0 的实测数字**:38 个文件一起 typecheck ⇒ exit 1,**4 条错误全落在 `RootView.swift:15/16`
> 那一条宏错误上**(H128 那条"第一个含错文件之后不再有意义地继续"在这里正好挡住,所以"其余文件被检查过"证明不了)。
> 顺带记一次**无效对照**:按"是否用到宏"把 38 个文件拆两组分别 typecheck,两组都报
> `cannot find 'Fmt' in scope` 这类跨文件符号 —— **拆组切断了模块内依赖,那两组的读数不能用**。
> 下面原文按历史记录保留,读的时候把「本机」换成「那台旧机」。逐条来源见 H208。
>
> ⚠️ **【历史:下面这一段整块说的是那台旧机,10-24 新机已逐层作废 —— 见本节最上面那块。
> 现在仍然成立的那半句是「运行验收固定在另一台机器」,它归维护者拍,不在这轮的三条门里。】**
> 这两条命令不在本机跑。本机的角色已由用户定死(2026-09-29):开发 Android / 鸿蒙 / 文档,
> 加上对 macOS「读代码、改代码、做类型检查」;macOS 的出包与运行验收固定在另一台机器上。**
> 别再在这台上重试,也别为了让它们跑起来去改源码 —— 下面四层是实测,不是"没装好":
> ① `macos/Package.swift` 是 `swift-tools-version:5.9`,而本机 SwiftPM 报 installed version 5.7.1
> (`swift --version` 自己写 5.7.2)⇒ 版本门直接挡回;
> ② **上限封在 SDK 上**:机型 `MacBookPro11,4`(无 T2),`softwareupdate --list-full-installers`
> 只列出 12.7.6 / 11.7 / 10.15 / 10.13 ⇒ **系统上限就是当前的 12.7.6,没有 Ventura 及以后**;
> 系统 12 ⇒ 最高 Xcode 14.2 ⇒ 最高 SDK **13.1**(`/Library/Developer/CommandLineTools/SDKs/` 只有 12 / 12.3 / 13 / 13.1),
> 而 `TranscriptPage.swift` 那四处双参数 `onChange` 要 macOS 14 SDK —— 14 SDK 只随 Xcode 15 分发,
> Xcode 15 又要 macOS 13.5+(`xcodebuild` 在这台直接报 requires Xcode)。
> **单独去装 Swift 5.9 编译器也没用:缺的是 SDK,不是编译器。**
> ③ 就算前两条都好办,**这台机器也验收不了产物**(2026-09-30 实测,拦点比先前记的更具体):
> `.app` 里写 `LSMinimumSystemVersion 13.0`,在本机 `open` 会被 LaunchServices 挡下 ——
> `error=-10825 kLSIncompatibleSystemVersionErr`;而**二进制的 `minos 13.0` 本身并不拦命令行进程**
> (拿 minos=13.0 的最小可执行文件在本机直接跑,正常退出 0 —— 先前"加载即拒"的说法不准确)。
> ④ **真正拦路的是 macOS 13 的 API 符号**:`RootView.swift:20`、`ListenStatsView.swift:16`、
> `FootprintView.swift:15` 用 `NavigationStack` 且没有降级分支,拿它编一个 minos=13 的命令行程序在本机跑,
> 实测是 `dyld: Symbol not found: _$s7SwiftUI14NavigationPathVMn` + SIGABRT(退出码 134)——
> **即"编得出来、跑不了",而要让它在 12.7.6 上跑,要重写的是整个根导航,不是那 4 行 `onChange`。**
> **所以「出包 + 运行验收」要在装了完整 Xcode(不是只有 CLT)且系统 ≥ macOS 13 的机器上做。**
> 另有两条本机专属的坏消息,免得有人想"那我在本机凑合编一下":
> ⑤ 本机 CLT 的 SwiftPM **连最小 manifest 都编不了** —— `$(xcode-select -p)/usr/lib/swift/pm/ManifestAPI/`
> 里只有 `libPackageDescription.dylib`,没有 `.swiftmodule`,于是任何工程都报
> `no such module 'PackageDescription'`(与 tools-version 无关);
> ⑥ `swift build --arch arm64 --arch x86_64`(出 universal)**走 xcbuild,而 xcbuild 只随完整 Xcode 分发**,
> CLT 机器直接报 `xcbuild executable ... does not exist` —— 这个检查甚至排在 tools-version 门之前。
> **「那装个旧版 Xcode 呢」这条也已经评估并否掉(2026-09-30,别重开)**:本机系统 12.7.6 最高只能装
> Xcode 14.2(Swift 5.7.2 / SDK 13.1),它只修掉 ⑤⑥;② 的 SDK 天花板(要 macOS 14 SDK 的那 4 处 `onChange`)、
> ③④ 的"编得出来也起不来"(`LSMinimumSystemVersion 13.0` / `NavigationStack` 无降级分支)一层不动,
> 而且产物只能是 x86_64 单芯片。**投入 ≈15 GB + Apple ID 登录,换来零验收收益。** 判据:
> **要换的是"能跑产物"的机器,不是往旧机器上加装工具链。** 详见 `docs/ROADMAP.md` 三-A 最后两行。
> 旁证:`macos/dist/余音-Reverb-1.0.2-arm64.dmg`(2026-09-20 那个包)里 `minos 13.0 / sdk 26.5 / arm64 单架构`,
> 是另一台得多的机器打的。
> **本机对 macOS 改动的最强验收 = 整模块 typecheck 差分,但差分必须两边都跑到 0 错误**:
> `swiftc -typecheck -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macos13.0 $(find Sources -name '*.swift')`
> —— 基线用 `git archive HEAD macos | tar -x -C /tmp/…` 解一份出来单独跑。
> **2026-10-01 修正过这条判据本身(见 H128)**:`swiftc -typecheck` 在**第一个含错误的文件之后
> 就不再有意义地继续**,所以"改前改后都是同样 4 条"**证明不了其余文件被检查过** ——
> 比法只能写成"两边都为 0"。而本机对**未改动的 HEAD 源码**就要中性化 **7 类 / 18 处调用点 + 1 个整文件**
> 14+/26-only 依赖才能走到 0(双参 `onChange`、轮播那四个 modifier、`focusEffectDisabled`、
> `SettingsLink`、`MainActor.assumeIsolated`、`nonisolated(unsafe)`(**语法级,连解析都过不了**)、
> 整个 `@available(macOS 26)` 的 `Transcriber`)—— 中性化只在 /tmp 的 scratch 树里做,**不动工作区**。
> 最后必须配**阳性对照**:往本次改动的两三个文件里各注入一个语义错(每次只留一个),
> 各自都得被报出来,否则那个 0 不成立。
> **并且这只证明类型没变多,证明不了界面与行为**(一帧都没跑起来)。
>
> **出包 = 一条命令**:`cd macos && ./package.sh`(2026-10-24 傍晚起在本机跑通,见上面那块)。它做
> **universal 编译**(`--arch arm64 --arch x86_64`)→ **架构硬断言**(少一个架构就 exit 1,不出 dmg)→
> 组装 .app → ad-hoc 签名 → **解包验收** → dmg 落进 `macos/dist/`,文件名带版本与架构(由架构列表推导)。
> 验收段是独立的 **`macos/verify-bundle.sh`**(2026-10-06 起,**每条判据都判成败、不过就退出 1**,
> 不再是"打印给人看"):处理量 → 架构**集合相等**(缺一个 ✗,多一个也 ✗)→ 判据词任一为 0 即 ✗ →
> 语言**集合相等** + 每套 `.strings` 的 `plutil -lint` → `Info.plist` 三键(认 `plutil` 的**退出码**,
> 不是"取到的字符串非空")→ `codesign --verify`。最后打印未覆盖范围。
> 为什么默认两个架构:`swift build` 不带 `--arch` 时**只跟随构建机芯片**,1.0.2 那个包就是这么变成
> arm64 单架构的,而 arm64-only 二进制在 Intel Mac 上没有退路(Rosetta 只翻译 x86→arm 一个方向)。
> ⚠️ **判据词表带类别前缀,挑词之前先看字节数**(`lit8:` ≤8 字节字面量 / `lit16:` ≥16 字节字面量 /
> `sym:` 标识符):Swift 的 `-O` 把 **9~15 字节**的字面量拆进两条 `movabsq` 立即数,整词 grep 恒 0,
> 那种词**在这端的 release 包里不能当判据**(2026-10-24 第一次真跑就栽在这里,逐条见 **H209**)。
> 每个词都单独拿 1.0.2 旧包验过负控制(全部 0),所以它报非 0 才算数;
> **而"负控制成立"不等于"判据成立"** —— 一个在任何 release 包里都是 0 的词,负控制永远通过、正向永远不通过。
> 架构断言同样拿那个 arm64-only 二进制空跑验过:**期望两个架构时报 `✗ 缺 x86_64` 并退出 1,只期望 arm64 时通过**。
> `bash macos/tools/selftest-verify.sh` 是断言脚本自己的自检(假 bundle 正向 + 每类失败形状各一道变异,
> 含 2026-10-24 新加的三道「词表写错」配置变异),写变异时确实抓出过几条写错的断言,见 H136。
> **仍未跑过的**是产物**跑起来**那部分:界面四项与自动续播验收一帧没做,清单在 `docs/ROADMAP.md` 三-A。

### iOS

```bash
cd ios
./build-ios.sh                 # 编译门(不需要证书)→ build/DerivedData/…/Reverb.app
DEVELOPMENT_TEAM=XXXXXXXXXX ./build-ios.sh --archive   # → build/Reverb.xcarchive
DEVELOPMENT_TEAM=XXXXXXXXXX ./build-ios.sh --export    # → dist/reverb-ios-<版本>-<构建号>.ipa
BUILD_NUMBER=2 DEVELOPMENT_TEAM=XXXXXXXXXX \
  ASC_KEY_ID=… ASC_ISSUER_ID=… ./build-ios.sh --upload # → TestFlight
```

- 编译门在本机可跑(2026-11-02 实测 exit 0,判据:版本 / 后台音频 / 本地化集合 / 内置物料 / 图标 / arm64);
  archive / export / upload **需要签名,本机尚未跑过** —— 原因与前置条件见 `docs/IOS.md`。
- 签名团队只从环境变量读,不写进工程文件;脚本不碰任何证书/口令。
- iOS 与 macOS **共用** `macos/Sources/Reverb/{Data,Playback}`,改那边要两端都过编译门。
- TestFlight:内部测试员无需审核;外部测试员首次要过 Beta App Review;每个构建 90 天过期;
  构建号每次上传必须递增。
- `ios/Reverb/**` 用 synchronized root group,加界面文件不用改 pbxproj;共享源码与本地化是显式引用。

### 发布物料(截图/商店图/上传用图标)

**不入库,流程与踩过的坑记在本地运营手册**(`docs/STORE-OPS.md`,gitignore 中,
仅本机可见)。仓库内只需记住:`*/dist/` 与 `*/store/` 下的东西永远不要 `git add`。
**换版时界面动过就要整套重拍,并与 `dist/` 里那份 release 包同批重建 kit** —— 判据见硬规矩 20。

---

## 硬规矩

下面每一条都对应一次真实事故。违反的代价不是风格问题,是返工或线上故障。

### 1. 包里有 / 没有,以解包 grep 为准

```bash
# Android 唯一那份,当前期望(H205 / 1.0.8):功能全开,所以四项都非 0
unzip -l dist/reverb.apk | grep -icE 'lib/|assets/sensevoice/'         # 非 0(4:两个 .so + 模型 + 词表)
unzip -l dist/reverb.apk | grep -cE 'assets/seed_podcasts\.json'       # 非 0(1)
unzip -l dist/reverb.apk | grep -cE 'assets/radio_stations\.json'      # 非 0(1;1.0.9 起的电台精选)
unzip -p dist/reverb.apk classes.dex | LC_ALL=C grep -ao 'itunes.apple.com\|fyyd\|gpodder' | wc -l  # 非 0(13,4/5/4)
unzip -p dist/reverb.apk classes.dex | LC_ALL=C grep -ao 'radio-browser\.info' | wc -l  # 非 0(1.0.9 电台目录地址,至少 1)
"$SDK/build-tools/<ver>/aapt2" dump permissions dist/reverb.apk | grep -cE 'RECORD_AUDIO|REQUEST_INSTALL_PACKAGES|ACCESS_LOCAL_NETWORK'   # 非 0(3;Android 17 起)
# HarmonyOS 商店包:模型、词表与识别库都在**嵌套的 entry-default.hap** 里 ——
# 直接对 dist/reverb.app grep 这两条会恒得 0(2026-11-13 实测,外层 .app 里只有一个 .hap 条目),
# 那不是"包里没有",是"查错了容器"。先解一层,清单落文件再数(H272:`grep -q` 直连管道会假阴性)。
T=$(mktemp -d); unzip -o -q dist/reverb.app '*.hap' -d "$T"
unzip -l "$T/entry-default.hap" > "$T/hap.list"
grep -cE 'rawfile/sensevoice/(model\.int8\.onnx|tokens\.txt)' "$T/hap.list"   # 非 0(2)
grep -cE 'libs/arm64-v8a/lib(sherpa|onnxruntime)' "$T/hap.list"               # 非 0(3)
grep -cE 'rawfile/radio_stations\.json' "$T/hap.list"                          # 非 0(1;1.0.9 起的电台精选)
rm -rf "$T"
```

合并前这一节写的是 store 渠道的「native / 模型 / 录音权限应为 0」,那组期望随 H205 一起翻转。
所以更要跑的是**降级档那一侧**:把 `CATALOG` / `SPECTRUM` / `HAS_ENGINE` 降到 `false` 出的包,
上面四项要按降级口径重新数一遍 —— 现在它是**一条命令改常量的事,不再是两份 source set**,
更容易改完不验。

这里的方法论是「声明加回来也要验、声明删掉也要验」,不是把某组期望值永久写死。
产品决策翻转时,grep 的期望值也会翻转(见 H70),并且必须同步 `docs/FEATURES.md`。

**上面那条 `aapt2` 在开发机上不在 PATH**(只有 `adb` 在;`sdk.dir` 读 `android/local.properties`)。
2026-10-07 实测:写成 `aapt2 dump permissions … 2>/dev/null | grep -c …` 时命令**根本没跑**,
`grep -c` 对着空 stdin 报 **0**,于是两个渠道都被读成「没有录音权限」—— 而自分发渠道实际是有的。
所以期望 0 的判据**必须先看那条命令自己的退出码和处理量**(权限清单打印出来数过行数再谈 0),
同理适用于任何"命令不存在 ≠ 没命中"的工具(现象与排查顺序记在 `docs/TROUBLESHOOTING.md` H156)。

⚠️ **同一种「空 stdout」还有第三个来源:参数根本没被拆成多个文件名。**
本会话的 shell 是 **zsh,而 zsh 不对未加引号的变量做词分割**(bash 会)——
所以 `grep -ac "$w" $FILES` 会把一百多个路径当成**一个**超长文件名去 open,错误写进 stderr,
再被 `2>/dev/null` 吃掉 ⇒ 整批复扫报 **0**,看起来正好是「已清零」
(2026-10-23 踩过:九个词全 0,真值是 17 / 29 / 12 处)。三条固定动作:
①清单落文件、走 `< /tmp/list.txt xargs grep`(**BSD xargs 没有 `-a` 选项**);
②报任何 0 之前先跑一条**必然非 0 的阳性对照**;③一次性复扫写成 `/tmp/x.sh` 用 `bash` 跑,别贴进交互 shell。
逐字复现与第三种同形来源记在 H206。

**中文字符串必须用 `LC_ALL=C grep -a` 搜原始字节** —— `resources.arsc` / `resources.index`
里的中文不是 ASCII,`strings` 看不见,曾因此差点得出错误结论。

### 2. 「编译期开关能删代码」不能跨工具链类推

Kotlin/R8 会折叠常量并删掉整支;**ArkTS 没有 DCE**,`Features.X ? A : B` 两支都会进包。
鸿蒙要做到「包里真的没有」,只能**把代码移出编译树**(见 `harmony/shelved/`)。

### 3. R8 删不掉 `.so` 与 assets

native 库与模型是构建系统按 source set 打进包的,R8 只折叠代码分支。合并 flavor 之后这两样
都在 `app/src/main/`(`jniLibs/arm64-v8a/libonnxruntime.so` + `libsherpa-onnx-jni.so`、
`assets/sensevoice/model.int8.onnx` + `tokens.txt`、`assets/seed_podcasts.json`),
所以**把 `AsrFactory.HAS_ENGINE` 降到 `false` 并不会让那 239 MB 模型与 26.9 MB native 库从包里消失** ——
它只是让界面与调用路径不再用它。真要做到「包里没有」,只能把文件本身移出构建树
(`tools/build-asr.sh` 负责放进来,`.gitignore` 已遮住)。

### 4. 修完 bug 或性能问题,必须更新 `docs/TROUBLESHOOTING.md`

格式固定:**现象 / 根因 / 修法 / 教训与可复用的规律**。编号连续递增、**不复用**(H1、H2、…);
条数不写进任何文档 —— 它每修一个 bug 就变,写了必漂(见 H63 教训 5)。
这是本仓库最有价值的文档,不要跳过。

### 5. 改功能就会让「自述」过期 —— 有一张必须同步的清单

功能一改,下面这些地方会**同时失真**,而且最容易漏的是 App 内那一处:

| 位置 | 说明 |
|---|---|
| **App 内关于页**(`about_p_features` / `about_p_philosophy`) | 会被逐字读到;Android 合并成一份包后只有一套(合并前是两套,见 H205) |
| 设置项标题与副标题 | 副标题常含「为什么/代价」,行为一改就不成立 |
| `docs/PRODUCT.md` + `docs/FEATURES.md` | 同一件事的叙述版与矩阵版,**两份都要改** |
| `docs/PRIVACY.md` + `site/reverb/privacy.html` + 同意页正文 | 涉及权限/网络/数据用途时 |
| **官网首页正文**(`site/reverb/index.html` 的 figcaption、能力清单、「获取」那一节) | 口径翻转最容易漏在这里:文案里是**人话**不是标识符(合并后残留的「完整版」就是这么留下的,见 H207)。硬规矩 20 那条只管到 `shots/` 张数与 `alt`,管不到句子本身 |

**五个语种一起改**:简中 / 繁中 / 英 / 法 / 西。
**但三端的「五套」形态不一样,别按一个数去找文件**:Android 与鸿蒙是**每个语种一套**
(`res/values-<locale>/strings.xml` / `resources/<locale>/element/string.json`,都是 5 份);
**macOS 只有 4 套** —— `macos/Localization/{en,es,fr,zh-Hant}.lproj/Localizable.strings`,
**简中是基础语言**(键名本身就是简体中文原文,没有 `zh-Hans.lproj`)。
所以 macOS 加一条文案 = 改代码里的默认串 **+ 4 个 `.strings`**,加起来才是五个语种;
只按「找 5 个文件」改,会把简中那一份漏在代码里。
已经栽过两次的具体坑:**繁体那条其实是简体**、**es/fr 整段还是英文** —— 两端都犯过。
改完用脚本体检一遍:`python3 tools/check-l10n.py`(2026-11-13 起入库)。它查**键集相等**、
**繁体文件里的简体独有字**、**非中文文件里的汉字**(备案号与品牌名白名单);退出码 1 即有问题。
刻意不拿"值是否等于英文"当判据 —— Anime / Bilibili / Auto / Version 这类同形词在 es/fr 里本来就一样,
那会制造误报(`-v` 只把它们列出来给人看)。

**撇号在两端不是同一种写法**(见 H191):Android 是 XML,法语那类撇号**必须**写 `\'`;
鸿蒙 `resources/*/element/string.json` 是 **JSON**,`\'` 是**非法转义**(构建会 exit 255,
但提示写的是"检查逗号",别被带走),撇号**直接写 `'`**。
而 JSON 里 `\\'` 是**合法**的、构建不拦,解出来就是一个上屏的反斜杠 —— 抄文案时最容易留下这个。
所以改完资源先跑一次严格 `json.load`(与 restool 同一判据、给精确行列号),再看渲染侧的反斜杠数。

### 6. 不要在渲染路径里做解析

播放页观察播放器,**播放中 500ms 一次 tick 就重渲一遍**。
早先每次重渲都把几十 KB 的 shownotes HTML 重跑十道正则 —— 轻则 CPU 长期高位,重则卡死。
**每秒会跑两次的代码,要按每秒两次来估成本。**
同一条规矩的算法是「**调用次数 × 每次成本**」:一个 O(N) 的查找函数本身不算贵,把它放进渲染路径里
**每个列表项各调一次**就变成 O(N²)(逐字稿页踩过,见 H137)。鸿蒙还有一层硬限制:
**ArkUI 的 `@Builder` / `build()` 体内不能声明局部变量**(实测 `10905209 Only UI component syntax
can be written here`),所以"顶层算一次存进变量再往下传"这个从 Kotlin/Swift 惯用的形状在本端不存在 ——
可选的只有三条:存字段(要管失效)、写成每元素 O(1) 的判据、按硬规矩 7 下沉成最小组件用 `@Prop` 传值。

### 7. 高频变化的状态不要挂在被整体观察的对象上(鸿蒙)

**ArkUI V1 的观察粒度是对象,不是字段,而且不区分 private。** `@Observed` 类上任何字段被赋值,
所有 `@ObjectLink` / `@State` 持有者都会重跑 `build()`。曾因 `positionMs = t`
(AVPlayer 的 `timeUpdate` 约 100ms 一次)让播放中每秒重建整页十次 —— 实测 10 秒 62 帧 jank(H64)。

判据不是"界面用不用这个字段",而是**"它多久变一次"**。一秒变多次的量放进普通对象
(`playback/PlaybackClock.ets`),需要它的界面**各自按自己需要的频率轮询**,并把高频刷新
**下沉到最小的组件**(进度条独立成 `SeekBar`,而不是重渲整个播放页)。

### 8. 「异步」只保证等待不阻塞,不保证计算不阻塞(鸿蒙)

ArkTS 没有协程,**没有 `withContext(Dispatchers.IO)` 这种一行搬走的办法**。
`await` 回来之后的同步计算照样占满调用线程:一个 8.5 MB / 1026 集的 RSS,
`XmlPullParser` 回调 + 每集一遍 `htmlToText` 实测 **1833ms**,一轮 15 源刷新约 4.5 秒占着 UI 线程(H65)。

重解析要走 `@Concurrent` + `taskpool`(现成例子:`net/FeedTask.ets`,连网络一起搬进子线程,
并保留回落本线程的降级)。**去抖也要连"生成数据"一起去抖** —— 只去抖写盘而每次都
`JSON.stringify` 等于没解决(用 `JsonFile.writeJsonDebouncedLazy`)。

### 9. 不要用「程序化操作也会触发的信号」识别用户操作

`isScrollInProgress`、`onValueChange` 这类分不清是谁干的。
逐字稿的自动滚动曾因此把自己判成「用户在滚」,净效果是每 4 秒才跳一下。
要用只有人能产生的事件(`DragInteraction` / `onTouch`)。

### 10. 时间轴/序列的不变式在数据出口保证,不在渲染侧兜底

渲染找「当前句/当前词」用的是「从后往前找第一个 `startMs <= now`」,
**只在起点单调不减时才正确**。队尾一个异常小的值就会让高亮钉死不动。
所以在数据出口一次性保证「≥0 且单调」(`SenseVoiceEngine.wordsFrom`、`TranscriptLines.monotonic`)。

### 11. 持久化数据的口径变了,就得加版本号

改了时间轴算法之后,用户设备上已生成的稿仍按旧口径显示 —— 界面无从分辨,
于是「修了等于没修」,而用户也没有清缓存的入口自救。
`TranscriptStore.CACHE_VERSION` 一变,旧稿自动作废重转。

### 12. 装包验证自己直接装 —— 不用问;要卸载才装的话,release 包先备份

用户 2026-10-16 明确授权:**代码改完之后只要这一步需要装机验证,代理自己装,整个过程不问**。
分三种情形:

| 情形 | 怎么做 |
|---|---|
| 签名相同(绝大多数) | **覆盖安装**:`adb install -r` / `hdc install -r`,数据天然留着,装完直接继续验证 |
| 必须卸载再装,**debug 包** | 直接卸载再装,不必备份 —— debug 那份里的数据本来就是夹具 |
| 必须卸载再装,**release 包** | **先备份 → 卸载 → 安装 → 启动后恢复备份 → 再继续验证**(步骤见下) |

**release 包那一轮的具体步骤**(只有签名不符、`install -r` 被拒时才需要):
1. 应用内「设置 → 完整备份」导出 JSON(SAF;建议名 `reverb-backup.json`,`SettingsScreen.kt:488`),
   落到公共目录后收到本机 —— Android `adb pull /storage/emulated/0/Download/reverb-backup.json`,
   鸿蒙 `hdc file recv`。**收到之后先 `wc -c` 断言非 0,再谈卸载。**
   ⚠️ **不要走 `adb backup`**:清单里 `allowBackup="true"` 是配合 `dataExtractionRules` / `backup_rules`
   故意限制过备份内容的,拿到的一份不等于应用自己的「完整备份」(后者才是跨端互通的格式)。
2. `adb uninstall` / `bm uninstall` → 装新包 → 启动。
3. 应用内「恢复备份」把第 1 步那份 JSON 导回去,核对订阅数与设置分区都回来了,**再继续验证**。
4. 报告里写明这一轮做过卸载与恢复(备份文件留在本地,别删)。

⚠️ **卸载等于丢数据**,这一条不因为"不用问"而消失 —— 授权改的是"要不要问",备份改的是"会不会丢"。
2026-10-06 那次就因为没先备份就 `bm uninstall`,在架 release 包的数据随卸载没了。

⚠️ 原来这一条写的是「装机前先问」,起因是覆盖安装把正在听播客的进程杀掉
(`reason=16 PACKAGE UPDATED`),而它**看起来像崩溃**、被误查了很久。现在授权变了,但那条知识不变,
换了形态:**装之前不需要等屏幕空闲**(播放态本来就会跨启动恢复),
**装之后要把 `PACKAGE UPDATED` 按"是我装的"读**,别把它记成一次 crash 现场。
同一条读法适用于 `pidof` 变空、`mCurrentFocus` 跳到桌面 —— 先 `dumpsys` 里认更新原因,再决定要不要查代码。
**签名材料仍然在授权之外**:keystore / 口令 / `build-profile.json5` 签名段一律不改。

### 13. 不要摆未获批的法定标识 —— 也不要照抄自己预写的那个值

监管要求的展示号(备案号等)在未获批时**不显示任何号**(注释块里备好、通过后启用)。
陷阱在于:**注释里预写的号也是猜的** —— 曾经按序列推测预写了一个值,实际下发的
是另一个;若直接取消注释就上线,摆出去的是一个**不存在的号**,比不摆更糟。
**结论:预写的是格式与位置,不是值。值一律以下发的凭证为准。**
(本项目的号及其两套序列关系,记在本地运营手册,不在此文。)

### 14. 构建缓存/日志绝不入库 —— 它们会把口令复制一份进去

`harmony/.hvigor/` 的 sync/cache **内嵌整份签名配置(含口令)**,曾因此让 release 签名口令
进了 43 个历史提交(私钥本体没进,但口令等于作废,见 H63)。
忽略规则要写成**全层级**(`.hvigor/` 而不是 `/.hvigor`)。

扫描泄露时:**不要只扫敏感文件名,要拿真实口令串去搜全历史** ——
按文件名只会找到配置文件,按串才会发现缓存也带着它。

### 15. 个人身份信息不入版本管理 —— 而且要逐项判断

分发登记类材料曾整份入库,理由写的是"证书指纹可从任何已发布安装包提取,不是机密"。
这句话对**指纹**成立,但同一份文件里还有**登记主体真名**与**平台证书标识**,
它们从 APK 里提不出来(Android 证书主体是 `CN=Yuyin Reverb`)—— 于是一个正确的理由
被当成了整份文件的通行证(见 H68)。

判断标准别问"它算不算机密",问 **"公开它以后能不能反查到一个具体的人"**。
这类材料只留本地(`.gitignore`),**删文件前先确认知识有别的落点**。

**法定展示的备案号本身保留**:它必须在 App 关于页显示,属公开信息。

### 16. 大产物不入版本管理

SenseVoice 模型(239,233,841 B)、词表、sherpa-onnx 的 `classes.jar` 与两个 `.so` 由
两端的 `tools/build-asr.sh` 各自备齐(固定上游版本 + 校验 sha256;鸿蒙那份还会按 sha256
从同机 Android 目录直接拷贝);`harmony/entry/src/main/resources/rawfile/sensevoice/`、
`harmony/entry/.cxx`、`dist/`、`build-profile.json5`(含签名口令)都在 `.gitignore` 里。

### 17. 「系统有这个 API」不等于「这个 API 能干这件事」

鸿蒙的 Core Speech Kit 接口形状完全对得上(喂 PCM、出文本),但它的离线档是给**短语音输入**
设计的,拿长音频转写实测 10 分钟只出 14 行碎片。**这种判断只能靠真机跑真实素材。**
(1.0.8 已改用 sherpa-onnx;这条教训保留,它解释的是"为什么当初不接系统能力"。)

### 18. 看不见中间值的问题,先造能看见的工具

逐字稿时间轴对不对,在真机上完全看不出来。whisper 时代为此写了主机端探针
(与线上同参数打印每个 token 的时刻),真相用**切片法**定(把音频截到 1.0 / 1.3 秒分别识别,
看第几个字还在里面)。换 sherpa-onnx 后那个探针随 whisper 一起删了,但**方法不变**:
2026-11-11 的选型实测就是先在主机上用同参数跑同一段 3 分钟素材,再上真机。
在此之前靠现象猜原因,错了两次。

### 19. 分发运营物料不入版本控制 —— changelog 例外入库

发布用的文案、上传图标、商店截图、物料包 —— 与签名材料同待遇,
**一律本地留存**(`*/store/`、`*/dist/` 都在根 .gitignore 与各端 .gitignore 里)。

为什么统一切出去而不是逐个判断:这些物料"逐个审"迟早出错 —— 截图里是真实收听数据,
文案和图标混着发布身份;而它们对读代码的人本来就没有价值。真正对外的信息另有出口:
版本变更写 **`CHANGELOG.md`(入库,是对外版本说明的上游)**,
隐私与合规写 `docs/PRIVACY.md`,迁移与本地资产清单写 `docs/LOCAL-ASSETS.md`。

---

### 20. 发布单位只有一个:各端 `dist/` 里那份**最终 release 包** —— 且界面变了要整套重拍截图

不管去处是鸿蒙应用市场、GitHub Releases 上的 Android apk / macOS dmg,还是 TestFlight 的 iOS ipa,
**拿出去的必须是那次 release 构建的产物**:不是 debug 包,不是 `*/build/outputs/` 里的中间产物,
也不是上一版留在 `dist/` 的旧包。各端的位置与"这就是发布物"的判据(跑命令,不是看构建日志):

| 端 | 发布物 | 判据 |
|---|---|---|
| Android | `android/dist/reverb.apk`(**唯一那份**,大陆商店与 GitHub Releases 传同一个文件) | `./build-release.sh`;脚本里已用 `apksigner` 读证书 DN,**是调试证书就 exit 1**(不是"verify 通过"就算数)。版本再对 `CHANGELOG.md`:`aapt2 dump badging` —— 注意 **aapt2 不在开发机 PATH**(H156),用 `$SDK/build-tools/<ver>/aapt2` 全路径,且"命令没跑成"和"版本不对"要按退出码分开读。⚠️ 重打前按 H204/H205 归档在架那份的 mapping |
| HarmonyOS | `harmony/dist/reverb.app` **+ `reverb-symbol.zip`**(符号包一并传,否则市场侧还原不了崩溃栈) | `build-release.sh` 末尾那条 `debugKey` 断言(命中即 exit 1);`reverb-unsigned.app` **只是备查,别传** |
| macOS | `macos/dist/余音-Reverb-<版本>-universal.dmg`(架构标记由 `EXPECTED` 推导,不是写死);Release 上的资产名是 **`Reverb.dmg`**(应用内更新按这个名字挑) | `./package.sh` 的架构硬断言(缺一个架构就不出 dmg);**`…-1.0.2-arm64.dmg` 那种单架构历史包不能顶替** —— Intel Mac 装 arm64 没有退路 |
| iOS | `ios/dist/reverb-ios-<版本>-<构建号>.ipa`(TestFlight 上传的就是它) | `./build-ios.sh --export` 的验收段:版本/构建号与工程设置一致、4 套 `.lproj` 集合相等、后台音频、内置物料、图标、arm64;**ipa 解包后 `embedded.mobileprovision` 必须在、`codesign --verify` 必须过**。⚠️ 构建号每次上传递增,同名/同号会被 TestFlight 拒 |

**报"包已就绪"要带出处**:那份文件的字节数与 `ls -lT` 时间戳,并说明它**晚于最后一次源码改动**
(`find android/app/src shared/seed \( -name '*.kt' -o -name '*.xml' -o -name '*.json' -o -name '*.py' \) -newer android/dist/reverb.apk`
列出来的必须为空。**括号不能省** —— 省了 `-newer` 只作用在第一个 `-name` 上,其余两类文件全被放过,
判据会假绿。鸿蒙把 `android/app/src` 换成 `harmony/entry/src`、产物换成 `harmony/dist/reverb.app`。)
这不是格式要求,是防"代码改了、包没重打" —— 那件事真发生过并被判过多次(见 H154 那轮"包比码旧"),
而 `dist/` 里躺着旧包时它**看起来是就绪的**。
iOS 的源码面是 `ios/Reverb` **加上**共享的 `macos/Sources/Reverb/{Data,Playback}`,
`-newer` 判据要把两边都列进去;只列 `ios/Reverb` 会放过共享层的改动。

**界面布局一变,同一轮的截图整套重拍,发布侧跟着换。**
商店图(`*/store/`,不入库)与官网首页引用的 `site/reverb/shots/*.jpg`(同样不入库,部署时手工上传)
是**同一批取景的两条出口**,所以只更新一侧就是自相矛盾 —— 线上首页会替你说出一句过期的话。
两个容易漏的点:①**底栏 / 主导航这类改动会让所有含底栏的截图同时过期,不是只有首页那一张**;
②重拍之后要对着 `site/reverb/index.html` 里 `<img src="shots/…">` 的**张数与 `alt`** 核一遍 ——
它等于在对外声明"顶层有几个入口",与硬规矩 5 的自述同步是同一件事。
流水线(1080×1920 直出会被拒收、深浅要 `cmd uimode night` 成对开关、数据用净化备份)与逐版记录,
在 `docs/STORE-OPS.md` 三 与七;上传仍是**逐个文件 + 先 `--dry-run` + 三方 SHA-256 验收**(同文六)。

---

## 仓库地图

只列"改这个功能该去哪"。三端同名概念尽量同名,便于对照着改。

### Android(`android/app/src/main/java/com/yuyin/reverb/`)

| 目录 | 职责 | 典型任务 |
|---|---|---|
| `data/model/` | `Podcast` / `Episode` / `FeedResult` | 加字段 —— 注意与另两端的备份格式互通 |
| `data/remote/` | `ITunesSource` · `AppleChartsSource` · `FyydSource` · `GpodderSource` · `RssParser` · `OpmlSupport` · `TranscriptFetcher` · `PodcastRepository`(编排 / 降级) | 换源、调降级顺序 |
| `data/local/` | 每个功能域一个 JSON store:`SubscriptionStore` / `HistoryStore` / `InboxStore` / `ListenStatsStore` / `TranscriptStore` / `BackupManager` … | 加持久化字段(要动 `CACHE_VERSION`,硬规矩 11) |
| `playback/` | `PlaybackService`(MediaSessionService)· `PlayerController`(门面 / StateFlow)· `playback/asr/` | 播放链路、选源次序(下载 → 缓存 → 流式) |
| `ui/screens/` | 各页面 | 界面改动 → 截图整套重拍(硬规矩 20) |
| `ui/components/` | 复用组件(`Components.kt` 1 444 行,已偏大) | 加通用控件 |
| `ui/share/` | 剪藏与足迹海报 | 分享图 |
| `cast/` | 自研 DLNA 投播:`CastController`(应用级状态机)· `SsdpDiscovery`(M-SEARCH + MulticastLock)· `DlnaClient`(SOAP AVTransport)· `CastDevice`;弹层在 `ui/screens/CastDialog.kt` | 投播链路;设备描述用 DOM 解析(JVM 单测里 XmlPullParser 是 stub) |
| `ui/screens/RadioScreen.kt` + `data/local/StationStore.kt` + `data/remote/RadioBrowserSource.kt` | 直播电台 tab:我的电台账本 / 在线目录检索 / 随包精选(`assets/radio_stations.json`) | 电台字段与另三端同形;只进手动备份,不进局域网同步 |
| `update/` | WorkManager 订阅巡检 + 新集通知 + 应用内更新(`SelfUpdate`,合并后商店那份也带,见 H205) | 后台刷新、更新检查 |
| ~~`app/src/{default,store}/`~~ | **已删除**(2026-10-18 合并 flavor,H205) | 渠道差异不再由 source set 承载;要降级改 `src/main` 里那三个常量 |
| `android/tools/` | `build-asr.sh` · `glass-shot.sh` · `play-button-check.sh` | ASR 产物、截图、播放键几何 |

### HarmonyOS(`harmony/entry/src/main/ets/`)

| 目录 | 职责 |
|---|---|
| `view/` | 21 个页面与组件(`DiscoverPage` 1 416 行、`Components` 1 438 行) |
| `store/` | 21 个 JSON store,与 Android `data/local/` 一一对应;`JsonFile` / `JsonTask` 是底座 |
| `net/` | `Sources` / `PodcastRepository` / `RssParser` / `FeedTask`(`@Concurrent`)/ `Http` / `RadioBrowserSource` … |
| `playback/` | `PlayerController` / `PlaybackClock`(高频时钟,硬规矩 7)/ 投播用系统 `AVCastPicker`(挂在 `view/PlayerPage.ets`) |
| `update/` · `backup/` · `theme/` · `util/` · `model/` | 对应 Android 同名职责 |
| `view/RadioPage.ets` + `store/StationStore.ets` | 直播电台 tab:账本 / 目录检索 / 随包精选(`rawfile/radio_stations.json`) |
| `harmony/shelved/` | **移出编译树**的代码 —— ArkTS 没有 DCE,只能这么"真的没有"(硬规矩 2) |

### macOS(`macos/Sources/Reverb/`)

`AppEnvironment` · `ReverbApp` · `RootView` · `Data/` · `Playback/` · `UI/`。
「电台」页与投播:`UI/RadioView.swift` · `UI/RoutePickerView.swift`(`AVRoutePickerView` 包装)· `Data/StationStore.swift` · `Data/RadioBrowserSource.swift`;iOS 直接编译同一批共享层文件。
缺口清单见 `docs/MACOS-GAPS.md` —— **盘 macOS 与手机端的一致性先看这份,别重新 grep 一遍。**

### iOS(`ios/Reverb/`)

| 目录 | 职责 |
|---|---|
| `App/` | `ReverbApp`(启动 / 隐私门)· `AppEnvironment`(依赖容器)· `RootView`(五格 Tab:发现 / 电台 / 追更 / 音阁 / 设置 + 迷你播放条) |
| `UI/` | 发现 / 电台 / 追更 / 音阁 / 设置 / 播放页 / 频道详情 / 逐字稿 / 队列 / 关于 / 同意页 / 主题组件;`RoutePickerView.swift` 是 AirPlay 按钮 |
| `../Localization/` | 4 套 `.lproj`(简中是基础语言,键名即简中) |
| `../Resources/` | 种子清单、引导音频、电台精选(`radio_stations.json`;由 `shared/*/sync.sh` 分发) |

**数据与播放层不在这个目录**:它直接编译 `macos/Sources/Reverb/{Data,Playback}`。
工程细节、TestFlight 流程与本机现状表见 `docs/IOS.md`。

### 其它

| 路径 | 职责 |
|---|---|
| `shared/guide/` | 引导音频 + 脚本(`make-guide.sh`),分发到各端 |
| `shared/seed/` | 种子清单(规范副本;`sync.sh` 分发到 Android + macOS + iOS,**不含鸿蒙**,理由写在脚本头) |
| `shared/radio/` | 内置精选电台 16 条(规范副本;`sync.sh` 分发到**四端**资源,`--check` 供提交前校验;合规口径与种子播客不同,见脚本头) |
| `site/reverb/` | 官网 + 隐私页;`shots/` **不入库**,部署时手工上传 |
| `marketing/<版本>/` | 宣传物料(宣传片 / 封面 / 配乐),流水线见 `marketing/README.md` |
| `tools/check-l10n.py` | 五语种资源体检(硬规矩 5):键集相等、繁体用字、非中文含汉字;全绿 exit 0 |

## 版本与发版

### 版本号一共四处,没有单一来源

| 端 | 文件 | 字段 | 当前值(2026-11-11,1.0.8 开发中) |
|---|---|---|---|
| Android | `android/app/build.gradle:38-39` | `versionCode` / `versionName` | `9` / `1.0.8` |
| 鸿蒙 | `harmony/AppScope/app.json5:5-6` | `versionCode` / `versionName` | `1000008` / `1.0.8` |
| macOS | `macos/Info.plist:29-32` | `CFBundleShortVersionString` / `CFBundleVersion` | `1.0.8` / `5` |
| iOS | `ios/Reverb.xcodeproj/project.pbxproj` | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `1.0.8` / `2` |

**四处必须手改,漏一处不会有任何东西报错。** 改完用这条核:

```bash
grep -nE 'versionCode|versionName' android/app/build.gradle harmony/AppScope/app.json5
grep -nA1 -E 'CFBundleShortVersionString|CFBundleVersion' macos/Info.plist
grep -nE 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' ios/Reverb.xcodeproj/project.pbxproj
```

⚠️ **iOS 的构建号(TestFlight build number)每次上传必须递增**,版本名可以不变;
同号会被 App Store Connect 拒。只这一轮覆盖用 `BUILD_NUMBER=2 ./build-ios.sh --upload`,
长期仍要回写工程里的 `CURRENT_PROJECT_VERSION`。

⚠️ **macOS 落后一版是常态,不是遗漏。** 1.0.5 那轮用户拍的端范围是 Android + 鸿蒙,
桌面端零改动,所以 `Info.plist` 停在 1.0.4 并在 `CHANGELOG` 里写明。
**但只要这一轮动了 macOS 源码,就必须同步改** —— 否则用户看到的版本号与代码不符,
而"四端共用一套版本节奏"这句承诺就没有任何东西在守。

⚠️ **合并 flavor 那一轮(10-18)故意把版本停在 `6` / `1.0.5` 没升** —— 那是为了拿合并包与在架的
default 包做资源差分(必须同版本才可比,判据见 H205)。**这份 `dist/reverb.apk` 与 GitHub Releases
上那个 1.0.5 字节不同**(资源侧等价、签名与构建时间不同)。
所以 **1.0.6 起必须先 `7` / `1.0.6` 再出包** —— 否则同一 tag 下资产同名 `reverb.apk` 会互相顶掉,
而应用内更新按名字挑(H203)。

### 发版顺序(固定)

1. **先定 `CHANGELOG.md`** —— 它是对外文案的唯一上游(硬规矩 19);
2. 各端出包:Android / 鸿蒙 `build-release.sh`,macOS `package.sh`,iOS `build-ios.sh --export`
   (TestFlight 还要 `--upload`);
3. 按硬规矩 20 做**解包验收 + mtime/SHA 判据**,不是看构建日志;
4. 界面动过 → 截图整套重拍 → 商店图与官网 `shots/` 是**同源两条出口,两侧都要换**;
5. 部署官网 → 上传商店 / GitHub Releases(**Releases 传的是公开分发仓 `revert-cast`,不是本机 git remote
   那个私有 `reverb`** —— 传错边,应用内更新就查不到新包,见「仓库的对外边界」与 H203)。
   资产名沿用 `reverb.apk` 与 `Reverb.dmg`(两端都按名字挑,不是取 `assets[0]`;漏传 dmg 的后果见上一节 ⚠️);
   **传完必查两条**:`gh api repos/cxyxlxdm/revert-cast/releases/latest --jq .tag_name` 要等于新版本号
   (指针真的移过来了),`--jq '.assets[0].digest'` 要等于本地 `shasum -a 256` 那份(上传没换字节)。
   多端同发时逐项核:`--jq '.assets[] | "\(.name) \(.size) \(.digest)"'` 的条目数 = 本轮上传件数,别只看第一条。

**回滚预案见 `docs/ROLLBACK.md`**(2026-11-13 落文,`REVIEW-2026-10-18.md` P0 第 7 条至此有正文)。
一句话口径:**回滚 = 用旧代码出一个版本号更高的包**,不是把版本号退回去 —— 四端都只对"更高版本"提示更新,
商店与 TestFlight 也只收更高 versionCode / build number。该文按渠道写了取件处、动作与验收,
并如实标注了"真正回滚一次"尚未演练。

⚠️ "上一版包在 `dist/` 里留着"这句**两端都得改写**(2026-10-18 清理备份时逐字节核过,并当场踩掉一份不可再生的东西):

- **Android(合并后只有那一份 apk)**:自分发那一侧的上一版包本身就在公开分发仓的 release 上,资产自带 sha256,
  所以"留着"的正确形态是**能取到 + 能证明它是那一版**,不是在 `dist/` 多存一份 65 MB 的旧 apk。核对:
  `gh api repos/cxyxlxdm/revert-cast/releases/tags/<上一版> --jq '.assets[]|"\(.name) \(.size) \(.digest)"'`
  与本地那份 `shasum -a 256` 比 —— **digest 相等才叫"外面有一份一样的",字节数相等不算**(同日实测有两个包同为
  64 958 828 B 而 sha256 不同,见 `docs/TROUBLESHOOTING.md` H154 那轮)。
  ⚠️ **但大陆商店那一侧的上一版只能回市场侧取** —— 公开仓上那个 apk 是**自分发口径**构建的,
  与交给商店的那份不是同一个文件(合并前是两个 flavor,合并后是同一份包但**分发处各存一份历史**)。
  而**它的 mapping 本地只此一份**,`build-release.sh` 重打时会 `rm -f` 顶掉(H205 的坑 3,已归档)。
- **鸿蒙**:release 的 `.app` 与 `reverb-symbol.zip` 是 `dist/` 里的**同名文件,每次重打直接覆写**,
  所以"上一版"在本地只可能活在归档里 —— 而归档往往是 **kit zip** 形态,**那份 zip 里就内嵌 `.app` 与符号包**
  (判据:`unzip -l <kit>.zip` 数得见 `reverb.app` / `reverb-symbol.zip` 两个条目)。
  ⚠️ **10-18 那次清理把在架鸿蒙 1.0.4 那份包与符号的本地唯一副本删了**(在
  `harmony/dist/_backup-shots-1012/reverb-harmony-submission-kit.zip` 内),本地已取不回来,只能回市场侧;
  **身份没丢** —— 那两份的 SHA-256 完整串只在本地 `docs/STORE-OPS.md` 七(10-12 那轮;本文不入库,换机必须带走),
  取回后按串核验即可。**教训与判据见 `docs/TROUBLESHOOTING.md` H204:kit zip 不是"素材",按发布物待遇核。**
- **崩溃栈还原**认的是**"符号包与那次构建同批"**,与工作区 git 里那份 namecache 不是一回事(见 H154 补记)。

**清 `*/dist/` 备份时,只有两类东西能删**(其余一律留):
① 与别处(现役 `dist/` 或公开仓 release)**逐字相同**的副本 —— 判据是 md5/sha256 相等,不是文件名、不是字节数;
② **从未分发出去**的中间构建(包 + 它的 mapping) —— 判据是那份包体的 sha256 与 release 上任何一个 tag 都不等,
且它对应的版本号已被后续构建取代。
**在野版本的 mapping 与它所在的那份 kit zip 要留** —— 鸿蒙的在野包就藏在 kit zip 里,按目录名当素材清掉就是事故(H204)。

## 代码风格

看几个现有文件就能感受到,这里的风格与常见项目不同,请沿用:

- **注释写「为什么」,不写「做了什么」。** 代码本身能说清做了什么;
  值钱的是"为什么这么写"和"曾经怎么写错的"。
- **注释用中文**,可以很长。关键决定用一整段解释,并引用 `TROUBLESHOOTING` 编号(如 `见 H60`)。
- **踩过的坑写在最近的代码旁边**,不只写进文档 —— 后来者改这行时才看得见。
- 数据结构上的**不变式要显式写出来**(例:`TranscribedWord` 那条「各条 text 拼接 == 整句」)。
- 四端字段命名与文件名尽量一致(缓存/备份格式互通),不一致的地方要注明。

**提交信息**也是中文,并且:写清**为什么**、**验收方式**,以及**没做完的部分**。
参考近期提交 —— 每条都说明了动机、影响面与遗留项。

---

## 工作节奏

- **完成一段任务就提交**,不要攒一大坨。提交信息按上面的要求写。
- **改完能编译的要编译一遍**;改了产物要重打包并解包核对(尤其动那三个降级常量的时候)。
- **发版时先更新 `CHANGELOG.md`** —— 它是对外版本说明的上游(硬规矩 19)。
- 报告结果要如实:失败就贴输出,跳过的步骤要说明。
  这个项目的文档里刻意保留了「已知问题」「没验过的路径」——同样的诚实标准适用于对话。

---

## 验证:单测 + 按端自证

**现状说清楚:有单元测试(只测纯逻辑),没有 UI 测试,没有 CI。** 三套单测覆盖的正是
四端**共享判据** —— 同一份订阅在四端显示的日期、同一段 shownotes 的清洗结果、同一份逐字稿
的时间轴不变式、直播流入口判定:

| 端 | 命令 | 判据 |
|---|---|---|
| Android(`app/src/test`) | `cd android && ./gradlew :app:testDebugUnitTest` | `app/build/test-results/testDebugUnitTest/*.xml` 里 failures / errors 都为 0。⚠️ AGP 9 起无 `testReleaseUnitTest`(只建 debug 单测变体),别按旧任务名跑后把"任务不存在"当失败(见 H282) |
| 鸿蒙(`entry/src/test`) | `export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk && /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw test --mode module -p product=default -p buildMode=debug --no-daemon` | `entry/.test/default/intermediates/test/coverage_data/test_result.txt` 末行 `Failure: 0, Error: 0`。⚠️ 断言失败时 hvigor **仍打 BUILD SUCCESSFUL**,别拿退出码当判据 |
| Swift 共享层(`macos/Tests/ReverbTests`,iOS 直接编译同一批源码) | `cd macos && swift test` | XCTest 汇总 exit 0 |

`macos/tools/selftest-verify.sh` 仍然只验打包断言脚本本身;单测也验不了界面与播放 ——
所以"改完了"这个结论还要靠下面这张表按端挣出来,而且**必须按端说,不能互相顶替**:

| 改了什么 | 最小自证 | 不够的 |
|---|---|---|
| Android 任意 Kotlin | `:app:testDebugUnitTest` 全绿 + `./gradlew :app:compileReleaseKotlin -q` exit 0(合并 flavor 后只有一份 release,H205;AGP 9 下 debug 单测与 release 同源码,见 H282) | 只跑编译 |
| Android 界面 / 播放 / 缓存 | 上面 + **装机跑一遍**对应路径 | 只看编译通过 |
| 降级档相关(动 `CATALOG` / `SPECTRUM` / `HAS_ENGINE`) | 上面 + **解包 grep**(硬规矩 1)。**合并前这一行写的是「渠道裁剪相关」——渠道没了,但这条自证更严了:降级现在只是一行常量,改完不验包就没人拦得住** | 只改代码不验包 |
| 鸿蒙任意 `.ets` | `hvigorw test` 全绿 + `assembleHap` BUILD SUCCESSFUL | 只跑 IDE 预览 |
| 鸿蒙界面 / 播放 | 上面 + **debug hap 装机** | 只编译 |
| 新增 native 类型包 | 上面 + `ohpm install` | 漏了报 `arkts-no-any-unknown`(H61) |
| macOS 任意 Swift | `swift test` 全绿 + **整模块 typecheck,改前改后都必须是 0 错误** | "改前改后都是同样 4 条"**证明不了**其余文件被检查过(H128) |
| iOS 任意 Swift(含共享层) | `swift test`(共享层)+ `cd ios && ./build-ios.sh` exit 0(编译门不需要证书)+ 产物判据;同改 `macos/Sources/Reverb/{Data,Playback}` 时 macOS 侧也要过 | 只跑模拟器变体 / 只看编译通过 |
| iOS 界面 / 播放 / 后台 | 上面 + **模拟器(或真机签名包)实跑**对应路径 | 只编译;本机 2026-11-02 只跑过模拟器,真机未跑 |
| 文档 | 数字与条数用 `grep -c` 现算 | 凭印象写"18 条" |

**三条附加规矩:**

1. **"编过了"不等于"验过了"。** 涉及行为的改动,报告里要写清跑到哪一步、哪一步没跑。
2. **规则类改动(缓存淘汰 / 时间轴 / 备份格式)必须留一条真机判据。**
   1.0.5 的缓存那批就是反面样本:代码与注释齐备,断网实跑一条没走。
3. **阳性对照。** 断言"这里没问题"时,先往里面注入一个已知错误,确认它**会**报出来 ——
   否则那个"没问题"不成立(硬规矩 1 与 H128 指向的是同一件事)。

## 文档写作规矩

文档是本仓库最大的资产,也是目前最大的负债(17 份 / 1.68 MB)。下面几条是为了不让它继续膨胀:

1. **一条知识只写一次,其它地方写编号。** 例如"缓存 300 MB 淘汰"只写在 `FEATURES.md`,
   代码注释里写 `见 docs/FEATURES.md 缓存一节`,不要复制一段。
2. **单个 `.md` 不超过 100 KB。** 超了就拆,原位置留一行指针。
   现在 `TROUBLESHOOTING.md`(880 KB)与 `ROADMAP.md`(335 KB)已超,是待拆项。
3. **状态汇报用表格,不用散文。** `ROADMAP.md` 平均每行 334 字节,意味着大量单段数千字的叙述 ——
   这类内容三个月后只有作者本人能读懂。
4. **`CHANGELOG.md` 是内部账本,不是对外文案。** 它含"一条没走""未验过"这类内部措辞,
   不能直接发给用户;对外版本说明要单独一份(见 `docs/REVIEW-2026-10-18.md` P1 第 13 条)。
5. **不要在任何文档里写"共有 N 条"这类可变量**(硬规矩 4 已有此训)。硬规矩条数、H 条目数、
   文件行数都属于这一类 —— 要写就写"用 `grep -c` 现算"。
6. **新增文档必须进 `## 文档地图`**,否则等于没写。

## 文档地图

| 文档 | 内容 |
|---|---|
| `README.md` | 入口与索引 |
| `docs/PRODUCT.md` | 功能介绍(叙述,面向使用者/评审) |
| `docs/FEATURES.md` | 功能清单(矩阵,**精确对照以这份为准**) |
| `docs/ARCHITECTURE.md` | 核心技术实现(分层、播放、持久化、渠道与降级闸、native、性能规律) |
| `docs/TRANSCRIPT.md` | 逐字稿专篇(三端取字方式与取舍,含鸿蒙换引擎的迁移路径) |
| `docs/TROUBLESHOOTING.md` | **踩坑记录**:现象/根因/修法/可复用的规律 |
| `docs/HISTORY.md` | 开发历程(顺序与因果,返工写得更详细) |
| `docs/ROADMAP.md` | 进度、遗留问题、演进方向(**含「没验过的路径」清单**) |
| `docs/MACOS-GAPS.md` | **macOS 缺口清单**:Android 与鸿蒙已实现、桌面端缺什么(每条带代码落点与成本)+ 口径漂移 + **不该移植的项** + 建议顺序。盘手机端与桌面端的一致性时先看这份,别重新 grep 一遍 |
| `docs/IOS.md` | **iOS 端**:为什么现在有(边界变更)、与 macOS 的共享层、工程结构、编译门、TestFlight 前置条件与流程、本机现状(模拟器与真机界面/播放已跑,**签名身份与真机安装已通,TestFlight 受免费团队所限未跑**)、排障 |
| `docs/research/*.md` | **调研原文 + 顶部提炼的 TODO**(每份 = 提炼结论 + `---` + 照抄原文)。**状态一律是"未开工、等拍板"**,拍板前别按文中的技术方案动手 |
| `CHANGELOG.md` | 版本变更记录(发版时追加;对外版本说明的上游) |
| `docs/RELEASE-NOTES.md` | **对外版本说明**(可直接发给用户;每版一段,只写新增功能与修复的 bug,不写验收状态与内部措辞) |
| `docs/LOCAL-ASSETS.md` | **本地资产与换机迁移**(哪些东西不在 git 里、新机怎么完整重建) |
| `docs/ROLLBACK.md` | **回滚预案**:什么算该回滚、"用旧代码出更高版本"的口径、各端上一版从哪取、四个渠道的分步动作、回滚包验收与数据兼容、未演练项 |
| ~~分发运营物料~~、~~`*/store/`~~ | **不入版本控制**(硬规矩 19)。清单与换机流程见 `docs/LOCAL-ASSETS.md` |
| `docs/PRIVACY.md` | 隐私政策(与 `reverb/privacy.html` 必须同步) |
| `docs/REVIEW-2026-10-18.md` | **一次性的项目体检**:规模基线、做对了什么、不足与优先级 TODO;含同日**复校记录**(12 处失准的订正,3.4 与文末校准表)。**看"当前处在什么位置"看这份,看"要做什么"看 ROADMAP** ⚠️ 其中"当前值/当前状态"类句子随时会漂,按文中给的命令重跑 |
| `docs/REVIEW-2026-10-25.md` | **一次性的代码体检(捉虫)**:四路审查的 bug 清单(高 3 / 中 10 / 低 6 族,基线 HEAD `8fcf3c7`)+ 四个系统性模式 + 方向增量;§6 有修复跟踪表可回填。⚠️ 行号是当日快照,修复时以引文内容定位;**修掉一条就回填一条状态,别攒**。**10-25 已全部回填**(全条 ✅ 已修 / 三条订正 / 族 F-3 待拍板),§7 写清"只过编译门、零装机、三端 dist 未重打";踩坑归口 H212–H214 |
| `marketing/README.md` | 宣传物料流水线(改文案 → 重渲染 → 重编码,一条命令) |

**动手之前**:改逐字稿看 `docs/TRANSCRIPT.md`;改渠道口径 / 那三个降级常量看 `docs/FEATURES.md`
渠道差异一节 + `docs/ARCHITECTURE.md` 第六节;不确定某个坑踩过没有,先 grep 一遍 `docs/TROUBLESHOOTING.md`。

## 会话记忆

`~/.agent-memory/…` 那套路径**在本机不存在**(2026-10-18 核过),原先指向它的两行已废弃。现在的落点:

- **项目级**:`<repo>/.workbuddy-ai/memory/MEMORY.md`(长期约定)+ `YYYY-MM-DD.md`(当日工作日志,只追加)
- **全局偏好**:由工具层在会话开始时自动注入,不需要在这里列路径,也不要手改

**写什么**:跨会话仍然成立的事实 —— 用户定死的边界(如"macOS 出包在另一台机器")、
新确立的约定、踩过且已修完的坑的结论。
**不写什么**:临时路径、一次性搜索结果、当天就能从代码里读出来的东西。

## 仓库的对外边界

⚠️ **先分清两个仓库,这件事上一版本文写错了**(2026-10-18 复校更正。判据是匿名 `curl` 的 HTTP 码,
不是靠文档互证 —— 同一个判据已记在 `docs/TROUBLESHOOTING.md` H144 的 2026-10-08 补记里):

| 仓库 | 可见性 | 装什么 |
|---|---|---|
| `github.com/cxyxlxdm/reverb` = **本机 git remote** | **私有**(匿名 API 404) | 全部源码与文档 —— 就是你在读的这个仓库 |
| `github.com/cxyxlxdm/revert-cast` | **公开** | 只有 `README.md` + **Releases**(Android `reverb.apk` 与 macOS `Reverb.dmg` 的分发处;1.0.1 / 1.0.2 放过 dmg,1.0.3~1.0.5 断过三版,1.0.6 起恢复每版都带 dmg —— 见下一段的后果)。Android 应用内更新查的就是它的 `releases/latest` —— **latest 是哪版别抄文档,现算**:`gh api repos/cxyxlxdm/revert-cast/releases/latest --jq .tag_name` |

⚠️ **macOS 那份 dmg 不是附带物,是 macOS 应用内更新的唯一来源**(2026-11-13 核对:1.0.3 起的「只传 apk」写法已过时,
按它出包会让 macOS 端从此查不到新版本,而且**没有任何报错** —— `SelfUpdate.swift` 在 release 列表里找
`name == "Reverb.dmg"` 的资产,找不到就跳过整条 release,用户侧表现是「已是最新」)。
自检:`gh api repos/cxyxlxdm/revert-cast/releases/latest --jq '.assets[].name'` 里必须同时有
`reverb.apk` 与 `Reverb.dmg`。1.0.6 起两端都恢复上传;1.0.3~1.0.5 那三版缺 dmg 是事实,别回头补传 ——
它们对应的 macOS 包本来就没发出去。

**iOS 的出口是 TestFlight,不是这两个仓库**:iOS 包不作为安装来源出现在 GitHub Releases 或 `site/` 下载页;
`ios/dist/*.ipa` 的正常去处是上传 App Store Connect。**1.0.7 有一处已发生的例外**:
该版把未签名归档件 `reverb-ios-1.0.7-1-unsigned.ipa` 也挂上了 release(理由与读数见 `CHANGELOG.md` 1.0.7 发版记录)——
它是**归档,不是安装路径**(未签名,`codesign` 直接判 unsigned,侧载也装不上),别在官网/README 里当下载项引用。
往后再挂不挂由维护者拍,不按「上次挂过」自动类推。
TestFlight 链接本身也不是公开下载地址,由维护者在 App Store Connect 里邀请测试员。

**两个都没有 `LICENSE` 文件。** 所以缺口的正确表述不是"公开仓库没证书",而是:
**对外发出去的东西(安装包 + 那个公开仓)没有任何许可声明** —— 用户装了包,法律上却没被告知能装、能备份、能转发到什么程度。
这是已知缺口(`docs/REVIEW-2026-10-18.md` P0 第 8 条),在它被决定之前:

- 不要把"开源"当成既定事实写进任何对外文案;
- 引用代码、给外部人看片段之前,先确认维护者的意图(代码仓私有,这层本来就要问);
- **别把公开仓当备份镜像往里推源码** —— 它的定位是分发页,不是代码出口。
