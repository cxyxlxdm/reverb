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
| **可重建** | 入库(源码、文档) | 用构建产物+脚本重建,不入库(语音模型与推理库) |
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
| **鸿蒙 release 口令的解密材料** | `harmony/signature/material/`(拷 `signature/` 时**必须连它一起拷**) | build-profile 里那串 `0000001B…` 是 DevEco 的**加密串**(AES-128-GCM),工作密钥由**与被签 keystore 同目录**的 `material/` 推出来:`fd` 三个 16 字节分量 XOR ⊕ 内置常量 → pbkdf2 以 `ac` 为 salt → rootKey → 解 `ce`(入口 `hvigor-ohos-plugin` 的 `getKeyStorePwd` → `DecipherUtil.decryptPwd(storeFile/..)`)。少了它 `SignHap` 报 `ENOENT …/signature/material`(00308018);**material 被换掉而密文没换**则报 `Signature material verification failed … unable to authenticate data`(00303242,authTag 不过)。**实测 material 是每个目录一套随机密钥**(与 `~/.ohos/config/material/` 逐文件比 sha256,五项全不同)⇒ 既不能从别处的 material 拼出来,也不会随重装 DevEco 复原。**留着加密口令、丢了 material = 口令作废**:2026-09-20 与 09-25 那两份口令备份就只拷了 build-profile 与 `signature/reverb.*`、没拷 `signature/material/`(全过程见 H123 第二轮)。**教训:密文与密钥是两件独立资产,必须同处、同批备份**。⚠️ 还有一条同样致命:**material 还原时只能整目录替换,不能与旧文件并排** —— hvigor 要求 `fd/0`、`fd/1`、`fd/2`、`ac`、`ce` **每个叶子目录恰好 1 个文件**,多一个就报 `00303121 Signing material error`(点名到 `material/fd/0`),而目录看起来完全正常。2026-09-29 出 1.0.3 市场包时就卡在这一步(全过程见 H123 第三轮);判定"密文与 material 是否同源"的可复现方法也在那条里(调 DevEco 的 `DecipherUtil.decryptPwd` 并配一份已知能签成的配置做对照)。本机现存的三套 material:`harmony/signature/material`(随签名走)、`~/.ohos/config/material`(自动签名)、`~/Library/Application Support/Huawei/DevEcoStudio26.0/options/data2/material`(IDE 自用)
  **▶ 10-24 傍晚这条要改两处读数**(现数,不是推测):
  "三套"实际是**四处落点** —— 加上 `~/Downloads/LANDrop/signature/material/`(见下面新增那一行,它与现役那套叶子同名同串);
  而**第三套的形状根本不合格**:IDE 那套 `fd/0 fd/1 fd/2 ac ce` **每叶 2 个文件**(实测),
  所以它**任何时候都不能当还原源** —— hvigor 要的是每叶恰好 1 个,整目录替换过去直接 `00303121`。
  另:`~/.ohos/config/material` 原先记成"自动签名/IDE 自用"这一档,
  **17:06 重注册 debug 签名之后它升级成活依赖** —— 新 debug 口令的密文只有它能解,丢了就是 `SignHap` 失败 |
| **鸿蒙 release 签名的非机密参数**(填签名时照着核) | 本行;材料本身在 `harmony/signature/` | keyAlias = **`yuyin`**;三段材料用**相对路径** `./signature/reverb.{p12,p7b,cer}`(hvigor 按工程根归一化,换机器仍成立);profile 绑 `com.yuyin.reverb`、`"type":"release"` + `"app-distribution-type":"app_gallery"`、有效期至 2029-08。**这几项的用途是照着核对、不是照抄恢复**:签名材料一律由本人维护,代理不代填、不代改、不代回滚(H123 教训 ⑦)—— 2026-09-29 曾把这段整段回滚成 08-15 的旧密文,而旧 material 已被覆盖且全盘无副本,结果 release 报 00303242、debug 段因 storeFile 指向已被轮换掉的 .p12 报 00303107,两条路径一起失效,最终由本人重做签名材料才出包。代理只做只读校验:`build-release.sh` 里的三条前置卡口会核这三项并格,不合格直接退出。 |
| **鸿蒙调试签名** | `~/.ohos/config/default_*.{p12,cer,p7b}`(在用户目录,**不在工程目录** → 换机不会随工程拷过来) | 真机 `hdc install` 的唯一路:release 的 `.p7b` 是 `"type":"release"` + `"app-distribution-type":"app_gallery"`,不绑设备也不允许侧装。这目录没了,`assembleHap -p product=default` 会停在 `SignHap` 报 `Invalid storeFile value`。恢复:DevEco → File → Project Structure → Signing Configs → 勾「Automatically generate signature」并登录开发者账号,由它重新生成三个文件并回写 build-profile 的 default 段。**注意它绑 bundleName**:生成时工程用的是哪个包名,这套签名就只认那个包名 —— 为装机测试临时改过包名的话,改回来之后 `SignHap` 会报 `00303074 bundleName … does not match … SigningConfigs`,再点一次 Fix 重新生成即可。⚠️ **但「release 那套不受影响」这句原先写错了,现已更正**:自动签名弹窗里勾了 release 配置(或对 release 配置点 Fix)时,它会把 build-profile 的 **release 段一起改写**成新生成的 `~/.ohos/config/release_*` —— 那套是 `"type":"debug"` 且绑着临时测试包名,**既不能装机也不能提交市场**,而段里原来的加密口令被就地覆盖、找不回来(实测与全过程见 H123)。
  ⚠️ **2026-10-24 换机实测:这一档"随不随工程走"不是重点,`build-profile.json5` 里那条绝对路径才是。**
  新机 `~/.ohos/config/` **带着旧机那 13 个条目过来了**(同名 `default_harmony_uW2…=.p12` 在,09-29 那份 / 1 128 B),
  但 default 段里写的仍是 `/Users/liang/.ohos/config/…` ⇒ `assembleHap -p product=default` 停在
  `SignHap` **`00303107 Invalid storeFile value`**、BUILD FAILED、exit 255。
  **release 段用相对路径 `./signature/reverb.*` 所以照常出包** —— 也就是说:
  **换机后只验 release 会完全看不出这条断了,而它断的是"装真机调试"这条路。**
  差的可能只是路径前缀(材料在同名目录里),但**签名段一律由本人维护,代理不代改** —— 判据与理由见上面「非机密参数」那一行与 H123 教训 ⑦
  **▶ 10-24 17:06 本人重注册了 debug 签名,这一条改口:路径断了 → 已通,且实测签得出来。**
  `build-profile.json5` 的 default 段现在指向**新机绝对路径** `~/.ohos/config/default_harmony_nMkNVRv…=.{cer,p7b,p12}`
  (四个文件 mtime 全在 17:06),文里 `/Users/liang` 残留 **0 处**(阳性对照:同一命令数 `/Users/cxyxl` = **3 处**)。
  判据不是"配置看着对了":`hvigorw assembleHap -p product=default -p buildMode=debug` 实测
  `:entry:default@SignHap` **真的执行**(592 ms)、BUILD SUCCESSFUL,
  `entry-default-signed.hap` **4 292 069 B @17:10** 比同批 unsigned 那份 **多 89 551 B** ——
  那 89 551 B 就是签名块。**注意符号包不往 zip 条目里写**,所以「`unzip -l` 出来的条目里 grep `sig`」恒 0,
  用那条判"签没签"会读成假阴性(同族见 H156 / H206 / H208 教训)。**装机那条路(硬规矩 12 的 debug 包)到此解锁。**
  ⚠️ **但这次重注册让一档依赖变了性**:`~/.ohos/config/material/`(09-26 那套)**现在是 debug 段新口令的解密材料**,
  不再是"IDE 自用"那一档 —— 它没了,今天这份能签出包的配置就解不开口令,症状又是 `SignHap` 失败。
  同目录里另外两套**已无任何配置引用**(`default_harmony_uW2…=` 09-29 那份、`release_harmony_uW2…=` 09-26 那份,后者是 H123 事故的产物),
  **但"没人引用"不是删它们的判据** —— 要删先按第三节那条:确认没有任何 build-profile/备份密文需要它解,再挪出仓库,别原地 `rm` |
| **分发登记材料** | `docs/BEIAN.md`(被根 .gitignore 点名忽略) | 主体真名、分发平台证书标识、证书指纹、备案号;发布提交平台时照着填。口径与理由见 `docs/HISTORY.md` 阶段五 |
| **发布文案与 分发平台图标** | `harmony/store/`、`android/store/`(2026-09-20 起不入库) | 发布文案两语种版 + appicon-216/512/1024;改文案五语种同步的规矩不变(AGENTS.md 硬规矩 5) |
| **发布截图与 发布物料包** | `harmony/dist/store/`、`android/dist/store/`(1080×1920 终图)、原生分辨率中间图 `*/dist/store-masters/`、两套 kit 目录(`harmony/dist/reverb-harmony-submission-kit/`、`android/dist/reverb-store-submission-kit/`)及同名 kit zip | 截图可用真机重拍(可重建但代价大,需两台真机+深色模式流程);**至少把截图与 kit zip 拷走**,免去下次发布全套重拍 |
| **官网图** | `site/reverb/shots/`(4 张) | 由发布原图缩放而来,拷了原图可不拷;随 dist 一起拷最省心 |
| **在野版本的崩溃栈还原材料** | 本次发布物在 `*/dist/` 根;**上一版只在别处** —— Android 完整版在公开分发仓的 release(资产自带 sha256),鸿蒙在分发平台侧。本地额外只留 `android/dist/_backup-1.0.4-preRebuild-1015/reverb-mapping.txt`(42 376 254 B,公开仓 tag 1.0.4 那份包的 R8 mapping;同字节的 apk 已删,外面那份逐字相同) | ⚠️ **2026-10-18 清 `*/dist/` 备份时,把在架鸿蒙 1.0.4 的 `.app` + `reverb-symbol.zip` 的本地唯一副本删了** —— 它藏在 `harmony/dist/_backup-shots-1012/reverb-harmony-submission-kit.zip` 里(**kit zip 内嵌发布物,不是素材**)。那两份的 SHA-256 **完整的串只剩本地 `docs/STORE-OPS.md` 七**(10-12 那轮 kit 那段)—— 原本并列为落点的 `harmony/store/上架文案.md` 第三节已被 1.0.5 的哈希覆写,**这一串随 `STORE-OPS.md` 一起走,而它不入库 ⇒ 换机没带走就断了**。从平台侧取回后按串核验即可。**换机时这一档只能回平台侧取,别指望本地有** —— 判据与教训见 H204。**另存一份在 `~/Documents/cast-backup-20260925/STORE-OPS-20261018.md`**(10-18 那一刻的快照;同样不入库,但与工程目录分处两地)—— ⚠️ **它不随工作区自动更新**,要用时先核:`md5 -q docs/STORE-OPS.md ~/Documents/cast-backup-20260925/STORE-OPS-*.md` 两个串相等才算数,不等就以工作区那份为准并重拷 |
| **历史迁移包** | 根目录 `MIGRATION.txt` | 上次迁移的打包/加密流程与机型细节;`reverb-migrate-secrets-*.tar.gz` 类密钥分包如仍存在,即签名材料的另一份拷贝
  ⚠️ **10-24 傍晚现查:这句条件句现在有落点了,而且落点很危险** —— 两包都在 **`~/Downloads/LANDrop/`**:
  `reverb-migrate-secrets-20260920.tar.gz` **24 543 B / 8 个条目**,里面是
  `android/app/reverb-release.jks` + `android/keystore.properties` + `harmony/signature/reverb.{p12,cer,p7b,csr}` +
  `harmony/build-profile.json5` + `docs/BEIAN.md`;另一包 `reverb-migrate-20260920.tar.gz` 101 183 006 B 是同日代码全量。
  ⇒ **这是 Android 私钥与鸿蒙 release 私钥在工程之外唯一的一份异地复本**,而 `~/Downloads` 是"随手清"的地方
  (同目录还堆着 339 MB 手机传来的照片视频)。**它同时是"半个备份"**:包里那份 `build-profile.json5` 的口令密文
  **没有配套 material**(H123 那个已知缺陷在同一次打包里犯了两次),所以它能救私钥、救不了口令。
  **建议处置归本人**:要么挪进 `cast-backup-20260925/` 那种有登记的归档位、要么按本节"密文与密钥同批备份"补一份 material ——
  代理不代移动签名材料,也不代删 |
| **旧密文与旧 material 的成对副本** | `~/Documents/reverb-signing-recovery-20260929/`(10-24 傍晚才发现,**原清单整条漏登记**) | 里面是 09-29 09:35 那次签名重做**之前**的 `build-profile.json5.before-20260929-093558`(3 231 B)+ `signature-material.before-20260929-093558/`(五个叶子目录各 1 个文件,文件名与现役 `harmony/signature/material/` **逐不同** ⇒ 另一套随机工作密钥)。
  **它的价值恰恰在"成对"**:本地唯一一份能让那串旧密文重新解得开的东西 —— 三套现役 material 都解不了它。
  与上一条同待遇:**不可再生,但也不能被当成"还原 source"往现役目录里拷**(拷进去就是 `00303121`,见上面 material 那一行的"整目录替换"训) |
| **release 签名材料的散装整份副本**(10-24 傍晚新登记,**位置本身就是风险**) | `~/Downloads/LANDrop/signature/` —— `reverb.{p12,cer,p7b,csr}` 4 个文件 + `material/`(五个叶子各 1 个文件,mtime 09-29 19:51) | 逐文件 sha256 与现役 `harmony/signature/` **同串**,`material/` 的五个叶子**文件名也与现役那套逐字相同**
  ⇒ 它是本地唯一一份「**私钥 + 配套 material 成对**」的副本,正是 H123 那两轮事故里"密文还在但 material 没了"那种死局的解药形状。
  ⚠️ **但它躺在下载目录里**(同目录还有 339 MB 手机传来的照片视频),而 `p12` 是私钥本体、`material` 是它的解密材料 ——
  **一次"清理下载"就把两样一起删掉**。处置归本人:要么挪进有登记的归档位、要么给它一条 `.gitignore` 之外的独立备份;
  **代理不代移动、不代删除任何签名材料**(硬规矩 12 末段)。也**别把它当还原源往回拷** —— 两份同串,拷了等于没动 |
| **对外长文唯一副本**(10-24 傍晚新登记) | `~/Documents/reverb-article.md`(18 354 B,10-18 22:24) | 「余音 · Reverb:一个不联网也能活着的播客客户端」—— 对外介绍长文,是硬规矩 19 那档「不入库的运营物料」,但**原先没登记**。
  仓库内 `find -name 'reverb-article*'` = **0 个** ⇒ 只此一份。改口径时它与 `CHANGELOG.md`(内部账本)、`docs/PRODUCT.md` 是三个不同受众的版本,别互相顶替 |
| **早期版本的原始截图(重拍要装回旧版 App)** | `~/Documents/web/reverb/shots/` 里 8 月那批 **11 个 `.png` / 该目录共 24 MB**(10-24 傍晚新登记) | 第二节原先只登记了 `site/reverb/shots/`(仓库内 4 张)与 `*/dist/store{,-masters}/`(1.0.5 那批 8 张),**漏了 1.0.2 时代这批原始 PNG**。
  它们不是"可重建":要重拍得把旧版 App 装回两台真机(旧包只在公开分发仓与商店侧,界面与数据都已变)。
  ⚠️ 同目录的 `index.html` 与仓库那份 **md5 逐字相同**(`4ed9a1d9…`)⇒ 那一档**不是**独有资产,`~/Documents/web/` 整体只是部署工作副本,**独有部分只有 `shots/` 里这批 PNG**。
  另有 `~/Documents/web-deploy-backups/`(15 个 `*.pre-deploy`,567 KB)—— 那是历次部署前的线上快照,**回得来(服务器上还有一份),按"可重建"排** |
| **与工程分处的本地快照(只剩一份)** | `~/Documents/cast-backup-20260925/`(瘦身前 226 MB → 10-23 实测 **59 MB**:cast-full 48 MB + 两个 bundle + 两份处置清单 + STORE-OPS 快照)。另一份 `cast-backup-20261012/` **已经不存在了** —— 10-18 整目录移进废纸篓,10-23 实测工程侧目录与 `~/.Trash/` 两处都查不到(`ls -d` 均报 No such file),即**已清空、不可再取** | 2026-10-18 做过逐条哈希取证并瘦身,**只用 mv 进废纸篓、没有 rm**;清单与每条证据(含"取回命令")在 `cast-backup-20260925/snapshot-trim-20261018-deleted-manifest.txt`。留下来的都是**别处没有的**:`cast-full/.git` 与两个 bundle 是 **filter-repo 之前历史的唯一副本**(代价:里面带着 H63 那条已泄露口令,取舍题归维护者)、1.0.2 两份 kit zip(**store apk + R8 mapping 的本机唯一落点**,工作区副本已随 10-18 清 dist 删除)、`STORE-OPS-20261018.md`(在架鸿蒙 1.0.4 身份串的异地副本)。**判"一份备份能不能删"只有两条合法判据:与别处哈希逐字相同(sha 相等,字节数相等不算)、或该构建从未分发** —— 旧版本截图不属于任一条,别按"看起来过期"清掉。⚠️ **Documents 不在 iCloud 同步范围**(`brctl status` → `Client zone not found`)⇒ 清空废纸篓就是终点,不可撤 —— **这句已在 10-23 兑现过一次**(20261012 那份就是这么没的) |
| **工具层的项目记忆与 Skill**(10-23 新登记,原清单漏了这一档) | `~/.qoder/projects/-Users-liang-Documents-cast/memory/`(实测 72 KB,含 `MEMORY.md` 索引与 6 条 project 记忆)、`~/.qoder/memory/`(52 KB,跨项目偏好)、`~/.qoder/skills/`(56 KB,含本仓库专用的 `android-channel-package-audit` 与 `zero-hit-must-prove-scan`) | **这三处都不在工程目录里,"全量拷贝项目目录"带不走**。里面写的是"签名材料只读、装机自办但卸载先备份、macOS 出包固定在另一台机器、release mapping 本地只此一份"这类**边界与前提**,丢了不会报错,只会让下一个会话重新踩一遍。AGENTS.md「会话记忆」一节说的 `<repo>/.workbuddy-ai/memory/` 在工程内,**与这三处不是同一套,两边都要带**。
  ⚠️ **10-24 换机时核过这一档的单位**:原先这里写的是「`.workbuddy-ai/memory/` 402 MB,会随拷贝走」,
  **把父目录当成了子目录** —— 实测 `.workbuddy-ai/` 整目录 402 MB / 1 769 个文件,
  而 `memory/` 本身只有 **1 个文件 / 28 305 B**。剩下 1 768 个文件全在
  `promo/`(164 MB / 921 个)、`promo2/`(152 MB / 820 个)、`footage/`(75 MB / 7 个)、`capture/`(12 MB / 20 个),
  **是宣传片素材,不是记忆** —— 它能随工程目录一起拷,但**属于"可重建但代价大"那一档**
  (渲染流水线见 `marketing/README.md`),别把它记成"不可重建资产"而漏登记真正的记忆目录 |

> 设备序列号、分发平台/开发者账号、cxyxl.cn 服务器的部署凭据等**只存在于本地**
> (MIGRATION.txt 与分发登记材料),不写进本文档 —— 仓库可能公开。

### 二-A、2026-10-24 换机后的逐项盘点(存在性 + 处理量,现算)

判据:**先给条目数与字节数,再说"在不在"**;口令只数键名、不打印值。取数脚本是一次性的
(`/tmp/asset_inv.sh`,按 H206 写成文件用 bash 跑),下面是它的全部读数。

| 第二节那一档 | 新机读数 | 判定 |
|---|---|---|
| Android 签名 | `keystore.properties` 121 B / `app/reverb-release.jks` 4 408 B | ✅ 在 |
| 鸿蒙 release 签名 | `harmony/signature/` 9 个文件 / 40 KB;`material/` 五个叶子目录 `fd/0 fd/1 fd/2 ac ce` **各 1 个文件**(多一个就 00303121) | ✅ 在,且 release 出包实测通过 |
| 鸿蒙 debug 签名材料 | `~/.ohos/config/` **13 个条目**,分三套:`default_harmony_nMkNVRv…=` **4 个 / mtime 10-24 17:06**(本人重注册的那套)、`default_harmony_uW2…=` 4 个 / 09-29(孤儿)、`release_harmony_uW2…=` 4 个 / 09-26(H123 事故产物,孤儿),外加 `material/` | ✅ **在,而且实测能用**:`build-profile.json5` 引用了 17:06 那套的三个文件、三条 `OK`;`assembleHap -p product=default -p buildMode=debug` 的 `SignHap` 真跑、signed hap **4 292 069 B**(比 unsigned 多 89 551 B)。上面那一行的「材料在、路径断了」**已作废** |
| `build-profile.json5` | 3 012 B / mtime **10-24 17:06**,`/Users/liang` 残留 **0 处**(阳性对照:同命令数 `/Users/cxyxl` = **3 处**,全在 default 段的 `certpath` / `profile` / `storeFile` 三行) | ✅ **这一条不再是待处置项**:本人把 default 段重注册到新机绝对路径了。release 段仍是相对路径 `./signature/reverb.*` + `keyAlias=yuyin`,**没被自动签名弹窗顺手动过**(那正是 H123 记着的风险,所以这一句要每次核)。**残留的只有一件事**:default 段用的是**绝对路径**,下次换机同样会断 —— 判据见上面「10-24 17:06」那段 |
| 分发登记材料 | `docs/BEIAN.md` 20 964 B | ✅ 在 |
| 发布文案与分发平台图标 | `android/store/` 3 个文件 / `harmony/store/` 1 个 | ✅ 在 |
| 发布截图与 kit | `*/dist/store/` 各 8 张;`*/dist/store-masters/` 8 与 9 张;两份 kit **目录与 zip 都在**(4 条路径) | ✅ 在 |
| 官网图 | `site/reverb/shots/` **4 个文件** / 168 KB | ✅ 在(张数与 `index.html` 的 `shots/` 引用一致,硬规矩 20) |
| 在野版本崩溃栈还原材料 | `android/dist/_backup-1.0.4-preRebuild-1015/` **1 个文件 / 41 384 KB** | ✅ 在;**这一轮另加了 `android/dist/_backup-1.0.5-mergedRebuild-1018-oldMachine/`(apk + mapping + SHA256.txt)** —— 因为 `build-release.sh` 会 `rm -f` 顶掉 mapping(H204/H205) |
| 历史迁移包 | 工程根 `MIGRATION.txt` 13 727 B | ✅ 在 |
| 与工程分处的快照 | `~/Documents/cast-backup-20260925/` **502 个文件 / 约 58 MB**;`cast-full/.git` 在、`.bundle` **2 个**、`STORE-OPS-20261018.md` 69 803 B | ✅ 全在(唯一副本那一档没断) |
| 工具层记忆与 Skill | `~/.qoder/projects/**-Users-cxyxl-Documents-cast**/memory/` 7 个文件 / 80 KB、`~/.qoder/memory/` 10 / 56 KB、`~/.qoder/skills/` 4 / 56 KB | ✅ 在,但**键名跟着机器变了**:旧 `-Users-liang-Documents-cast` 目录**不存在** ⇒ 记忆是改名搬过来的。**换机后这条必须现算**,否则"有记忆"与"会话能读到记忆"是两件事 |
| 可重建产物(1.0.8 起) | `app/libs/sherpa-onnx.jar` 245 045 B、`jniLibs/arm64-v8a/libonnxruntime.so` 22 249 560 B + `libsherpa-onnx-jni.so` 4 609 320 B、`assets/sensevoice/model.int8.onnx` 239 233 841 B + `tokens.txt` 315 894 B | ✅ 在(`tools/build-asr.sh` 备齐;下载后按 sha256 校验) |
| ~~可重建产物(1.0.7 及以前)~~ | `libreverb_asr.so` 1 679 264 B、`whisper-model.bin` 59 707 625 B | 1.0.8 已移除,不再需要;换回来只改 `AsrFactory` + `build-asr.sh` 的分支 |
| 构建缓存 | **10-24 下午做了一次清空重建实验,数字如下。** 搬过来的那份:`harmony/.hvigor/` 31 个文件 / **14 MB**,**21 个 mtime 早于 10-24**(最老 09-25);`keyPassword` ×5 + `storePassword` ×5 + DevEco 密文前缀 `0000001B` ×10,分落 2 个文件(`cache/task-cache.json` 与 `outputs/sync/output.json`);**`/Users/liang` 出现 22 968 次**。清空后重跑一次 debug 构建(31 tasks executed / 0 up-to-date,是真·全量)→ 新缓存 12 个文件 / 704 KB,键名命中只剩 `cache/task-cache.json` 一处(密文 ×2),`sync/output.json` **不再回来**(它是 DevEco sync 写的,hvigor CLI 不产) | ⚠️ **一半是卫生、一半是活源头**:清掉能少 8 处键名副本 + 那 22 968 条旧机路径,但 `task-cache.json` 那份**每次构建都会再生**,所以"清了就好了"不成立(归本人判,可再生,但它是 H63 同族)。**旧缓存没有删,但已挪出仓库** → `~/Documents/cast-hvigor-preMig-20261024/`(31 个文件 / 14 MB)—— 原因见下面那行:第一次归档在仓库内、加后缀改名,**把忽略规则改失效了** —— 删它一条 `rm -rf` 的事,留着是因为里面还有 10-17 的构建遥测可比对。见第三节同一行 |
| ⚠️ **旧缓存的归档落点(10-24 下午定的,含一个当场踩到的坑)** | 第一次归档成 `harmony/.hvigor.preMig-20261024/`,**结果它出现在 `git status` 的未跟踪列表里** —— 忽略规则写的是 `.hvigor/`(根 `.gitignore:8`,全层级)与 `/.hvigor`(`harmony/.gitignore:8`),**两条都只认这个名字**,加后缀改名等于把 H63 那层保护关掉:14 MB、内含 10 处 DevEco 密文串的目录就摆在"顺手 `git add -A` 会带走"的位置上。现已挪出仓库 → **`~/Documents/cast-hvigor-preMig-20261024/`(31 个文件 / 14 MB)** | ⚠️ **可删,归本人判**(内容与上面那行同:纯缓存,重跑构建自动再生)。**要复用的规律是那条判据**:给"为 X 写的忽略规则"做任何改名归档之前,先 `git check-ignore -v <新路径>` —— 它不给命中,就别怪规则没生效。仓库根另有一个 09-27 的空 `.hvigor/` 目录(0 个文件),不是本轮产物,没动 |
| **对外产物里的本机路径**(不属于第二节任何一档,是解包时顺带照出来的) | 1.1.0 发布包对 `libonnxruntime.so` 与 `libsherpa-onnx-jni.so` 扫 `/Users/` **各 0**;1.0.7 及以前那份 `libreverb_asr.so` 曾有 **14** 条本机源路径(whisper.cpp / ggml 编译时烙进去的 `/Users/liang/Documents/Workspace/source/cast/…`,连旧机的仓库落点都不是),已随 1.0.7 包分发出去了 | ✅ 本机路径这一条已归零。1.1.0 同时能扫到上游 CI 路径 `/home/runner/`,它来自 `build-asr.sh` 固定 sha256 的 sherpa-onnx / onnxruntime 预编译 AAR,不是这台机器的构建路径,不能据此判成本机痕迹(见 H297);也不要为消灭它篡改校验过的二进制。**已固化的零成本动作**:`/Users/` 留在解包判据词里,重打或再换引擎时会立刻变红。判"要不要管"仍按**硬规矩 15**那条问法:不是"算不算机密",是"公开它能不能反查到一个具体的人" |

**盘点结论**:第二节**没有丢东西**(签名、kit、快照、唯一副本、记忆五档逐项到位);
真正的遗漏是**三条"在新机上不成立"的环境前提** —— `gh` 与 `ffmpeg` 没装、
鸿蒙 debug 签名路径断、`.hvigor` 旧缓存连口令密文一起搬了过来。
(**当天傍晚这三条里 `gh`/`ffmpeg` 已补装、debug 签名已由本人重注册并实测签得出包,`.hvigor` 做了清空重建实验 —— 逐条见下面两段补记与第四节,别把这句当今天。**)
另有**一条与换机无关、却被同一次解包照出来的对外产物痕迹**(上面最后那行 `.so` 里的构建机路径),
它不属于"缺件",属于"从没登记过的东西第一次被看见"。取证过程见 `docs/TROUBLESHOOTING.md` H208。

> **10-24 傍晚第二次盘点 —— 上面那句「第二节没有丢东西」仍然成立,但「没有遗漏」不成立。**
> 换机带过来的东西一件没缺(逐条现数见上表);漏的是**登记表本身的六条**,外加一条比漏登记更急的。
>
> **漏档六条**(共同成因见再下面那段):
> ① **`~/Downloads/LANDrop/reverb-migrate-secrets-20260920.tar.gz`(24 543 B / 8 条)** ——
> Android 与鸿蒙两把**私钥在工程外唯一的一份异地复本**,原先只用条件句「如仍存在」提了一句、没写落点;
> ② **`~/Downloads/LANDrop/signature/`(5 个文件 + `material/`,mtime 09-29 19:51)** ——
> 这是这一轮最意外的一条:**一整套散装 release 签名材料**,四份 `reverb.{p12,cer,p7b,csr}` 与现役
> `harmony/signature/` **sha256 逐文件同串**(`cd93f4b0…` / `6db503a3…` / `e9ce5c40…` / `c78c02f9…`),
> 而且 `material/` 五个叶子的**文件名也与现役那套逐字相同** ⇒ 它是本地唯一一份「**私钥 + 配套 material 成对**」的副本,
> 也就是 H123 那两轮"密文还在但 material 没了"的事故里**真正能救回来的那种形状**。
> **但它躺在 Downloads** —— 一个"清一下下载目录"就会带走的地方,而且里面是私钥本体。
> ⚠️ 别因为它是副本就把它当还原源往回拷:两份同串 ⇒ 拷了等于没变;要动的是**位置**,不是内容(归本人)。
> ③ **`~/Documents/reverb-signing-recovery-20260929/`** —— 旧密文 + 旧 material 的**唯一成对副本**,整条没登记
> (它和 ② 是**不同**的两套:②的 material 与现役同名,③的那套叶子文件名与现役全不同 ⇒ 只能解 ③ 里那份 build-profile 的密文);
> ④ **`~/Documents/web/reverb/shots/` 里 1.0.2 那批 11 个 PNG(该目录 24 MB)** —— 「重拍要装回旧版 App」这一档从没登记过;
> ⑤ **`~/Documents/reverb-article.md`(18 354 B / 10-18 22:24)** —— 对外长文(「不联网也能活着的播客客户端」)的唯一副本,
> 仓库内同名文件 **0 个**;按硬规矩 19 它本来就不该入库,但"不入库"≠"不登记",它现在就是没登记的那一档;
> ⑥ **`~/.ohos/config/material/` 变了性** —— 它原先被写成"IDE 自用那套",而 17:06 重注册 debug 签名之后,
> **它成了新 debug 口令的唯一解密材料**,和 `signature/material` 同待遇。
> ⇒ **这六条现在都补进了第二节。** 它们为什么扫不出来:10-24 上午那次盘点的遍历单位是**第二节那张表里的路径**,
> 所以"没写进表的东西"永远不可能被那次盘点发现。补做的动作是**反着扫**(拿材料名去家目录找,而不是拿目录名去表里找):
> `find ~/Documents ~/Downloads ~/Desktop -maxdepth 3 \( -iname '*reverb*' -o -iname '*.p12' -o -iname '*.jks' -o -iname '*material*' \)`
> **实测读数:16 个命中**,①②③④⑤ 五条全在里面(`web/reverb`、`LANDrop/signature`、`reverb-article.md` 都是命中项)。
> ⚠️ **但这条命令有它的边界,别当万能扫**:④ 命中的是 `web/reverb` 这一层,`shots/` 里那 11 个 PNG 在 maxdepth 4,
> 要 `cd` 进去数才看得见;⑥ 那种绑在工具链目录上的**根本不在这三个根里** —— 它要靠 `~/.ohos` 进根列表。
> 所以正确的形状是**两遍互补**:遍历表 = 保证登记过的都在,反扫 = 保证没登记的被看见,
> 而反扫的根列表要显式含 `~/Documents ~/Downloads ~/Desktop ~/.ohos ~/.ssh ~/.qoder`(少一个根就少一类漏项)。见 H208 傍晚补记。
>
> **顺带核掉的一条虚警**:`docs/STORE-OPS.md` 与异地快照 `STORE-OPS-20261018.md` 的 **md5 不等**
> (`cbc16f8…` ≠ `2f1649e…`,工作区那份 78 782 B 比快照 69 803 B 大),按第二节那条判据本来要判"快照过期";
> 但**真正不可再生的那部分两副本都在** —— 把两文件里的 64 位十六进制串取集合做差,**双向都空**(各 7 条、去重 7 条),
> 差的只是 10-18 之后新加的散文。⇒ **在架鸿蒙 1.0.4 的身份串没断**,快照仍当异地副本用,只是别再指望它覆盖新写的段落。
>
> **⚠️ 一条不属于"漏登记"、但才是真风险的:整节资产没有第二份拷贝。**
> 现数:`tmutil destinationinfo` → **`No destinations configured`**(这台机器从没配过 Time Machine 目标)、
> `diskutil list external` 只有一块 17.2 MB 的**磁盘映像**(`/Volumes/余音 Reverb` 是本次那个 dmg 的挂载点,不是备份盘)、
> `df -h /` 只有一块 460 Gi 系统盘 ⇒ **签名私钥、口令密文与 material、kit、`cast-backup-20260925` 那份
> filter-repo 之前历史的唯一副本,此刻全在同一块物理盘上**;而 `~/Documents` 不在 iCloud 同步范围(本节第五节第 2 条那句已登记过)。
> 上一条"10-18 那次清空废纸篓当场毁掉一份在架鸿蒙包"就是这块盘的单向性兑现过一次的样子。
> **要补的是第二块盘或一份加密异地,不是再往表里加一行** —— 这是本人的一条待拍板(与 #207「旧历史留还是清」是同一道题的两半)。
>
> **git 侧同一条读数**:判据是 `git log --branches --not --remotes --oneline | wc -l`,**要现跑别抄**。
> 10-24 傍晚现数 = **6**(H208 与 H209 那批文档提交还没推)⇒ 第五节第 1 条那句「判据 = 0」当时**不成立**,
> 那几条知识在推送之前也只在这块盘上有一份。分支数本地 16 / 远端 16 这条仍相等。

> **10-24 下午补记 —— 上面那三条"遗漏"处理完之后的状态,以及一条新发现的、比它们都急的东西。**
> ① `gh` / `ffmpeg` **已补装**(见第四节;顺带订正:本节原判定里"brew 没装"是错的,缺的只是 formula);
> ② `.hvigor` 旧缓存**做了清空重建实验**(结论见上面表里那两行),缓存本身**挪出仓库放在
> `~/Documents/cast-hvigor-preMig-20261024/`** —— 中途还踩出一个新坑:加后缀改名会让 `.hvigor/`
> 那条忽略规则失效,14 MB 带口令键名的目录直接进 `git status` 未跟踪列表,判据见同一行;
> 结论从"清掉就干净了"改成"清的收益是 8 处键名副本 + 22 968 条旧机路径,而 `task-cache.json` 那份每次构建都会再生";
> ③ 鸿蒙 debug 签名段那三行**仍未动**(签名配置代理不代改),但性质升级了:
> 它不是静态残留,**每跑一次构建就往新缓存再撒一份旧机路径**(实测 ×5)。
> **▶ 10-24 17:06 这一条被本人处置掉了**:重注册 debug 签名后 default 段指向新机路径,`/Users/liang` 归 0,
> debug hap 实测签得出来(判据与那 89 551 B 的读法见上面第二节「鸿蒙调试签名」那一行的傍晚补记)。
> 上面那句"每跑一次构建再撒一份"随之停止兑现 —— 它当时的读数是真的,只是前提(那三行没改)已经不在了。
> ④ **新发现的不在原三条里**:本人装 Xcode 之后,`xcode-select` 已切到 Xcode 而许可未同意,
> 于是 `/usr/bin/git` 连带 `xcrun`/`swift`/`clang`/`python3` **在本机全部不可用** ——
> 这条如果不登记,下一个会话会以为"仓库坏了"而不是"许可没同意"。
> ⑤ 另两条缺件登记进第四节:**Pillow**(截图流水线,三处 heredoc import)与 **numpy**(宣传片配乐),
> 都要等 python3 能用之后再装。

## 三、可重建 —— 不用拷,新机按说明重建

| 资产 | 重建方式 |
|---|---|
| 语音模型 + 推理库(1.0.8 起,Android) | `cd android && ./tools/build-asr.sh`(下载 SenseVoiceSmall int8 与 sherpa-onnx AAR,按 sha256 校验,把 `classes.jar` 解到 `app/libs/`、两个 `.so` 放进 `jniLibs/arm64-v8a/`;`build-release.sh` 出那份唯一发布包前会检查在不在)。⚠️ **「可重建」不等于「字节相同」**:模型与上游 `.so` 是下载来的,同一 sha256 才可复现;但整包 SHA 仍会随打包时间/签名变化(认包靠 mtime + SHA,见 H208 根因 ⑧)。1.0.7 及以前的 whisper `libreverb_asr.so` 是**本机 CMake 编译**的,会把构建机绝对路径烙进 `.so`;换引擎后 `/Users/` 现读数为 0。预编译 sherpa / onnxruntime 里的 `/home/runner/` 是上游 CI 路径,不是本机痕迹(见 H297) |
| 语音模型 + 词表(1.0.8 起,鸿蒙) | `cd harmony && ./tools/build-asr.sh` —— 把模型 239,233,841 B 与词表 315,894 B 放进 `entry/src/main/resources/rawfile/sensevoice/`(已 gitignore)。**同机有 Android 那份时直接从 `android/app/src/main/assets/sensevoice/` 拷**,sha256 一致才收;没有才去 hf-mirror 下。推理库随 sherpa har 由 `ohpm install` 带入,`harmony/build-release.sh` 出包前会检查模型在不在、出包后再解包核对 |
| ~~whisper native 库 + 模型~~ | 1.0.8 起不再需要。要回退时改 `AsrFactory` 与 `build-asr.sh` 两处即可,产物仍在 `tools/build-asr.sh` 的历史分支里 |
| 构建缓存 | `.gradle`、`build`、`.cxx`、`.hvigor`、`oh_modules` —— 删了自动再生,永不拷贝。⚠️ **「永不拷贝」在换机时是硬要求而不只是省空间**:`harmony/.hvigor/` 的 sync/cache 内嵌整份签名配置(含口令),把它拷到新机等于在别处多撒一份口令副本 —— 这正是 H63 让它进了 43 个历史提交的那条路(AGENTS.md 硬规矩 14)。**10-24 把这句话的代价量化了**:搬过来的 `.hvigor` 让新机多出 10 处 DevEco 密文串与 22 968 条旧机绝对路径,清空重建后只剩 `cache/task-cache.json` 里那一份(×2 串),**它随每次构建必然再生**;所以正确的规则是**迁移时不带它**,而不是"事后清" |
| `android/local.properties` | 打开 Android Studio 自动生成(只含 sdk.dir)。别把本机那份拷过去 —— 里面是本机路径 |
| `harmony/build-profile.json5` | `cp build-profile.template.json5 build-profile.json5` 后填签名段(签名材料来自第二节) |
| 打包产物 | `android/build-release.sh`、`harmony/build-release.sh`、`macos/package.sh`(Android 合并 flavor 后没有 `--store` 了,H205) |

## 四、新机环境依赖

> ⚠️ **2026-10-24 整机迁移**(旧 `MacBookPro11,4` / macOS 12.7.6 / 用户 `liang`
> → 新机 Apple Silicon / macOS 27.0.1 / 用户 `cxyxl`)之后,本节**逐项在新机重测过**。
> 下面每条都带 10-24 的实测来源;旧机那些"286 MB / 装在 /usr/local/share"的读数已作废,
> 但仍留在第五节的换机清单里当历史。全部结论的取证过程见 `docs/TROUBLESHOOTING.md` H208。

- **通用**:git、python3(`/usr/bin/python3`)、adb(`$SDK/platform-tools/adb`)新机都有。
  ⚠️ **但这一行的前半句 10-24 下午起有条件了** —— 见下面「Xcode」那条:`/usr/bin/git` 与 `/usr/bin/python3`
  都是 developer dir 的 shim,dir 一切到 Xcode 而许可未同意时**它们全体报错**,git 的替代路径写在那条里。
  **`ffmpeg` 与 `gh` 已在本机补齐**(10-24 下午 `brew install` 后现数:`brew list --formula | grep -cE '^(gh|ffmpeg)$'` = **2**;
  `gh 2.103.2` / `ffmpeg 9.0.2`)。**原先那句「新机没有」是当时的真读数,不是笔误** ——
  它同时把 `brew` 本身误写成"没装":实测 `/opt/homebrew/bin/brew` 在且 Homebrew 7.0.10,
  缺的只是这两个 formula。取证顺序应当是**先 `command -v brew` 再谈装不装**,否则会把"缺包"写成"缺包管理器"。
  **`gh` 装了不等于能用**:`gh auth status` 报 `The token in default is invalid` ⇒ 旧机那份凭据没跟着搬过来
  (旧机实测登录在 keyring),要 `gh auth login` 重来一次才能跑发版顺序第 5 步那两条 `gh api` 判据。
  **Python 图像/数值库两个原先都缺,10-24 晚间已装**:① **Pillow** —— 用的地方是 `android/tools/glass-shot.sh:192,217` 与
  `harmony/tools/glass-shot.sh:43`(`from PIL import Image`,截图流水线的裁剪段),缺它截图导不出来;
  ② **numpy** —— `marketing/src/score.py:15`,宣传片配乐(`marketing/README.md:51`)。**这两个都不是仓库内的 `.py` 里 import 出来的**:
  PIL 那三处藏在 shell 的 heredoc 里,所以 `grep -rl 'import PIL' --include='*.py'` 报 **0**,
  差点被我当成"本仓库不用 PIL"(`--include` 的 glob 过滤是"空 stdout ≠ 没命中"家族里的**第四种同形来源**,记在 H208 教训)。
  **两个都归"python3 能用之后一条命令"类**:`python3 -m pip install --user pillow numpy`
  —— 10-24 下午跑它只会拿到那句许可提示,所以**当时不在代理能验的范围内**,别按"已装"写。
  傍晚许可同意之后 `python3` 恢复了,但**当时代码里那句"两样都还没装"仍然成立**,不是笔误。
  ▶ **10-24 晚间这条已翻面**:装机验收那一轮顺手补装,实测 `python3 -c "import PIL,numpy"` **exit 0**,
  版本 **PIL 11.3.0 / numpy 2.0.2**(`--user` 装进当前解释器的用户目录)。
  ⚠️ **换机要重装的仍是这两条** —— 它们在用户目录、不在仓库,git 带不过去;
  复验判据就是上面那条 import 命令的**退出码**,不是 `pip list | grep`(那条是"命令没跑成"家族的老同形来源)。
- **macOS 端 / Xcode**:10-24 本人正在装完整 Xcode,**已经落地但许可没同意**
  (`xcode-select -p` = `/Applications/Xcode.app/Contents/Developer`,`xcodebuild -version` = Xcode 27.1 / 27A9275)。
  这一件事同时改动两条口径:
  ① **旧拦路消失了**:`SwiftUIMacros` 宏插件在 Xcode 里有 5 份(含 `MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib`),
  而 CLT 那份仍是 0 —— 「本机出不了包是因为 CLT 缺 SwiftUI 宏插件」这条(H208 的 macOS 根因)**只剩前半句成立**;
  universal 出包要的 `xcbuild` 也在了,但**落点不是** `Developer/usr/bin/xcbuild`,而是
  `Xcode.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/Support/xcbuild`(1 处命中)。
  ② **新的拦路是许可**:`sudo xcodebuild -license` 没跑之前,`xcrun` / `swift` / `swiftc` / `clang` /
  `/usr/bin/python3` / **`/usr/bin/git`** 全部只回一句许可提示 —— 包括本文件与 AGENTS.md 里所有
  `xcrun --show-sdk-path` 形态的命令。**当前唯一能提交的办法**是直接调真二进制
  `/Library/Developer/CommandLineTools/usr/bin/git`(实测 2.54.0 Apple Git-157,与 Xcode 那份同版本)。
  ⚠️ **「装完 Xcode 就能出包」这句现在还不能写进结论**:同意许可之后必须真跑一遍
  `cd macos && ./package.sh` 才算数(它的架构硬断言与解包验收才是判据),那之前 macOS 侧仍然只有
  `bash macos/tools/selftest-verify.sh` 是实测过的。
- **Android 端**:**只有 Temurin 21,没有 JDK 17** —— 这不影响出包:项目钉的是
  `VERSION_17` / `jvmTarget '17'`(**language level**,AGP 9 起 jvmTarget 跟随 `compileOptions`),
  不是 JDK 17 这个运行时。10-24 用 21 全绿:编译门 exit 0、`build-release.sh` exit 0、解包审计 6 项全 PASS。
  Android SDK 在 `/Users/cxyxl/Library/Android/sdk`(`platforms` 有 android-34 与 **37.0**,
  **API 37 的平台包目录带小版本号,没有裸 `android-37`**;`build-tools` 有 34.0.0 与 36.0.0);
  `./gradlew` wrapper 已在库中(**9.9.1**)。⚠️ 2026-11-15 起工具链是 AGP 9.5.1 / Gradle 9.9.1 /
  Kotlin 2.2.10;Gradle 9.9.1 的发行包从官方站下载极慢,本机是从腾讯镜像取的、sha256 对齐官方后才放进
  `~/.gradle/wrapper/dists/`(见 H282)
- **鸿蒙端**:DevEco Studio(内含 SDK、`hvigorw`、`ohpm`、`hdc`);
  `export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk`(AGENTS.md 常用命令一节)。
  **`hdc` 不在 PATH**(10-24 实测),全路径 `$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc` 存在
- **macOS 端**:新机是 Apple Silicon + macOS 27,**旧机那四层门槛(系统上限 / SDK 13.1 /
  LaunchServices 拒 -10825 / `NavigationStack` 符号缺失)全部作废**。
  但**新机仍然出不了 macOS 包,拦点换了一层**:本机只有 Command Line Tools
  (`xcode-select -p` = `/Library/Developer/CommandLineTools`),Swift 6.4 能用,
  而 **CLT 不带 `SwiftUIMacros` 宏插件**(`find "$(xcode-select -p)/usr/lib/swift" -name 'SwiftUIMacros*'` = 0),
  于是 `@State` 展不开、`swift build` 在 `RootView.swift` 直接崩 —— 日志 2 239 行里 **386 条 error,
  全是这一处的下游**(宏未找到 220 + `'self' is immutable` 116 + `cannot find '$xxx' in scope` 等 50)
  (6 行 `@State` 最小复现在本机同样报同一条 ⇒ **不是源码问题**)。
  出 universal 还额外要完整 Xcode(`xcbuild` 不随 CLT 分发)。
  **本机唯一能跑的 macOS 验收 = `bash macos/tools/selftest-verify.sh`**(10-24 实测 `pass=9 fail=0`;
  **这个数已漂** —— 傍晚新增三道配置变异后条数变了,一律以脚本末行自己打印的为准)
  —— 见上面第五节第 6 条与 AGENTS.md「macOS」一节的 10-24 改口块

  ⚠️ **上面这两句在 10-24 下午同时过期一半**(本人开始装完整 Xcode 之后现测的)。
  `xcode-select -p` 已切到 `/Applications/Xcode.app/Contents/Developer`(Xcode 27.1 / 27A9275),
  于是:
  ① **「CLT 缺 `SwiftUIMacros`」这个拦路没了** —— 宏插件在 Xcode 里有 5 份,含
  `MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib`;`xcbuild` 也在,
  但落点是 `Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/Support/xcbuild`,不是 `Developer/usr/bin/`。
  ② **换上了一个更靠前的拦路:Xcode 许可未同意。** 它挡的是 developer dir 的所有 shim,
  实测受影响:`xcrun` / `swift` / `swiftc` / `clang` / `/usr/bin/python3` / **`/usr/bin/git`**
  —— 连那句"本机唯一能跑的验收"也跑不了了:
  `bash macos/tools/selftest-verify.sh` 现在 **exit 1、`clang x86_64 失败`**(它只要 CLT 自带工具,
  而那些工具现在全在许可后面)。**所以这一轮之后,macOS 侧在本机是零验收可跑**,不是"只剩 selftest"。
  ③ **`sudo xcodebuild -license accept` 之后必须重跑判定**,不能直接按"装好了"写结论:
  要依次验 `selftest-verify.sh`(期望 `pass=9 fail=0`)、`swift build -c release`、
  以及 `./package.sh` 的架构硬断言与解包验收 —— 三条各自跑过才能把「本机出不了 macOS 包」这句撤掉。
  **▶ 10-24 傍晚这三条按序跑过了:① exit 0(新增三道配置变异后由脚本自己打印通过条数,`pass=9` 那句已漂)
  ② exit 0(`Build complete! 15.46 秒`)③ 第一次 **exit 1**,报的 9 条「判据词 0 命中」是**判据自己的错**
  —— Swift 的 `-O` 把 9~15 字节的字符串字面量拆进两条 `movabsq` 立即数,整词 grep 恒 0;改完词表之后
  **exit 0**,`dist/余音-Reverb-1.0.4-universal.dmg` **4 161 690 B** @13:39:05(包内 9 604 048 B、
  `x86_64 arm64` 两架构、4 套 `.lproj`、adhoc 签名验过)。逐条排除过程与教训见 **H209**。
  ⇒ **「本机出不了 macOS 包」这句在本文件与 AGENTS.md 里作废了;作废的范围只到"出包 + 解包验收",
  产物一帧没跑过,运行与界面验收仍然没做。**
  ④ 许可没同意期间**提交仍然做得动**,判据是绕开 shim 用真二进制:
  `/Library/Developer/CommandLineTools/usr/bin/git`(实测 2.54.0 Apple Git-157,Xcode 那份同版本同尺寸)。
  本轮文档提交就是这么走的。**别把这条当长期方案** —— 它是症状的 workaround,同意许可后 `/usr/bin/git` 自然恢复。
  **(傍晚已 accept,`/usr/bin/git` 与 `xcrun --show-sdk-path` 实测都恢复正常,现在用系统那个 git 就行。)**
- **真机**:Android 真机 + 鸿蒙真机各一台(序列号见 MIGRATION.txt);10-24 迁移当天**两台都没连上**
  (`adb devices` 的 "List of devices attached" 为空、`hdc list targets` 给 `[Empty]`),
  所以装机冒烟(第五节第 7 条)那次没跑成。
  ⚠️ 迁移后第一次 `adb devices` 报的是 **`failed to start daemon`**(带过来的旧 socket 让客户端连不上 5037),
  **这不是没装 adb** —— `adb kill-server` 之后 daemon 正常起、空列表才是"真没接设备"。
  `adb install -r` / `hdc install -r` 装包,**装机代理自办、要卸载才先备份**(硬规矩 12)
- **路径是写死在文档里的**,新机三串落点:
  `JAVA_HOME=/Users/cxyxl/Library/Java/JavaVirtualMachines/jdk-21.0.12.1+1.jdk/Contents/Home`、
  `android/local.properties` 的 `sdk.dir=/Users/cxyxl/Library/Android/sdk`(该文件 gitignore,新机要自己写)、
  `DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk`。
  新机用户名或安装位置一变,这三串就要同步改(AGENTS.md「环境准备」+ `README.md` + `CLAUDE.md` + 本文 + 各处构建命令)。
  ⚠️ **别拿 `/usr/libexec/java_home -v 17` 当版本校验**:10-24 实测它**忽略版本参数**、
  返回当前注册的最新 JVM 并 exit 0(`-v 99` 给同一个串)。旧机上它返回空 ⇒ 症状是"看起来像没装 JDK";
  新机上它静默给 21 ⇒ 症状是"要 17 拿到 21 而退出码是 0"。**两次都不是判据**,认版本用 `java_home -V`。
  **`aapt2` / `apksigner` 在新机同样不会在 PATH 里**(只有 `adb` 在),照 H156 用全路径并读退出码
- **认证与账号**:`origin` 走 SSH ⇒ `~/.ssh/` 里那几把私钥(`github_key` 等)必须带走或在新机重签;
  10-24 新机 `github_key` 在、`git ls-remote` 通(16 条分支 / 2 个标签 / 0 条未推送)。
  ⚠️ **同日下午装了 Xcode 之后 `/usr/bin/git` 被许可挡住**,那句"通"要改成"**用 CLT 那份 git 才通**"
  (`/Library/Developer/CommandLineTools/usr/bin/git`,原因见上面 macOS 那条 ②④)—— SSH 私钥本身没问题,
  被挡的是 git 这个入口。
  `gh` 的登录 10-23 实测存在 keyring 里,**不随目录拷贝走**,新机要装 `gh` 再 `gh auth login` 重来一次(10-24 两条都没做)。
  **10-24 下午:装的那一半做了(`brew install gh`,gh 2.103.2),`gh auth login` 那一半仍没做** ——
  `gh auth status` 现报 `The token in default is invalid`(搬过来的旧凭据已失效)。
  ⇒ **发版顺序第 5 步那两条必查项(`releases/latest` 的 tag 与 `assets[0].digest`)现在仍跑不了**:
  命令在、凭据不在。这一条只有本人能做(login 是交互式的,还要选 token 来源)。
  华为开发者账号 / 应用市场后台 / cxyxl.cn 部署凭据的落点见本节末尾那句(只在 MIGRATION.txt 与 BEIAN.md)
- **⚠️ 迁移会把口令副本再生一次**:`harmony/.hvigor/` 按第二节"永不拷贝"排除了,这正确;
  但**新机第一次 `build-release.sh` 会重新生成它,里面同样内嵌整份签名配置(含口令)**。
  所以"排除缓存"这件事在迁移后要**持续**成立,不是只在拷贝那一刻成立 —— 硬规矩 14 的忽略规则
  写成全层级 `.hvigor/` 正是为了这个(见 H208)

## 五、换机操作清单(按序执行)

1. **仓库本体有两条路,选一条,但都要验**:
   ① `git clone` —— 10-23 起可用:远端有全部 16 条分支与 2 个标签,判据
   `git log --branches --not --remotes --oneline | wc -l` = 0(本地 0 条未推送)。**它只给代码与历史**,
   第二节那些 gitignore 的东西一件都不带。
   ② 拷工程目录(含 `.git`)—— 会把第二节一起带走,代价是**必须先排除缓存**:
   `android/app/build`(实测 1.3 GB)、`android/.gradle`(21 MB)、`harmony/.hvigor`(10-24 实测 14 MB / 31 个文件,**里面内嵌签名口令:10 处 DevEco 密文串 + 22 968 条旧机绝对路径**),
   `harmony/entry/.cxx`(2.4 MB)、`*/oh_modules`、`harmony/build`(2.8 MB)、`macos/.build`、`android/local.properties`。
   ⚠️ **到新机后如果要把旧缓存留着比对,别在仓库内给它加后缀改名** —— 忽略规则只认 `.hvigor` 这个名字,
   改名等于把那层保护关掉(10-24 踩过,判据与现象在第二节"归档落点"那行)。要留就挪出仓库。
   到新机第一件事:再落一份异地副本(远端或第二块盘),别把"唯一副本"这件事重演一遍
2. **拷第二节全部资产**。口令类文件(jks/p12/keystore.properties)单独打包、加密传输,
   不要与代码包走同一渠道(流程见 MIGRATION.txt)。
   ⚠️ 10-23 补一句:**"全量拷贝工程目录"这一条腿覆盖不到第二节里那三处目录外资产** ——
   `~/.ohos/config/`(鸿蒙 debug 签名)、`~/Documents/cast-backup-20260925/`(filter-repo 之前历史的唯一副本)、
   `~/.qoder/`(项目记忆 / 全局偏好 / 两个本仓库专用 Skill)。它们要各自单独拷。
   **▶ 10-24 傍晚这条从三处改成六处**(第二节新增那几行的落点全都不在"工程目录"这条腿上,也不在原先三处里):
   另加 **`~/Downloads/LANDrop/`**(09-20 两份迁移分包 + 一整套散装 release 签名材料,含 `material/`)、
   **`~/Documents/reverb-signing-recovery-20260929/`**(旧密文与旧 material 的成对副本)、
   **`~/Documents/web/reverb/shots/`**(1.0.2 那批 11 个原始 PNG)。
   **换机时的正确问法不是"我拷了哪几个目录",而是"第二块盘上有没有这些"** ——
   这一轮实测 `tmutil destinationinfo` = `No destinations configured`,即**这台机器一份异地副本都没有**,
   而 `~/Documents` 又不在 iCloud 同步范围。
3. `cp harmony/build-profile.template.json5 harmony/build-profile.json5`,填入签名段
4. 按第四节装环境
5. 重建可重建产物:`./tools/build-asr.sh`
6. **三端构建验证**(都过 = 环境完整):
   - `cd android && ./build-release.sh`(唯一那份;解包复核见硬规矩 1。合并 flavor 后没有 `--store` 了)
   - `cd harmony && ./build-release.sh`(签名通过 = 第二节材料齐)
   - `cd macos && ./package.sh` —— **必须是一台装了完整 Xcode 的机器**(10-24 在新机上重新判过,
     结论比旧机那一版**更严**,不是"换了台机器就通了"):
     **只有 Command Line Tools 的机器连 `swift build` 都过不去** —— CLT 不带 `SwiftUIMacros` 宏插件,
     `@State` 展不开(`find "$(xcode-select -p)/usr/lib/swift" -name 'SwiftUIMacros*'` = 0;
     6 行 `@State` 最小复现同样报这一条,所以**跟源码无关**);出 universal 的 `--arch arm64 --arch x86_64`
     走 `xcbuild`,而 `xcbuild` 只随完整 Xcode 分发。
     **CLT 机器连原本准备的退路(整模块 `swiftc -typecheck` 差分)也没有了** —— 38 个文件一起 typecheck
     实测 exit 1,4 条错误**全部**是 `RootView.swift` 的宏展开那一条,所以基线根本到不了 0
     (H128 那条"第一个含错文件之后不再有意义地继续"在这里正好挡住:剩下的文件是否被检查**证明不了**)。
     ⚠️ 顺带记一次**无效对照**:把 38 个文件按"是否用到宏"拆两组分别 typecheck,两组都报错但报的是
     `cannot find 'Fmt' in scope` 这类跨文件符号 —— **拆组切断了模块内的依赖,那两组的读数不能用**。
     所以这类机器对 macOS 只剩"读代码 / 改代码"这一项能力。
     ⚠️ 旧机那四层门槛(SwiftPM 5.7.1 / 系统上限 12.7.6 / SDK 13.1 / `LSMinimumSystemVersion` 拒启动)
     在新机上**逐条都不成立也不再相关**;下面这几句是给历史记录留的,读的时候把"本机"换成"那台旧机":
     脚本默认出 universal,CLT 的 SwiftPM 还缺 `PackageDescription.swiftmodule` 连 manifest 都编不动,
     系统低于 13 的机器连产物都跑不起来 —— 逐层实测见 AGENTS.md「macOS」一节(含 10-24 改口块)与 H124 补记,
     新机的四条实测见 H208
7. 装真机冒烟:订阅一档、播一集、看逐字稿;截图管线试拍一张(AGENTS.md「截图」)
