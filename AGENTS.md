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
| `reverb/` `site/` | 官网与隐私政策页 | 静态 HTML |
| `reverb-android/` `reverb/shots/` | 发布截图 | 原始 / 发布 / 官网三套 |

**四条不可动摇的约束**(所有设计的上游):

1. **零后端。** 没有服务器、没有账号、没有云同步、**没有任何上传数据的代码路径**。
2. **不接任何第三方 SDK。** 系统能力不算三方。分享一律走系统分享。
3. **合规是设计输入。** 隐私同意门与渠道功能隔离在架构层面体现,不是界面上加判断。
4. **「删掉」必须可验证。** 声明某渠道没有某功能,验收方式是**解包 grep**。

Android 有**两个渠道**(`default` 自分发 / `store` 大陆商店),功能范围不同;
鸿蒙只有商店渠道;macOS 自分发。差异见 `FEATURES.md`「渠道差异」。

---

## 常用命令

### Android

```bash
cd android
./build-release.sh                 # 自分发渠道  → dist/reverb.apk(≈64 MB,含语音模型)
./build-release.sh --store        # 大陆商店渠道 → dist/reverb-store.apk(≈3.9 MB)
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

### 截图(发布物料)

```bash
# 抓图:鸿蒙只能写 .jpeg,除非显式 -t png
hdc shell snapshot_display -t png -f /data/local/tmp/x.png && hdc file recv /data/local/tmp/x.png .
adb exec-out screencap -p > x.png
# 生成发布图:居中垫到 9:16,底色是 App 深色背景 #141E20
ffmpeg -i 原图.png -vf "pad=1575:2800:(ow-iw)/2:0:0x141E20" -pix_fmt rgba 发布图.png   # Android 1272×2800
ffmpeg -i 原图.png -vf "pad=1512:2688:(ow-iw)/2:0:0x141E20" -pix_fmt rgb24 发布图.png  # 鸿蒙 1216×2688
```

鸿蒙还有一套官网图:`ffmpeg -vf scale=407:900 -q:v 4` → `reverb/shots/web/*.jpg`。

---

## 硬规矩

下面每一条都对应一次真实事故。违反的代价不是风格问题,是返工或线上故障。

### 1. 渠道隔离的验收是解包 grep,不是点界面

```bash
# 大陆商店渠道:必须全为 0
unzip -l dist/reverb-store.apk | grep -icE 'lib/|whisper-model'
LC_ALL=C cat classes*.dex | grep -ac 'itunes.apple.com\|fyyd\|gpodder'
aapt2 dump permissions dist/reverb-store.apk | grep -c RECORD_AUDIO
```

**中文字符串必须用 `LC_ALL=C grep -a` 搜原始字节** —— `resources.arsc` / `resources.index`
里的中文不是 ASCII,`strings` 看不见,曾因此差点得出错误结论。

### 2. 「编译期开关能删代码」不能跨工具链类推

Kotlin/R8 会折叠常量并删掉整支;**ArkTS 没有 DCE**,`Features.X ? A : B` 两支都会进包。
鸿蒙要做到「包里真的没有」,只能**把代码移出编译树**(见 `harmony/shelved/`)。

### 3. R8 删不掉 `.so` 与 assets

native 库与模型是构建系统按 source set 打进包的。渠道要「没有」它们,
只能靠那个 source set 里压根没有这些文件(`app/src/default/jniLibs`、`app/src/default/assets`)。

### 4. 修完 bug 或性能问题,必须更新 `TROUBLESHOOTING.md`

格式固定:**现象 / 根因 / 修法 / 教训与可复用的规律**。当前 63 条,编号连续(H1…H63)。
这是本仓库最有价值的文档,不要跳过。

### 5. 改功能就会让「自述」过期 —— 有一张必须同步的清单

功能一改,下面这些地方会**同时失真**,而且最容易漏的是 App 内那一处:

| 位置 | 说明 |
|---|---|
| **App 内关于页**(`about_p_features` / `about_p_philosophy`) | 复核人员一定会读到;Android 需按渠道分别写 |
| 设置项标题与副标题 | 副标题常含「为什么/代价」,行为一改就不成立 |
| `PRODUCT.md` + `FEATURES.md` | 同一件事的叙述版与矩阵版,**两份都要改** |
| 发布文案 `*/store/发布文案.txt` | 两端各一份 |
| `PRIVACY.md` + `reverb/privacy.html` + 同意页正文 | 涉及权限/网络/数据用途时 |
| 发布截图 | 任何 UI/文案改动都会让它过期 |

**五个语种一起改**:简中 / 繁中 / 英 / 法 / 西。
已经栽过两次的具体坑:**繁体那条其实是简体**、**es/fr 整段还是英文** —— 两端都犯过。
改完用脚本体检一遍(繁体文件里不该出现简体独有字;非中文文件不该以英文原句开头)。

### 6. 不要在渲染路径里做解析

播放页观察播放器,**播放中 500ms 一次 tick 就重渲一遍**。
早先每次重渲都把几十 KB 的 shownotes HTML 重跑十道正则 —— 轻则 CPU 长期高位,重则卡死。
**每秒会跑两次的代码,要按每秒两次来估成本。**

### 7. 不要用「程序化操作也会触发的信号」识别用户操作

`isScrollInProgress`、`onValueChange` 这类分不清是谁干的。
逐字稿的自动滚动曾因此把自己判成「用户在滚」,净效果是每 4 秒才跳一下。
要用只有人能产生的事件(`DragInteraction` / `onTouch`)。

### 8. 时间轴/序列的不变式在数据出口保证,不在渲染侧兜底

渲染找「当前句/当前词」用的是「从后往前找第一个 `startMs <= now`」,
**只在起点单调不减时才正确**。队尾一个异常小的值就会让高亮钉死不动。
所以在数据出口一次性保证「≥0 且单调」(C++ 侧 `tidyWords`、`TranscriptLines.monotonic`)。

### 9. 持久化数据的口径变了,就得加版本号

改了时间轴算法之后,用户设备上已生成的稿仍按旧口径显示 —— 界面无从分辨,
于是「修了等于没修」,而用户也没有清缓存的入口自救。
`TranscriptStore.CACHE_VERSION` 一变,旧稿自动作废重转。

### 10. 装机前先问

不要在用户可能正在使用时覆盖安装 —— 曾因此让应用在用户听播客时被系统杀掉
(`reason=16 PACKAGE UPDATED`),而当时被误判成崩溃查了很久。

### 11. 不要摆未获批的备案号

站点登记未通过时,官网页脚**不显示任何号**(注释块里备好、通过后取消注释)。
注意 **APP备案号(`…号-1A`)与网站备案号(`…号-1`)是两套序列**,不能互相沿用。

### 12. 构建缓存/日志绝不入库 —— 它们会把口令复制一份进去

`harmony/.hvigor/` 的 sync/cache **内嵌整份签名配置(含口令)**,曾因此让 release 签名口令
进了 43 个历史提交(私钥本体没进,但口令等于作废,见 H63)。
忽略规则要写成**全层级**(`.hvigor/` 而不是 `/.hvigor`)。

扫描泄露时:**不要只扫敏感文件名,要拿真实口令串去搜全历史** ——
按文件名只会找到配置文件,按串才会发现缓存也带着它。

### 13. 大产物不入版本管理

whisper 的 `.so`(1.6 MB)与模型(57 MB)由 `tools/build-asr.sh` 重建(固定 commit + 校验 sha256);
`harmony/entry/.cxx`、`dist/`、`build-profile.json5`(含签名口令)都在 `.gitignore` 里。

### 14. 「系统有这个 API」不等于「这个 API 能干这件事」

鸿蒙的 Core Speech Kit 接口形状完全对得上(喂 PCM、出文本),但它的离线档是给**短语音输入**
设计的,拿长音频转写实测 10 分钟只出 14 行碎片。**这种判断只能靠真机跑真实素材。**

### 15. 看不见中间值的问题,先造能看见的工具

逐字稿时间轴对不对,在真机上完全看不出来。为此写了主机端探针
(`android/tools/asr-probe/`,与 JNI 同参数打印每个 token 的时刻),
真相用**切片法**定(把音频截到 1.0 / 1.3 秒分别识别,看第几个字还在里面)。
在此之前靠现象猜原因,错了两次。

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
- 报告结果要如实:失败就贴输出,跳过的步骤要说明。
  这个项目的文档里刻意保留了「已知问题」「没验过的路径」——同样的诚实标准适用于对话。

---

## 文档地图

| 文档 | 内容 |
|---|---|
| `README.md` | 入口与索引 |
| `PRODUCT.md` | 功能介绍(叙述,面向使用者/评审) |
| `FEATURES.md` | 功能清单(矩阵,**精确对照以这份为准**) |
| `ARCHITECTURE.md` | 核心技术实现(分层、播放、持久化、渠道隔离、native、性能规律) |
| `TRANSCRIPT.md` | 逐字稿专篇(三端取字方式与取舍,含鸿蒙换引擎的迁移路径) |
| `TROUBLESHOOTING.md` | **62 条踩坑**:现象/根因/修法/规律 |
| `HISTORY.md` | 开发历程(198 次提交的顺序与因果,返工写得更详细) |
| `ROADMAP.md` | 进度、遗留问题、演进方向(**含「没验过的路径」清单**) |
| `BEIAN.md` | 登记信息与流程(只记公开信息,不含私钥口令) |
| `PRIVACY.md` | 隐私政策(与 `reverb/privacy.html` 必须同步) |

**动手之前**:改逐字稿看 `TRANSCRIPT.md`;改渠道相关看 `FEATURES.md` 渠道差异一节 +
`ARCHITECTURE.md` 第六节;不确定某个坑踩过没有,先 grep 一遍 `TROUBLESHOOTING.md`。

## 共享记忆

会话开始时读取：

- 全局偏好：`~/.agent-memory/global/MEMORY.md`
- 本项目记忆：`~/.agent-memory/projects/source-cast/MEMORY.md`

`projects/` 是 Claude Code 原生记忆的只读镜像，勿直接编辑（会被 sync 覆盖）。
