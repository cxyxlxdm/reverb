# AGENTS.md — 在本仓库工作的约定

> 给编码代理(以及第一次接手的人)看的操作手册。**内容以本文为准**;
> `CLAUDE.md` 只是指向这里的薄指针,不重复内容。
>
> 本文只写「怎么在这个仓库里干活」。产品与实现的知识在别处,见文末文档地图。

---

## 这是什么

**余音 · Reverb** —— 一款播客客户端,三个原生端:

| 目录 | 端 | 技术栈 |
|---|---|---|
| `android/` | Android | Kotlin / Jetpack Compose |
| `harmony/` | HarmonyOS | ArkTS / ArkUI |
| `macos/` | macOS | Swift / SwiftUI |
| `shared/` | 共享物料 | 图标、种子清单、引导音频(脚本分发到各端) |
| `site/` | 个人主页 + 余音官网与隐私政策页(`site/reverb/`) | 静态 HTML |

**四条不可动摇的约束**(所有设计的上游):

1. **零后端。** 没有服务器、没有账号、没有云同步、**没有任何上传数据的代码路径**。
2. **不接任何第三方 SDK。** 系统能力不算三方。分享一律走系统分享。
3. **合规是设计输入。** 隐私同意门与渠道功能隔离在架构层面体现,不是界面上加判断。
4. **包里有 / 没有,都必须可验证。** 声明某渠道包含或不含某功能,验收方式是**解包 grep**。

Android 有**两个渠道**(`default` 自分发 / `store` 大陆商店),功能范围不同;
鸿蒙只有商店渠道;macOS 自分发。差异见 `docs/FEATURES.md`「渠道差异」。

---

## 常用命令

### Android

```bash
cd android
./build-release.sh                 # 自分发渠道  → dist/reverb.apk(≈64 MB,含语音模型)
./build-release.sh --store         # 大陆商店渠道 → dist/reverb-store.apk(≈3.9 MB)
# 只想过编译(快):
./gradlew :app:compileDefaultReleaseKotlin :app:compileStoreReleaseKotlin -q
# 备齐离线识别的两样产物(不入版本管理,缺了打包会报错退出):
./tools/build-asr.sh [--force]
# 主机端探针:用与 JNI 同参数跑 whisper,打印每个 token 的时刻
./tools/asr-probe/run.sh [音频文件]
adb install -r dist/reverb-store.apk
```

### HarmonyOS

```bash
cd harmony
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
HV=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw
# debug hap(装机调试用)
$HV assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
# 发布包
./build-release.sh [--fast]        # → dist/reverb.app + reverb-symbol.zip
```

`hdc` 在 `$DEVECO_SDK_HOME/default/openharmony/toolchains/`。
**新增 native 类型包(`.so` 的 `index.d.ts`)之后必须跑一次 `ohpm install`**,
否则类型解析成 `any`、报 `arkts-no-any-unknown`(症状很误导,见 H61)。

### macOS

```bash
cd macos
swift build -c release             # 只编译
./package.sh                       # 编译 → .app → ad-hoc 签名 → dmg(无需 Xcode GUI)
```

> ⚠️ **这两条命令在开发机(本文写作时那台)跑不起来**:只有 Command Line Tools
> (Swift 5.7.1 / macOS 12.7.6 / SDK 13.1),而 `macos/Package.swift` 声明
> `swift-tools-version:5.9` + `.macOS(.v13)` ⇒ SwiftPM 直接版本门挡回,且没有 macOS 14 SDK
> (`TranscriptPage.swift` 的双参数 `onChange` 要它)。**出包要在装了 Xcode 15+ 的机器上做。**
> 这台机器上能做的最强验收是**整模块 typecheck 并与改前基线差分**:
> `swiftc -typecheck -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macos13.0 $(find Sources -name '*.swift')`
> —— 基线用 `git archive HEAD macos | tar -x -C /tmp/…` 解一份出来单独跑,再逐条比对错误集;
> **只说"错误没变多"是不够的,要同时说明它证明不了什么**(界面与行为一帧都没跑起来)。见 H124。

### 发布物料(截图/商店图/上传用图标)

**不入库,流程与踩过的坑记在本地运营手册**(`docs/STORE-OPS.md`,gitignore 中,
仅本机可见)。仓库内只需记住:`*/dist/` 与 `*/store/` 下的东西永远不要 `git add`。

---

## 硬规矩

下面每一条都对应一次真实事故。违反的代价不是风格问题,是返工或线上故障。

### 1. 包里有 / 没有,以解包 grep 为准

```bash
# Android 大陆商店渠道当前期望(H70):目录接口非 0;native / 模型与录音权限仍为 0
unzip -l dist/reverb-store.apk | grep -icE 'lib/|whisper-model'              # 0
LC_ALL=C cat classes*.dex | grep -ac 'itunes.apple.com\|fyyd\|gpodder'       # 非 0
aapt2 dump permissions dist/reverb-store.apk | grep -c RECORD_AUDIO         # 0
# HarmonyOS 商店包当前同样应能 grep 到目录接口 URL(非 0)
```

这里的方法论是「声明加回来也要验、声明删掉也要验」,不是把某组期望值永久写死。
产品决策翻转时,grep 的期望值也会翻转(见 H70),并且必须同步 `docs/FEATURES.md`。

**中文字符串必须用 `LC_ALL=C grep -a` 搜原始字节** —— `resources.arsc` / `resources.index`
里的中文不是 ASCII,`strings` 看不见,曾因此差点得出错误结论。

### 2. 「编译期开关能删代码」不能跨工具链类推

Kotlin/R8 会折叠常量并删掉整支;**ArkTS 没有 DCE**,`Features.X ? A : B` 两支都会进包。
鸿蒙要做到「包里真的没有」,只能**把代码移出编译树**(见 `harmony/shelved/`)。

### 3. R8 删不掉 `.so` 与 assets

native 库与模型是构建系统按 source set 打进包的。渠道要「没有」它们,
只能靠那个 source set 里压根没有这些文件(`app/src/default/jniLibs`、`app/src/default/assets`)。

### 4. 修完 bug 或性能问题,必须更新 `docs/TROUBLESHOOTING.md`

格式固定:**现象 / 根因 / 修法 / 教训与可复用的规律**。编号连续递增、**不复用**(H1、H2、…);
条数不写进任何文档 —— 它每修一个 bug 就变,写了必漂(见 H63 教训 5)。
这是本仓库最有价值的文档,不要跳过。

### 5. 改功能就会让「自述」过期 —— 有一张必须同步的清单

功能一改,下面这些地方会**同时失真**,而且最容易漏的是 App 内那一处:

| 位置 | 说明 |
|---|---|
| **App 内关于页**(`about_p_features` / `about_p_philosophy`) | 会被逐字读到;Android 需按渠道分别写 |
| 设置项标题与副标题 | 副标题常含「为什么/代价」,行为一改就不成立 |
| `docs/PRODUCT.md` + `docs/FEATURES.md` | 同一件事的叙述版与矩阵版,**两份都要改** |
| `docs/PRIVACY.md` + `reverb/privacy.html` + 同意页正文 | 涉及权限/网络/数据用途时 |

**五个语种一起改**:简中 / 繁中 / 英 / 法 / 西。
已经栽过两次的具体坑:**繁体那条其实是简体**、**es/fr 整段还是英文** —— 两端都犯过。
改完用脚本体检一遍(繁体文件里不该出现简体独有字;非中文文件不该以英文原句开头)。

### 6. 不要在渲染路径里做解析

播放页观察播放器,**播放中 500ms 一次 tick 就重渲一遍**。
早先每次重渲都把几十 KB 的 shownotes HTML 重跑十道正则 —— 轻则 CPU 长期高位,重则卡死。
**每秒会跑两次的代码,要按每秒两次来估成本。**

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
所以在数据出口一次性保证「≥0 且单调」(C++ 侧 `tidyWords`、`TranscriptLines.monotonic`)。

### 11. 持久化数据的口径变了,就得加版本号

改了时间轴算法之后,用户设备上已生成的稿仍按旧口径显示 —— 界面无从分辨,
于是「修了等于没修」,而用户也没有清缓存的入口自救。
`TranscriptStore.CACHE_VERSION` 一变,旧稿自动作废重转。

### 12. 装机前先问

不要在用户可能正在使用时覆盖安装 —— 曾因此让应用在用户听播客时被系统杀掉
(`reason=16 PACKAGE UPDATED`),而当时被误判成崩溃查了很久。

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

whisper 的 `.so`(1.6 MB)与模型(57 MB)由 `tools/build-asr.sh` 重建(固定 commit + 校验 sha256);
`harmony/entry/.cxx`、`dist/`、`build-profile.json5`(含签名口令)都在 `.gitignore` 里。

### 17. 「系统有这个 API」不等于「这个 API 能干这件事」

鸿蒙的 Core Speech Kit 接口形状完全对得上(喂 PCM、出文本),但它的离线档是给**短语音输入**
设计的,拿长音频转写实测 10 分钟只出 14 行碎片。**这种判断只能靠真机跑真实素材。**

### 18. 看不见中间值的问题,先造能看见的工具

逐字稿时间轴对不对,在真机上完全看不出来。为此写了主机端探针
(`android/tools/asr-probe/`,与 JNI 同参数打印每个 token 的时刻),
真相用**切片法**定(把音频截到 1.0 / 1.3 秒分别识别,看第几个字还在里面)。
在此之前靠现象猜原因,错了两次。

### 19. 分发运营物料不入版本控制 —— changelog 例外入库

发布用的文案、上传图标、商店截图、物料包 —— 与签名材料同待遇,
**一律本地留存**(`*/store/`、`*/dist/` 都在根 .gitignore 与各端 .gitignore 里)。

为什么统一切出去而不是逐个判断:这些物料"逐个审"迟早出错 —— 截图里是真实收听数据,
文案和图标混着发布身份;而它们对读代码的人本来就没有价值。真正对外的信息另有出口:
版本变更写 **`CHANGELOG.md`(入库,是对外版本说明的上游)**,
隐私与合规写 `docs/PRIVACY.md`,迁移与本地资产清单写 `docs/LOCAL-ASSETS.md`。

---

## 代码风格

看几个现有文件就能感受到,这里的风格与常见项目不同,请沿用:

- **注释写「为什么」,不写「做了什么」。** 代码本身能说清做了什么;
  值钱的是"为什么这么写"和"曾经怎么写错的"。
- **注释用中文**,可以很长。关键决定用一整段解释,并引用 `TROUBLESHOOTING` 编号(如 `见 H60`)。
- **踩过的坑写在最近的代码旁边**,不只写进文档 —— 后来者改这行时才看得见。
- 数据结构上的**不变式要显式写出来**(例:`TranscribedWord` 那条「各条 text 拼接 == 整句」)。
- 三端字段命名与文件名尽量一致(缓存/备份格式互通),不一致的地方要注明。

**提交信息**也是中文,并且:写清**为什么**、**验收方式**,以及**没做完的部分**。
参考近期提交 —— 每条都说明了动机、影响面与遗留项。

---

## 工作节奏

- **完成一段任务就提交**,不要攒一大坨。提交信息按上面的要求写。
- **改完能编译的要编译一遍**;改了产物要重打包并解包核对(尤其渠道相关)。
- **发版时先更新 `CHANGELOG.md`** —— 它是对外版本说明的上游(硬规矩 19)。
- 报告结果要如实:失败就贴输出,跳过的步骤要说明。
  这个项目的文档里刻意保留了「已知问题」「没验过的路径」——同样的诚实标准适用于对话。

---

## 文档地图

| 文档 | 内容 |
|---|---|
| `README.md` | 入口与索引 |
| `docs/PRODUCT.md` | 功能介绍(叙述,面向使用者/评审) |
| `docs/FEATURES.md` | 功能清单(矩阵,**精确对照以这份为准**) |
| `docs/ARCHITECTURE.md` | 核心技术实现(分层、播放、持久化、渠道隔离、native、性能规律) |
| `docs/TRANSCRIPT.md` | 逐字稿专篇(三端取字方式与取舍,含鸿蒙换引擎的迁移路径) |
| `docs/TROUBLESHOOTING.md` | **踩坑记录**:现象/根因/修法/可复用的规律 |
| `docs/HISTORY.md` | 开发历程(顺序与因果,返工写得更详细) |
| `docs/ROADMAP.md` | 进度、遗留问题、演进方向(**含「没验过的路径」清单**) |
| `CHANGELOG.md` | 版本变更记录(发版时追加;对外版本说明的上游) |
| `docs/LOCAL-ASSETS.md` | **本地资产与换机迁移**(哪些东西不在 git 里、新机怎么完整重建) |
| ~~分发运营物料~~、~~`*/store/`~~ | **不入版本控制**(硬规矩 19)。清单与换机流程见 `docs/LOCAL-ASSETS.md` |
| `docs/PRIVACY.md` | 隐私政策(与 `reverb/privacy.html` 必须同步) |

**动手之前**:改逐字稿看 `docs/TRANSCRIPT.md`;改渠道相关看 `docs/FEATURES.md` 渠道差异一节 +
`docs/ARCHITECTURE.md` 第六节;不确定某个坑踩过没有,先 grep 一遍 `docs/TROUBLESHOOTING.md`。

## 共享记忆

会话开始时读取：

- 全局偏好：`~/.agent-memory/global/MEMORY.md`
- 本项目记忆：`~/.agent-memory/projects/source-cast/MEMORY.md`

`projects/` 是 Claude Code 原生记忆的只读镜像，勿直接编辑（会被 sync 覆盖）。
