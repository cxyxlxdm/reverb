# 本地资产与换机迁移(LOCAL-ASSETS)

> 这份文档回答两个问题:**哪些东西不在 git 里?换一台机器怎么把开发环境完整重建?**
>
> 背景:本仓库没有配置任何 git remote —— 这台机器上的 `.git` 是唯一副本。
> 而不入版本控制的东西不会跟着 `.git` 走。所以「换了台电脑」这件事的成败,
> 取决于是否照着第二节把不可重建的资产拷了过去。
>
> 上一次整机迁移:2026-08-31。当时的打包清单与加密传输流程写在根目录
> `MIGRATION.txt`(本地留存,不入库 —— 里面有机型/路径细节),搬箱照旧参考它;
> 本文是其「知识部分」的入库版,两者配合使用。

---

## 一、什么该入库、什么不该 —— 判据

两个维度组合判断(详细推演见 `MIGRATION.txt` 第二节):

| | **公开无害** | **公开有害** |
|---|---|---|
| **可重建** | 入库(源码、文档) | 用构建产物+脚本重建,不入库(whisper 模型) |
| **不可重建** | 视价值决定(通常是文档) | **本地留存**(签名、口令、身份信息) |

在此之上叠加一条 2026-09-20 定的统一口径(AGENTS.md 硬规矩 18):

> **所有与应用市场相关的资料一律不入版本控制;changelog 入库。**

发布文案、分发平台图标、发布截图、发布物料包属于运营物料而非代码资产,
逐项判断「这张图有没有收听数据、这段文案带不带身份」太费心且早晚出错,
所以整体划出去,与签名材料同待遇。changelog(`CHANGELOG.md`)是开发者文档,入库。

## 二、不可重建 —— 换机必须拷贝(丢了就没了)

| 资产 | 位置 | 说明 |
|---|---|---|
| **Android 签名** | `android/keystore.properties` + `android/app/reverb-release.jks` | 口令四项 + 私钥。丢了 = Android 端(尤其商店渠道)永远无法以同一身份更新 |
| **鸿蒙签名** | `harmony/signature/`(`reverb.p12` 私钥、`.cer`、`.p7b`、`.csr`)+ `harmony/build-profile.json5` | release 签名口令在 build-profile 里;模板 `build-profile.template.json5` 在库中,新机可 `cp` 后填,但 p12 无法再生 |
| **分发登记材料** | `docs/BEIAN.md`(被根 .gitignore 点名忽略) | 主体真名、分发平台证书标识、证书指纹、备案号;发布提交复核时照着填。口径与理由见 `docs/HISTORY.md` 阶段五 |
| **发布文案与 分发平台图标** | `harmony/store/`、`android/store/`(2026-09-20 起不入库) | 发布文案两语种版 + appicon-216/512/1024;改文案五语种同步的规矩不变(AGENTS.md 硬规矩 5) |
| **发布截图与 发布物料包** | `harmony/dist/store/`、`android/dist/store/`(1080×1920 终图)、原生分辨率中间图 `*/dist/store-masters/`、两套 kit 目录(`harmony/dist/harmony/`、`android/dist/android-store/`)及 kit zip | 截图可用真机重拍(可重建但代价大,需两台真机+深色模式流程);**至少把截图与 kit zip 拷走**,免去下次发布全套重拍 |
| **官网图** | `site/reverb/shots/`(4 张) | 由发布原图缩放而来,拷了原图可不拷;随 dist 一起拷最省心 |
| **历史迁移包** | 根目录 `MIGRATION.txt` | 上次迁移的打包/加密流程与机型细节;`reverb-migrate-secrets-*.tar.gz` 类密钥分包如仍存在,即签名材料的另一份拷贝 |

> 设备序列号、分发平台/开发者账号、cxyxl.cn 服务器的部署凭据等**只存在于本地**
> (MIGRATION.txt 与分发登记材料),不写进本文档 —— 仓库可能公开。

## 三、可重建 —— 不用拷,新机按说明重建

| 资产 | 重建方式 |
|---|---|
| whisper native 库 + 模型 | `cd android && ./tools/build-asr.sh`(固定 commit + sha256 校验;`build-release.sh` 打默认渠道前会检查在不在) |
| 构建缓存 | `.gradle`、`build`、`.cxx`、`.hvigor`、`oh_modules` —— 删了自动再生,永不拷贝 |
| `android/local.properties` | 打开 Android Studio 自动生成(只含 sdk.dir) |
| `harmony/build-profile.json5` | `cp build-profile.template.json5 build-profile.json5` 后填签名段(签名材料来自第二节) |
| 打包产物 | `android/build-release.sh` / `--store`、`harmony/build-release.sh`、`macos/package.sh` |

## 四、新机环境依赖

- **通用**:git、python3、ffmpeg(截图后处理与官网图)、adb(Android platform-tools)
- **Android 端**:JDK(Android Studio 自带)、Android SDK;`./gradlew` wrapper 已在库中
- **鸿蒙端**:DevEco Studio(内含 SDK、`hvigorw`、`ohpm`、`hdc`);
  `export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk`(AGENTS.md 常用命令一节)
- **macOS 端**:Swift 工具链即可;`package.sh` 用 codesign ad-hoc 签名,无需证书
- **真机**:商店渠道验证用 Android 真机 + 鸿蒙真机各一台(序列号见 MIGRATION.txt);
  `adb install -r` / `hdc install -r` 装包,**装机前先问**(硬规矩 12)

## 五、换机操作清单(按序执行)

1. **拷仓库本体**(含 `.git`;它是唯一历史副本)。到新机第一件事:再备份一份,或配个远端
2. **拷第二节全部资产**。口令类文件(jks/p12/keystore.properties)单独打包、加密传输,
   不要与代码包走同一渠道(流程见 MIGRATION.txt)
3. `cp harmony/build-profile.template.json5 harmony/build-profile.json5`,填入签名段
4. 按第四节装环境
5. 重建可重建产物:`./tools/build-asr.sh`
6. **三端构建验证**(都过 = 环境完整):
   - `cd android && ./build-release.sh --store && ./build-release.sh`(解包复核见硬规矩 1)
   - `cd harmony && ./build-release.sh`(签名通过 = 第二节材料齐)
   - `cd macos && swift build -c release && ./package.sh`
7. 装真机冒烟:订阅一档、播一集、看逐字稿;截图管线试拍一张(AGENTS.md「截图」)
