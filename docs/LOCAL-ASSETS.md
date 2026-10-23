# 本地资产与换机迁移(LOCAL-ASSETS)

> 这份文档回答两个问题:**哪些东西不在 git 里?换一台机器怎么把开发环境完整重建?**
>
> 背景(2026-10-23 改口,原句「本仓库没有配置任何 git remote —— 这台机器上的 `.git` 是唯一副本」
> 已不成立):远端是**私有仓** `git@github.com:cxyxlxdm/reverb.git`,16 条分支与 2 个标签都已在远端,
> 判据 `git log --branches --not --remotes --oneline | wc -l` = **0**(现算,别抄这句)。
> 标签的数法有个坑:那两条都是**轻量标签**(`git cat-file -t refs/tags/<t>` = `commit`),
> 所以 `git ls-remote --tags origin | grep -c '{}'` 恒为 **0** —— 看着像"远端没标签"。
> 要数就用 `grep -c 'refs/tags/'` 或 `git ls-remote --tags origin | wc -l`(本机 10-23 就这么错过一次)。
> **所以代码与历史不再是单副本 —— 但这句话不减轻本文其余部分的义务**:
> 第二节列的东西全部被 gitignore,它们**不跟 `.git` 走**,丢了仍然就没了。
> 「换了台电脑」的成败,取决于是否照着第二节把不可重建的资产拷了过去。
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
| **Android 签名** | `android/keystore.properties` + `android/app/reverb-release.jks` | 口令四项 + 私钥。丢了 = Android 端(尤其商店渠道)永远无法以同一身份更新。**同理:签名不可更换** —— 同包名换签名会让已装用户无法覆盖升级,唯一一次换签发生在 1.0.0 未到达用户的窗口(见 H82 前提) |
| **鸿蒙 release 签名** | `harmony/signature/`(`reverb.p12` 私钥、`.cer`、`.p7b`、`.csr`)+ `harmony/build-profile.json5` | release 签名口令**只**以加密串的形式存在于 build-profile 里;模板 `build-profile.template.json5` 在库中,新机可 `cp` 后填,但 p12 无法再生。⚠️ **build-profile.json5 会被 DevEco 的「自动生成签名」整段覆盖**(2026-09-26 就覆盖过一次,加密口令随之丢失,见 H123)—— 配好 release 段之后要**立刻连 material 一起备份一份**,别把它当"改坏了能重填"的普通配置 |
| **鸿蒙 release 口令的解密材料** | `harmony/signature/material/`(拷 `signature/` 时**必须连它一起拷**) | build-profile 里那串 `0000001B…` 是 DevEco 的**加密串**(AES-128-GCM),工作密钥由**与被签 keystore 同目录**的 `material/` 推出来:`fd` 三个 16 字节分量 XOR ⊕ 内置常量 → pbkdf2 以 `ac` 为 salt → rootKey → 解 `ce`(入口 `hvigor-ohos-plugin` 的 `getKeyStorePwd` → `DecipherUtil.decryptPwd(storeFile/..)`)。少了它 `SignHap` 报 `ENOENT …/signature/material`(00308018);**material 被换掉而密文没换**则报 `Signature material verification failed … unable to authenticate data`(00303242,authTag 不过)。**实测 material 是每个目录一套随机密钥**(与 `~/.ohos/config/material/` 逐文件比 sha256,五项全不同)⇒ 既不能从别处的 material 拼出来,也不会随重装 DevEco 复原。**留着加密口令、丢了 material = 口令作废**:2026-09-20 与 09-25 那两份口令备份就只拷了 build-profile 与 `signature/reverb.*`、没拷 `signature/material/`(全过程见 H123 第二轮)。**教训:密文与密钥是两件独立资产,必须同处、同批备份**。⚠️ 还有一条同样致命:**material 还原时只能整目录替换,不能与旧文件并排** —— hvigor 要求 `fd/0`、`fd/1`、`fd/2`、`ac`、`ce` **每个叶子目录恰好 1 个文件**,多一个就报 `00303121 Signing material error`(点名到 `material/fd/0`),而目录看起来完全正常。2026-09-29 出 1.0.3 市场包时就卡在这一步(全过程见 H123 第三轮);判定"密文与 material 是否同源"的可复现方法也在那条里(调 DevEco 的 `DecipherUtil.decryptPwd` 并配一份已知能签成的配置做对照)。本机现存的三套 material:`harmony/signature/material`(随签名走)、`~/.ohos/config/material`(自动签名)、`~/Library/Application Support/Huawei/DevEcoStudio26.0/options/data2/material`(IDE 自用) |
| **鸿蒙 release 签名的非机密参数**(填签名时照着核) | 本行;材料本身在 `harmony/signature/` | keyAlias = **`yuyin`**;三段材料用**相对路径** `./signature/reverb.{p12,p7b,cer}`(hvigor 按工程根归一化,换机器仍成立);profile 绑 `com.yuyin.reverb`、`"type":"release"` + `"app-distribution-type":"app_gallery"`、有效期至 2029-08。**这几项的用途是照着核对、不是照抄恢复**:签名材料一律由本人维护,代理不代填、不代改、不代回滚(H123 教训 ⑦)—— 2026-09-29 曾把这段整段回滚成 08-15 的旧密文,而旧 material 已被覆盖且全盘无副本,结果 release 报 00303242、debug 段因 storeFile 指向已被轮换掉的 .p12 报 00303107,两条路径一起失效,最终由本人重做签名材料才出包。代理只做只读校验:`build-release.sh` 里的三条前置卡口会核这三项并格,不合格直接退出。 |
| **鸿蒙调试签名** | `~/.ohos/config/default_*.{p12,cer,p7b}`(在用户目录,**不在工程目录** → 换机不会随工程拷过来) | 真机 `hdc install` 的唯一路:release 的 `.p7b` 是 `"type":"release"` + `"app-distribution-type":"app_gallery"`,不绑设备也不允许侧装。这目录没了,`assembleHap -p product=default` 会停在 `SignHap` 报 `Invalid storeFile value`。恢复:DevEco → File → Project Structure → Signing Configs → 勾「Automatically generate signature」并登录开发者账号,由它重新生成三个文件并回写 build-profile 的 default 段。**注意它绑 bundleName**:生成时工程用的是哪个包名,这套签名就只认那个包名 —— 为装机测试临时改过包名的话,改回来之后 `SignHap` 会报 `00303074 bundleName … does not match … SigningConfigs`,再点一次 Fix 重新生成即可。⚠️ **但「release 那套不受影响」这句原先写错了,现已更正**:自动签名弹窗里勾了 release 配置(或对 release 配置点 Fix)时,它会把 build-profile 的 **release 段一起改写**成新生成的 `~/.ohos/config/release_*` —— 那套是 `"type":"debug"` 且绑着临时测试包名,**既不能装机也不能提交市场**,而段里原来的加密口令被就地覆盖、找不回来(实测与全过程见 H123) |
| **分发登记材料** | `docs/BEIAN.md`(被根 .gitignore 点名忽略) | 主体真名、分发平台证书标识、证书指纹、备案号;发布提交平台时照着填。口径与理由见 `docs/HISTORY.md` 阶段五 |
| **发布文案与 分发平台图标** | `harmony/store/`、`android/store/`(2026-09-20 起不入库) | 发布文案两语种版 + appicon-216/512/1024;改文案五语种同步的规矩不变(AGENTS.md 硬规矩 5) |
| **发布截图与 发布物料包** | `harmony/dist/store/`、`android/dist/store/`(1080×1920 终图)、原生分辨率中间图 `*/dist/store-masters/`、两套 kit 目录(`harmony/dist/reverb-harmony-submission-kit/`、`android/dist/reverb-store-submission-kit/`)及同名 kit zip | 截图可用真机重拍(可重建但代价大,需两台真机+深色模式流程);**至少把截图与 kit zip 拷走**,免去下次发布全套重拍 |
| **官网图** | `site/reverb/shots/`(4 张) | 由发布原图缩放而来,拷了原图可不拷;随 dist 一起拷最省心 |
| **在野版本的崩溃栈还原材料** | 本次发布物在 `*/dist/` 根;**上一版只在别处** —— Android 完整版在公开分发仓的 release(资产自带 sha256),鸿蒙在分发平台侧。本地额外只留 `android/dist/_backup-1.0.4-preRebuild-1015/reverb-mapping.txt`(42 376 254 B,公开仓 tag 1.0.4 那份包的 R8 mapping;同字节的 apk 已删,外面那份逐字相同) | ⚠️ **2026-10-18 清 `*/dist/` 备份时,把在架鸿蒙 1.0.4 的 `.app` + `reverb-symbol.zip` 的本地唯一副本删了** —— 它藏在 `harmony/dist/_backup-shots-1012/reverb-harmony-submission-kit.zip` 里(**kit zip 内嵌发布物,不是素材**)。那两份的 SHA-256 **完整的串只剩本地 `docs/STORE-OPS.md` 七**(10-12 那轮 kit 那段)—— 原本并列为落点的 `harmony/store/上架文案.md` 第三节已被 1.0.5 的哈希覆写,**这一串随 `STORE-OPS.md` 一起走,而它不入库 ⇒ 换机没带走就断了**。从平台侧取回后按串核验即可。**换机时这一档只能回平台侧取,别指望本地有** —— 判据与教训见 H204。**另存一份在 `~/Documents/cast-backup-20260925/STORE-OPS-20261018.md`**(10-18 那一刻的快照;同样不入库,但与工程目录分处两地)—— ⚠️ **它不随工作区自动更新**,要用时先核:`md5 -q docs/STORE-OPS.md ~/Documents/cast-backup-20260925/STORE-OPS-*.md` 两个串相等才算数,不等就以工作区那份为准并重拷 |
| **历史迁移包** | 根目录 `MIGRATION.txt` | 上次迁移的打包/加密流程与机型细节;`reverb-migrate-secrets-*.tar.gz` 类密钥分包如仍存在,即签名材料的另一份拷贝 |
| **与工程分处的本地快照(只剩一份)** | `~/Documents/cast-backup-20260925/`(瘦身前 226 MB → 10-23 实测 **59 MB**:cast-full 48 MB + 两个 bundle + 两份处置清单 + STORE-OPS 快照)。另一份 `cast-backup-20261012/` **已经不存在了** —— 10-18 整目录移进废纸篓,10-23 实测工程侧目录与 `~/.Trash/` 两处都查不到(`ls -d` 均报 No such file),即**已清空、不可再取** | 2026-10-18 做过逐条哈希取证并瘦身,**只用 mv 进废纸篓、没有 rm**;清单与每条证据(含"取回命令")在 `cast-backup-20260925/snapshot-trim-20261018-deleted-manifest.txt`。留下来的都是**别处没有的**:`cast-full/.git` 与两个 bundle 是 **filter-repo 之前历史的唯一副本**(代价:里面带着 H63 那条已泄露口令,取舍题归维护者)、1.0.2 两份 kit zip(**store apk + R8 mapping 的本机唯一落点**,工作区副本已随 10-18 清 dist 删除)、`STORE-OPS-20261018.md`(在架鸿蒙 1.0.4 身份串的异地副本)。**判"一份备份能不能删"只有两条合法判据:与别处哈希逐字相同(sha 相等,字节数相等不算)、或该构建从未分发** —— 旧版本截图不属于任一条,别按"看起来过期"清掉。⚠️ **Documents 不在 iCloud 同步范围**(`brctl status` → `Client zone not found`)⇒ 清空废纸篓就是终点,不可撤 —— **这句已在 10-23 兑现过一次**(20261012 那份就是这么没的) |
| **工具层的项目记忆与 Skill**(10-23 新登记,原清单漏了这一档) | `~/.qoder/projects/-Users-liang-Documents-cast/memory/`(实测 72 KB,含 `MEMORY.md` 索引与 6 条 project 记忆)、`~/.qoder/memory/`(52 KB,跨项目偏好)、`~/.qoder/skills/`(56 KB,含本仓库专用的 `android-channel-package-audit` 与 `zero-hit-must-prove-scan`) | **这三处都不在工程目录里,"全量拷贝项目目录"带不走**。里面写的是"签名材料只读、装机自办但卸载先备份、macOS 出包固定在另一台机器、release mapping 本地只此一份"这类**边界与前提**,丢了不会报错,只会让下一个会话重新踩一遍。AGENTS.md「会话记忆」一节说的 `<repo>/.workbuddy-ai/memory/` 在工程内(402 MB,会随拷贝走),**与这三处不是同一套,两边都要带** |

> 设备序列号、分发平台/开发者账号、cxyxl.cn 服务器的部署凭据等**只存在于本地**
> (MIGRATION.txt 与分发登记材料),不写进本文档 —— 仓库可能公开。

## 三、可重建 —— 不用拷,新机按说明重建

| 资产 | 重建方式 |
|---|---|
| whisper native 库 + 模型 | `cd android && ./tools/build-asr.sh`(固定 commit + sha256 校验;`build-release.sh` 出那份唯一发布包前会检查在不在) |
| 构建缓存 | `.gradle`、`build`、`.cxx`、`.hvigor`、`oh_modules` —— 删了自动再生,永不拷贝。⚠️ **「永不拷贝」在换机时是硬要求而不只是省空间**:`harmony/.hvigor/` 的 sync/cache 内嵌整份签名配置(含口令),把它拷到新机等于在别处多撒一份口令副本 —— 这正是 H63 让它进了 43 个历史提交的那条路(AGENTS.md 硬规矩 14) |
| `android/local.properties` | 打开 Android Studio 自动生成(只含 sdk.dir)。别把本机那份拷过去 —— 里面是本机路径 |
| `harmony/build-profile.json5` | `cp build-profile.template.json5 build-profile.json5` 后填签名段(签名材料来自第二节) |
| 打包产物 | `android/build-release.sh`、`harmony/build-release.sh`、`macos/package.sh`(Android 合并 flavor 后没有 `--store` 了,H205) |

## 四、新机环境依赖

- **通用**:git、python3、ffmpeg(截图后处理与官网图)、adb(Android platform-tools)
- **Android 端**:JDK(Android Studio 自带)、Android SDK;`./gradlew` wrapper 已在库中
- **鸿蒙端**:DevEco Studio(内含 SDK、`hvigorw`、`ohpm`、`hdc`);
  `export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk`(AGENTS.md 常用命令一节)
- **macOS 端**:Swift 工具链即可;`package.sh` 用 codesign ad-hoc 签名,无需证书。
  但**工具链有硬门槛(Xcode 15+ / macOS ≥ 13)**,构建机与开发机可能是两台 —— 见上面第五节第 6 条
- **真机**:Android 真机 + 鸿蒙真机各一台(序列号见 MIGRATION.txt);
  `adb install -r` / `hdc install -r` 装包,**装机代理自办、要卸载才先备份**(硬规矩 12)
- **路径是写死在文档里的**:`JAVA_HOME=/Users/liang/.java/jdk-17.0.12+7/Contents/Home`(10-23 实测 286 MB,
  且**不在 `/usr/libexec/java_home` 的注册表里**)、`android/local.properties` 的
  `sdk.dir=/usr/local/share/android-commandlinetools`、`DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/…`。
  新机用户名或安装位置一变,这三串就要同步改(AGENTS.md「环境准备」+ 本文 + 各处构建命令),
  否则复现的是"看起来像没装 JDK"那个症状而不是真的缺工具。
  **`aapt2` / `apksigner` 在新机同样不会在 PATH 里**(只有 `adb` 在),照 H156 用全路径并读退出码
- **认证与账号**:`origin` 走 SSH ⇒ `~/.ssh/` 里那几把私钥(`github_key` 等)必须带走或在新机重签;
  `gh` 的登录 10-23 实测存在 keyring 里,**不随目录拷贝走**,新机要 `gh auth login` 重来一次。
  华为开发者账号 / 应用市场后台 / cxyxl.cn 部署凭据的落点见本节末尾那句(只在 MIGRATION.txt 与 BEIAN.md)

## 五、换机操作清单(按序执行)

1. **仓库本体有两条路,选一条,但都要验**:
   ① `git clone` —— 10-23 起可用:远端有全部 16 条分支与 2 个标签,判据
   `git log --branches --not --remotes --oneline | wc -l` = 0(本地 0 条未推送)。**它只给代码与历史**,
   第二节那些 gitignore 的东西一件都不带。
   ② 拷工程目录(含 `.git`)—— 会把第二节一起带走,代价是**必须先排除缓存**:
   `android/app/build`(实测 1.3 GB)、`android/.gradle`(21 MB)、`harmony/.hvigor`(15 MB,**里面内嵌签名口令**)、
   `harmony/entry/.cxx`(2.4 MB)、`*/oh_modules`、`harmony/build`(2.8 MB)、`macos/.build`、`android/local.properties`。
   到新机第一件事:再落一份异地副本(远端或第二块盘),别把"唯一副本"这件事重演一遍
2. **拷第二节全部资产**。口令类文件(jks/p12/keystore.properties)单独打包、加密传输,
   不要与代码包走同一渠道(流程见 MIGRATION.txt)。
   ⚠️ 10-23 补一句:**"全量拷贝工程目录"这一条腿覆盖不到第二节里那三处目录外资产** ——
   `~/.ohos/config/`(鸿蒙 debug 签名)、`~/Documents/cast-backup-20260925/`(filter-repo 之前历史的唯一副本)、
   `~/.qoder/`(项目记忆 / 全局偏好 / 两个本仓库专用 Skill)。它们要各自单独拷。
3. `cp harmony/build-profile.template.json5 harmony/build-profile.json5`,填入签名段
4. 按第四节装环境
5. 重建可重建产物:`./tools/build-asr.sh`
6. **三端构建验证**(都过 = 环境完整):
   - `cd android && ./build-release.sh`(唯一那份;解包复核见硬规矩 1。合并 flavor 后没有 `--store` 了)
   - `cd harmony && ./build-release.sh`(签名通过 = 第二节材料齐)
   - `cd macos && ./package.sh` —— **要一台 Xcode 15+ 且系统 ≥ macOS 13 的机器**(SwiftPM 工程声明 tools 5.9,
     源码用了 macOS 14 SDK 的双参数 `onChange`);**而且必须是完整 Xcode 而不是只有 Command Line Tools** ——
     脚本默认出 universal(`--arch arm64 --arch x86_64`),那条走 xcbuild,CLT 里没有;CLT 的 SwiftPM
     还缺 `PackageDescription.swiftmodule`,连 manifest 都编不动。**系统低于 13 的机器连产物都跑不起来**,
     这类机器只能承担 macOS 的「读代码 + 整模块 typecheck 差分」。逐层实测见 AGENTS.md「macOS」一节与 H124 补记
7. 装真机冒烟:订阅一档、播一集、看逐字稿;截图管线试拍一张(AGENTS.md「截图」)
