# 余音 · Reverb 进度、遗留问题与演进方向

> 三端各自到了什么程度、还有哪些东西没做完或没验过、以后可能往哪走。
>
> 与其它文档的分工:功能全貌见 `PRODUCT.md` / `FEATURES.md`,实现见 `ARCHITECTURE.md`,
> 做的过程见 `HISTORY.md`,具体故障见 `TROUBLESHOOTING.md`。
> **本文只记「未完成」与「以后」**,所以通篇偏悲观 —— 那是它的用途。
>
> 状态截止 **2026-10-06**。
> **在架口径仍是 2026-10-01 用户给的那一次**(鸿蒙 1.0.3 在架、Android 暂停上架、macOS 不存在上架)——
> 那一行下面标着「2026-10-01」的日期是**口径的来源日期**,不是本文的更新时间,别把它们当过期信息改掉。
> 10-01 之后累计进来的是:10-02 全局复核(A2 三张表)、10-05/10-06 两批修复与 A2 逐条清账、
> 10-06 无障碍标注(#92 / H143)与 1.0.4 五道门。

---

## 一、三端版本与进度

**在架状态(2026-10-12 用户口径)**:鸿蒙 **1.0.4 已在应用市场在架**(上一版 1.0.3 亦审核通过,2026-10-01)
—— 这是三端里当前唯一的公开版本。
Android **只上过华为应用商店**,且**在架版本停在 1.0.1**:1.0.2 审核被拒,拒因就是 H120 那条
`a.gray.BulimiaTGen.f`「风险应用」误报 ⇒ **Android 暂时停止上架**。
macOS 走自分发 dmg,**不存在"上架"这一步**。
下表里的「就绪」只指代码与产物就绪,**不等于在架**。
⚠️ **2026-10-12 起主干代码已经比下表三份 1.0.4 包更新**:「播放缓存 + 封面磁盘缓存」(1.0.5 主线)已合入并升到
`versionCode 6 / 1000005`,而**双端包都还没重打** ⇒ `*/dist/` 里那三份是 1.0.4 的产物,
按硬规矩 20 **不能代表 1.0.5**,更不代表缓存功能已装机验过(见三-A 那一行)。

| | 已出包 | 主干当前 | 分发 | 状态 |
|---|---|---|---|---|
| **Android 自分发版** | 1.0.3(versionCode 4)`dist/reverb.apk` = 63,408 KB,**解包验收过** | **1.0.4 已出包(versionCode 5)`dist/reverb.apk` = 64,958,828 B / 168 条目,解包验收全绿**(当前这份是 **2026-10-10 09:27 的第十三次重打**,上游是「追更 = 全部订阅频道的全部单集」;判据见门 5「第十三 / 第十四次」那两段。核心成对判据:`classes.dex` 里 **`persisted=` / `parse=` / `sort=` 新 1 / 旧 0**) | 官网 / GitHub Releases | ⏸ **暂不发布**(Android 整体暂停,2026-10-01)。体积大是因为内置 57 MB 语音模型 + 1.6 MB `.so`。**这条不经商店审核**,所以那个拒因与它无关 —— 用户这次给的是"上架"口径,自分发渠道此前公开发过哪些版本**不在本次口径内**,别当已上线写 |
| **Android 大陆商店版** | 1.0.3(versionCode 4)`dist/reverb-store.apk` = 3,428 KB,**解包验收过** | **1.0.4 已出包(versionCode 5)`dist/reverb-store.apk` = 3,534,995 B / 165 条目,解包验收全绿**(当前这份是 **2026-10-10 09:37 的第十四次**,只重打 store —— 上游是解包验收抓出来的 **H169:store 关于页五语漏改「追更」栏与「待播」段**。`lib/` + 模型 + `RECORD_AUDIO` 三项仍为 0(权限清单 10 行整份打印过,与旧包逐字节相同);15 条新串 new=1/old=0、7 条旧串 new=0/old=1) | **目前只在华为应用商店**(不是"大陆各家") | ⛔ **在架版本停在 1.0.1**:1.0.2 提交审核被拒,拒因就是 H120 那条 `a.gray.BulimiaTGen.f` 风险应用误报 ⇒ **Android 暂时停止上架**(2026-10-01 用户决定)。1.0.4 的包已出好、解包验收过,但**先别传** —— H120 的**候选包名判别测试包还没做**,再传一次大概率还是同一个拒因(**这是 1.0.4 双端上架唯一还没解的前置**)。⚠️ 2026-10-10 路线重排:**"申诉"这条已从修法里撤出**(用户口径:腾讯没有可跟进的人工客服通道,投材料等于写进黑箱),而 **CA 证书背书这条路同时出局**(Android 签名模型不经证书机构 + H120 实测跨证书持续)。可控维度只剩**包名 / 包内容 / 不走商店的分发路径**三条,详见 H120 的「后续(2026-10-10)」。 |
| **HarmonyOS** | 1.0.2(versionCode 1000002)`dist/reverb.app` ≈ 952 KB | **1.0.4 已出包 —— 第十三次(2026-10-10 09:26)`dist/reverb.app` 1,098,727 B** / `entry-default.hap` 2,454,922 B / 18 个文件 / versionCode 1000004 / `app.debug=false`;核心串证:`modules.abc` 里 **`末次合并` 新 1 / 旧 0**,`resources.index` 里关于页追更那句**五语各 new=1 / old=0**。前几份依次留在 `dist/_backup-1.0.4-preGateWording-2337/`、`_backup-1.0.4-preInboxFull-0925/`(dist 不入库) | 仅应用市场 | ✅ **1.0.3 已在架**(审核通过,2026-10-01;签名经过见 H123)。审核提的那条 1.0.4 必修项(主题「跟随系统」要重进才生效)**已修并真机复验过**(H126,2026-10-06)。1.0.4 的包**已于 2026-10-12 确认上架**。✅ **主干当前已是 1.0.5 的码**(播放缓存 + 封面磁盘缓存,versionCode 1000005),**包未重打、功能未装机** —— 见三-A 那一行 |
| **macOS** | 1.0.2(build 1)—— 唯一的历史包已归档到 `dist/余音-Reverb-1.0.2-arm64.dmg`(9 月 20 日**另一台机器**打的:`minos 13.0 / sdk 26.5 / arm64 单架构`) | **播放模式 + 列表自动连播已同构移植(2026-09-29)**、**批注已同构移植(2026-10-01)**;`Info.plist` 已 bump **1.0.4 / build 2**,包还没出 —— `package.sh` 已改成「**universal 编译 → 架构硬断言 → 签名 → 解包验收 → dmg(带版本与 universal 标记)进 `dist/`**」一条命令,但**本机跑不到那一步** | 自分发 dmg,**不存在"上架"这一步**(2026-10-01 用户确认:macOS 无需上架) | 代码就绪(**含 2026-10-07 的 H157 设置页五处提示与 H159 海报 / 剪藏两处**,四套 `.strings` 各 +7 键、五语取值与两端逐字一致),**出包与运行验收都未做**;**分工已定(2026-09-29 用户决定):这台机器只做 Android / 鸿蒙 + macOS 的读改与类型检查,出包固定在另一台** —— 本机六层不够(tools-version 5.7 vs 5.9、SDK 封在 13.1、`LSMinimumSystemVersion 13.0` 让 LaunchServices 报 -10825、根导航用了 macOS 13+ 的 `NavigationStack`(缺符号即崩)、CLT 的 ManifestAPI 没有 `.swiftmodule`、多 `--arch` 要 xcbuild 而它只随完整 Xcode),见三-A 最后一行与 H124 补记。**「装旧版 Xcode 迁就本机」已评估并否掉**(2026-09-30,见三-A)。**顺带:本机的「typecheck 基线差分」判据已于 2026-10-01 修正,先前那种"两边错误条数一致"的比法有一条覆盖洞,见 H128** |

> 产物尺寸是**上一版实测值**,新版出包后要重新量(尤其鸿蒙这次改了资源与混淆口径)。

**1.0.3 Android 两渠道的解包验收**(2026-09-29 21:2x,硬规矩 1 的口径;处理量先摆出来:
`reverb.apk` 168 条目 / dex 1 个 6,364,616 B,`reverb-store.apk` 165 条目 / dex 1 个 6,352,056 B):

| 判据 | 期望 | default 实测 | store 实测 |
|---|---|---|---|
| `aapt2 dump badging` 包版本 | 两端都 4 / 1.0.3 | ✅ `versionCode='4' versionName='1.0.3'` | ✅ 同左 |
| `lib/` 条目 | default 1 / store **0** | ✅ `lib/arm64-v8a/libreverb_asr.so` 1,679,264 B | ✅ 0 |
| `whisper-model` 条目 | default 1 / store **0** | ✅ `assets/whisper-model.bin` 59,707,625 B | ✅ 0 |
| `RECORD_AUDIO` | default 1 / store **0** | ✅ 在(9 条权限) | ✅ 0(7 条;比 default 少 `RECORD_AUDIO` + `MODIFY_AUDIO_SETTINGS`) |
| 目录接口 URL(在线目录已恢复,H70) | **两侧都非 0** | ✅ dex 内 `itunes.apple.com`=1 / `fyyd`=3 / `gpodder`=3 | ✅ 同样 1 / 3 / 3 |
| 签名方案 | v2+v3,并**显式补 v1** | ✅ v2 true / v3 true;v1 见下 | ✅ 同左 |

**v1 的判读口径**(容易自己骗自己,写死在这里):`apksigner verify --verbose` 对这两包都报
`Verified using v1 scheme (JAR signing): false` —— **这不是没补上**,而是 minSdk≥24 时平台安装校验
根本不采用 v1,apksigner 如实报"不采用"。要看块在不在,用 `jarsigner -verify`(两包都回
`jar verified.`)或直接查 `META-INF/REVERB.SF` + `REVERB.RSA` + `MANIFEST.MF` 三件齐不齐。
补签这一步在 `build-release.sh` 里,不是 gradle 的 `enableV1Signing`(AGP 8.5 在 minSdk≥24 会忽略它)。

**没扫的**:两包的 dex 里没有再核 `BOOT_COMPLETED`(1.0.3 删掉的那条权限)—— 上面权限清单
已经证明它不在 manifest;至于**代码里**是否还残留接收器类,本轮没扫。

功能完整度(以自分发 Android 版为基准 100%):

- **macOS ≈ 95%**:少真实频谱与后台更新巡检(均为平台限制),多一项「系统级词级转录」质量更好
  (**「批注」2026-10-01 已同构,Android / 鸿蒙已真机跑过(2026-10-05 / 10-07),macOS 仍一帧没看过**)
- **HarmonyOS ≈ 85%**:少真实频谱、少本机语音转写;其余对齐(**「批注」2026-10-01 已同构,并已在这台机上真机跑过六条里的四条 + 备份恢复一整圈**)
- **Android 大陆商店版 ≈ 85%**:少真实频谱、本机语音转写与内置种子;在线目录与电台已恢复,与 HarmonyOS 同档

> ~~一处待统一的小事:macOS 版本号写的是 `1.0`,另两端是 `1.0.0`~~
> ✅ **2026-09-10 已统一并动态化**:三端都是 `1.0.1`,且 App 内展示一律**运行时读取包信息**
> (Android `BuildConfig.VERSION_NAME` / 鸿蒙 `bundleManager` / macOS 读 `Info.plist`),
> 字符串资源里不再写死版本 —— 以后发版只改构建配置一处。

### 1.0.2(代码已齐,待正式出包)

两个功能都已在主干实现并过验收(2026-09-13),版本号 bump 与发布材料统一在出包时做:

- **频道分享(三端)**:频道详情页生成含频道 Logo、频道名、简介与「余音 · Reverb」落款的水墨图片,
  交给系统分享面板;不分享 RSS 地址,避免私有订阅源凭据泄露。
  已完成:三端真机验证(macOS 卡片与 ShareLink 面板、Android 两渠道真机、
  鸿蒙 ShareKit 面板与快进不空白探针)。
- **系统级备份(Android Auto Backup + 鸿蒙 BackupExtensionAbility)**:
  白名单数据进用户自己的系统云(H84 记录的决策翻转)。已完成:双渠道 debug 解包
  (manifest + 两份规则各 9 项 include)、鸿蒙 hap 解包、真机 `bm dump` 注册确认
  与数据路径核对;隐私文案五语种同步且**未升 PRIVACY_VERSION**(不重弹同意页)。

**出包前清单**(✅ 2026-09-20 已出包;分发平台的运营事项——截图重拍、物料包重建、
渠道安全扫描、官网部署核验——都不在此文,记在本地运营手册):

1. ✅ 版本号:Android versionCode 3 / versionName 1.0.2,鸿蒙 1000002 / 1.0.2,macOS 1.0.2(8795273)
2. ✅ release 包解包复核(硬规矩 1 全套):商店渠道 native/模型 0、目录接口 grep 4、
   权限无 RECORD_AUDIO;两渠道 allowBackup=true + fullBackupContent 9 项 include +
   dataExtractionRules(云+迁移两段各 9);鸿蒙 release .app 的 modules.abc 目录接口 grep 3、
   BackupExtension + backup_config 8 项 include、权限仅 INTERNET/GET_NETWORK_INFO/KEEP_BACKGROUND_RUNNING;
   版本号三包核对一致
3. ✅/⬜ App 内备份恢复跨端链路已验:桌面 reverb-backup.json(订阅 31/历史 100/统计 88/设置)
   经 hdc 推到鸿蒙 Download → 设置→恢复备份→选文件 → hilog「恢复订阅 31 条/恢复下载 1 集/
   恢复完成 importedSettings=true」,订阅/历史/收听统计页面均实数据渲染(2026-09-20 debug hap 真机)。
   ⬜ 剩系统云备份链路:Android 已验(LocalTransport,见三-A);鸿蒙等市场包发布后走
   (debug 包不进备份选项清单,见 harmony-cloud-backup 卡口)

### 1.0.3(鸿蒙市场包**已出包、解包核对全绿**,2026-09-29 20:05)

2026-09-29:三端里这轮只有鸿蒙要出市场包(Android 代码同批已齐,出包时 bump versionCode 4;
macOS 的 1.0.3 尚未出包 —— 它的播放模式是**同日在 1.0.3 定稿之后**才同构移植过去的,不会回到 1.0.3 那两节
的对外说明里,见 FEATURES.md 该行与 CHANGELOG 的 1.0.4 节)。

- ✅ 版本号:`harmony/AppScope/app.json5` → versionCode 1000003 / versionName 1.0.3
- ✅ `CHANGELOG.md` 1.0.3 节已定稿(对外版本说明的上游)
- ✅ 硬规矩 5 同步:关于页 `about_p_features` 补「播放模式」一项,五语种 × 两端共 10 份文件;
  顺手改掉 fr 一处拼写(`statististiques` → `statistiques`,两端各一处,原本就在)
- ✅ release 模式编译与打包都过(`entry/build/release/…/entry-default-unsigned.hap` 2.36 MB)
- ⚠️ **`SignHap` 失败(2026-09-29 白天,已于当晚 20:05 解决并出包)**:DevEco 的自动生成签名在 09-26 把
  `build-profile.json5` 的 **release 段**一起改写成了绑临时测试包名的 debug 材料。
  - ✅ **配置侧已回滚**:从覆盖前的两份备份(`~/Documents/cast-backup-20260925`、
    `~/Downloads/LANDrop/reverb-migrate-secrets-20260920`,都是 08-15 那一版)整段恢复 release 段,
    拿回 `./signature/reverb.{p12,p7b,cer}` + keyAlias **`yuyin`** + 两串加密口令;
    动手前把当时的配置与 material 存进 `~/Documents/reverb-signing-recovery-20260929/`(可退)。
  - ✅ **卡口加进 `build-release.sh`**:开跑前 1 秒校验「release 段指向 signature/*」
    「profile 的 bundle-name 等于 app.json5」「profile 的 type 是 release」,不合格就打印修法。
    两个方向都实测过(坏配置三条全中并退出、好配置放行)。
  - ⚠️→✅ **明文口令这条路的终局:回滚不可行,只能重做签名材料。** 回滚带回的 08-15 密文解不开 ——
    解密密钥 `harmony/signature/material/` 在 09-26 12:14 被重写,而 material 是**每个目录一套随机密钥、
    全盘没有旧副本**(与 `~/.ohos/config/material/`、IDE 的 `…/DevEcoStudio26.0/options/data2/material/`
    逐套试解,三套都解不开那两串),于是报 `00303242 … unable to authenticate data`(GCM authTag 不过)。
    **判定方法(比试错快,可复现)**:直接调 DevEco 自己的
    `hvigor-ohos-plugin/src/utils/decipher-util.js` 的 `decryptPwd(path.resolve(storeFile,'..'), 密文)`,
    并拿一份**已知能签成功的配置**当对照(09-26 自动签名那份的 default 段能解出 11 位明文) ——
    对照不过说明是判定实现写错了,不是密文失配。自研复刻版曾把 default 段也判成解不开,就是假阴
    (坑在 `material/fd/0|1|2` 是**子目录**,得读子目录里那个 16 字节文件)。
    **由用户本人**在 DevEco 重做签名材料后出包;代填口令、代改签名文件、代回滚都不做(见 H123 教训 ⑦)。
  - ⬜ 明文口令若确实找不回:只能新 CSR → 平台重发一张发布证书 + Profile。
    **前提**是先在分发平台后台核实没有以旧证书提交/过审的版本(同包名换签名会断已装用户的升级路径,H82 前提)。
  - ℹ️ 私钥与证书本体都完好(`harmony/signature/reverb.*` 自 08-15 未动、Profile 有效期到 2029-08)。
- ✅ **市场包已打出并核对通过**:`dist/reverb.app` 1032 KB(hap 2 359 391 B)+ `reverb-symbol.zip` 616 KB。
  签名这一关的完整经过(自动签名覆盖 → 回滚配置带回旧密文 → material 失配 → 用户重做签名材料后
  又因 material 每层残留两份文件报 `00303121`)记在 **H123**,含可复现的判定方法。
- ✅ 解包核对(硬规矩 1,**两侧都验**,处理量:hap 内 17 个文件 / 解包后 2 357 081 B,
  连 .app 外层共扫 20 个文件 / 4 717 447 B):
  - 目录接口「有」侧:`modules.abc` 里 itunes.apple.com=1、fyyd=3、gpodder=3(均非 0)
  - 「没有」侧:`debugKey` 0 命中(20 个文件全扫)、`RECORD_AUDIO` 0、whisper 相关 0
  - 权限恰好三条:`INTERNET` / `GET_NETWORK_INFO` / `KEEP_BACKGROUND_RUNNING`
  - `BackupExtension`(带 `$profile:backup_config`)+ `FeedUpdateExtension`(workScheduler)都在;
    `backup_config.json` 的 `includes` **8 项**齐全,`allowToBackupRestore=true`
  - 版本一致:`module.json` 与 `pack.info` 都是 1000003 / 1.0.3,`bundleName=com.yuyin.reverb`、
    `debug=false`、`buildMode=release`、`apiReleaseType=Release`
  - 硬规矩 5 复核:五语种关于页在 `resources.index`(75 568 B)里都能搜到播放模式一行
    (简中「顺序」/繁中「順序、單曲循環」/英 sequential / 法 modes de lecture / 西 modos de reproducción)
  - 未覆盖范围:**没有装机实跑**(市场包只解包核对;真机验证按惯例走 debug hap + 临时测试包名),
    签名链有效性依赖 AGC 上传时的校验;`libc++_shared.so`(1.26 MB)与 `libreverb_pcm.so`(58 KB)是
    预期的 native 件,未逐项反编译
- ✅ **debug 签名同日也由用户修好**:`build-profile.json5` 的 default 段现在指向真实存在的 `.p12`,
  profile 绑**正式包名** `com.yuyin.reverb`、`type=debug`;`assembleHap -p product=default -p buildMode=debug`
  的 `SignHap` 跑过(7.7 s),产出 `entry/build/default/outputs/default/entry-default-signed.hap` 3.84 MB。
  **只做到"能签",没有装机**(正式包名可能与设备上已装版本签名不同,覆盖安装要先问用户)。
  修好之后按 H123 教训复验过 release 段:三段材料路径、`keyAlias=yuyin`、profile 绑 `com.yuyin.reverb`
  且 `type=release` 全部未变,两串口令密文仍能解 —— 所以 20:05 那个市场包不必重打。
- ⬜ 分发平台的运营事项(截图重拍、物料包重建、审核提交)按惯例不在此文,记本地运营手册

---

### 1.0.4(目标:**Android + 鸿蒙双端上架**,2026-10-06 用户定)

本版不是"攒一批改动起个名",而是**两端都要出正式包并交到分发渠道**:Android 走商店渠道(华为应用商店 + 自分发 apk),鸿蒙走应用市场。
由此,下面五道门**全过才有包**,顺序不按"哪个先做完"而按"哪道门会挡死后面所有步"。

| # | 门 | 现状与判据 |
|---|---|---|
| 1 | **Android 的 1.0.2 拒因必须先解**(=#62) | 商店在架版本停在 1.0.1,1.0.2 因 `a.gray.BulimiaTGen.f`「风险应用」**误报**被拒(H120),此后 Android 整体暂停上架。**这条不解决,1.0.4 传上去撞的是同一堵墙** —— 与本版代码改动无关,属前置。**2026-10-10 路线重排**:「申诉」撤出(腾讯无可跟进的人工通道,用户口径)、「买 CA 代码签名证书」出局(Android 信任根里没有颁发者字段可被采信 + H120 跨证书实测)⇒ 剩下唯一手段是**候选包名判别测试包**(需要用户出包 + 装机 + 覆盖一个云端重扫周期)。**⚠️ 2026-10-10 两条追加口径**:①**跑判别之前冻结 store 包内容** —— 这个实验的全部效力来自"只有包名变了",顺手改包面特征会让结果无从归因(见 H120 教训 ⑥);②`AndroidManifest.xml:37` 的全局明文开关**不是等价改写** —— 按域白名单只能列已知域,而「按 URL 订阅」把 `http://` 当合法输入,默认拒绝明文等于关掉这条功能路径,要单独拍板(H120 后续第 3 条已按实测更正)。**不需要拍板的那一半已做**:内置清单 9 条 + 官网 OPML 3 条明文源升 https 并逐个实拉到 RSS 验过(这两家 host 的 14 个 feed 共 9,041 条 enclosure 全是 https);清单只进 default 渠道与被测的 store 包无关,但 **default 渠道的 1.0.4 包要重打**、OPML 的**线上那份还没重新部署**。**另一条不依赖厂商的路:自分发渠道不经审核,1.0.4 现在就能发** |
| 2 | **装机复验批次必须跑**(=#84/#85/#60/#61/#66/#67/#98) | 本版的改动里**绝大多数只过到编译**:备份分区勾选框(H141 六条)、日志四行与文件附件(H142 四条)、播放态跨启动补验(H129)、批注(H127/H133)、跟随系统深色(H126,市场审核提的那条 **1.0.4 必修**)、睡眠倒计时收敛(H132)、分类排序手势(H139 那批)、**无障碍标注实听三条**(H143:主播放键随状态念「播放」/「暂停」、已下载的图标念「已下载,点击删除」、快退键念「快退 15 秒」而不是「15」)。**【2026-10-07:Android 那一半已从"只能实听"变成"工具读得到",见 H143 补记】** 三条在 Pixel 3 的 `1.0.4-debug` 上用 `uiautomator dump` 的 `content-desc` 逐条读到 —— 暂停↔播放随状态**在同一坐标当场换名**、已下载↔下载两态各读到 `已下载，点击删除` 与 `下载`、把设置里快退改到 15 秒之后标签跟着变 `快退 15 秒`(所以它是按秒数重算的,不是写死)。顺手还取到收藏键随点击当场换名、队列页上移/下移/移出队列三条 —— **判据边界也写清了**:`uiautomator` 的层级取自 AccessibilityNodeInfo,所以标签读得出; 而 H129 补记那条「禁用态读不出」仍然成立,两件事不可互推。鸿蒙那三条**仍然只能实听**,而且判据在 2026-10-08 又收紧了一档(见 H143 补记):**不是「`SymbolGlyph` 这类节点恒空」,而是 `uitest dumpLayout` 整条通道没有无障碍字段** —— 本轮 83 份鸿蒙 dump、13,958 个节点里 `description` 非空 **0 个**,而同批 `text` 非空 2,221 个(所以不是解析失败,是通道就没有)。**由此新增一条同族判据:播放页进度条**。ArkUI 的 `Slider` 不设 `accessibilityText` 时把 **value 原始数字**念出来,真机 dump 里是 `101300.000000` 而界面上写 `01:41`;已加「当前 / 总长」两个格式化时间的标签,**但这条加完同样只能实听**。并且不要再拿"Android 念百分比"当对照 —— 那是没测过的推断:Android 的 `android.widget.SeekBar` 节点 `content-desc` 是**空串**、dump 里也不含 range 信息,**两端这一寸都只能实听**。macOS 那一格未动。<br>**Android 用 debug 包(正式包名里是真实用户数据,**要换签名才能装时先按硬规矩 12 备份**),鸿蒙装机前先 `bm dump` 认对面是 debug 还是 release。**装机不用问**(2026-10-16 用户改口,授权与 release 备份步骤见硬规矩 12)。<br>**已跑完的两条(2026-10-06)**:跟随系统深色 **H126**(②③④ 过,① 只到两段拼接,原始形状本机造不出来 —— 逐条与缺口见该条补记)、长时任务空窗 **H125**(播中切集两个方向各 736 / 723 ms 窗口内零 `[Background]` 行,负控制是同会话明确暂停那跳系统侧照打 `onContinuousTaskStop`)。另:播放态跨启动同日补上 **③**(冷启恢复后点迷你条:`AudioSession 已激活 → state=playing` 实测 38 / 30 ms,且**全程零条 `播放 … 源=网络`** = 没重下单、预载直接出声)、**⑥ 双向**(H145)、**⑧ 电台分支**(冷启读到 `cur=- ctx=0@0 upNext=0`、零条 `restore cur=`、迷你条节点 0)。**同日 H141 六条全部走完**(`BackupSectionDialog` 8 行连点两轮圈都当场跟着变 / 全不勾那颗 `opacity` 1.0→0.38 且点了无面板无日志 / `导出 分区=2` 与勾选数一致 / 只含两分区的旧备份其恢复框 `rows=2` 且「批注」不出现 / **取消的两条路各自都静默**:返回键有 `[Files] 用户取消保存` 无提示、✕ 连日志都没有也无日志,因为 promise 压根不 resolve / fr 与 es 各装一次语言后 8 行、行距 183px、末行完整露出且离按钮 26px 无裁切)⇒ 这一批里**唯一一条"改了交互形状、必须装机才验得到"的**已落地。**装机的同一轮里撞到并修掉两条**:(a)**H146**「语言」弹层点「跟随系统」当场不生效、冷启动也不生效 —— 根因是 `setAppPreferredLanguage('default')` 按 SDK 说明**只在冷启动生效**,而本端切语言靠 `loadContent` 当场重画;修法是当场把系统语言解析成具体标签、持久化仍存空串。(诊断期间差点被一次**假冷启动**骗过去:`aa force-stop -b <包>` 报 10104002 根本没杀进程,判据只能是杀前后 `pidof` 的 PID 变没变。)(b)**#99** `Files.saveText` 返回 `boolean`,于是导出备份 / OPML / 日志三处把「按了取消」渲染成「操作未完成」,与 Android 那四个 `if (uri != null)` 的静默口径不一致 ⇒ 改成 `SavedResult{cancelled, ok}`,已在真机双向验过(取消无提示、成功出现「已导出备份」)。<br>**同日又跑完三项**:(c)**H142 ①** —— 鸿蒙分享日志的面板里是一张**文件卡片**「Reverb log, 2.08 KB」而不是内联文本块(⚠️ 收到的那一端本机没有可用接收目标,所以"末尾不被截"这一半仍是推断,本端能证明的只有"交出去的是文件 uri");**② 只验到卡片层**(标题/描述实测「余音 HarmonyOS 日志反馈, 请描述你遇到的问题…」),**落进邮件应用之后的两条判据在本机不可验** —— 系统邮件应用里没有已登录账号,点它直接进「账户登录」页,**没有登录任何账号、没填凭据**,原路退出;分享面板按 ✕ **既无提示也无日志**(promise 压根不 resolve,与 H147 的**保存侧**必须由 `cancelled` 区分是两回事)。(d)**H148** —— 同一次同屏对照里发现设置页「当前日志 **9 KB**」而分享卡片是 3.73 KB:`sizeBytes()` 写的是「每字符 × 3」(按中文估),而日志行**以 ASCII 为主** ⇒ 2.4 倍高估;改成按 `dump()` 的真实 UTF-8 字节并算入行间 `\n`,装机后「**2 KB**」↔ 卡片「**2.08 KB**」。**判据是两个数一致,不是数字变小了**。(e)**分类排序的长按拖动四条真机走完**(慢速 `uitest uiInput drag`、velocity 200 足以同时满足 `LongPressGesture{500ms}` + `PanGesture`):首行下移一行、再拖第二行上移两行 ⇒ 草稿过半才换位且两次都对;「完成」→ `[Category] 保存顺序 19 项` + chip 行当场变序;**冷启动**(force-stop 后 `pidof` 由空到新 PID)读到 `[Category] 自定义顺序 19 项`、chip 序保持;「取消」那一路**丢弃草稿**(拖完点取消,chip 仍是旧序)。设备末态已把 chip 拖回默认(推荐/新闻/商业/…)。(f)**播放态 ⑤ 的后半(播完自动接同一列的下一集)鸿蒙真机等完了一整次**:同一列内 `ctx=5@0 → 5@1`、队列代际 1→2,不是跨列也不是电台分支;顺带量到另一条形态 —— 从批注行 `playAt` 起的播放(`ctx=1@0`)播完**不续列**,只释放 AudioSession 与长时任务,这正是设计要的。(g)**批注的备份/恢复闭环(判据 ⑤)鸿蒙真机走完**:分区框只勾「批注」→ 导出 → `Download/reverb-backup.json` 2.19 KB → 在批注段用垃圾桶删掉那条(确认框里带被删原文,`[Store] 删批注 … total=0`,段内落到空态)→ 恢复备份 → **「恢复数据」对话框里只列出「批注」一个分区**,`[Backup] 恢复完成 importedSettings=false` ⇒ 文件确实只含勾选的那一份,而恢复侧的分区清单是**从文件内容推出来的**(不是照抄导出侧的 8 行)→ 那条批注回来,文字 / 时间戳 / 所属集与删除前逐项一致,条数 1 → **再恢复一次同一个文件,条数仍是 1**(合并幂等,没有翻倍)。(h)**H138 的读盘归一在 Android 真机跑通了(2026-10-07)**:六条手写 `notes.json`(甲 `createdAt=2000` / 乙一·乙二**同刻** 3000 / 丙 `positionMs=-90000` / 丁缺 `episode` / 戊 `audioUrl` 空)经 `cat` 管道进 `adb shell "run-as <debug 包> sh -c 'cat > files/notes.json'"` 写进沙箱(**`run-as` 读不到 `/sdcard`,只能走 stdin**),`force-stop` 后冷启动 ⇒ 批注段四行:乙一 02:03 / 乙二 03:42 / 甲 10:54 / 丙 **00:00**,丁戊不出现 ⇒ 倒序、同刻稳定、负值归 0、无效条目跳过四条一次全中。**同一天把「鸿蒙侧不可取证」那句更正掉了**:应用自己的沙箱文件 `hdc shell cat` 可读(`/data/app/el2/100/base/<bundle>/haps/entry/files/`,写不可),于是两端各取一份真机写出的 `notes.json` 逐键比对:外层 5 键 + `episode` 内层 11 键**同序**、同为紧凑无空格 JSON ⇒ 三端格式互通这条从推定变成实测;唯一差异是 id 生成式(UUID vs `now-random`),合并只按全等去重故不影响。~~**鸿蒙侧这条仍不可注入**(沙箱只读、Download 那份应用读不到)~~ ⇒ **2026-10-07 更正:可以注入**。那句"沙箱只读"是在 release 签名包上试出来的,对 **debug hap 不成立** —— `hdc file send` 能直接写进应用沙箱(落盘属主仍是应用 uid,下次启动就读得到),同一手法在 H150 的双端同夹具验收里已经用来注入鸿蒙侧的订阅数据了。所以这六条夹具在鸿蒙侧复现同一张表**不再有工具缺口** —— 且**同日(2026-10-07)真的跑完了**:`hdc file send` 把乱序六条写进 `haps/entry/files/notes.json` → 冷启动 ⇒ 日志 `[Store] 批注加载 4 条`、批注段四行「乙一 02:03 / 乙二 03:42 / 甲 10:54 / 丙 00:00」**与 Android 那张表逐行同字同序**,删掉乙一之后盘上 `h138-ding`/`h138-wu` 计数归 0(整份重写带走被跳过的条目,两端行为一致)。末态 `notes.json` 推回 recv 的那份 `[]`(2 B),重启后日志仍是 `批注加载 0 条`。逐条见 H138 验收。**macOS 未跑。**<br>**设备末态如实记录**:主题与语言已回到用户原配置(跟随系统 + 深色·水墨);测试批注「装机验收批注甲」验完已删除,**批注段现在是空的**(同日为了取字节又恢复过一次、读完再删,末态仍是空)；Android debug 侧那六条 H138 测试批注也已逐条删净;同日 H133⑦ 那套 ENDED 夹具同样收干净 —— 测试批注走行内图标 + 二次确认(确认框正文带原句)删除,日志 `NoteStore remove … total=0`、`files/tail_probe.wav`(1,440,044 B)已 rm、`favorites.json` / `history.json` / `playback_state.json` / `listen_stats.json` 四份按 md5 逐字节还原到夹具之前那份快照(`history.json` 冷启动时被应用自己重写了一次,唯一差异是一个 `updatedAt` 时间戳,11 条内容与顺序全同)、收藏列的播放模式点回**随机播放**(`play_mode_map` 的 `fav=2`,与改动前同值)。⚠️ **`notes.json` 的末态是"文件不存在"而不是 `[]`** —— 这是有意:该文件先前由 `cat >` 注入过,权限落成 `666`(同目录其余都是 `600`),而批注正文是用户文本,不该 world-readable,所以删掉让应用下次写入时按自己的 `600` 重建;`Download/reverb-backup.json` 是**只含批注分区**的那一份(2.19 KB,且里面那条批注已删,恢复它不会带回任何东西)—— 覆盖掉了上一轮那份含 8 分区的测试文件;Android debug 侧为 H142 ③ 落的 `/sdcard/Download/reverb-log.txt`、`还142.txt` 与 `cache/shares/reverb-log.txt` 三份测试文件已删净(两处 `ls` 均 `total 0`,MediaStore 行随之消失),但**它的日志缓冲被「清空日志」清成了 0 B** —— 这是那条空分支判据的必经动作、不可逆,9-27 起那 8,538 行已在清空前 pull 存档。**H142 ④ 这一轮又在这台机上落了三份,同样已清**:注入用的 `/sdcard/Download/reverb-log.txt`(那一次它是个**目录**)、SAF 撞名自动改名的 `reverb-log (1).txt`(76,336 B)、正向对照重新生成的 `cache/shares/reverb-log.txt`(81,908 B);`cache/shares` 本身是 `rmdir` 之后由应用重建的,末态 `drwx--S---` 与故障前逐字相同;`files/` 六个数据文件 md5 与装机前全等(变的三份 history / popular_cache / profileInstalled 都是应用自己写的),`notes.json` 仍不存在。鸿蒙侧:H149 那套临时探针所在的**带仪表 debug 包已被干净包替掉**(4,038,933 B、解包核对过 `[Probe]`=0),真机上一集(岩中花述 S9E9)播到中途后暂停,迷你条在;⚠️ **两个合成稿缓存曾记为"删不掉",2026-10-07 已删**:原先那句"sandbox 不可写"只对 **release 签名包**成立 —— debug hap 的沙箱**双向都进得去**(`hdc file recv` 读、`hdc file send` 写、`hdc shell rm` 删,落盘属主仍是应用 uid),`files/transcripts/h137_synth_0001.zh-CN.json`(167,972 B)与 `…_0002…`(129,437 B)已用后者清掉,复验过目录里不再存在(见 H149 补记)。**这一条的教训是"删不掉"这个结论本身当时是错的**:它来自在 release 包上试了一次 permission denied 就外推到了 debug 包;<br>另外**「沙箱可写 ⇒ 备份互通不必人工搬文件」这句也被推翻过一次**:恢复走的是 `DocumentViewPicker`,它看的是**媒体库 Docs** 而不是私有沙箱,塞进沙箱选择器看不见;真正通的那一步是 `hdc file send` 进 `/storage/media/100/local/files/Docs/`(见下面 (i) 那段);<br>**剩余待跑**:H143/#92 读屏三条(**只能人耳判**,`dumpLayout` 对 `SymbolGlyph.description` 恒空)。**H133⑦(编辑器开着跨集)两端都已于 2026-10-07 验到 `ENDED` 自动续播那一瞬间** —— 鸿蒙靠把剩余时间压到 9~20 秒真等片尾;Android 先跑了一次媒体键手动换集(那一次**还没**跑到那一寸),随后用离线夹具补上:90 秒合成 WAV 走 `file://` 播、夹具列表放收藏列、下一集故意指向一个不存在的文件 ⇒ 自动续播立刻 `onPlayerError code=2001` → `state IDLE`,于是"编辑器开着而 `current` 已换"这一格从一闪而过撑成 48 秒的稳定窗口。判据是盘上那两个数(`episode.id` 仍是甲、`positionMs` 仍是开弹层那一刻的 36679,而保存发生在换集之后 48 秒)。手法逐条记在 **H133 的补记**。<br>**(i)H140 的跨端恢复 ✅ 已于 2026-10-07 双向真机跑完,28 项断言 0 条 ✗**(原判据 = Android 导出 → 鸿蒙恢复,逐项核对深色态/字号档/语言/仅 Wi-Fi/更新提醒/分类顺序,反向再跑一遍 —— 两侧都跑了:Android 导出 14 键 → 鸿蒙 `preferences/reverb_settings`,鸿蒙导出 14 键 → Android `reverb_settings.xml` + `reverb_prefs.xml`;界面侧当场生效:鸿蒙转深色,Android 整页转浅色·宣纸 + 字号「特大」+ 快进 30 秒并弹「恢复完成」)。<br>**这条为什么此前挂"未真机"、又是怎么解开的**:(a)**两端原本设置完全相同**,直接交叉恢复验不出东西 —— 所以先把每端各挑 ≥2 个键改成与对方不同的值,再拿对方的导出恢复,然后**逐键**核对(本端自产自读永远测不出"导出少写了一个键")。(b)**阻塞点不在工具而在选路**:恢复走 `Files.pickText` → `DocumentViewPicker`,它浏览的是**媒体库 Docs**(`/storage/media/100/local/files/Docs/`),不是应用私有沙箱 —— 把文件塞进沙箱选择器看不见;而 `hdc file send <本地> /storage/media/100/local/files/Docs/` 直接落得进去(属主 `20001006`,与选择器自己写出的那份同一属主),选中后应用**真的读到了内容**(日志 `[picker] document select … errorcode is = 0` + 返回 URI,28,930 行 hilog 里 `恢复解析失败` **0 次**;内容只有 `{"probe":"send-test"}` 的探针文件走的是「无法识别的备份文件」那一支 —— **文件读不出/解析失败**与**读出但不是备份**在日志上分得开)。<br>**三个操作坑 + 两条口径记在 H149 的第三层补记里**,择要:① 选择器顶部「文档」芯片查的是**媒体库索引**,hdc 推进去的文件它看不见,必须走 浏览 → 我的手机 那棵目录树;② SAF 宫格视图的 `dump` 里 text/bounds 会**错一格**(第一次交叉恢复因此点到了同名旧文件,那一次不作数 —— 夹具必须换名或换目录);③ **Android 有两个 prefs 文件**(`reverb_settings.xml` 存大部分设置,`category_order`/`region_override` 在 `reverb_prefs.xml`),鸿蒙只有一个,核对时别只看一处;④ 字号**两端都优先 `fontScale`、下标 `fontIndex` 回落**,所以一份文件不会在两台机器上落出两档;⑤ `categoryOrder: []` 在两端都是**「不动本机顺序」的有意语义**,不是失败。<br>**这一批里"帧率/重建次数"那三条已于 2026-10-07 全部量完(H132 睡眠倒计时、H137 逐字稿渲染路径、H139 分类胶囊跟手)**,用的不是数 jank(它们身上 jank 恒为 0,而"没掉帧"证明不了"没白重建"),是临时属性计数器:组件根节点挂 `.opacity(Probe.op('x-const'))` + `.saturate(Probe.op('x-dep', this.<@State>))`,每秒把计数打一条 `[Probe]` 进 hilog,`SeekBar` 那一支(自己 250 ms 轮询,必然 4/s)当阳性对照。**结论三条**:定时开着时**只有** `SleepCountdownText` 每秒重建 1 次、播放页与迷你条 0 次(H132);逐字稿页重建次数=心跳的 12/s、"当前行"判定 1/s(滚动时 3~6/s)、**且 1400 句稿那一页只数到 15 个稿行节点 ⇒ `ForEach` 不给不可见行建 `ListItem`,原先那条"要不要换 `LazyForEach`"的结构性疑问据此关掉**(H137 + 三-A2 那一行);慢速横滑切分类时**只有胶囊**逐帧重建 112~119/s、整行 `ChipsRow` 只在手势首尾各 4 次(H139)。**探针已从工作区与装机包里撤干净**(7 个文件 `git checkout --`、`util/Probe.ets` 删除、重装后 `modules.abc` 1,598,260 B 里 `[Probe]`=0 且三条阳性对照都在),手法、合成素材被推翻的第一版、以及**设备末态留有两个合成稿缓存**(见下)都记在 **H149**。<br>**H142 ③(Android 导出日志)已于 2026-10-07 真机跑完**:满日志时导出的 696,817 B / 8,538 行与分享那份 `cmp` 逐字节相同(首行 9-27、末行是刚刚那条 `[Backup] export`,整份无截断);清空后「当前日志 0 B」,再导出得 14 B、内容就是 `(暂无日志)`,与同一时刻分享侧那份 md5 全等 ⇒ 空分支两侧同源。顺带记一条取证陷阱:这台机器的中文 Gboard 会把 `input text` 的 ASCII 标点折成全角、把字母串当拼音组字,所以改名实测落盘成 `还142.txt`(扩展名是 SAF DocumentsUI 按 MIME 补的,不是应用加的)。<br>**#98 已跑完并结案(2026-10-07)**:它圈定的三条 #43 / #47 / #49 全部在 Pixel 3 debug 包上真机验过(#47 于 2026-10-05,#43 与 #49 于 2026-10-07,逐条见上面那两行),夹具与 prefs 残留已清。<br>**「恢复后按 `updatesEnabled` 重排提醒任务」(#89)也已真机走完,而它是这一批里唯一一条"接上就跑出两个真 bug"的**:关掉提醒根本没关掉任何东西(H152:`stopWork` 五种参数形状在本机 SDK 全部 401,现改 `stopAndClearWorks()`,并写明"全应用只注册这一个 work"这条前提),恢复备份会弹系统通知授权框并把刚导入的值改回去(H153:`Toggle.onChange` 对程序化赋值同样回调,现按等值判断挡掉)。逐条取证与"没覆盖"(Android 的 `cancelUniqueWork` 本轮没重跑)记在下面「手动备份 settings 分区跨端互通」那一行。**这批改动晚于上一次出的那份 1.0.4 包 ⇒ 鸿蒙已在 2026-10-07 05:03 按新码重打并复跑解包验收(判据见下面门 5 那一行的第三次出包段),同日 06:32 又因 H154 第四次重出(判据见同一行末尾);Android 两渠道这轮没有源码改动,`android/dist` 那两份仍是有效的 1.0.4 包。**<br>**H157 之后这批又添两条"只到编译"**(2026-10-07 08:2x,判据与缺口都写在 H157):①**Android 三条导出(备份 / OPML / 日志)的失败分支一次都没在真机上走过** —— 这轮把「`openOutputStream` 返回 null 也算成功」改成如实报错,而 H155 那套 `run-as chmod cache/` 的杠杆对 SAF 落点(应用沙箱之外)不适用,三条候选注入杠杆与"为什么不写成测试"记在任务 **#122**;②**macOS 设置页那五处新提示没有任何运行证据**(本机六层不够),它与 #121(剪藏海报同族静默)一起排 **#59**。Android 那两个包已按新码 08:20 / 08:21 第八次重打并复跑解包验收 ⇒ 上面那句"Android 这轮没有源码改动"只对 05:03 那一次成立,**当前 Android 的两份是 08:2x 那两份**。<br>**同日 09:1x:上面 ① 已闭合,而且闭合的方式顺手抓出一条新的真缺陷**(H158)。三条导出的失败分支**在 Pixel 3 上真走通了**(`chmod` 与 `unlink` 两条杠杆实测都不造成失败,原因是 FUSE 不理 shell 改权限、MediaProvider 会把 unlink 掉的文件重开;可用的是第三条:`run-as` 冻住自己进程 → 把 SAF 落点换成同名目录 → 唤醒 ⇒ `openOutputStream` 抛 `EISDIR` ⇒ 弹「备份失败」+ 日志带整段栈)。⚠️ **命中的是 throw 臂,`openOutputStream` 返回 null 那条臂仍无证据,不写成"两条都验过"**。而取证过程中量到**导出文件名本身是错的**:OPML 那一行落盘成 `reverb-subscriptions.opml.xml`(mime `application/xml` 让 MediaProvider 按注册扩展名补了后缀),鸿蒙同格是干净的 `.opml` ⇒ mime 已改 `text/x-opml`,三条导出各验一份产物(`.opml` 364 B / `reverb-backup.json` 68,006 B / `reverb-log.txt` 85,288 B)。**这条改动晚于 08:20 那两份包 ⇒ Android 需要第九次重打才带得上它**,判据见门 5 末尾。② 那句(macOS 五处新提示无运行证据)不动,仍与 #121 一起排 **#59**。<br>**同日 10:0x:#121 的代码已改完,它从"待办的代码"变成"待取运行证据的第三条"**(H159)。`saveWithPanel` 的返回从 `Void` 换成 `ShareCardOutcome{saved, cancelled, failed}`,两条 tap-time 调用点各挂一句 `.alert`(标题即本地化 key),`分享图片生成失败` 补进四套 `.strings`(199→200 键 × 4,五语取值与两端逐字一致含弯撇号);三处**后台预渲染**调用点只写日志、不弹提示(那一次渲染不是用户发起的动作,它自带的反馈是"分享按钮没出现")。验收 = `typecheck-diff.sh` 两棵树各 38 文件 / 中性化各 9 类 / **都 0 错误** + 三个改动文件各注入一次阳性对照全中。**"失败会弹、取消不弹"这两条本机无从取证** ⇒ 与设置页那五处、出包本身一起挂在 **#59**(macOS 不挡双端上架,但 1.0.4 的 macOS 说明要提到它)。 |
| 3 | **代码待办清账** | 排得进本版的:#97 文档失真(以代码为准)。**#97 已于 2026-10-06 收尾**,八处全部逐条拿代码行号或解包结果改口,并把 A2 的**编号口径写死**(A2-1 用 1–5、A2-2 用 6–12、A2-3 用 11–19,号段重叠 ⇒ 引用必须带小节前缀)。同一轮把政策页那两处失真**真的发到了线上**:过程里挖出两件不该漏的事 —— ① `rsync` 的源目录 `/Users/liang/Documents/web/` 是 9-20 的旧快照,**原样执行那条命令一个字节都不会变而退出码是 0**;② 新版页面里「批注进系统备份」这句对在架的鸿蒙 1.0.3 不成立(解包实测白名单 8 项、不含 `notes.json`),上线前补了「自 1.0.4 起」的限定。两条与验收方法(三方 SHA-256 一致)都记在 **H144**,部署流程补进本地运营手册第四节。**#92 鸿蒙无障碍标签已于 2026-10-06 补齐**(2 处原有 → 30 处,新增 28 处;Android 反向补 3 处,含一处硬编码中文 `contentDescription = "设置"`),文案 15 个新键 × 5 语种与 Android 逐字比对全等 —— 但**鸿蒙端读屏一次没听过**,`uitest dumpLayout` 对 `SymbolGlyph` 的 `description` 恒空,本端没有任何自动化证据,所以它的三条判据挂在第 2 道门一起走(见 H143)。**【2026-10-07 更正这一格的取证形态】** Android 那三条已经从"只能实听"变成"工具读得到" —— `uiautomator dump` 的层级取自 AccessibilityNodeInfo,`content-desc` 逐条读到并随状态/设置当场变(见 H143 补记);鸿蒙那三条仍是实听,两件事**不可互推**,别因为 Android 取到了就把本端也写成"已验"。**#93 已于 2026-10-06 结案,且结案方式是"它不是 bug"** —— H9 那句「仍未解决」早被后面的 **H17**(`updateTime` 用 epoch 毫秒后,亮屏锁屏实测 `14:48 / 45:47` 并按真实速度推进)与 **H21**(息屏约 30 秒后系统切低功耗卡片 UI,只留进度条、不显示数字,应用侧无从干预)推翻,却原地留了一百多条,于是任务清单一直把它挂成"待修的真 bug";本轮差点据此往 `AvSessionBridge.sync` 里加"把时长也写进 `AVPlaybackState.duration`",查证后**已回退**。H9 已改成指向这两条并记下教训:**排查任何"已知问题"之前,除了 grep 症状词,还要顺着同一症状的更大编号再读一遍。** **#95 同日结案,方式是"决定不做"** —— 三端读点全是按 tag 取值(没有任何一处把"表里有这个键"当成"还在订阅"),清它只省几字节,代价是丢掉"重新订阅接上原模式";判据与理由补进 H119 那条残留,两端代码注释也各写成"这是决定,不是待办"。 排不进来的如实写进 1.0.4 说明或留下个版本:**#96 Android 玻璃折射**(API 33 挡住,鸿蒙那一层在低版本本来就没有)、**macOS 全部**(#59 出包、A2-2#7 官方稿、#11 导出勾选 —— macOS 没有"上架"这一步,不挡双端)、#94 逐字稿行数差(要先定位是分句口径还是解析漏,属分析项) |
| 4 | **版本号两处 + CHANGELOG 定稿** —— ✅ 2026-10-07 已做 | Android `app/build.gradle` → `versionCode 5 / 1.0.4`、鸿蒙 `AppScope/app.json5` → `1000004 / 1.0.4`(macOS 的 `Info.plist` 早已占 1.0.4 / build 2)。**bump 的时机**:原话是"装机复验之前不动版本号,否则验的是 1.0.3、发的是 1.0.4 就脱钩"—— 第 2 道门在 10-06/10-07 两批真机里已跑完主体(H126/H125/H129/H138/H141/H145/H148 + 分类排序 + #43/#49),剩下的几条是**实听与窄窗口类**(H143 读屏三条只能人耳,H142④ 那一格窄窗口 —— H133⑦ 后来也于同日两端验完,见第 2 道门;H140 双向恢复已于同日跑完,帧率那三条亦已量完,见上一段),它们要的是"在装了本分支代码的机上量",而 debug 包与 release 包在这几条上没有差别 ⇒ 先 bump 再出包不算脱钩,如实记在这里。**CHANGELOG 的 1.0.4 节同批改口**:六处「只过到编译/一次都没点过/尚未真机」按实证改成真话(批注两端真机 + 落盘字节逐键比对、Android 渐隐像素对照、鸿蒙分类排序四条 + 字形、鸿蒙分区框六条、鸿蒙日志分享是文件卡片),**两处仍是未验的如实留着**(macOS 全部、H142④;H140 双向恢复与 H133⑦ 同日已从这几处里划掉)。同日又补一处改口:Android「导出日志」从"仍未跑"改成实测(与分享那份逐字节相同、空日志时是 `(暂无日志)`)。`CHANGELOG.md` 是对外版本说明的唯一上游(硬规矩 19),发布文案由它派生、只留本地 |
| 5 | **出包 + 解包验收** —— ✅ 2026-10-07 三包全出、判据全绿(**H150 之后重出过一次;鸿蒙又因 H152 / H153 在 05:03 第三次重出,再因 H154 在 06:32 第四次重出,判据见本行末尾**) | 处理量先摆出来:Android `reverb.apk` 168 条目 / dex 6,393,296 B、`reverb-store.apk` 165 条目 / dex 6,378,480 B;鸿蒙 `reverb.app` 3 文件 / 内含 `entry-default.hap` 17 条目(`modules.abc` 806,000 B + `resources.index` 84,508 B)。<br>⚠️ **这组数字是第二次出包的**。第一版三包打在 00:57–01:00,而 H150 的代码提交在 03:19 —— **包比代码旧**。判据不是"看起来差不多":新包里能 grep 到 H150 才有的 `&nbsp;`(Android dex 与 `modules.abc` 各 1 处,鸿蒙 abc 也 1 处),dex 比旧包大 1,156 B、abc 大 372 B。**结论写死一条规矩:dist 里的包必须在**最后一个代码提交之后**重打,否则上传的是没修的码。**<br>顺带在这一步撞到并修掉一条出包脚本的静默失败(**H151**):后台 shell 没有 `ANDROID_HOME` 时,脚本的 SDK 解析落到一个不存在的默认路径 → 找不到 `apksigner` → **把"验不了"当成"没签名"**,于是退出码 0、`dist/reverb.apk` 已被自己 `rm` 掉、只剩一个 `-unsigned.apk`。修法是 SDK 解析改读 `local.properties` 的 `sdk.dir`(与 Gradle 同口径)+ 当场断言 `build-tools` 存在 + "有 keystore 却验不了"改成 exit 1 + `rm` 挪到判定之后;两条断言各自都用变异验过有牙齿。<br>**Android 两渠道**:`aapt2 dump badging` 都是 `versionCode='5' versionName='1.0.4'` ✅;`lib/` 与 `whisper-model` default 各 1(`libreverb_asr.so` + 57 MB 模型)、**store 两侧都 0** ✅;`RECORD_AUDIO` default 在、**store 0** ✅(store 权限行数 9 条,含 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` 那枚 AndroidX 自带的,与 1.0.2 那份备份包同形);目录接口 URL **两侧都非 0** 且与 1.0.3 逐项同数(`itunes.apple.com`=1 / `fyyd`=3 / `gpodder`=3)✅;签名 v2+v3 true、v1 按既定口径判(`apksigner` 报 false 是因 minSdk≥24 平台不采用,`META-INF/REVERB.SF`+`RSA`+`MANIFEST.MF` 三件齐=3)✅;签名者 DN `CN=Yuyin Reverb`(不是调试证书)✅。<br>**鸿蒙**:包版本 1000004 / 1.0.4、`app.debug=false` ✅;权限**恰好三条**(`INTERNET` / `GET_NETWORK_INFO` / `KEEP_BACKGROUND_RUNNING`)✅;`libs/` 里只有自研 `libreverb_pcm.so`(57,888 B)+ `libc++_shared.so`,**无任何识别模型** ✅;`debugKey` 在 `modules.abc` 与 `resources.index` 两侧都 **0** ✅;目录 URL 非 0(abc 1/3/3)✅;**`backup_config.json` 的 includes 从 8 项变 9 项、`notes.json` 已在白名单里** —— 这条是政策页「自 1.0.4 起批注进入系统备份」那句的落地凭证(H144 里承诺的那半)。<br>⚠️ **一条如实留下的告警**:release 构建新增三条 `The 'fill' API is supported since SDK 26.0.0`(本端 compatible 是 6.0.2(22)),位置在 `SettingsPage.ets:347/390/748` 的 `Circle().fill(...)`(主题配色对话框的色点 + 开关圆点 + 关于页那颗)。已在真机当场截图核对**四颗色点全部画出来了**(青瓷/黛蓝/绯红/竹青,选中的还是青瓷没被改动),所以这台机器上不构成故障;**但更旧系统的运行时行为本机无从验证**,记在这里而不是"告警=无害"<br>**✅ 2026-10-07 05:03 第三次出包(只重打鸿蒙)**:上游是 H152 / H153 两条改动。**Android 两渠道这轮没有源码改动**(`git log fdf41d2..HEAD -- android/` 为空)⇒ 04:01 / 04:05 那两份仍是当前包。<br>处理量:`reverb.app` 1,090,628 B(3 条目)→ 内含 `entry-default.hap` 2,433,340 B / 解出 17 个文件 2,431,030 B(`modules.abc` 806,108 B,比上一份大 108 B;`resources.index` 84,508 B 不变)。<br>判据逐条都跑了 grep:包版本 **1000004 / 1.0.4**(`pack.info` 与 `module.json` 两处一致)、`app.debug=false`;**权限是集合相等**而不只是"数到三条"(`INTERNET` / `GET_NETWORK_INFO` / `KEEP_BACKGROUND_RUNNING`,缺 0 项、多 0 项);`debugKey` 0 次、`whisper` 与 `models/` 各 0 次;`libs/` 仍只有 `libreverb_pcm.so` 57,888 B + `libc++_shared.so`;`backup_config.json` 的 includes 仍 9 项且含 `notes.json`。<br>**"新码真的在包里"按串验,不按体积猜**:`modules.abc` 里 `stopAndClearWorks` 1 次、`already added` 1 次(H152 的两支各一),而失效的那条 `stopWork` **0 次** —— 这条是负控制,它要是还在就说明打的是旧码。目录 URL 按 `grep -oa` **逐次**计 = `itunes.apple.com` 4 / `fyyd` 4 / `gpodder` 3(⚠️ 与上面第二次那组 1/3/3 **不是同一算法**:那次按 `grep -c` 数命中行数,而 abc 里这些串都在同一行 ⇒ 两组数不可互相当差分读)。<br>顺带一条会漂的记号:上面那条 `fill` 告警的位置因本次加注释从 `SettingsPage.ets:347/390/748` 变成 **347 / 390 / 766**,同三处、条数不变。<br>**仍未跑**:release 包**没有装机跑过**(它是上传市场用的签名包;本机装的是同码 debug 包,运行时证据全部来自 debug 包,见 H152 / H153 的验收段)。被覆盖的上一份留在 `harmony/dist/_backup-1.0.4-preH152-20261007-0502/`(dist 不入库,仅本机可见)<br>**✅ 2026-10-07 06:32 第四次出包(只重打鸿蒙,上游是 H154)**:同样先 `git status` 确认工作区干净、脚本自带清缓存。**这一包的"新码在场"不能用串证** —— H154 改的两处都是表达式(`ForEach` 的键值、以及把 `!h.played` 换成回 store 问一次),**没有引入任何新字符串常量**:实测新旧 `modules.abc` 的**可打印字符串集合逐条相等**(各 6,625 条,新增 0 / 消失 0)。所以判据换成**符号包差分** —— `reverb-symbol.zip` 里 `entry-sourceMaps.map` 的 74 个编译单元逐个解 VLQ 映射并数段数:**只有 `DiscoverPage.ets` 12,186 → 12,201 与 `LibraryPage.ets` 7,421 → 7,452 这两条变了**,其余 72 条一条不差;`resources.index`(sha256 相同)、`module.json`、`pack.info` **逐字节相同**(本条不动资源与配置),而 `ets/modules.abc` 从 806,108 → 806,320 B。<br>处理量:`reverb.app` 1,090,751 B(3 条目)→ `entry-default.hap` 2,433,552 B / 解出 17 个文件。**其余判据全复跑**:版本 1000004 / 1.0.4(`pack.info` 与 `module.json` 两处一致)、`releaseType Release`、`debug=false`;权限**集合相等**(三条,缺 0 多 0);`debugKey` / `whisper` / `models/` / `libreverb_asr` 在 abc 与 `resources.index` 两侧各 **0**;`libs/` 仍只有 `libreverb_pcm.so` 57,888 B + `libc++_shared.so`;`backup_config.json` includes 仍 9 项且含 `notes.json`;目录 URL 按逐次计 `itunes.apple.com` 4 / `fyyd` 4 / `gpodder` 3。<br>**上一轮三条串证的回归检查也跑了**(确认第四次重打没把已修的码打回去):`stopAndClearWorks` 1、`&nbsp;` 1、`pendingSeekExplicit` 1,失效的 `stopWork` 仍 0。<br>**顺带记一条比数体积更硬的口径**:一份包里"改了哪几个源文件"是可以直接从符号包读出来的 —— 以后凡是**改表达式而无新串**的改动,判据就用 source map 段数差分,不要用字节差。<br>**这一轮的一条副产品**:解包时顺手对比了两端系统备份白名单 —— Android 10 项(7 个 file + 3 个 sharedpref)、鸿蒙 9 项(7 个 file + 2 个 preferences),差的那一项是 Android 独有的第二个 prefs 文件(`reverb_prefs.xml`,H140 已记);**两端的 `playback_state.json` 都不在白名单里**,这是对称的(会话态不是用户内容),不算漂移。被覆盖的上一份留在 `harmony/dist/_backup-1.0.4-preH154-20261007-0640/`<br>**✅ 2026-10-07 07:29 第五次出包(H155 之后,三包全部重打 + 07:36 鸿蒙第六次)**:上游是「日志失败要出声」那一条 —— Android 两条调用点接进 `backupMsg` 弹层、两端各加 `log_send_failed`(新键)与 `saved_fail`(鸿蒙新加)的五语串。<br>**处理量先摆出来**:Android `reverb.apk` 64,954,732 B / 168 条目 / dex 6,393,976 B / `resources.arsc` 440,608 B;`reverb-store.apk` 3,526,803 B / 165 条目 / dex 6,379,544 B / arsc 436,388 B。鸿蒙 `reverb.app` 1,090,825 B / 3 条目 → `entry-default.hap` 解出 17 个文件 2,431,662 B(`modules.abc` 806,360 B、`resources.index` 84,888 B)。<br>**判据逐条(两侧都跑了,不只验"删掉的那侧")**:版本 Android `versionCode='5' versionName='1.0.4'` 两渠道一致 ✅、鸿蒙 `pack.info` 与 `module.json` 两处 1000004 / 1.0.4 ✅;native+模型 default 各 1 / store 各 0 ✅;**`RECORD_AUDIO` default 1 / store 0** ✅;目录接口 URL 两侧都非 0(dex 按行计 1/3/3、abc 按次计 4/4/3)✅;鸿蒙权限**集合相等**(三条,缺 0 多 0)、`debugKey` / `signCert` / `storeFile` / `keyAlias` 在 2,431,662 B 处理量上各 **0** ✅。<br>**本轮新增的判据词按串验在包里**:两渠道 `resources.arsc` 与鸿蒙 `resources.index` 里,`日志发送失败`/`保存失败` 两条各 1 次,且**五语十组(两键 × 五语种)在每个包里都各 1 次**。<br>⚠️ **这一轮差点把 `RECORD_AUDIO` 判反**:本机 `aapt2` **不在 PATH**(只有 `adb` 在),写成 `aapt2 dump … 2>/dev/null` 再接 `grep -c` 时命令根本没跑,`grep -c` 对空 stdin 报 0,于是**两个渠道都被读成「没有录音权限」,而自分发那份实际有**。改法是按 `sdk.dir` 取绝对路径 + 先看退出码 + 把权限清单整份打出来数过行数(default 9 条 / store 7 条 + 1 枚 AndroidX 自带 permission)再谈那个 0。这条已经写进 AGENTS.md 硬规矩 1,免得下一个人照着原文再踩一次;完整的现象/根因/排查顺序记在 **H156**。<br>⚠️ **一处「0」是判据自己写错**:鸿蒙 `resources.index` 里搜 `l'enregistrement`(直撇号)报 0 —— 回读源文件才看出我这轮新写的 fr 那份用的是**弯撇号** `l’enregistrement`,而 Android 既有的同名键是 `l\'enregistrement`(渲染成直撇号)。**同一键两端渲染出不同字**,是解包 grep 抓出来的、上一轮逐键读源码没看出来。改的是**我这轮新加的那一份**(鸿蒙改直撇号,与 Android 既有值和两端 fr 的多数写法一致)⇒ 只有鸿蒙需要第六次重打(07:36,1,090,825 B);改后十组按**渲染值**逐字节比对(`\'` 反转义后比),不一致 0 处。<br>**一条子串误报记录**:`p12` 在 `modules.abc` 报 1,回读上下文是混淆后的标识符 `p126` 的前三个字符(同一片里 `d126`/`e126`/`f126`/`r126`/`v126` 连排),不是签名材料路径 —— 短词命中必须回读,这条也在技能的反例清单里。<br>**未覆盖**:macOS 无包(本机六层不够,见三-A);鸿蒙 release 签名包**仍未装机跑过**,运行时证据全部来自同码 debug 包;Android 差分别名 `reverb-mapping.txt` 42,307,333 B / `reverb-store-mapping.txt` 42,233,179 B 同在 dist。**dist 全部不入库**,被覆盖的上一份分别在 `*/dist/_backup-1.0.4-preH155-20261007-0724/` 与 `harmony/dist/_backup-1.0.4-preFr-0735/`。<br>**✅ 2026-10-07 07:43 第七次出包(只重打鸿蒙,上游是「两端共享键按渲染值扫出的 6 条纯形态漂移」)**:把 H156 教训 ④ 当判据跑了一遍 —— 两端各 244 个共享键 × 五语种 = 1220 组,Android 侧先把反斜杠转义与 XML 实体还原再比,分三层:值全等 1031 / **同一句只差直弯撇号 6** / 措辞本就不同 183。**只改鸿蒙那一侧**(同一键总有一边是既有值,动另一边就等于只重打一个端 ⇒ Android 那两个包继续有效,不必为六个标点重出 65 MB 的发布包)。改后复跑同一个脚本:**纯形态漂移 0 条**。处理量 `reverb.app` 1,090,814 B → hap 解出 17 个文件 2,431,658 B(`resources.index` 84,888 B、`modules.abc` 806,360 B)。<br>**这一轮的验收写法是「新旧双向」**:六条各在 `resources.index` 里搜两种形态 —— 新 **1** 次、旧 **0** 次;后半截是负控制(只报"新的在",一份新旧都有的包也能过)。上一轮那两个新键一并回归:`日志发送失败`/`保存失败`/`日誌發送失敗`/`儲存失敗` 各 1 次,弯撇号那版 `Échec de l’enregistrement` **0**、直撇号版 **1**;版本 1000004 / 1.0.4、权限**集合相等**(三条)、`debugKey`/`signCert`/`storeFile`/`keyAlias` 各 0、目录 URL 逐次计 4/4/3。<br>**那 183 条措辞不同本轮未读**,理由与"下次怎么读"写进 H156 的补记(它是文案体检,不是发布判据;两端 UI 与渠道范围本就不同)。被覆盖的上一份留在 `harmony/dist/_backup-1.0.4-preFormSweep-0743/`。<br>**✅ 2026-10-07 08:20/08:21 第八次出包(只重打 Android 两渠道,上游是 H157 的 Android 那一侧)**:`git status --short` 为证,这一轮只碰 `android/` 与 `macos/` ⇒ **鸿蒙 07:43 那份仍是当前包**,不必为一条 Android/桌面的改动重打第三个端。<br>处理量:`reverb.apk` 64,954,732 B / 168 条目 / dex 6,392,564 B / `resources.arsc` 440,608 B;`reverb-store.apk` 3,526,803 B / 165 条目 / dex 6,377,744 B / arsc 436,388 B(两份都被 md5 与 07:29 那备份区分:体积相同、md5 不同)。<br>**判据逐条(两侧都跑)**:两渠道 `versionCode='5' versionName='1.0.4'` ✅;`lib/`+`whisper-model` default **2** / store **0** ✅;**`RECORD_AUDIO` default 1 / store 0** ✅(权限清单整份打印并数过:default 10 条 `uses-permission` / store 8 条,差的两条正是 `RECORD_AUDIO` + `MODIFY_AUDIO_SETTINGS`);目录接口 URL 两侧都非 0(按行计 1/3/3)✅;`apksigner` v2+v3 true、DN `CN=Yuyin Reverb`、`META-INF` 三件齐(v1 false 是 minSdk≥24 的既定口径)✅。`aapt2` / `apksigner` 均按 `sdk.dir` 绝对路径跑并看退出码(H156 的固定写法)。<br>**这一轮的"新码在包里"按三条串验**:`writeTextViaSaf` / `openOutputStream` / `目标不可写` 在两渠道各 1 次(中文走 `LC_ALL=C grep -a` 搜 dex 原始字节)。⚠️ 同一次 dex 反而**小了**(default 6,393,976 → 6,392,564 B)—— 三段重复写盘合成一个 helper;**但体积不当判据**(H154 定的那条),这条要写下来免得下一个人把"变小"读成"少打了东西"。<br>**一条流程上的自我纠正**(必须留在这行,因为它影响这一轮所有数字的可信度):第一次给两个渠道重打时**并发**跑了两个后台任务,两者写同一批 `/tmp/h157/*.log` 与 `android/dist/`,重复的那个已立刻杀掉。日志有可能交错 ⇒ **这一轮的结论一律按产物本身判**(`unzip -l`、按全路径 `aapt2 dump` + 退出码 + 整份权限清单、dex 按串),而不是按日志尾部那行 `exit=0`。教训与 H155「注入要清点目标是否已存在」同族:**并行跑的判据必须是彼此无关的产物,不能是共享的中间文件。**<br>**第八次当时「仍未跑」的那条已于同日 09:1x 跑掉**:Android 这三条导出的**失败分支**在 Pixel 3 的 debug 包上真造出来一次(`run-as` 冻住本进程 → 把 SAF 落点换成同名目录 → 唤醒 ⇒ `openOutputStream` 抛 `EISDIR` ⇒ 弹「备份失败」+ 日志带整段栈);另两条候选杠杆(chmod / unlink)**实测不造成失败**,原因与手法记在 H158。⚠️ **命中的是 throw 臂,`返回 null` 那条臂仍无证据** —— 在 user build 上没有可复现的杠杆,这条按一句留着而不是"两条都验过"。同一轮量出并修掉一条新缺陷:OPML 那行落盘成 `.opml.xml`(mime 让 MediaProvider 补了后缀),已改 `text/x-opml`。**这条改动晚于 08:20/08:21 那两份包 ⇒ 下面有第九次重打。** macOS 侧本轮只到 typecheck 差分(新脚本 `macos/tools/typecheck-diff.sh`:base 38 文件 / 309,051 B 与 mod 38 / 311,791 B 各中性化 9 类、各 **0 错误**,阳性对照在 `SettingsView.swift:459:48` 报出,撤净回 0)—— **一帧都没跑起来**,实跑仍排 #59。<br>**✅ 2026-10-07 09:14/09:15 第九次出包(只重打 Android 两渠道,上游是 H158 的 mime 改动)**:**串行跑的**(default → store 在同一条命令里先后跑,各自独立日志文件)—— 这是上一轮那条「并发跑两个后台任务、共享 `/tmp` 日志与 `dist/`」的自我纠正落成流程,不再有中间文件互踩。<br>处理量:`reverb.apk` 64,954,732 B / 168 条目 / **单个** `classes.dex` 6,392,560 B / `resources.arsc` 440,608 B;`reverb-store.apk` 3,526,803 B / 165 / 6,377,744 B / 436,388 B。<br>**"新码在包里"按串验,并配一条负控制**:两渠道 dex 里 `text/x-opml` 各 **1**、`application/xml` 各 **0**(后者不在就是打在旧码上);H157 那三条回归串 `writeTextViaSaf` / `openOutputStream` / `目标不可写` 各 1(中文走 `LC_ALL=C grep -a`)。<br>**其余判据逐条复跑**:两渠道 `versionCode='5' versionName='1.0.4'` ✅;`lib/`+`whisper-model` default **2** / store **0** ✅;**`RECORD_AUDIO` default 1 / store 0**,`MODIFY_AUDIO_SETTINGS` 同向 ✅(清单整份打印并数过:default 10 条 / store 8 条 `uses-permission`,与第八次同数);目录接口 URL 按行计两侧 1/3/3 ✅;`apksigner verify` 退出码 0、v2+v3 true、v1 false(minSdk≥24 既定口径)、DN `CN=Yuyin Reverb` ✅。<br>⚠️ **一条判据写法上的坑,数错了才发现**:`unzip -l` 的条目名整条丢给 `grep -c 'META-INF/'` 报的是 **71**,而第八次记的是 **3** —— 那 68 条差额是 Kotlin/AndroidX 自己带进 `META-INF/` 的文件(含 `services` 等子目录)。**签名三件必须按名锚着数** —— 只看 `META-INF` 一层下的 `MANIFEST.MF` / `REVERB.SF` / `REVERB.RSA`,两渠道各 **3** 条齐;否则这条判据会在某一次被读成"多了一堆签名文件"。与 H156 同族:**判据词的写法本身会漂,数出来的差异要先怀疑算法再怀疑产物。**<br>⚠️ **另一条"数字变了但语义没变"**:`resources.arsc` 大小与第八次逐字节同(440,608 / 436,388),而 **md5 变了**;`aapt2 dump resources` 两版**逐行全等**(6,211 / 6,188 行,`diff` 输出 0 行)⇒ 差的是容器写出的排布,不是资源语义。结论按 dump 判,不按 md5 判。<br>本次 dex 从 6,392,564 → 6,392,560 B(改的是一根字符串,短 4 字节,方向对得上)—— **仍然按串判,体积只作旁证**(H154 那条)。<br>**未覆盖**:鸿蒙 07:43 那份仍是当前包(本轮只碰 `android/` 与 `docs/`、`CHANGELOG.md`);同日 10:25 的 H159 **只碰 `macos/` 与文档** ⇒ 两端包都不必第十次重打 —— 判据是 `git show --name-only` 的顶层目录清单,不是"看着像没动"。这条也顺带说明"dist 必须晚于最后一个代码提交"该怎么读:**比的是同一端的源码**,不是整个 HEAD (macOS 在 10:25 之后确实比两端包新,而它本来就没有包)。macOS 无包;Android **release 签名包没有装机跑过** —— 这一轮的运行时证据全部来自同码 debug 包 `com.yuyin.reverb.android.debug`,因为正式包名里是真实用户数据(硬规矩 12);差分别名 `reverb-mapping.txt` / `reverb-store-mapping.txt` 同在 dist,`*/dist/` 全部不入库,被覆盖的上一份留在 `android/dist/_backup-1.0.4-preH158-0912/`。<br>**2026-10-08 又重打一次(Android 两渠道 10:04 / 10:05 = 第十次;鸿蒙 10:01)**,因为 H160(倍速 `1,×`、fr 词名、进度条 `accessibilityText`)与 H161(许可页/数据来源五语化 + store 覆盖空串、鸿蒙倍速按 locale)这两批改动**都不在 10-07 那三份里**。本轮新增的解包判据三条:① store 的 `whisper` 裸词 **arsc 0 / dex 0**,而 default 同一时点 **11 / 4** —— 这一对同时证明"覆盖生效"和"文案确实进了 default 的资源";② `resources.arsc` 里 fr 的 `reconnaissance vocale` 与 `Le flux RSS` 各 1(新串真的进包,不是只在源码里);③ 鸿蒙 `modules.abc` 里 `NumberFmt` 命中 1、`resources.index` 里五套新串各 1。**处理量**:default 168 条目 / `resources.arsc` 443,324 B、store 165 条目 / 438,480 B、鸿蒙 hap 17 条目 / `modules.abc` 808,444 B + `resources.index` 85,803 B;`aapt2` 两条 dump **退出码都是 0**(权限行数 default 12 / store 10,先数行数再谈那个 0)。**仍未做的一步:真机取串** —— 两台机器装的都是本轮之前的包。 **被覆盖的上一份(10-07 09:14 / 09:15 与 07:43 的鸿蒙三件)留在两端的 `dist/_backup-1.0.4-preLicenses-1000/`**。<br>⛔ **本行到第十次为止**:此后 11–14 次出包各在本节下方另起一段(第十二 / 十三 / 十四次在「2026-10-09 / 2026-10-10」那三段里)。**当前 dist 里的三份 = 第十三次(2026-10-10 09:26–09:29 三包)+ 第十四次(同日 09:37,只 store,上游 H169)**,逐条「命令 + 期望值 + 处理量」见下面「2026-10-10 第三批」那一段末尾的门 5。 |

> 1.0.3 的对外说明**不回改**(已发布的是既成事实);1.0.4 的 CHANGELOG 里那些「只过到编译、一次都没点过」的句子,
> 在第 2 道门跑完之前**不能删** —— 它们是给下一个接手的人看的验收状态,不是免责装饰。

**【2026-10-08 门 2 / 门 5 各补一段】**

- **门 2 · 本轮(2026-10-08)那批改动已双端真机复验完**,逐条结论与手法在 **H161 的补记**,择要:
  ① **许可页与数据来源五语化** —— 鸿蒙在 zh / fr / es 三种界面语言下各读一次层级表,三条新键全部是当地语言、
  **没有一条漏成键名**(`L.s` 失败回落的形状正是键名,所以"没看到键名"本身就是证据);
  Android 默认渠道 fr / es 读到 `whisper.cpp (reconnaissance vocale…)` / `(reconocimiento de voz…)`,中文渠道 8 行全在。
  ② **一条取证边界写死**:`src_publisher_rss` / `src_site_opml` 那两条在 **Android 任何渠道都上不了屏**
  (渲染它们的分支条件是 `BuildConfig.CATALOG == false`,而两个渠道的 CATALOG 都是 true)⇒
  **这两行的设备证据只能来自鸿蒙**,Android 侧证据只到资源层(五套各一份、与鸿蒙按渲染值逐字相同)。
  ③ **商店渠道两层都不提离线识别**已装机对上:store 那份切 fr / es 各读一次,依赖列表 **6 行**、
  whisper 那两行不在、也没留空行(默认渠道同一时刻 8 行);源码侧 `src/store/res` 五套覆盖**未覆盖计数 0**。
  ④ **倍速小数分隔符**:鸿蒙三处调用点(设置页默认倍速 / 倍速列表 / 播放页 chip 与弹层)在 fr、es 均读到
  `0,8× 1,25× 1,5× 1,75× 2×` 且**整数那格是 `1×`**,切回中文立即回到点 —— 顺带把「格式化实例按 tag 缓存会失效」
  这条从源码层抬到设备层。⑤ **fr/es 通读那三处修复**里,工具能读的两条已读(`1×` 无逗号尾巴、印记单位
  两端各为 `sceaux` / `sellos`),**第三条(读屏念进度条)两端仍只能实听**:本轮当场复现了为什么 ——
  同一屏里 `Slider` 节点 text 是 `87688.000000`、它两侧的两个 Text 是 `01:27` / `04:42`,而**整份 dump 137 个节点
  `description` 非空 0 个**(同批 text 非空 15 个,所以不是解析失败,是通道没有这个字段)。
  **门 2 剩下的仍然只有 H143/#92 那三条实听 + 这一寸。**
  设备末态:Android 默认 debug + 语言「跟随系统」;鸿蒙 `app_language` 空串、主题与语言回到原配置;
  两台机器的 release 签名包都没动过。⚠️ 一条过程如实记:取证中途曾临时往 `NumberFmt` 塞过一个探针,
  **它从未装进机器**(那一次 `assembleHap` 没产出新 hap,设备上一路都是 10:53 那份),源码当场回退、工作区干净。
- **门 5 · 「包必须晚于最后一个代码提交」这条判据要精确化**,本轮正好撞上一个需要解释的反例:
  `dist/` 三份的 mtime(鸿蒙 10:01 / Android 10:04、10:05)**早于**把这批改动落进 git 的那条提交(10:43),
  按字面读法要重打第十一次。实测两侧都不是问题:最后一次**源码**改动是 09:57:19 < 三份包,
  而包里读得出只有新码才有的东西 —— 默认渠道 `resources.arsc` 里 `lic_whisper` 五套齐全(含 fr 的
  `reconnaissance vocale`)而**它的 dex 里 `whisper.cpp` 是 0**(旧写法必然落在 dex),商店渠道**整个键不存在**。
  ⇒ **准确表述是"包必须晚于最后一次源码改动";提交时间只是它的一个代理信号,两边顺序反了时按串判、不按 `git log` 时间判。**
  据此本轮**没有重打**,并把门 5 整条解包判据复跑一遍(全绿):Android 两渠道 versionCode 5 / 1.0.4、
  `RECORD_AUDIO` 1 / 0、store 无 `lib/` 无识别模型、签名 v2+v3 且 DN `CN=Yuyin Reverb`;
  鸿蒙 1000004 / 1.0.4、`debug=false`、权限三条**集合相等**、`backup_config` includes 9 项含 `notes.json`、
  `debugKey` / `whisper` / `libreverb_asr` / `models/` 四个落点各 0,上一轮三条串证(`stopAndClearWorks` 1、
  `&nbsp;` 1、`pendingSeekExplicit` 1)各自仍在,失效的 `stopWork` 仍 0。
  **另记一条计数口径**:门 5 与 H161 原先写的 `whisper`「11 / 4」用同一条命令复现不出来
  (`LC_ALL=C grep -oa whisper` 按出现次数实测 arsc 12 / dex 1;那个 `4` 只在数 `WhisperEngine` 时出现)。
  定性结论两侧都更硬(商店渠道 arsc 与 dex 双侧 0),**从这条起判据一律写成「命令 + 期望值 + 处理量」**,
  只写数字会在下一次复跑时被读成回归。

**【2026-10-08 第二批:三格「追更」+「待播」段 + 下载闸门 —— 门 2 已于 2026-10-09 双端跑完,跑出两条真 bug】**

- **门 2 · 本批改动双端真机复验已于 2026-10-09 跑完**(两台机器装的都是与当前源码同码的 debug 产物)。逐条结果:
  ① **底部三格**的拇指命中 —— 鸿蒙实测等分 `[131,2497][449,2634]` / `[449…][767…]` / `[767…][1085…]`、
  Android(Pixel 3)分界 382 / 698,**三格各自点中且落到正确页面**;判据按 H165 那条纪律走:**每次点击前重新 dump 取矩形**。
  ② **追更页**的起播与长按「加入队列」都跑到(判据是应用自己的日志 `playQueue count=… tag='inbox'` /
  `enqueue id=…` 与落盘 `playback_state.json` 的 `upNext`,不靠界面看起来对)。
  ③ **音阁六个分段逐段点右端那颗动作** —— 订阅(排列切换)/ 收藏 / 下载 / 待播(清空)/ 历史(清空)/ 批注,
  六段各当场读出变化;「这一段没内容就不摆动作」也读到(清空之后那颗随之消失)。
  ④ **两处「清空」各自都先弹确认**,取消与确认两个分支都验:取消 ⇒ 队列 2 行 / 历史 1 条 / 队列页 1 行**都不动**,
  确认 ⇒ 清空并落到空态。**取证的坑记在 H167**:弹框打开时 `dumpLayout` 只含遮罩那一支的节点,
  所以"列表 0 条"必须同批断言分段 chips 仍在;同名串「清空」一屏出现两颗(条上 + 框里),按矩形 y 区分。
  ⑤ **下载闸门** —— 连着 Wi-Fi 点下载**放行并落盘**(两条各下完 33,678 KB / 108 MB),这就是用户报的那条 bug 的正解;
  根因、判据与代价见 **H166**。**⚠️ 这一条只验了放行侧**:「真蜂窝下确实被拦」在本机造不出(无 SIM),
  仍是未验项,已同步记在三-A。
  ⑥ **`selectedTab` 旧值恢复**这一条**本机不可强制取证** —— 三条办法(`am kill`、`kill`、`always_finish_activities=1`)
  实测都造不出进程死亡,所以只能给代码级结论:它走 `rememberSaveable` 的 instance state、**不落盘**,
  与"冷启动落在第 2 格"那条纸面担心不是同一条路径(冷启动读的是持久化的那一格)。如实记在 H167。
- **跑出来并已修的两条**:(a)**闸门误拦**(H166 —— 本端 `networkCap` 压根不上报 `NOT_METERED`,
  判据退回「只有蜂窝才拦」,并**第二次**把五语 Toast / 权限用途串 / 隐私页 / 站点 privacy.html 的句子改口,见 G5 补记);
  (b)**清空无二次确认 + 段序号是隐式契约**(H164/H165 —— 两端待播与队列页各补确认框、
  六段序号收成具名常量 `SEG_*`;H165 那条「动作应绑本段自己的数据」**仍未做**,已登记)。
- **门 5 · 本批已重打并复跑解包验收(2026-10-08 22:10–22:12;重打前的三份已备份到
  `android/dist/_backup-1.0.4-preIA-2210/` 与 `harmony/dist/_backup-1.0.4-preIA-2210/`)**。
  ⚠️ **下面这一整段数字描述的是 10-08 那一份包**,闸门文案在 10-09 又翻了一次 ⇒ **当前包在下面「2026-10-09 第十二次出包」那一段**。
  逐条按「命令 + 期望值 + 处理量」记,便于第三人复现:
  - **Android 两渠道**(`aapt dump badging` / `aapt2 dump permissions` / `apksigner verify --verbose`):
    versionCode 5 / versionName 1.0.4 × 两渠道;包名 `com.yuyin.reverb.android`;
    v2 + v3 均 true,v1 false;证书 DN `CN=Yuyin Reverb, OU=Reverb, O=Reverb, …`。
    **权限侧先打印清单再数**(H156:aapt2 不在 PATH,命令没跑与没命中长得一样):
    default 权限清单 **12 行**、`RECORD_AUDIO` **1**;store **10 行**、`RECORD_AUDIO` **0**;两次 `aapt2` 退出码都是 **0**。
    native/模型:`unzip -l … | grep -c ' lib/'` 与 `grep -c whisper-model` —— default **1 / 1**,store **0 / 0**。
    解包串(处理量:arsc 444,224 / 438,904 B;classes.dex 6,399,180 / 6,384,972 B;命令 `LC_ALL=C grep -oa <串> <文件> | wc -l`,
    **按出现次数**而不是行数):`itunes.apple.com` arsc **5** / dex **1**(两侧都非 0,目录接口在店里真的带);
    `whisper.cpp` default arsc **10** / store arsc **0**;`lic_whisper` default **2** / store **0**。
  - **本批新加的三条串证**(两侧都验,含"声明没有也要验"那一侧):
    `追更` 与 `待播` 在新包 default arsc **3 / 3**、store arsc **1 / 1**(非 0 ⇒ 三格与待播段真的进包),
    而**重打前那两份同一条命令读到 0 / 0** —— 负对照成立,这个非 0 才算数。
    `Updates` / `Up next` 两渠道均非 0。
  - **鸿蒙**(`unzip -p reverb.app '*.hap'` 再解 hap):versionCode **1000004** / versionName **1.0.4** / `debug` **false**;
    `requestPermissions` 恰三条**集合相等**(`INTERNET` / `GET_NETWORK_INFO` / `KEEP_BACKGROUND_RUNNING`);
    `backup_config` includes **9 项**且含 `notes.json`;`debugKey` / `whisper` / `libreverb_asr` / `models/`
    在 `resources.index`(86,513 B)与 `ets/modules.abc`(819,980 B)两个落点各 **0**;
    新图标 `resources/base/media/ic_tab_feed.svg` 在包内。
  - **闸门改口的两侧(10-08 那一份的读数,口径已于 10-09 再翻一次)**:当时新句五语各 **1**
    (`当前网络按用量计费` / `目前網路按用量計費` / `This network is metered` / `Réseau facturé` /
    `Red con límite de datos`),旧句 `当前不是 Wi-Fi` 与 `目前不是 Wi-Fi` 各 0(旧包里 `当前不是 Wi-Fi` 是 1)。
    ⚠️ **10-09 装机跑出「计费」这一句也是假的**(本端连着 Wi-Fi 也不上报 `NOT_METERED`,见 H166),
    判据退回「只有蜂窝才拦」⇒ **上面这五句现在是应当为 0 的那一侧**,按蜂窝的新句才是应为 1 的一侧。
    ⇒ 这就是 G5 补记那条「判据每翻一次,句子要重跑一遍 grep」的实际后果:**上一轮的"新句"会变成这一轮的旧句**。
  - **新码在不在包里 = 按串判**(与上一轮同一条规律):`nearestSlot` / `FeedPage` / `slotCx`
    在新包 `modules.abc` 各 **2**,在重打前那份**全 0**。
  - 上一轮的三条串证仍在(`stopAndClearWorks` 1、`&nbsp;` 1、`pendingSeekExplicit` 1)。
  - **未覆盖范围**(照规矩明说):arsc/dex 里只扫了上面点名的串,不是全量词表;
    `resources.index` 的中文靠 `LC_ALL=C grep -a` 搜原始字节(`strings` 看不见);
    hap 内 18 个条目没有逐个解出;签名链只验到 scheme 与 DN,没在线校验证书有效期。
- **✅ 2026-10-09 23:38–23:43 第十二次出包(三包全重打,上游是闸门第二次改口 + 两端确认框 + `SEG_*` 常量)**:
  **串行跑的**(default → store → 鸿蒙 release 在同一条命令里先后跑,各自独立日志,见上面那条流程自我纠正),
  三段退出码 **0 / 0 / 0**;被覆盖的上一份(10-08 那三件)在 `android/dist/_backup-1.0.4-preGateWording-2337/`
  与 `harmony/dist/_backup-1.0.4-preGateWording-2337/`(dist 不入库)。**它同时就是下面所有数字的负对照包**。
  逐条按「命令 + 期望值 + 处理量」记:
  - **处理量**:`reverb.apk` 64,958,828 B / **168 条目** / `classes.dex` 6,404,192 B / `resources.arsc` 445,060 B;
    `reverb-store.apk` 3,534,995 B / **165** / 6,389,056 B / 439,740 B。
    鸿蒙 `reverb.app` 1,098,179 B → `entry-default.hap` 2,454,032 B / **解出 18 个文件**
    (`ets/modules.abc` 823,872 B、`resources.index` 87,015 B);负对照旧包 1,096,610 B / abc 819,980 B。
  - **版本与包名**:`aapt dump badging` 退出码 **0**,两渠道都 `versionCode='5' versionName='1.0.4'`、
    `package: name='com.yuyin.reverb.android'`;鸿蒙 `module.json` 1000004 / 1.0.4 / **`"debug":false`**,
    `pack.info` 的 `summary.app.version` 同值(两处一致)。
  - **权限(先整份打印并数行数,再谈那个 0 —— H156)**:default `aapt2 dump permissions` 退出码 **0**、
    清单 **12 行**(stderr 0 行)、`RECORD_AUDIO` **1** / `MODIFY_AUDIO_SETTINGS` **1**;
    store **0** / 清单 **10 行** / 两者各 **0**。
  - **native 与模型**:`unzip -l | grep -c ' lib/'` 与 `grep -c whisper-model` —— default **1 / 1**,store **0 / 0** ✅。
  - **目录接口 URL(两侧都非 0,"声明有"同样要验)**:命令 `LC_ALL=C grep -oa <串> <文件> | wc -l`(**按出现次数**);
    arsc `itunes.apple.com` / `fyyd` / `gpodder` = **5 / 10 / 10**(两渠道同数),dex = **4 / 5 / 4**(两渠道同数)。
    ⚠️ 这里与 10-08 记的"dex 1"不可互比:**那一个是按行数**,同一条 URL 在 dex 里同处一行 ⇒
    这正是 ROADMAP 上面那条「判据一律写成命令 + 期望值」的原因。
  - **签名**:`apksigner verify --verbose` 退出码 0,两渠道 **v2 true / v3 true / v1 false**(minSdk≥24 的既定口径)、
    v3.1 与 v4 false;`META-INF` 签名三件**按名锚着数**各 **3**(不写 `grep -c 'META-INF/'`,那会把库自己带进去的
    71 条一并数进来,见第九次出包那条);证书 DN `CN=Yuyin Reverb, OU=Reverb, O=Reverb, L=Hangzhou, ST=Zhejiang, C=CN`。
  - **⭐ 本轮的核心判据 = 闸门文案第二次改口的两侧**(`resources.index`,新包 vs `_backup-…-preGateWording-2337` 那份):
    | 侧 | 串 | 新包 | 旧包 |
    |---|---|---|---|
    | 应为 1(按蜂窝说话) | `当前是蜂窝网络` | **1** | 0 |
    | | `目前為行動網路` | **1** | 0 |
    | | `on a cellular network` | **2**(Toast + 权限用途各一) | 0 |
    | | `données mobiles` / `datos móviles` | **3 / 3** | 1 / 1 |
    | 应为 0(上一轮的"新句") | `按用量计费` / `按用量計費` | **0 / 0** | 1 / 1 |
    | | `is metered` / `facturé` / `límite de datos` | **0 / 0 / 0** | 1 / 2 / 1 |
    | 回归(更早那句) | `当前不是 Wi-Fi` / `目前不是 Wi-Fi` | **0 / 0** | 0 / 0 |
    ⚠️ **两条如实标注**:① fr / es 那两条旧包里就是 1 —— 设置里「蜂窝下载」副标题同一片区域也在说 `données móviles`,
    **所以它们单独不能当判据**,判据落在上表前三行(新 1 / 旧 0)与"计费侧归零"那两行;
    ② `facturé` 旧包 2 而不是 1(旧值两处用到该词),期望写的是 **0**,不是"变小"。
  - **本轮最硬的"新码在包里"证据是一条日志串,不是文案串**:`modules.abc` 里 **`判定=蜂窝` 新 1 / 旧 0**,
    而 **`判定=计费` 新 0 / 旧 1** —— 这一对同时证明改的是**拦截那一支的代码**,而不只是注释与文案。
    同一行的 `闸门拦下` 与 `bearer=` 两侧各 1(回归,说明日志本身没被删)。
    Android 两渠道 dex 里 `blocked by cellular` 各 **1**、`isActiveNetworkMetered` 各 **1**(本端实现本轮未动 ⇒ 这是回归检查)。
  - **`SEG_*` 段序号常量在包里读不到(abc 命中 0)**,这是预期的:标识符不落串,属 H154 那类"改表达式而无新串"的改动,
    **所以它不进判据**,别把那个 0 读成"没打进去"。
  - **三格与待播的串证(非 0 即进包)**:`追更` 鸿蒙 index **4** / default arsc **3** / store arsc **1**;
    `待播` **8 / 5 / 3**;`Updates` **2 / 2 / 1**;`Up next` **2 / 1 / 1**。
    `nearestSlot` / `FeedPage` / `slotCx` 在 abc = **2 / 6 / 2**(三格命中判定与追更页真的在)。
  - **新键 `confirm_clear_queue` 五语两侧都验**:鸿蒙 `resources.index` 五个取值各 **1**;
    Android 两渠道 `resources.arsc` 各 **5**(每渠道五语齐);**旧包里同一条命令读到 0** ⇒ 负对照成立。
  - **应为 0 的落点复跑**:鸿蒙 `debugKey` / `whisper` / `libreverb_asr` / `models/` 在 abc 与 index **两个落点各 0**;
    `signCert` / `storeFile` / `keyAlias` 各 0;`libs/` 只有 `libreverb_pcm.so` 57,888 B + `libc++_shared.so` 1,262,504 B
    (**无任何识别模型**);store 的 `whisper.cpp` arsc **0** / dex **0**、`lic_whisper` **0**,default 对应 **10 / 2**。
  - **鸿蒙权限与备份白名单**:`requestPermissions` **集合相等**(恰 `INTERNET` / `GET_NETWORK_INFO` /
    `KEEP_BACKGROUND_RUNNING`,缺 0 多 0);`backup_config.json` includes **9 项**且含 `notes.json`;
    新图标 `resources/base/media/ic_tab_feed.svg` 在包内(hap 共 18 个文件)。
  - **一条会漂的记号再记一次**:release 构建那三条 `The 'fill' API is supported since SDK 26.0.0` 的位置
    又因加注释从 `SettingsPage.ets:347/390/766` 变成 **349 / 392 / 775** —— 同三处、条数不变。
  - **未覆盖范围**(照规矩明说):macOS 无包(本机六层不够,见三-A);**release 签名包没有装机跑过**,
    运行时证据全部来自同码 debug 包(硬规矩 12);arsc / dex / abc 里只扫了上面点名的串,不是全量词表;
    **真蜂窝下的拦截分支无证据**(该机无 SIM);`hap` 内 18 个条目没有逐个解出内容比对;证书有效期未在线校验
    (**2026-10-10 已补:有效期从包内读到,在线状态仍未查 —— 见下面「提审前的独立复跑」**)。
- **站点这一条已闭环(2026-10-09 23:48 部署)**:`site/reverb/privacy.html` 那句在本轮被改了两次
  (先「是否按用量计费」,装机证明计费信号取不到之后又改成「读取当前**网络类型**…(Android 侧还据此判断是否计费)」)
  ⇒ **第一次于当天 08:14 上线,第二次于 23:48 上线**。方向判定按流程第 0 步跑:先 `curl` 取线上哈希
  (`de72936195e2cb71…` / 17,342 B)与仓库比,再读 diff 确认**线上那份是上一版口径、仓库这份才对**,
  所以方向是 仓库 → 线上(不是倒灌)。部署 = 拷贝目录旧那份先 `cp -p` 到
  `/Users/liang/Documents/web-deploy-backups/privacy.html.20261009-234824.pre-deploy` → `--dry-run` → 只传那一个文件。
  **验收 = 四方 SHA-256 一致**(`182f0db066b6a088…`,仓库 = 服务器 = `cxyxl.cn` = `www.cxyxl.cn`,17,398 B,两处 HTTP 200),
  加内容判据(按出现次数):`网络类型` **2**、`Android 侧还据此判断该网络是否按用量计费` **1**、
  上一版那句 `是否按用量计费，以支持` 与 `限量热点也算计费网络` **各 0** —— 删掉的那一侧同样验了。
- **【2026-10-10 第三批:「追更」去掉截断 = 全部订阅频道的全部单集 —— 代码 + 文案 + 双端构建 + 门 2 双端真机 + 门 5 解包验收(第十三 / 第十四次出包)全部已跑】**
  来自用户提的意见:「这一页目前只是新关注的或最近更新的,并不是所有已关注频道的节目……
  **所有订阅的节目都能在这个页面管理,全部能往下翻**」。先按指令核过 **ROADMAP / 三-A / D 节:这条从未规划过**,
  不是 2.0 项,所以按"本轮执行"处理,不是"先记录"。
  - **成本判断的三个实测数字(2026-10-09 用当前 20 个订阅的 feed 量的)**:合计 **7,464 集 / ≈48.6 MB XML**,
    单源中位数 ~200,最大 **2,828**(All Ears English)与 **1,053**(声动早咖啡)⇒ "有没有上千集的"答案是**有**。
    **而网络与解析成本一字未变** —— `repo.feed()` 一直是整份下载 + 整份解析 RSS,旧的"每源 12 集"只限制
    解析完留下多少。真正新增的只有三项,各自处理了:
    ① **排序里的重复解析** —— 比较器里调 `parsePubMillis` 在全量下是"十万次比较 × 每次 new `SimpleDateFormat`",
    改成**每集解析一次 + 比较器只查 `id → 毫秒` 键表**(两端同构,硬规矩 6 的「调用次数 × 每次成本」);
    ② **落盘体量** —— 改成**内存全量 / 落盘 300 条**(`persistMax` / `PERSIST_MAX`),
    因为两端 `load()` 都在主线程同步读这一份 JSON。⚠️ **这里原先写的"单集约 7 KB ⇒ 全量落盘几十 MB ⇒ 300 条 ≈ 2 MB"
    是拿 macOS 旧包那份 747 KB / 100 条推的,装机把它否掉了**:真机 `inbox.json` 逐条量出来
    单条 min 628 / 中位 811 / max 1,554 B(鸿蒙 300 条那份 **333,160 B**)、
    min 678 / 中位 1,354 / max **9,143 B**(Android 300 条那份 **741,253 B**;另一档 160 条那份中位 3,611 B)
    ⇒ 300 条实测 **0.33–0.74 MB**,按中位外推到七千集才是 **6–27 MB** 这一档(H65 的形状仍在,只是倍数没写那么大);
    而**冷启动实测没变慢**(Android `am start -W` 160 条 2,564 / 300 条 2,291 / 回到 160 条 2,283 ms;
    鸿蒙 `[Inbox] 加载 300 条` 落在启动后 16 ms 内)⇒ "首帧若变慢先降到 100"降级为观察项。
    ③ **渲染规模** —— **不需要新工具**:两端列表都只求值可见行(Android `LazyColumn`;鸿蒙
    `List` + `ForEach` 有 H137 的真机否证 —— 1,400 句稿的逐字稿页 `uitest dumpLayout` 只数到 **15 个稿行节点**),
    所以这一端**没有**引入 0 先例的 `LazyForEach`,依据写在 `FeedPage.ets` 注释里。
  - **顺带确认"不会被撑爆"的两处**:`PlaybackStateStore` 两端都是「以当前集为中心 `CONTEXT_HALF=40` 窗口 +
    `UP_NEXT_CAP=300`」⇒ 传全量列表当队列不写全量;历史表两端 `max=100` ⇒ 行内 `isPlayed` 判断是 O(≤100),可接受。
  - **发现页首屏那一节收成 20 条**(`HOME_LATEST_MAX`),读的还是同一个 store。理由不是性能而是可达性:
    全量会把那一节下面的「导入更多」行顶到几千行以外。⚠️ **这一节在 `!CATALOG` 分支里而两端当前渠道 CATALOG 恒 `true`**
    (鸿蒙 `Features.ets:19`,Android `build.gradle:69/88`)⇒ **今天的包里它不渲染**,所以"用户可见"这句要收窄成
    "**降级渠道**才可见的变化";它已写进 CHANGELOG 与 `InboxScreen.kt` / `FeedScreen` 的两处「不是同一份列表」说明。
  - **鸿蒙的形状约束**:首屏那一截写成方法 `homeEpisodes()` 而不是局部变量 —— `@Builder` / `build()` 体内
    不能声明局部变量(H137 实测 `10905209`)。
  - **文案 30 条值已改口并逐条回读**:关于页 `about_p_features` 的追更那条 + 两个空态串
    (Android `inbox_empty_no_subs` / `inbox_empty_no_updates`,鸿蒙 `empty_inbox_nosubs` / `empty_inbox`)× 五语 × 两端。
    **旧措辞在 `android/app/src/main/res` 与 `harmony/entry/src/main/resources` 两个目录复扫 0 命中**
    (处理量:逐文件 grep,非 `strings`)。鸿蒙 `base` / `zh_TW` 是**半角逗号**,批量替换第一次就因此漏了 4 条。
    ⚠️ **但这一轮当时漏了第三个目录:`android/app/src/store/res`。** 上面那两条扫描路径只覆盖主 flavor,
    而商店渠道的关于页是**另一份物理文件**(source set 覆盖),于是 store 那份五语到解包验收才被抓出来仍是旧形状
    —— **见 H169**,已于同日第十四次出包修掉(下面门 5 末段)。
  - **双端构建已过**:Android `./gradlew :app:compileDefaultReleaseKotlin :app:compileStoreReleaseKotlin -q` **exit 0**;
    鸿蒙 `assembleHap --mode module -p product=default -p buildMode=debug` **BUILD SUCCESSFUL in 22 s**。
  - **门 2 · 装机判据(✅ 2026-10-10 双端真机跑过,装机是用户批准的两台都装)**
    判据按「命令 + 期望值 + 读数」逐条落:
    - 鸿蒙 `hdc shell hilog | grep '刷新完成'`(**流式**,一次性 dump 里 8,253 行只捞到 1 条 `Reverb`)
      ⇒ 期望 `得到 N 条` 是订阅集数之和而不是 100 / 12 ⇒ **读数 `源=1 得到 390 条 落盘 300 条 末次合并=0ms 总=657ms`**;
      同一 feed `curl` = 1,040,671 B / **390 个 `<item>`** ⇒ 390 就是全量(旧口径只会有 12)。
    - Android `adb logcat | grep 'Reverb/InboxStore'`(tag 是 `Reverb/<模块>`,写 `-s Reverb` 会 0 命中)
      ⇒ **同机差分**:装本轮包**之前**那份包在同一台、同一批订阅上跑到 `episodes=24`(旧口径 12×2),
      装完跑到 `episodes=160 persisted=160 parse=93ms sort=1ms`,而 `curl` 两源 = **73 + 87 = 160**;
      再挂第三个源(390 集)成 3 订阅 ⇒ `episodes=550 persisted=300 parse=261ms sort=3ms`
      ⇒ **内存侧 = 三源之和、落盘侧 = 封顶 300,两侧同时成立**。
      键表形状也对上了:`sort` 1→3 ms 几乎不随 N 涨,`parse` 93→261 ms 随 N 线性。
      (⚠️ 如实:第一次改夹具那一轮日志读到 `subs=2`,重做一遍才是 `subs=3`,没复现第二次,不登记成 bug 但不算已解释。)
    - **追更页能翻到底** ✅:Android 160 条那一栏 swipe 29 次到底 = `自我进化论｜No.1 …` `Thu, 30 Jan 2020`;
      550 条那一栏到底 = `女孩子的潜台词到底是什么` `Tue, 18 Dec 2018`(三源里最早的一集);
      鸿蒙 390 条那一栏到底同一集(`uitest dumpLayout` 末屏 `y=2117 … / Tue, 18 Dec 2018`)。
    - **冷启动秒开** ✅:读数见上一条 ② 的 `am start -W` 三份 + 鸿蒙 `[Inbox] 加载 300 条`(启动后 16 ms)。
    - ❌ **发现页首屏那一节恰好 20 条 —— 装机取不到,原因不是漏改而是这一格在当前渠道不渲染**:
      那一节在 `!Features.CATALOG` / `!BuildConfig.CATALOG` 分支里,而两端今天所有渠道 CATALOG 恒 `true`
      (鸿蒙 `Features.ets:19`,Android `build.gradle:69/88`)⇒ **20 条这一刀只有降级渠道用得到,
      只能靠代码与编译,判据本身已按 G5 同步改掉**(本节末第③条同此)。
    - ⚠️ 一条弱证据留着别当判据:Android `dumpsys gfxinfo` 在追更页 swipe 全程 **1,128 帧 / Janky 7.36% /
      95th 36 ms**,但取证窗口混着 `uiautomator dump` 自身的停顿 ⇒ 只能说没出现新的长卡顿。
    - **夹具已还原**:第三个订阅是沙箱写 `subscriptions.json` 造的(输入法把 URL 转成拼音,搜索框走不通),
      测完写回原文件并**按 md5 证明与动手前逐字节一致**(1,782 B / 2 条),再冷启读到 `subs=2 / episodes=160`。
  - **门 5 · ✅ 第十三次重打(2026-10-10 09:25–09:29,三包全重打)+ 整套解包验收复跑(全绿)**,
    **紧接着 ✅ 第十四次出包(同日 09:37,只重打 store 一个包)—— 上游是这次验收抓出来的 H169**。
    三段串行构建退出码 **0 / 0 / 0**(default → store → 鸿蒙 release,各自独立日志);
    被覆盖的上一份(10-09 23:38 那三件)在 `android/dist/_backup-1.0.4-preInboxFull-0925/` 与
    `harmony/dist/_backup-1.0.4-preInboxFull-0925/`(dist 不入库)。**它同时就是下面所有数字的负对照包。**
    ⚠️ 第十四次之前 store 又落了一次备份:`android/dist/_backup-1.0.4-preStoreAbout-1010/`。
    ⚠️ **这一段的时间戳本轮改过一次,改法是量而不是回忆**:先前写的是「第十四次 = 10:36」,
    `ls -lT dist/reverb-store.apk` 实测 **09:37:52**(备份目录建于 09:36:58,里面那份是 09:29:13 的第十三次 store)。
    ⇒ 凡写「第 N 次出包在 HH:MM」,HH:MM 必须从 `ls -lT` 抄,不要按当时的印象补 —— 这条数字本身不当判据
    (判据是 arsc 与串),但**它会影响下一个人怎么读时间线**(包比码旧还是码比包旧,靠的就是这一列)。
    **逐条按「命令 + 期望值 + 处理量」记;命令一律 `LC_ALL=C grep -oa <串> <文件> | wc -l`(按出现次数,中文搜原始字节)。**

    ### 第十三次(三包):处理量
    - `reverb.apk` **64,958,828 B / 168 条目** / `classes.dex` 6,405,060 B / `resources.arsc` 445,256 B
      (负对照旧包同字节数 64,958,828 B,md5 `cd3af9f2…` vs 旧 `cca980d3…` ⇒ **字节数相同而内容不同,判"是不是新包"只看 md5**)
    - `reverb-store.apk` **3,534,995 B / 165** / dex 6,390,276 B / arsc 439,804 B(旧包同样 3,534,995 B)
    - 鸿蒙 `reverb.app` **1,098,727 B**(md5 `ac8025e4…` / 旧 `6265d40a…`)→ `entry-default.hap` **2,454,922 B / 解出 18 个文件**
      (`ets/modules.abc` 824,612 B、`resources.index` 87,165 B;负对照旧包 1,098,179 B / abc 823,872 B / index 87,015 B)
    - **版本与包名**:`aapt dump badging` 退出码 **0**(stderr 0 行),两渠道都 `versionCode='5' versionName='1.0.4'`、
      `package: name='com.yuyin.reverb.android'`;鸿蒙 `module.json` 的 `app.version` = **1000004 / 1.0.4 / `"debug":false`**,
      `pack.info` 的 `summary.app.version` = `{code:1000004,name:"1.0.4"}`(两处一致)。

    ### 权限 / 产物 / 签名(两渠道 + 鸿蒙)
    - **权限(先整份打印并数行数,再谈那个 0 —— H156)**:default `aapt2 dump permissions` 退出码 **0**、清单 **12 行**、
      `RECORD_AUDIO` **1**;store **0** / 清单 **10 行** / `RECORD_AUDIO` **0**,且**新旧两份清单逐字节 diff 相同**;
      鸿蒙 `module.json` 的 `requestPermissions` **3 项**且与旧包**集合相等**
      (恰 `INTERNET` / `GET_NETWORK_INFO` / `KEEP_BACKGROUND_RUNNING`,缺 0 多 0)。
    - ⚠️ **一条"看着像泄漏其实不是"的分类(第十四次复跑时读出来的)**:store 的 `classes.dex` 里 `RECORD_AUDIO` 命中 **1**(旧包同样 1),
      上下文是 `android.permission.READ_MEDIA_VIDEO\0android.permission.RECORD_AUDIO\0…` 一串**权限名常量表**,
      来自 main 源码集、被 R8 保留的字符串常量。**manifest 里没有 ⇒ 装机不会申请**;判据按"权限清单 = 0"走,别把 dex 这一处读成渠道隔离失败。
    - **native 与模型**:`unzip -l | grep -icE 'lib/\|whisper-model'` —— default **2**(`lib/arm64-v8a/libreverb_asr.so` 1,679,264 B +
      `assets/whisper-model.bin` 59,707,625 B),store **0** ✅;
      鸿蒙 `libs/` 只有 `libreverb_pcm.so` 57,888 B + `libc++_shared.so` 1,262,504 B(**无任何识别模型**)。
    - **目录接口 URL("声明有"同样要验,非 0 即进包)**:default 与 store **同数** ——
      arsc `itunes.apple.com` / `fyyd` / `gpodder` = **5 / 10 / 10**,dex = **4 / 5 / 4**。
    - **签名**:`apksigner verify --verbose` 退出码 **0**,两渠道 **v2 true / v3 true / v1 false**(v3.1 与 v4 false,minSdk≥24 的既定口径);
      `META-INF` 签名三件**按名锚着数**各 **3**(`MANIFEST.MF` / `REVERB.SF` / `REVERB.RSA`;不写 `grep -c 'META-INF/'`,那会把库自带的 71 条一起数进来);
      证书 DN `CN=Yuyin Reverb, OU=Reverb, O=Reverb, L=Hangzhou, ST=Zhejiang, C=CN`。

    ### ⭐ 本轮核心判据 = 两处文案改口的两侧 + 一条新日志串
    **负对照包 = `_backup-1.0.4-preInboxFull-0925`(= 第十二次那份)。**
    - **Android `resources.arsc`(default)**:

      | 侧 | 串 | new | old |
      |---|---|---|---|
      | 应为 1 | `播过的单集全在这一栏` | **1** | 0 |
      | | `every episode from the shows you follow` | **1** | 0 |
      | | `这些频道还没有可播的单集`(空态二) | **1** | 0 |
      | 应为 0 | `暂无最新内容`(空态二旧句) | **0** | 1 |
      | | `新一期就会汇到这里`(空态一旧句) | **0** | 1 |
      | 回归(上一轮已改) | `待播、历史、批注六栏管理` | **1** | 1 |
      ⚠️ `订阅、最新、收藏、下载` 这一条在**两份 default 包里都是 0** —— 主 flavor 的旧形状早在 10-08 那轮(第十二次)就改掉了,
      **它只有 store 那份还留着 ⇒ 这个 0/0 正是 H169 的入口**(见下面第十四次那一段)。
    - **Android `classes.dex`(default)——本轮最硬的"新码在包里"证据**:
      **`persisted=` 新 1 / 旧 0**、**`parse=` 新 1 / 旧 0**、**`sort=` 新 1 / 旧 0**
      ⇒ 这三条是「内存全量 + 落盘有界」那行新日志的字段,**只有真改了代码才会出现**;
      同处 `refresh done` / `blocked by cellular` / `isActiveNetworkMetered` 两侧各 **1**(回归,说明日志与闸门都没被删)。
    - **鸿蒙 `resources.index`**:关于页追更那条**五语各 new=1 / old=0**
      (`播过的单集全在这一栏` / `播過的單集全在這一欄` / `every episode from the shows you follow` /
      `tous les épisodes de vos émissions suivies` / `todos los episodios de tus programas seguidos`),
      空态一的新句同样**五语各 1 / 旧 0**(`这里汇总它们播过的全部单集` 等五条;
      旧的 en `Subscribe to shows to see their latest` 侧 **new 0 / old 1**);
      旧句 `订阅频道的新单集` **new 0 / old 1** ⇒ 两侧都验。
    - **鸿蒙 `modules.abc`**:**`末次合并` 新 1 / 旧 0**(本轮新日志那一行的字段,同 Android 的 `parse=` 一个地位);
      `落盘` **3 / 2**(新增一处 = 刷新完成那行,旧的两处是落盘相关的其它日志,不是"变少");
      `得到` / `刷新完成` / `闸门拦下` / `判定=蜂窝` / `bearer=` **各 1 / 1**(回归)。
    - **三格与待播(非 0 即进包,本轮未动 ⇒ 回归检查)**:`追更` abc **2** / index **4**;`待播` index **8**;
      `Updates` abc **4** / index **2**;`Up next` index **2**;
      `nearestSlot` / `FeedPage` / `slotCx` 在 abc = **2 / 6 / 2**;新图标 `resources/base/media/ic_tab_feed.svg` 在包内(hap 共 18 个文件)。
    - **`confirm_clear_queue` 五语取值两侧都验(它是第十二次那轮引入的,这一轮只算回归)**:
      鸿蒙 index 五个取值各 **1**;Android **default arsc 各 1 / store arsc 各 1**;**负对照包同一条命令也是 1**
      ⇒ **如实写成回归,不写成本轮判据**(本轮那份负对照已经含有确认框,所以"旧包 0"这一侧在本轮不成立)。
    - **应为 0 的落点复跑**:鸿蒙 `debugKey` / `whisper` / `libreverb_asr` / `models/` 在 **abc 与 index 两个落点各 0**;
      `signCert` / `storeFile` / `keyAlias` 各 **0**;store 的 `whisper.cpp` arsc **0** / dex **0**、`lic_whisper` arsc **0**
      (default 对应 **arsc 10 / 2**),store 的 `classes.dex` 里 `whisper-model` **0**(default **1**)。

    ### ✅ 第十四次:只重打 store 一个包(H169 —— store 关于页五语漏改,不是代码改动)
    - **为什么可以只打一个包**:本轮五个文件全在 `android/app/src/store/` 下,不进 default flavor 的编译树。
      判据不是"我说它不影响",而是 `find android/app/src harmony/entry/src -type f \( -name '*.kt' -o -name '*.xml' -o -name '*.ets' -o -name '*.json*' \) -newer android/dist/reverb.apk`
      列出的**恰好只有这 5 个文件**。
    - **新包与旧包字节数相同(3,534,995 B)而 md5 不同**(`6de60003…` vs `631e8e0f…`);
      真凭据在里面那一层:`resources.arsc` **439,804 → 440,704 B(+900 B)**,与"五份文案各加一栏"的方向一致。
    - **成对判据(处理量:新 arsc 440,704 B / 旧 439,804 B;包内条目 165)**:
      **15 条新串全部 new=1 / old=0** —— 三处各五语:
      ① 「追更」栏 `播过的单集全在这一栏` / `播過的單集全在這一欄` / `every episode from the shows you follow` /
      `tous les épisodes de vos émissions suivies` / `todos los episodios de tus programas seguidos`;
      ② 六栏句 `订阅、收藏、下载、待播、历史、批注六栏管理` / `訂閱、收藏、下載、待播、歷史、批註六欄管理` /
      `six shelves — subscriptions, up next` / `abonnements, à suivre, favoris, téléchargements` /
      `suscripciones, a continuación, favoritos`;
      ③ 「播放模式」句 `播放模式（顺序 / 单曲循环 / 随机）` / `播放模式（順序 / 單曲循環 / 隨機）` /
      `play modes (sequential` / `modes de lecture (séquentiel` / `modos de reproducción (secuencial`。
      **7 条旧串全部 new=0 / old=1** —— `订阅、最新` / `訂閱、最新` / `subscriptions, latest` / `abonnements, nouveautés` /
      `suscripciones, novedades` / `分栏管理` / `分欄管理` ⇒ **两侧都验,负对照成立**。
      ⚠️ **判据词的写法本轮纠过一次(复跑时才发现)**:上面②最初记的是**半句** `six shelves` / `à suivre` / `a continuación`,
      复跑时 `a continuación` 报 **new=2 / old=1** —— 回读 `cat -v` 出的上下文是既有那一条
      **`Reproducir a continuación`**(别的键),即**短串被前缀吃掉**。换成整句锚定的②之后 15/15 全对。
      与 H155 的 `p12`、H156 的行/次口径同族:**命中数要先怀疑判据词的写法,再怀疑产物。**
    - **其余 store 判据同轮复跑**:目录接口 URL **5 / 10 / 10**(arsc)、**4 / 5 / 4**(dex);`lib/`+`whisper-model` **0**;
      `whisper.cpp` **0** / `lic_whisper` **0**;权限清单 `aapt2` 退出码 **0 / 10 行 / stderr 0 行**且与旧包**逐字节相同**;
      `apksigner verify` 退出码 **0**、v2/v3 true;`META-INF` 三件 **3**;
      成本与闸门日志串 **new=old 各 1**(`persisted=` `parse=` `sort=` `refresh done` `blocked by cellular` `isActiveNetworkMetered`)
      ⇒ **本轮只动文案,代码没变的结论有独立证据**。
    - ⚠️ **这一份没有装机读过**:两渠道**同包名**,装 store 变体会覆盖用户机上那份 default debug(硬规矩 12);
      「哪一份 flavor 的覆盖生效」由 arsc 直接证明(新串在 store 包里、旧串不在),比截图更贴这一问;
      **store 关于页五语的渲染折行与排版仍是未验路径**。

    ### ✅ 提审前的独立复跑(2026-10-10,只复验、**不重打包**)
    - **为什么不重打**:两条 `find` 各自跑过 ——
      `-newer android/dist/reverb.apk` 只列出 `android/app/src/store/res/` 下那 5 个文件(第十四次已把它们打进新 store 包),
      `-newer harmony/dist/reverb.app` 对鸿蒙源码**为空**,`-newer android/dist/reverb-store.apk`(最晚那份)**整体为空**。
      ⇒ 判据仍然是「包必须晚于最后一次**源码**改动」,不是「晚于提交」。
    - **这一轮不复用上一次的记录,每条命令自己跑一遍**(处理量:default dex 6,405,060 B / arsc 445,256 B;
      store dex 6,390,276 B / arsc 440,704 B;鸿蒙 abc 824,612 B / index 87,165 B;hap 18 个条目 / 2,454,922 B)。
      结果与上面两段记录的数字**逐条相同**:default dex 三条 `persisted=` `parse=` `sort=` **1 / 0**;
      store arsc 15 条新串 **1 / 0**、7 条旧串 **0 / 1**;鸿蒙 abc `末次合并` **1 / 0**、`判定=蜂窝` 1 / 1、`判定=计费` 0 / 0;
      鸿蒙 index 关于页五语 **1 / 0**、旧句 **0 / 1**;清空确认五语取值各 **1 / 1**(回归)。
      期望 0 的落点同样自己数过:鸿蒙 `debugKey` / `whisper` / `libreverb_asr` / `models/` / `signCert` / `storeFile` /
      `keyAlias` / `material/` 在 abc 与 index **各 0**;store 的 `whisper` 在 arsc 与 dex **各 0**(区分大小写)。
    - **补上三项一直在"未覆盖"里的取证**:
      ① **签名连续性**:`keytool -printcert -jarfile` 读到两个 1.0.4 渠道与 **1.0.2 归档那两个包同一串
      SHA-256**(`9C:BC:97:E4:…:E4:4E`)⇒ 老用户是覆盖升级,不是换签名;证书 Owner `CN=Yuyin Reverb, OU=Reverb, O=Reverb, L=Hangzhou, ST=Zhejiang, C=CN`,
      scheme **v2 true / v3 true / v1 false**(v3.1、v4、SourceStamp 全 false),`apksigner verify` 退出码 0。
      ② **证书有效期从包里读出来**:2026-09-05 → 2054-01-21(SHA384withRSA)⇒ **"未在线校验"现在只指在线的
      CRL / 平台侧状态没查**,不再是"连有效期都不知道"。
      ③ **鸿蒙 release 侧的三个标记**:`module.json` 的 `app` = `versionCode 1000004` / `versionName 1.0.4` /
      **`debug=false`、`buildMode=release`、`apiReleaseType=Release`**,权限**集合相等**(三条,缺 0 多 0)、
      `backgroundModes=['audioPlayback']`、`backup_config.json` includes 9 项含 `notes.json`。
    - ⚠️ **两条自己踩到的口径纠正**:`aapt dump badging` 接 `| grep` 之后 `$?` 是 **grep 的退出码**,
      所以"退出码 0"必须**去掉管道单独取一次**(本轮就是这么补验的);
      `grep -oa whisper` **加 `-i` 会把 default 从 12 / 1 变成 16 / 6**(多出来的是 R8 保留的 `WhisperEngine` 类名),
      渠道差异那句的命令**必须写死成区分大小写**。两条与 H155 / H156 同族。
    - **仍未覆盖**:release 包没装机跑过;真蜂窝拦截无证据(该机无 SIM);hap 18 条目未逐个解出比对;
      store 关于页五语未装机通读(#149);证书**在线**状态未校验。

    ### 未覆盖范围(照规矩明说)
    - macOS 无包(本机六层不够,见三-A);**release 签名包没有装机跑过**,运行时证据全部来自同码 debug 包(硬规矩 12)。
    - arsc / dex / abc / index 里**只扫了上面点名的串,不是全量词表**;鸿蒙 hap 的 18 个条目没有逐个解出内容比对。
    - **真蜂窝下的拦截分支无证据**(该机无 SIM),五语拦截 Toast 同样没取到。
    - 证书的**在线状态 / CRL** 未校验(有效期已从包里读到:2026-09-05 → 2054-01-21,见上面「提审前的独立复跑」②)。
    - **会漂的记号再记一次**:release 构建那三条 `The 'fill' API is supported since SDK 26.0.0` 的行号
      会随注释增删继续漂(上一轮是 `SettingsPage.ets` 349 / 392 / 775)⇒ **按条数与文件认,不按行号认**。
  - **本轮读出来、刻意不在本轮做的三条(如实登记)**:
    ① **`markPlayed` 对"没在收听历史里的单集"两端都静默 no-op** —— 旧截断下这一列几乎都是有进度的新集,
    全量之后没播过的集是常态,于是 Android 那颗"标记已播完"点下去没反应;鸿蒙追更页压根没有这颗按钮。**未改**。
    ② **macOS 的 inbox 仍是每源 12 / 全局 100**(`macos/Sources/Reverb/Data/InboxStore.swift` 的
    `perFeedCap=12` / `maxCount=100`,已 grep 确认还在)⇒ **三端在这条上漂移**,本机出不了包也跑不了产物(三-A 六层),
    所以不改并提交"验不了的改动"。③ **发现页首屏 100→20 这一刀在当前渠道不渲染** —— 那一节挂在
    `!Features.CATALOG` / `!BuildConfig.CATALOG` 分支里,两端今天所有渠道 CATALOG 恒 `true`
    (鸿蒙 `Features.ets:19`,Android `build.gradle:69/88`)⇒ 只有降级渠道用得到,
    收口方式因此从"装机看过"改成"代码 + 编译",装机判据本身已按 G5 同步改掉(见上面门 2 的 ❌ 那条)。

### 1.0.5(目标:**播放缓存 + 断网可浏览**,2026-10-12 用户定,端范围 Android + 鸿蒙)

用户口径原话是"已经加载过的列表,包含文字和图片,都要能够缓存下来,如果网络异常,也要至少能够浏览;
已经播放过的……下次再播放,就无需再联网播放了……**这是与下载完全不同的功能,缓存需要与下载区分开存储**,
在设置里新增清除缓存功能"。四条口径已拍板(端范围两端 / 首播时后台整集落缓存 / 300 MB 预算 + LRU /
文字与图片都要离线可见)。

| # | 门 | 现状与判据 |
|---|---|---|
| 1 | **代码 + 五语文案 + 文档同步** | ✅ **已做完**:两端 `AudioCacheManager`(整集预取 + 预算 LRU + 单飞)+ 鸿蒙 `ArtworkCache`(封面磁盘缓存)+ 选源链接上(下载 → 缓存 → 流式)+ 设置页占用与「清除缓存」口径 + 关于页两套 × 两端 / 同意页 / 副标题与确认框五语 + `FEATURES` / `PRODUCT` / `PRIVACY` / 官网隐私页 / `ARCHITECTURE` / `CHANGELOG` 1.0.5 节 + **H170 / H171**。<br>⚠️ **一条设计代价**:没有申请 `dataTransfer` 长时任务(不扩权限面)⇒ App 挂起时补齐缓存会停 |
| 2 | **双端编译** | ✅ Android 两渠道 `compileDefault/StoreReleaseKotlin` exit 0、鸿蒙 `assembleHap` BUILD SUCCESSFUL(仅既有三条 `fill` 告警)。**版本号已 bump:Android `versionCode 6 / 1.0.5`,鸿蒙 `1000005 / 1.0.5`**;macOS 本轮零改动、`Info.plist` 仍 1.0.4 |
| 3 | **装机与断网实跑** | ⛔ **缓存这条仍然一条没跑**(九条判据里 ①②③④⑥⑦ 都在等装机窗口;蜂窝那一条本机造不出,与 H166 同一寸)。<br>⚠️ **口径更正**(2026-10-16):这一行原先写的判据词 `source=cache` **在 Android 不存在**,那是鸿蒙侧的措辞;Android 侧对应的是英文日志(`cache done id=` / `evicted id=` / `cache skipped on metered net id=`),**且"命中缓存起播"这一端根本没有日志** ⇒ 判据只剩「该 URL 无新网络请求 + 断网按一下就出声」。逐条读数与替代判据写在 **三-A 那一行的 ②**。<br>⑨(界面动了要整套重拍截图)也还没做,但它排在底部栏那一轮观感结论之后(#167 → #166)。 |
| 4 | **出包 + 解包验收** | **Android 两渠道已出包并解包核过**(当前 `dist/` 两份:2026-10-16 09:00:52 / 64,958,828 B / md5 `5c7395d6…` 与 09:07:26 / 3,547,283 B / md5 `248492b0…`;判据词 `AudioCacheManager` 两渠道 dex 各命中 **3**、阴性对照 **0**;store 权限 10 行含 package 头 = **9 条**、无 `RECORD_AUDIO`/`MODIFY_AUDIO_SETTINGS`,无 `dataTransfer`;`ArtworkCache` 在 Android 为 0 且必须是 0(那是鸿蒙自研的封面缓存,Android 复用 Coil)。✅ **鸿蒙也已重打并解包核过**(2026-10-16 09:11:19,`dist/reverb.app` **1,110,731 B** / 符号包 650,780 B;旧 10-10 那份 1,098,727 B 已被覆盖)。处理量:hap **18 条目** / `modules.abc` **848,976 B** / `resources.index` **88,817 B** / `libs/` 下 **2 个 `.so`**;`pack.info` 与 `module.json` 两侧都读到 **1000005 / 1.0.5**;权限**恰好 3 条**(`INTERNET` / `GET_NETWORK_INFO` / `KEEP_BACKGROUND_RUNNING`,app 级 0 条,整份打印数过行数);`debugKey` 在解出来的 hap 上再跑一次仍是 **0**;串按 `-ao`:目录接口 **4 / 4 / 3**、`AudioCache` **11**、`ArtworkCache` **5**(与 Android 那条「必须为 0」相反,本端必须有)、`清除缓存` 1 / `展开播放条` 1 / 阳性 `追更` 4 / 阴性 0。<br>⚠️ **这份 release 包没装过机**(机上现在是 `appProvisionType: debug`,换装要走「应用内完整备份 → recv → 卸载 → 装 → 恢复」),而缓存那批的**断网实跑**还要真的关网(本机 hdc 无 root)⇒ #161 鸿蒙侧仍是**包侧已验、运行侧未验**。详见三-A 的 ⑧ |
| 5 | **发布** | 待 3、4 跑完。**与 1.0.4 的鸿蒙上架互不影响**:市场侧 1.0.4 已在架,1.0.5 是下一次提交;Android 商店那条(#62,H120 误报拒因)仍未解 |

#### 1.0.5 追加一批(2026-10-13):**鸿蒙底部栏改用系统 `Tabs` 的栏** + 播放条随滚动收束

用户反馈两条(栏矮、靠下)并给了方向(用系统自带组件,参照预装华为音乐)。口径与判据见 **H172**。

| # | 门 | 现状与判据 |
|---|---|---|
| 6 | **代码 + 五语文案 + 自绘栏退役** | ✅ **已做完**:新增 `view/BottomBar.ets`(系统栏口径常量 + `SystemTabItem` + 收束左槽 `HomeSlot`)、`MiniPlayerBar` 改一物两用(`collapsed` 分支)、`Index.shell()` 挂系统 bar 属性、三个页面 12 处滚动容器接 `onDidScroll` → 收束累计量;`a11y_home` 五语;**自绘玻璃栏移出编译树到 `harmony/shelved/`**(README 有六步复原清单)。Android 侧 48dp 玻璃栏**不动** |
| 7 | **编译** | ✅ 鸿蒙 `assembleHap` BUILD SUCCESSFUL(34s,7 条告警全在**本轮未触碰的文件**,是既有的 `fill` API 版本提示)。**Android / macOS 零改动**,不需要重编 |
| 8 | **装机三条判据** | ✅ **三条都跑过了**(2026-10-13 夜,debug hap 装机)。① **通过**:栏 182px = 56vp、栏下沿→屏底 91px = 28vp、图标 78px = 24vp、三格各 406px,与参照物逐项对上;② **机制双向通过**(上滑收束 / 点左槽展开,收束态内标题→播放页、队列符号→队列页各自路由正确),**"跟不跟手"仍待人眼**;③ **答法与预想不同**:不是"淡出的 tab 会不会被误触",而是**它反过来把三个 tab 全吃了** —— 落点容器那道铺到屏底的透明 padding 吞掉整条栏的点击,已修,见 **H173**。<br>顺带量出两处偏差并修完:收束态封面中心比栏中心低 1.4vp(改上下不对称留白 4/6,复量 0.46vp);**栏是一块白磨砂压在水墨界面上**,根因是从未向系统声明应用深浅态,已修并双向验过,见 **H174** |
| 10 | **H174 的连带复核** | ⚠️ **只验了本端底部栏与状态栏图标**。同一根因还会出现在系统弹窗、半屏面板、输入法 —— 现在它们跟着 `setColorMode` 一起对了,但**没有逐个截图留证**。另:「跟随系统」那一档(0)映射 `NOT_SET` 之后是否仍真的跟随,**本轮没在深色系统上复验**(设备一直在浅色模式) |
| 9 | **硬规矩 20:截图整套重拍** | ⛔ **待装机之后**。底栏变了 ⇒ **所有含底栏的商店截图与官网 `site/reverb/shots/*.jpg` 同时过期**,不是只有首页那一张;kit 要和新包同批重建。**鸿蒙在架 1.0.4 不受影响**,这条排在 1.0.5 出包那一轮 |

#### 1.0.5 追加二批(2026-10-14):系统栏换成 `HdsTabs` **悬浮页签**(真材质),自绘胶囊退役

上一批装机之后又走了自绘悬浮胶囊(`PillTabBar`,已进 `harmony/shelved/`),这一批把问题问到底:
**「预装华为音乐那种悬浮 + 真磨砂 + 按压光晕」系统到底给不给**?查证结论给的是**大部分给、交互不给**:
`@kit.UIDesignKit` 的 `HdsTabs` + `barFloatingStyle`(悬浮、左右留边、底部抬起、`systemMaterialEffect`
真材质、按压点光源)是公开 API,而**「按住横向拖动切格」与「光晕 1:1 跟手」在 HDS 里没有任何公开入口**
(`HdsTabsAttribute` 全量属性里没有拖动/手势项,逐条证据写在 `view/BottomBar.ets` 头部)。
用户拍板走这条,并接受交互退回**点按切换**。

| # | 门 | 现状与判据 |
|---|---|---|
| 11 | **代码 + 自绘胶囊二次退役** | ✅ **已做完**:`Index.shell()` 的 `Tabs` → `HdsTabs`,`barFloatingStyle(barFloating(inset, windowWidthVp, materialType))` 一次给齐三个必需条件(`barOverlap(true)` + `vertical(false)` + `barPosition(End)`);**刻意摘掉**上一版盖在系统材质上的 `barBackgroundColor` / `barBackgroundBlurStyle` / `divider`(留着就等于"量的是我们自己的那层压色,不是系统材质",见 H174);材质**探针取**(`pickMaterialType()` 读 `getSystemMaterialTypes()`,有 IMMERSIVE 用 IMMERSIVE,否则 ADAPTIVE —— 探针失败的症状是栏透明);栏里每一格**仍是自绘 `SystemTabItem`**,因为 `BottomTabBarStyle` 用系统主题色,会丢掉本 App 的强调色与手动深浅;`harmony/shelved/PillTabBar.ets` + README 复原清单 |
| 12 | **SDK 口径的代价** | ✅ `build-profile.json5` 两个 product 的 `compatibleSdkVersion` / `targetSdkVersion` 从 `6.0.2(22)` 升到 **`6.1.0(23)`**(`barFloatingStyle` / `miniBar` / `hdsMaterial` 都标 `@since 6.1.0(23)`)。⚠️ **这意味着 6.0.x 的设备不再能安装本包**,上架前要按这一条复核受众口径。<br>另外 `HdsTabsMiniBar.barLayoutMode` 是 **6.1.1(24)**,在本口径下**不可用** —— 所以播放条收束这一轮**仍是我们自己那套**(随播放条叠在系统栏之上),没换成系统 `miniBar`:一次只换一个变量 |
| 13 | **编译** | ✅ 鸿蒙 `assembleHap`(debug)BUILD SUCCESSFUL。**踩过的坑**:`barFloatingStyle` 那串属性名写在块注释里时,旁边若带 `**` 强调会被解析成 `*/` **提前闭合注释**,正文当代码编译 ⇒ 251 条离奇报错(现象是 `Cannot find name '不动'`)。改完编译过,但**这类"注释里出现 `*/`"的形状要防** |
| 14 | **装机判据** | ✅ **本机(BRA-AL00,密度 3.25)第一轮跑过**,判据与结果逐条:<br>① **真材质生效** ✅ —— 列表从胶囊背后滚过时能读出封面被糊进胶囊(浅色块在胶囊左端透出),不是"整条透明";<br>② **几何** ✅ —— `dumpLayout` 量到 `TabBar [74,2415][1141,2597]`,参照物(预装华为音乐)`[75,2415][1141,2597]`,差 1px(23vp 在本机是 74.75px);栏底 2688−2597=91px=28vp=整个手势避让区;**这一条是第一轮没过的**(只给 `barSideMargin` 时胶囊按内容收缩居中 `[224,2415][992,2597]`,补 `barWidth` 后又踩到 `'100%'` 顶没侧边距 ⇒ 见 **H176**,现按"窗口宽 − 2×23vp"给);<br>③ **点按切换** ✅ 三格各点一次都换页;**按下点光源**⚠️ 瞬态,截图取不到证,**留给人眼**;<br>④ **选中色跟强调色** ✅ 选中那格图标与文案是本项目的水墨绿,未选中是 onSurfaceVariant;<br>⑤ **播放条收束落点** ✅ 收束态整块落在胶囊带 `[2415,2597]` 内、展开态在胶囊上方留 8vp;<br>⑥ **深浅** ⚠️ 深色本轮量过,**浅色没在这版上复拍**(换 `barWidth` 之前那次冷启动是浅色,胶囊与材质正常);<br>⑦ **底部余量** ⚠️ 只滚到底验了「追更」一页,末项在胶囊之上不压住 |
| 15 | **装机第一轮留下的三条待办** | (a)**✅ 10-14 第二轮已做完并真机量过**:播放条整块内缩到与胶囊同宽(`MINI_SIDE_MARGIN` 取 `BAR_SIDE_MARGIN` 同一个值),展开态从通栏改成 48vp 高的长椭圆胶囊(`MINI_H` 60→48、圆角=半高、`clip(true)` 收进度线两个方头)。<br>装机复量:展开态胶囊 `[74,2235][1142,2390]`(与 `TabBar [74,2415][1141,2597]` 左右同缝,差 1px 是 vp 取整)、高 155px=47.7vp、与胶囊上沿留 25px=7.7vp≈8vp;收束态 `[74,2416][1142,2598]` 与胶囊等高,**最右那颗队列按钮右边界 1091 < 胶囊 1141**(原 1164,越界 7vp 已消失),封面 143px=44vp、回主页图标 79px=24vp 都在带内。<br>⚠️ **一条刻意的让步**:参考片展开态是 40vp,这里停在 48 —— 再矮就要把展开态封面压到 32,而 `Artwork` 边长在它自己组件内部、父层动画管不到,40↔44 那档跳幅会从 4vp 涨到 12vp 并读得出来。**要做到 40 得先让封面尺寸可动画**,不是只改这个数(理由写在 `BottomBar.MINI_H` 注释里)。<br>(b)**首帧中间格不画**那个一次性现象:本轮两次冷启动各数了三格的亮像素(3206 / 1071 / 806),**复现不出来**,先记着,再出现时按"系统栏项首帧"这条线查。(c)**浅色态在这版上补拍一次** —— 仍未做,(a) 这轮只跑了深色 |
| 15b | **装机第三轮(10-15):小圆球 + 频道页悬浮** | ✅ **真机量过**(同一 debug hap,深色态)。<br>① **收束态左端那颗球** ✅ —— 槽层 `[74,2415][256,2597]`(56×56vp、**左缘与胶囊同缝**),盘 52vp、心 `(165.5, 2506.5)`,参照物"直径 ≈172px、心 `(166, 2506)`" → **差 0.5px**;盘上图标 `[126,2468][205,2546]` 与参照 `[126,2467][205,2545]` **逐像素相同**;整块右界 1142、末按钮右界 1117(参照 1115)。<br>② **球的语义改判过一次**:第一版画的是 `sys.symbol.house`(回主页),装机对着参照物复看发现口径错 —— 参考片切到哪个频道、盘上就是那个频道的图标,它是"整条栏收在这里",不是"回家"。现在盘上是 `BALL_ICONS[curTab]`,点击动作是**展开播放条**、不切页。<br>③ **盘面颜色**由 `primary` 16% 改判为 `onSurface` 10%:前者把盘染成一层绿、与同色图标糊成实心圆点;对照参考片两张截图(亮/暗封面各一张)确认**盘中性、强调色只在图标上**。**两态取景见下面 ⑤;浓淡的最终裁量仍在人眼。**<br>④ **频道详情页播放条改悬浮** ✅ —— 胶囊 `[74,2415][1142,2571]`(48vp 高、底边离避让区 26px=8vp、左右同缝),末集滚到底 `[0,2155][1216,2415]`,**底边正好压在胶囊上沿**,`contentEndOffset(56vp)` 生效。<br>⚠️ **这一轮差点把 ④ 判成 bug**:两次读到"没生效",根因是取证侧(手势注入被静默拒绝 + 单次 dump 抓到回弹途中的帧),**见 H177**。<br>**与参照物剩下的两条差额**(都不在本批范围):参照的收束态封面是**正圆 + 外圈进度环**(我们是圆角方封面、进度线在胶囊上沿);参照展开态 40vp / 封面 32vp(我们 48 / 40,受限于 15(a) 那条"封面尺寸不可动画")。<br>**⑤ 浅色态这一轮补拍了**(设置页切到「浅色 · 宣纸」再切回):悬浮栏材质**跟着变浅**(H174 那条修在浅色态成立)、
展开胶囊与收束态那颗球都正常,球在浅色下读成"略深一层的玻璃 + 强调色图标",与参考片亮封面那张同调。
⚠️ **频道详情页的悬浮条只在深色下量过**(同一批组件,浅色没单独取景)。<br>
⚠️ ① 那版"球已独立"**装机没成立**(缝整个放进了胶囊内部)—— 第四轮改判见 15c。 |
| 15c | **装机第四轮(10-15):把"球 → 胶囊"那道缝挪到胶囊外面** | ✅ **改判并真机量过**。
①那版把 14vp 全算成胶囊的**左内边距**,于是球盘右缘 249 / 胶囊左缘 256,**外缝只剩 2vp**,
两个圆头几乎相切 —— 观感仍是"胶囊左端鼓出一颗球"。拿参考片(`r4_ball.png`,同机同密度)重量:
**外缝 32px = 10vp + 内白 15px = 4.6vp**,总距离(盘 → 封面 ≈ 15vp)与我们相同,只是缝在胶囊**外面**。
改法:`MINI_PAD_COLLAPSED.left` 14 → 5,新增 `HOME_SLOT_GAP = 8` 挂在**球槽的右边距**上
(⚠️ 不能挂外层 `Row` 的 `space`,那会让展开态那个零宽槽也吃一道缝、整条播放条白右移)。
**改后实测**:胶囊左缘 `256 → 282`、外缝 `2vp → 10.2vp`、封面左缘 `301 → 298`(参照 302,未动);
展开态**逐像素未受影响**(胶囊 `[74,2233][1142,2389]`、封面 `[119,2246][249,2376]`)。
<br>⚠️ **一条报障查完没改代码**:「从发现切走时光晕最后跳回发现」—— 用绝对亮度量到的那团亮
是**背后封面透过 IMMERSIVE 材质**,不是选中指示;换成"背景不变的逐帧序列 / 动画中途强制重建 /
冷启动首切"三种能成立的判据之后**未复现**,三条候选(`index` 绑状态变量、`barFloatingStyle`
每次新建、发现页滚动复位)一条都没被指认。**判据问题与教训见 H178。**
<br>❗ **顺带确认、待拍板的一条**:收束态胶囊 `[74,2415][1142,2597]` 与 `TabBar` **完全重合**
⇒ **三个 tab 在收束态点不动**(实测:点音阁格前后 dump 逐字节相同、点追更格打开的是播放页),
当前唯一换页路径是先点那颗球把条展开。两条候选改法:收束态只占栏的一部分宽度 /
让胶囊空白区把点击透给底下的栏(容器那层已经是 `HitTestMode.None`,见 H173)。
<br>**⚠️ 这一条在第五轮已改判、不再是"待拍板"**:见下面 15d ②。 |
| 15d | **装机第五至第七轮(10-15):收束态与栏等高 + 系统栏淡掉 + 图标/封面三档改小** | ✅ **三轮都真机量过**(最后一版 hap 4162863 B)。<br>
**① 整块抬到与栏等高**:收束态块高 44 → **56vp**(`MINI_H_COLLAPSED = TAB_BAR_H`)。旧 44 装机读出两条:
我们的胶囊**嵌在系统栏那条胶囊里**(那一行两层底)、按钮按 44 那档配所以比 tab 图标小一圈还被半高圆角削。
实测胶囊 `[282,2415][1142,2597]` = 264.6×**56.00vp**,盘心 / 封面心 / 栏心 `2506.5 / 2506 / 2506` 三线同线。
<br>**② 收束态把系统栏整条淡掉**(`barFloating()` 里 `barOpacity: collapsed ? 0 : 1`)⇒
15c 那条"待拍板"改判为**这一形态的必然**:那一行归播放条与那颗球,三个 tab 点不动,要切格先展开。
⚠️ **两条装机才看得见的性质**(写进 H178 补记):`barOpacity` 是**样式对象里的量**、不吃属性动画所以**瞬变**
(补救要逐帧 `postFrameCallback`,先例在 `shelved/GlassTabBar.ets`);且它淡掉的是**整条栏含系统磨砂底板**,
于是球周围变成清晰的列表内容在透 ⇒ 盘的底色 alpha 一路从 0.10 给到 **0.45** 才读得出来。
<br>**③ 三枚按钮 24 → 20 → 16**。**"改小了但看着没变化"被报了两次**,第二次用像素证明改动确实生效
(节点 78px → 65px,盘内亮度 patch 43/50/45 → 61/69/70)但**低于感知阈值**:13px 只占屏宽 1%,
而播放/暂停是**实心**形状,按外接框缩 17% 肉眼几乎不动 ⇒ 一步跨到 16(累计 −33%)。
命中框不跟着缩(`MINI_HIT_EXT = 节点 + 24` = 40vp,实测节点外 17px 仍可点)。
<br>**④ "图标上下左边距父容器太近"量的其实不是按钮而是封面** —— 按钮当时离胶囊上沿实测 72px = 22vp,
不存在贴边;封面是 `4+40+4` / `6+44+6`,上下各剩 4/6vp、左 5vp。**先量间隙再定改哪个元素**。
于是整机缩一档:封面 40/44 → **34/40**,纵向 padding 由封面反推(块高 − 封面)÷ 2
(⚠️ 不能单独调,否则块高会漂离 56)。第七轮再把收束态左内距 8 → **14**(实测 45px = 13.85vp,
三枚按钮 x 一像素未动、位移由标题那段的权重吸收)。
<br>**⚠️ 两条明知代价选下来的**:球盘 → 封面总距因此到 **23.7vp**(参考片 15vp)—— 想压回去只能减小外缝,
而外缝小到 2~4vp 就复现 15c 修掉的"两个圆头相切";封面两态差 4vp → **6vp 且仍是瞬移**
(尺寸在 `Artwork` 内部,父层动画管不到)—— 要消掉得先让封面尺寸本身可动画,这是下一轮若还要缩的**唯一正确方向**。
<br>**待人眼复核**:6vp 那档瞬移在 340ms 弹簧途中读不读得出来(连拍抓不到中间帧,单帧开销 >340ms)。 |
| 16 | **下一步候选** | 把播放条收束交给系统:`HdsTabsFloatingStyle.miniBar` + `HdsTabsController.applyMiniBarStyle(COLLAPSE/EXPAND)` + `applyHideAnimation(SCROLL_ANIMATION)`;`barLayoutMode` 要 6.1.1(24),动它之前先决定口径是否再升一档 |

#### 1.0.5 追加一批(2026-10-15):**Android 播放条收成胶囊 + 随滚动收束**(端范围由用户拍板)

用户原话的边界是:"**除了滑动的光晕效果不必按鸿蒙来,其他都可以改成和鸿蒙一样**"。
所以这一批**只动播放条与栏高**,玻璃栏那三层(静止底 / 透镜 / 跟手光晕)一个几何没改,
横拖切格也留着 —— 不移植 `HdsTabs`,Android 没有等价物,而且这一条是被明确点名要保留的。

| # | 事项 | 状态与判据 |
|---|---|---|
| A1 | 几何常量落地 | ✅ `Components.kt` 一组具名常量:`MINI_H 44` / `MINI_H_COLLAPSED = GLASS_BAR_H`(52)/ `MINI_GAP 8` / `MINI_SIDE_PAD = GLASS_SIDE_PAD`(24,**与栏同一道缝**,宽度只有一个来源)/ 封面 32↔36 / 按钮图标 16 + 命中 40 / 球槽 52、盘 48、外缝 8、盘底 `onSurface` 45%。<br>⚠️ **五处几何全部读钳过的 `fc = f.coerceIn(0f, 1f)`,不读裸 `f`** —— 0.86 是欠阻尼,落点过冲 ≈0.5%,而 `lift`/`padding(end=)` 喂的是有非负约束的 `Dp`。装机即崩就是这个,见 **H180** |
| A2 | **为什么栏是 52 而不是鸿蒙的 56** | ⚠️ **两条张力都记在 `GlassNavBar.GLASS_BAR_H` 的注释里**:① 历史上"把栏从 44 抬到 56"被人眼否过("高度增加太多了,只需要增加一点点");② 本端透镜按住时 ≈53.7dp,**栏到 56 它就不再鼓出栏外** —— 那正是点名要留的效果。所以只抬 4。**装机两条走向各管一个变量**:还嫌矮 → 抬 56 同时抬 `REST_H`;玻璃不鼓 → 只动 `REST_H` 44→47。**不许同批一起改**(改了就读不出是哪一处起的作用) |
| A3 | 收束判据接线 | ✅ **不改任何一页的 `scrollState`**:三张列表各有自己的滚动状态、没人往上报,所以在外层 `Box` 挂 `NestedScrollConnection.onPostScroll`,只吃 `consumed.y` + `source ∈ {Drag, Fling}`(硬规矩 9:程序化滚动不算用户意图),累计 ±40dp 翻转、每次翻转清零。<br>⚠️ **`consumed.y` 与手指方向反号**(向上划报**负**值),换算写在出口处一次(`dragged = -consumed.y`)—— 装机划了二十几次纹丝不动就是这条,见 **H181**。<br>⚠️ 累加器是 `FloatArray` 而不是 `mutableFloatStateOf`:它是判据中间量,**不该触发任何重 compose**。<br>⚠️ 本端 Compose 1.6.x 的 `onPostScroll` 第二个参数是 `Offset`(1.7 起才是 `NestedScrollParams`),升级时这处签名要跟 |
| A4 | 布局从上下排改叠放 | ✅ `Column { MiniPlayer; GlassNavBar }` → `Box(height = 栏 + 缝 + 展开档)`,两者都 `align(BottomCenter)`。**让位量按展开态恒定**(`onSizeChanged` 报出去的 `bottomPad` 与收没收束无关),否则每次翻转重排整条列表 —— 而翻转恰好发生在滚动中。<br>⚠️ **落点那道 `lift` 写在 `MiniPlayer` 内部、由同一条 `f` 派生**:若在 `MainShell` 按值取动画分数传进去,外壳会逐帧重排三张满屏列表(硬规矩 6/7)。<br>⚠️ **`align` 只能挂在 `AnimatedVisibility` 那一层,不能往下透传** —— 它自己包一层容器,子节点的父级数据会被吃掉、整块退化成顶对齐(顶边钉死 1813.5px,`lift` 只剩撑高)。已把 `MiniPlayer` 的 `modifier` 形参**删掉**,见 **H181** |
| A5 | 栏淡掉 | ✅ `collapsed` 参数 + `graphicsLayer { alpha = barFade.value }` 挂在最外层节点(少挂一处会看到"板子没了影子还在")。走**弹簧**不是鸿蒙那条 `barOpacity` 瞬变。手势**门控而不是提前 return** —— 淡掉的栏仍要消费指针事件,否则点击漏到下面的列表上 |
| A6 | 收束态三个 tab 点不动 | ✅ **是这一形态的必然,不是缺陷**(与鸿蒙 15c 同一条结案):那一行只剩胶囊与那颗球。想切格先点球展开或向上滚 |
| A7 | 文案 + 无障碍 | ✅ 新增 `a11y_expand_player` × 五语(盘上那颗球在收束态才有可读标签,展开态它是零宽被裁掉的) |
| A8 | 编译 / 出包 / 解包 / 装机 | ✅ 两 flavor release 各过编译 exit 0;**两渠道 1.0.5 release 都已重打进 `dist/`**(default 64 958 828 B @09:00:52 / md5 `5c7395d6…`、store 3 547 283 B @09:07:26 / md5 `248492b0…`;签名由脚本断言 `CN=Yuyin Reverb`)。解包验收处理量(数字为**在 `dist/` 现份上复跑**所得,default / store 两列):APK **168 / 165 条目**,`classes.dex` **6 418 180 / 6 403 632 B**,`resources.arsc` **447 180 / 442 612 B**,权限清单 **12 行(11 条)/ 10 行(9 条)**(`aapt2` rc=0 且整份打印数过行数);期望逐项 —— native `.so` **1 / 0**、whisper 模型 **1 / 0**、`RECORD_AUDIO` **1 / 0**、`MODIFY_AUDIO_SETTINGS` **1 / 0**、`dataTransfer` **0 / 0**、目录接口域名 `itunes.apple.com` / `fyyd` / `gpodder` = **4 / 5 / 4**(两渠道相同)、新串「展开播放条」在 arsc 命中 **1 / 1**、缓存判据词 `AudioCacheManager` **3 / 3** ⇒ **该非 0 的全部非 0**。<br>⚠️ **计数口径**:**串一律 `LC_ALL=C grep -ao` 按出现次数计**,不用 `grep -c`(二进制里的"行"没有意义;上一版这里写的 1/3/3 就是行数,复跑成 4/5/4)。阳性对照同批跑(追更 3 / 音阁 5 / 待播 5 / 现编假串 `一句没入库的假串` 0),阴性对照 `NotARealClassXyz` 0。<br>✅ **装机几何判据已跑过**:播放键 bounds 展开 `[617,1852][661,1896]` ↔ 收束 `[639,2006][683,2050]`,落差 **154px = 56dp**,与算式 `lift(165px) − Δ块高/2(11px)` 逐项对得上;球的「展开播放条」收束态在 `[111,2001][166,2056]`、展开态消失。**12 轮往返:收束 12/12、展开 12/12,`pidof` 全程同一个进程、crash buffer 处理量 0 字节**(H180 那条崩溃不再复现)。<br>✅ **装机那一轮跑在当时那份 `dist/` 包上**(08:27 `adb install -r` 覆盖安装;签名相同 ⇒ 数据全在,
备份这一步因此没触发)。判据写成一条可复验的命令:`pm path` → `adb pull base.apk` → **MD5 与 `dist/reverb.apk` 相同**
(`13f1e704ce6c5c488b5a4bc765783352`)—— 这比"版本号对得上"强,因为它排除了"装的是同版本号的另一份构建"。
在这份上重跑 **10 轮:收束 10/10、展开 10/10**,`pidof` 不变、crash buffer 0 行 / 0 FATAL。
⚠️ **同一条几何判据有一条取证前置**:**下滑手势起笔必须在滚动容器内**(发现页 y≈1300);
起笔落在固定头部(y≈500,搜索框与 chip 那一段)时 `consumed` 恒 0,于是"划了不动"看起来像回归,实际是划错了地方。<br>⚠️ **未覆盖范围**:① 鸿蒙 `dist/reverb.app` 仍是 **10-10 09:26 那份**(1 098 727 B;43 个源码文件比它新,含 1.0.5 版本号与 HdsTabs 那批),**必须重打才算 1.0.5**;② 截图 kit 未随这批重建(界面动了,硬规矩 20 —— 但等人眼那四条定稿再拍,否则白拍一轮);③ dex 里 `http://` 按 `-ao` 计 **7 次出现 / 6 个不同串**,逐条回读全是库命名空间(裸串 1、`g.co/dev/packagevisibility`、XMP、TTML、MS DRM、xmlpull),**没有一条是订阅源或目录接口**;清单原文那条归 0 判据见下一行。<br>✅ **#153 那条"清单里 http:// 归 0"这次跑掉了**,而且是在**解出来的 assets 原文**上跑的(不是 dex):default 包 `assets/seed_podcasts.json` 51 867 B 命中 **0**(09:00 那份上复跑仍是 0;dex 里 `http://` 亦复跑 = **7 次 / 6 个不同串**,逐条回读仍全是库命名空间);store 包 assets 只有 3 条(`baseline.prof` / `baseline.profm` / `guide_intro.m4a`,**种子清单本来就不进 store**),逐条命中 0。<br>✅ **store 渠道 1.0.5 当前这份**(3 547 283 B,2026-10-16 09:07:26 / md5 `248492b0…`,与 default 同批重打):165 条目 / 单 dex 6 403 632 B / `resources.arsc` 442 612 B;native + 模型 + `.so` 合计 **0**,权限清单 9 条(aapt2 rc=0 且整份打印出来数过)**不含 `RECORD_AUDIO` 也不含 `MODIFY_AUDIO_SETTINGS`**,目录接口域名 **4 / 5 / 4**(`itunes.apple.com` / `fyyd` / `gpodder`,按 `-ao` 计次)与「展开播放条」「清除缓存」各 1、`AudioCacheManager` 3(阳性对照:追更 3 / 音阁 5 / 待播 5;阴性 `NotARealClassXyz` 0)。 |
| A9 | **装机判据:几何一半已换成工具判据跑过,观感一半仍待人眼** | **已用 bounds 跑掉的**(不需要眼睛):收束/展开是否真的发生、落点落差是否等于算式值、左端那颗球是否只在收束态出现、往返 12 轮不崩。<br>**仍待人眼的四条**:① 栏 52 这一档够不够 / 是否显小;② 透镜鼓出量从 2.85dp 缩到 **0.85dp**,还读不读得出"鼓出栏外";③ 收束态三个 tab 点不动能否接受;④ 封面 32↔36 那 4dp 瞬移在弹簧途中看不看得见。另两条一并看:⑤ 展开态标题区被三枚 40dp 命中框挤到什么程度(机上实测三枚图标中心相距 138px ⇒ `spacedBy(10.dp)` 仍在生效,标题列约 132dp 宽);⑥ 底部让位量改了之后列表末项压不压栏。<br>⚠️ **装机窗口只装 release 签名包,但崩溃类与几何类判据不必占它** —— 本仓库的 debug 包 applicationId 是 `com.yuyin.reverb.android.debug`,**与 release 那份并存装在同一台机上**,所以"划二十次看崩不崩 / 探针看中间值"这类先在 debug 上跑,release 窗口只留给观感(见 H180 取证 ①、H181 取证 ①)|
| A10 | 下一步候选 | 若 ① 读成"还是矮",抬 56 并同轮定 `REST_H`;若 ② 读成"玻璃不鼓",**只**动 `REST_H`。真正的形状缺口仍是**封面尺寸可动画**(A4/A9⑤ 两处的让步都挂在它上面) |
| A11 | **鸿蒙侧对照项:同一条 0.86 欠阻尼弹簧要不要钳**(承 H180,#172) | ⏳ **读码已完成,结论是"不同形"**:鸿蒙从不手写"分数 × 长度",`.animation({curve: morphSpring()})` 吃的是两个**字面量**(`.height(collapsed ? TAB_BAR_H : 0)` / `.margin` / `.opacity`),插值由 ArkUI 做 ⇒ Android 那条"过冲进 padding"的路径在本端不存在。**残余风险只剩展开那一支:高度 56→0,按同一条曲线会瞬间算出负高度**,而 ArkUI 布局层怎么处理负值没有公开说明。<br>⚠️ **七轮装机没崩过是经验证据,不是证明**,所以这条**不结案、也不写成"已对齐"**(硬规矩 2 禁止反方向类推)。剩下的判据要装机窗口:`hilog` 打收放途中的 `getRectanglePosition().height`,或看有没有尺寸类异常。若确认框架自钳 ⇒ 把 `BottomBar.ets` 注释里那句"未验"改口 |
| A12 | **鸿蒙划到底保持收束**(边界回弹冒充用户意图,#174) | ✅ **已装机验过**。「滑到底刚收进去就弹回展开」不是阈值问题:回弹同样走 `onDidScroll`,是 `st=Fling` 帧、每帧 −3~−10.6vp、**一整串 −45~−48vp**,而阈值只有 40 ⇒ 必然掀翻(逐帧读数、30 次翻转中 15 次该形态、以及"挂错容器 / 手势起笔在固定头部"两条取证坑全在 **H183**)。修法是**把方向锚在 `Scroll` 帧**(新增 `morphDir`,`Fling`/`Idle` 只许延续),顺带堵掉程序化滚动那条硬规矩 9 的洞。<br>**四条 bounds 判据**(节点类型是第二路独立证据):到底 `COLLAPSED y=2415..2597 h=182 type=Row` → **底部再硬划 6 次仍 COLLAPSED**(本条判据)→ 列表内往回划 5 次 `EXPANDED y=2235..2390 h=155 type=Stack` → 往回轻划靠惯性仍 EXPANDED(真意图照旧算)。<br>⚠️ **Android 没做同构,而且是查过才确定的**:本端 `consumed` 不吃边界回弹(走 overscroll 通道),10 轮划到底本来无此现象 ⇒ 按硬规矩 2 不跨工具链类推 |
| A13 | **Android 频道页 / 待播页播放条改悬浮**(承用户 10-16 反馈,#173) | ✅ 代码完成、两 flavor 各过编译 exit 0。两处从 `Column { 内容; 播放条 }`(播放条**占布局槽**、把内容往上顶,读起来是"底部一块不透明的板")换成统一的 `FloatingMini`:`Box` 里内容铺满 + 播放条 `align(BottomCenter)` 浮在上方、离底 8dp,让位量经 `LocalGlassBottomPad` 落到那一页的 `contentPadding`。<br>⚠️ **这两个入口不参与收束**(收束是给"底部还有一排 tab"那一行准备的),且 `align` 仍挂在 `AnimatedVisibility` 层(H181 根因 B 的防线)。<br>✅ **装机判据已跑**(09:00 那份 `dist/reverb.apk`,覆盖安装):滚动容器 `SCROLL [0,242][1080,2116]` 铺到窗口底、播放条 `1973..2094` **与之重叠 121px**(旧 `Column` 排法不可能);末行底边 1907 → 条顶 1973 = **66px = 24dp**、→ 窗口底 = **209px = 76dp**(= 24+44+8),与算式逐项对得上;连划 14 次不收束、无「展开播放条」那颗球。tab 外壳回归:正 3 次 `[639,2006][683,2050]`+球 / 反 3 次 `[617,1852][661,1896]`-球。<br>⚠️ **待播页只验到一半**:该机队列当时为空,没有可滚列表 ⇒ "末项可达"只在频道页量过 |
| A14 | **两端频道页底部那块不透明板**(承用户 10-16 第二次反馈,#175) | ✅ **两端已改码、已装机、像素判据量过**。真凶不是播放条(用户原话:「不是胶囊,是别的那一段」),而是**更外层那一条底部 padding + 同色背景**:Android 是 `FullScreen` 的 `systemBarsPadding`(频道页/待播页上一轮只把播放条改悬浮,**没动这层外壳**),鸿蒙是 `NavDestination.padding({ bottom: bottomInset })` + `backgroundColor`。列表被截在 `屏高 − 手势区`,线以下永远是纯色板 ⇒ 两端都改成 tab 外壳那一条口径:**只垫顶部、背景铺满整窗、底部避让量拆成「胶囊落点」与「内容让位」两处**(⚠️ 只拆一半会分别得到"末行被压住"与"胶囊贴小白条")。<br>**判据是纯像素**:**从屏底往上数"连续整行同色"的行数,采样时排除系统小白条所在的 x 区间**(第一版写成"屏底往上 45px 内整行同色的行数",两个坑都记在 H184:行间距会让它随滚动位置假阳性、居中小白条会把连续段截断成 17)。Android 修复前 **44px = 16.0dp**(正好等于手势区)→ 修复后 **0**,胶囊底边距屏底 **66px 未变**;鸿蒙 胶囊底边 2571(距屏底 116px)以下 2572..2684 **每行 56~195 个非底色采样点**,同一构建里加载失败的空白频道页同区间 **全为 0**(阴性对照,证明那些像素是内容)。两端 tab 页无回归。<br>⚠️ **Android 这半是在两份产物上各量一次**:第一轮只装了 debug,而用户手上跑的是当天 09:13 那份 release ⇒ 用户回读「Android 还有」完全成立;重打 release(`dist/reverb.apk` 21:11 / 64 975 212 B,签名 `CN=Yuyin Reverb`)并 `install -r` 覆盖装后,同一条判据在**那份包上**复跑 = 0。<br>⚠️ **两端节点树在这一页都不可用**,所以 A13 那句「`SCROLL [0,242][1080,2116]` 铺到窗口底」要按新认知读:**2116 是 a11y 的裁剪线(= 窗口 2160 − 手势区 44),不是绘制边界** —— 悬浮那条判据(滚动容器从 1973 变到裁剪线)仍然成立,但**以后这类"内容到不到屏底"的断言一律走像素**,`uiautomator` 的 bounds 与鸿蒙 `uitest dumpLayout`(只回 sceneboard)都给不出。<br>⚠️ **已知漂移**:鸿蒙 `queue` 分支本轮没动,仍是旧口径(底部 padding + 无悬浮胶囊);两端「待播」页队列为空,内容穿行判据在那一页无从成立。全部见 **H184** |

---

## 二、分发与官网部署(运营事项,不在此文)

发布物料、渠道提交流程、官网手动部署与核验清单,全部记在本地运营手册
(gitignore,不进仓库)。对仓库内文档只有一条含义:**`site/` 改了不等于线上生效**,
部署是手工动作。

---

## 三、遗留问题

### A. 没验过的路径(**最需要优先补的一类**)

| 项 | 情况 |
|---|---|
| ~~鸿蒙的备份导出/导入~~ | ✅ **2026-08-26 已在真机验通**(含本轮把 stringify/parse 移进子线程的改动)。导出:经系统保存面板落到 Download,**93.37 KB**,日志 `[Backup] 导出 分区=7` + `[Files] 已保存`;恢复:选同一文件 → `恢复订阅 15 条`、`ListenStats 合并 9 个频道(按设备取 max)`、`恢复完成 importedSettings=true`。**重启后计数与恢复前完全一致**(订阅 15→15、历史 22→22、印记 5→5、收听 9→9 个频道)⇒ 合并是幂等的,G-Counter 的性质成立 |
| **macOS 的落盘改动**(本轮改动过) | `AppSupport.save` 改成去抖 + 后台编码写盘、逐字稿缓存移出主 actor。**只有编译 + 启动/退出冒烟保证**:本机网络对取源主机一直 -1005,启动后没有任何写触发;窗口又取不到辅助功能句柄(未打包成 .app),没法脚本驱动。手动验 30 秒:播十几秒 → ⌘Q → 看 history.json 的 mtime<br>**这一轮(#6⑦⑧⑮ 同批)又加了两处进同一片地,验收清单跟着变长**:<br>① `FeedCacheStore` 改走 `AppSupport.save`(见 H135)⇒ 除 history 那条之外,还要验**频道缓存**:点「刷新最新」等十几路源回来,`feed_cache.json` 的 mtime 应当**只变一次**而不是十几次;若设置页将来接上「清除缓存」,清空后 0.4 秒再 stat 一次 —— 文件必须还在但内容变成 `{}`(旧写法 `removeItem` 会被 pending 里那份快照复活)。<br>② 逐字稿缓存加 `version`(见 H134)⇒ 拿一份改动前转好的英文集旧稿打开,日志应出现「缓存是旧口径(v1),丢弃重转」且第三页回到"等你手动转录";**这条会真的作废用户已有稿件**,所以界面上那句「需要重新转录」的文案是否讲得通,要在真机上读一遍 |
| **macOS 出包断言在真产物上是第一次**(#17 已改掉,见 H136) | `verify-bundle.sh` 的每条判据都已在**本机**用假 bundle 的正向 + 八道变异验过(`bash macos/tools/selftest-verify.sh` → `pass=9 fail=0`),外加拿归档的 `dist/余音-Reverb-1.0.2-arm64.dmg` 跑出一个真负控制(**12 条不通过**:缺 `x86_64` + 11 个判据词全 0;而 `CFBundleVersion` 与四套 `.strings` 全过 —— 所以它不是"一律报错"的假严格)。<br>**没跑过的是另一半:一个真 universal 包走过去把断言全绿**。构建机上第一次跑 `./package.sh` 时若断言报红,按这个顺序判:先看报的是哪一类(架构/词/语言/版本/签名),再拿 `lipo -archs`、`plutil -p` 手工复核那一条 —— **别第一时间改判据**,这套断言已有自检兜着,历史上这类报红的第一嫌疑人是包本身(1.0.2 那次就是) |
| ~~鸿蒙的冷启动耗时~~ | ✅ **2026-08-26 已量**:启动 → 「本地数据就绪」**132 ms**,其中各 store 同步读盘只占 **24 ms**(15 订阅 / 22 历史 / 100 最新 / 15 频道缓存)。三端齐了:Android 219 ms(`am start -W` 全过程)、macOS 约 53 ms(store 合计)、鸿蒙 132 ms。**结论仍是不改** |
| ~~鸿蒙的「官方逐字稿」路径~~ | ✅ **2026-08-25 已在真机验通**。方法:手机网络到不了 buzzsprout(`curl_code 28`,与 App 无关),改用本机 `http.server` + `hdc rport` 反向端口喂一份合成 feed(真实的 Podcast Index JSON 稿,10245 条词级条目)。结果:第三页出现、文案走「发布方提供了逐字稿」分支、10245 条合成 **1345 可读行**、**逐字高亮生效**(当前词加粗更亮、同句其余 55% 透明)。<br>**顺带发现一处待查 → ✅ 2026-10-07 结案(见 H150)**:同一份稿 Android 侧记录约 1480 行、鸿蒙 1345 行 —— 查下来**不是算法差异,是量的阶段不同**:1480 是 `glueOrphans` 的入口、1345 是出口,实测 pre→post 塌缩比 0%~88.6%,9.1% 属常见区间。两端真码差分 49 组 × 4 模式 **196 份输出逐字节相同**(负控制 8 条各自被检出)。但顺着不变式 `join(words)==text` 查出**两条屏幕可见的移植漂移**并已修:Android 并句时丢了词级空格(逐词卡拉OK读出 `andhe's`)、鸿蒙在无词级时间时凭空造伪词(同一份整句稿两端高亮粒度不同),另有取稿器五条(数组根 / `word`+`start`+`endMs` 键名 / 秒→毫秒截断 / 单段时钟 / VTT 的 `NOTE` 块与 `SPEAKER 01:`、`&nbsp;`)。双端真机跑同一份三形状夹具 feed:**149 / 149 / 3 句,三份落盘缓存逐字节相同**;鸿蒙那条从未真机跑过的逐词高亮分支(H137)这次也第一次跑出来了。`CACHE_VERSION` **没有 +1**,理由与判据写在 H150。 |
| ~~鸿蒙 native 解码只验过 m4a/AAC~~ | ✅ **2026-10-07 先纠正这条本身写错了对象,再把该验的那一半真机跑完**。原文把**两条互不相干的解码路径当成了一条**:<br>① **用户侧播放走系统 `media.AVPlayer`**(`playback/PlayerController.ets:121`,网络源直接 `setMediaSource`/`url`,本地下载走 `fdSrc`),**格式支持是系统的,不经过本仓库任何解码代码**;<br>② 那条 `reverb_pcm.cpp`(`OH_AVDemuxer` + 按 track 报回的 mime 建 `OH_AudioCodec`)是**转写的 PCM 输入侧**,唯一入口 `SpeechTranscriber.ets:118 PcmReader.open`,而 `Features.ets:38 LOCAL_ASR=false` ⇒ 界面上走不到(硬规矩 2:ArkTS 无 DCE,代码仍在包里,但不可达)。**所以"只验过 m4a/AAC"这句原来挂在①上,是把死路径的账记到了活路径头上。**<br>**① 已补验**(夹具与取证口径见 H150 补记):三份 ffmpeg 合成的 12 秒正弦,单集在**鸿蒙真机**播完 —— 24 kHz **单声道 MP3** → `dur=12048`、44.1 kHz 立体声 MP3 → `dur=12042`、22.05 kHz 单声道 AAC → `dur=12000`,三条都 `state=playing` → `state=completed`,**`播放错误` / `装载失败` / `重试耗尽` / `jank` 各 0 次**(app 侧日志处理量 33 行)。**⇒ mp3、单声道、非 44.1 kHz 这三项在播放链路上不再是"没实测"。**<br>**仍未覆盖**:② 那条 native 分支(要先把 `LOCAL_ASR` 打开、而系统识别质量本身不够用,见 H62);其它容器 opus/ogg/flac 没测;`Features.LOCAL_ASR=true` 之后 native 侧对 mp3/单声道/24 kHz 是否同样解得动,也仍是未知——那一次只证明了 AVPlayer |
| 三端的 es / fr 界面没有做过通读 —— **静态那一半已系统扫过(2026-10-07),剩的只有"读一遍"那一半** | **处理量**:Android 336 键 × 5 套 = 1,680 条 + 鸿蒙 333 × 5 = 1,665 条 + macOS 199 × 4 套 = 796 条(简中在代码里,没有 `zh-Hans.lproj`),合计 **4,141 个键-实例**。**四类判据各扫一遍,结论都是 0,而每个非 0 项都逐条回读过**:<br>① **键集相等** —— 每端四套非基础语种的键集与本端基础(zh)套**逐一相等**,macOS 四套 `Localizable.strings` 各 199 键,缺键 **0**、多键 **0**(缺键的症状是静默回落成中文,界面上看不出来,所以这条必须机器判);<br>② **繁体没翻** —— 用的是**语料差集**而不是按位对齐的简→繁映射表(后者在译文改写过措辞时会造出 `加→載` 这种假字对):候选"简体独有字"Android 221 个 / 鸿蒙 224 / macOS 141,**三份繁体文件里含候选字的条数全 0**;繁中值与简中逐字相同的 65 / 68 / 35 条**逐条回读**,全部是两种书写法同形的词(科技、取消、收藏)、URL、备案号与 `%d 秒` 那类格式占位串;<br>③ **es / fr 整段留英文** —— 与英文逐字相同的条数 11 / 24(Android es/fr)、14 / 22(鸿蒙)、9 / 13(macOS),**逐条回读**后全是品牌名 `Reverb`、隐私与 OPML 两条 URL、备案号、`%1$d h %2$d min` 这类单位占位,以及法西里本就同形的词(`Culture`/`Arts`/`Religion`/`Pause`/`Version`/`Canada`),**没有一条是整句没翻**;<br>④ **撇号/引号形态漂移** 早一批已按渲染值扫过并对齐 6 条(见 H156)。<br>**这一轮顺带读出来的两处,已登记不在这四条里**:共享键的**措辞漂移 3 条**(zh 那两条是鸿蒙缺一个「为」字、fr 那两条是 **Android 侧写得不好** —— `Marquer comme lu` 是"读过",这是播客;第 3 条 `queue_empty` 是整句改写)与**半角标点 18 vs 6 的体量差**,判据、改法与为什么推到 1.0.5 全写在 **H156 补记二** 与下面 D 节。<br>**还剩的只有机器给不出结论的那一半**:真机上切到 fr/es 通读长段落(关于页五段、隐私同意页、逐字稿空态、备份对话框 8 行)看**裁不裁、顶不顶、换行断在哪**,以及 ② 里那些"看着合法"的同形词由母语者判一次(`genre_truecrime` 的法文写作 `True Crime` 而 Apple 用 *Histoires vraies*、`region_short_auto` 的西文写作 `Auto`)—— 这两条**不是缺陷判定,是需要人**。<br>✅ **2026-10-08 把"读一遍"那一半跑完了**(两端各切一次 fr / es,逐页落 dump 再读串,不是肉眼看两屏)。处理量:鸿蒙 **83 份 dump / 13,958 个节点**(`text` 非空 2,221 条逐条读过)+ Android **63 份 / 931,816 B**(`text` 非空 947 条、`content-desc` 非空 257 条)。跑出来四条,全部写进 **H160**:<br>① **真渲染缺陷 `1,×`(Android 独有,两个调用点)** —— `"%.2f".format()` 走默认 locale,法/西里小数点是逗号,而去尾零那行只 `trimEnd('.')`,于是整数倍速渲染成 `1,×`(dump 里命中 **11 次**)。两处已改成 `trimEnd('.', ',')`,并做了主机端复算(4 locale × 5 倍速 = 20 组:fr/es 下 `1,` → `1`、`1,25` 不变,**zh/en 改前改后逐字节相同** = 阴性对照)。<br>② **同端两个词名** —— fr 关于页把「印记」的单位写成 `tampons`,同语种其余 6 处叫 `sceau`;两端各一处已统一,`tampon` 计数改前 1 / 改后 0。<br>③ **鸿蒙进度条念的是原始毫秒** —— dump 里 `Slider` 的 `text=101300.000000` 而界面同刻写 `01:41`;已加 `accessibilityText`(当前 / 总长两个格式化时间)。<br>④ **两处登记不改**:许可页有中文硬编码(`LicensesScreen.kt:34-35`,只在 default 渠道显示,R8 那半见 :30-33 注释)⇒ 排 1.0.5;**`site/reverb/privacy.html` 只有一份简体中文**(`hreflang` 0 个),而**五语的 `privacy_url` 都指向它**(两端 10 处命中 URL 完全相同)⇒ fr/es 用户点开的隐私政策是中文 —— 这条属于站点工程与部署(三个副本的坑见 H144),不在装机窗口内。<br>**两条结案(看着像缺陷、其实不是)**:非本地格式的日期两端同形 = 既有口径;西语 `Huella de escucha` / `sellos` 双名三端一致 = 设计。<br>**这一行仍然没做完的**:① 与 ② 的修法已在 2026-10-08 重打两端三包并复跑解包判据(store 侧新增「`whisper` 在 arsc 与 dex 双 0」这条,见 H161 验收表),**但真机上仍然一个串都没取过**(两台机器装的都是本轮之前的包);② 需要母语者判断的那两条(机器给不出结论)**仍在**;③ **需要人的那一半还是零** —— 读屏一次都没实听过,而截断/溢出只做了"读串 + 三处最险的回读截图",**没做像素级溢出测量**,窄屏 × 最大字号那一档没覆盖;④ 新登记一条**跨端漂移**(不是本端缺陷):fr/es 下**两端小数分隔符不同**(鸿蒙 `${speed}×` 是裸拼接、恒为 `1.25×`;Android 走 locale、`1,25×`),要对齐得在鸿蒙侧引入 locale ⇒ 见 D 节。 |
| macOS 的转录在旧系统上的降级 | 门控写的是 `@available(macOS 26, *)`,低版本显示提示 —— 没有在低版本真机上验过 |
| 鸿蒙下载闸门的**蜂窝拦截分支**(2026-10-09 判据改成「只有蜂窝才拦」,这行的方向跟着翻) | **放行侧已真机验通**:连着 Wi-Fi 点下载 ⇒ 放行并落盘 33,678 KB(见 H166 验收与上面门 2 ⑤)。**拦截侧没证据**:这台机**无 SIM**(状态栏「无 SIM 卡 \| 仅限紧急呼叫」),`bearerTypes` 里永远出不来 `BEARER_CELLULAR(0)`,所以"真蜂窝下确实被拦、并且弹的是那句『当前是蜂窝网络』"这一寸只能靠 bearer 判据的代码读法背书。⇒ 插卡真机上要补的是**两条一起**:拦截发生 + Toast 文案的渲染值(五语各一次也顺带)。**另记一条设计代价**:限量/计费的 Wi-Fi 热点在鸿蒙**会被放行**(本端拿不到计费信号),Android 侧仍拦 —— 这是两端不等价,不是待修 bug |
| 1.0.1 播放门面重写(6cacf80)后的**音频焦点表现** | **2026-10-07 在这台设备上补过,结论是补不了,而且卡点是结构性的** —— 但顺着读码读出一条真实的两端不对称,已登记进 D 节。<br>① **抢占方向(我起播 → 对方让位)**:仍只有 H80 那次单机冒烟,今天没能重跑。<br>② **被抢占方向**:需要一个「能驱动、且读得到本机音频」的第二家媒体应用。本机可发声的只有 华为音乐(`com.huawei.hmsapp.music`)/系统视频播放器/录音机/浏览器 —— 前两者首启是登录与合规墙(在用户的个人机上不该代点);而 `hdc shell` **写不进媒体库**(`/storage/media` Permission denied,shell uid 不在 `file_manager` 组),`anco_audio` 同样 Permission denied,`/data/local/tmp` 对方应用又读不到 ⇒ **夹具喂不进第二个应用**,这条路在本设备形态下不通,换工具也换不出来。要补得靠「一台已登录、能直接播第二家 App 的设备」或两台机器。<br>③ **代码层已能定论的部分(与真机取证无关)**:Android 侧本仓库**零自写焦点代码**(`grep -rIn AudioFocus android` 在源码 0 命中,824 条命中全在 R8 的 mapping/usage 产物里),焦点由 Media3 库托管,并且**解包验得过**:两个渠道 dex 里 `androidx/media3/exoplayer/AudioFocusManager` 各 4 次、`onAudioFocusChange` 各 2 次命中(store dex 6,377,744 B / default dex 6,392,560 B;usage.txt 里该类 0 条 ⇒ 没被 R8 删)。鸿蒙侧只在自家播放生命周期内 activate/deactivate `AudioSession(CONCURRENCY_PAUSE_OTHERS)`(`PlayerController.ets:584-602`),`audioInterruptMode` 设的是 `SHARE_MODE`(`:561`,而 H80 已写明它只管进程内中断单元、不是跨应用并发策略),**并且从未订阅 `AVPlayer.on('audioInterrupt')`** ⇒ 「被对方打断」这一路在应用侧没有任何处理,谈不上对方释放后自动恢复。该接口在装机 SDK 里可用(`@ohos.multimedia.media.d.ts:3592`,`@since 9`;本工程 `compatibleSdkVersion 6.0.2(22)`)。<br>**所以这行剩下的不是"没验",是"有一端有库兜底、另一端没有等价默认"这个结构性差别** —— 判据、修法与动它之前必须先取的证,写在 D 节那一行 |
| 1.0.1 会话命令改幂等后的**耳机媒体键回归** | 锁屏 / 控制中心已验;有线耳机线控与蓝牙 AVRCP 的重复派发场景(H83 的根因路径)没有真机回归 |
| **1.0.2 系统备份的云端全链路** | 解包与鸿蒙真机注册已验(H84);**Android 端真实链路已于 2026-09-19 验通**(某国产定制 ROM / Android 16:`bmgr backupnow` 生成 ~412KB 载荷(与白名单体量相符)→ 卸载重装 → `bmgr restore <token>` → 订阅 9 条、继续收听进度、听书统计全部回归。传输用的是**本地调试传输**(LocalTransport,设备未绑 GMS 备份账号,云端传输报 Transport error)——数据管线(按 data_extraction_rules 生成载荷→传输→恢复)与云端一致,只有存储后端不同;纯云端链等用户绑账号后自然生效。鸿蒙侧仍是卡口:debug 包被云备份「备份选项」清单排除(实测清单内三方应用全 release 签名),本地 release hap 无法 hdc 侧载(9568322),市场在架 1.0.1 又不含 backup 扩展 ⇒ **等 1.0.2 发布后用市场包走**(装市场包→种数据→云备份→卸载重装→恢复),那也正是真实用户场景 |
| **1.0.2 系统备份后的平台安全扫描** | `allowBackup=false` 是 H75 误报时期的缓解措施之一,翻转后受影响渠道须重跑平台扫描(H84) |
| ~~Android 玻璃栏的同构移植~~ | ✅ **2026-09-27 已在真机验通**(Android 16 / 1272×2800 / 密度 476 → 2.975 px/dp)。夹具 `android/tools/glass-shot.sh` 首次跑通,一次出三帧(静止 / 按住 / 拖动中),口径全部用像素量出来:① **拖动全程透镜尺寸恒定** —— 按住帧与拖动帧的高亮连通块**同为 321×152 px**(同一裁剪窗内被截到同一底边),只有中心 x 从 371 走到 597;含整栏 1.06 缩放后为 322×169 px = 107.9×56.8 dp,宽高比 1.90 ≡ `ASPECT`;上沿 y=2596 高出栏顶 13 px,**鼓出栏外没被裁**(栏 143 px = 48.1 dp ✓)。② **静止时栏上没有任何玻璃** —— 静止帧整栏找不到 >38 px 的中性高亮连通块(那块是 音阁 图标的白描边),只剩扁灰底。③ **内容零形变** —— 发现图标静止帧 61×96 px 中心 (386,2671),按住/拖动两帧都是 65×102 px 中心 (371,2670),差值恰好等于整栏 1.06 缩放(636+(386−636)×1.06=371),**按住与拖动两帧完全相同**。<br>夹具第一次跑暴露的三个真问题已修:`wm density` 双行时取到的是 Physical(应取 Override)、dp→px 用整数除法把 2.975 截成 2、按压点按"栏宽四等分"算偏了 33 px。装机门禁见下一行 |
| Android 侧载要过 ROM 的安装门禁 | 这台机子对 `adb install` 会弹「检测结果:涉及敏感权限 → 继续安装」,**命令挂着不返回也不报错**(第一次跑夹具时白等了十分钟)。按「装机前先问」的规矩,这一步由用户在机上点;脚本里 `INSTALL=0` 可只抓帧不重装 |
| **Android 的玻璃折射(鸿蒙第 0.5 层)未做** | 不是能力缺口而是取源问题:能截到的只有整个 window,而里面带着栏自己。方案与代价见 `GlassNavBar.kt` 的「折射:尚未落地」与 H103。<br>**真机的代价已经看得见**:拖动中途那颗透镜停在两格之间时,镜内就是一块比栏底更深的暗面(鸿蒙那一层里是折射过来的页面内容)。静止与按住两态不受影响 |
| **Android 栏底留白:量过了,结论是不照抄 0.62** | 鸿蒙把留白收到手势区的 0.62 倍(`INSET_KEEP`),Android 一直是整个 inset 留空(`MainShell` 的 `navigationBarsPadding`)。本机量出来:手势区 48 px(16.1 dp),小白条 y 2768..2778(下沿距屏底 21 px = 7.1 dp),栏底 y=2752 → **栏底到小白条 16 px,小白条到屏底 21 px**,已经比"对称"还紧一点(对称要把栏底抬到 2747,即 1.10×inset)。**照抄 0.62 会把栏底压到 2770,直接盖住小白条上沿** —— 0.62 是那台鸿蒙机避让区偏大造成的设备特定值,不是可移植的常量。鸿蒙的**规则**(两道间距对称)成立,数值各机自量 |
| ~~Android「继续收听」卡片的长按菜单(02489ed)~~ | ✅ **2026-10-07 已在真机验通**(Pixel 3 / Android 16 / `1.0.4-debug`,判据形态与鸿蒙那次 H100 一致:菜单节点直接读,不靠截图)。<br>**先记清上一轮为什么断**:三件事叠在一起 —— 全新安装没有历史、内置引导音频只有 30 秒播完即 `played=true` 被口径排除、机子中途被用户拿去用。这次不造夹具,直接用真实历史里停在中间的三集(进度 8 分钟 / 1:51:36 / 1:55:32),横条当场就有三张卡。<br>**取证写法**:菜单项是文字不是图标,所以 `uiautomator dump` 的 `text` 就够(与 H143 那条「标签读得出」同源);长按用 `input swipe x y x y 800`,与鸿蒙 `uinput -T -d … -i 800 -u` 同量级。结果四条:<br>① **三项文案齐** —— 那一帧 dump 里只有 `下一个播放` / `加入队列` / `标记为已播完` 三条(菜单是独立窗口,页面节点不进来)。<br>② **锚点在手指上** —— 按下 x=225 → 首项左缘 x=258,x=620 → 653;两次按下 y=1000 而首项顶边都是 1061 ⇒ **左缘 = 按点 x + 33px、顶边 = 按点 y + 61px 恒定**,与鸿蒙 H121 的「顶边恒在按点下方 29px」同形(规则可同构,数值各机自量)。按在贴右缘那颗(x=950)时菜单落到 `[675,1061][906,1380]`、整块在屏内 ⇒ H113 那条「贴右缘菜单完整」的鸿蒙判据在 Android 也有对等物。<br>③ **三项各自的效果都取到应用自己的日志 + 落盘态** —— `加入队列` ⇒ `[Player] enqueue id=6aafab73… size=1` 且 `playback_state.json` 的 `upNext` 多出该集;`下一个播放` ⇒ `[Player] playNext id=6a9d6a20… size=2` 且 `upNext` 顺序变成 **[S9E8, S9E9]**(置顶而不是追加);`标记为已播完` ⇒ `[HistoryStore] markPlayed … played=true`,**那张卡当场从横条消失**、另两张原位不动(不跳转、不重启)。<br>④ **可逆性一并验掉** —— 去音阁 · 历史长按同一行,第三项文案**当场是「标记为未播完」**(同一个菜单按 `played` 换向),点下去 `played=false` ⇒ 卡片回到横条原位。所以「删除 = 标记已播完」这个设计不会把用户进度弄丢,注释里那句「从历史『标记未播完』即可复原」是**实测过的**。<br>顺带回归到队列页:两行各带 `上移 / 下移 / 移出队列`,清完之后的空态文案是「队列是空的。长按单集「加入队列」,排着慢慢听」。<br>**没验到的一条(工具边界,如实记)**:`加入队列` 之后那句 Toast「已加入播放队列」**读不到** —— toast 窗口不进 `uiautomator dump`(点完 0.35 秒立刻 dump,只拿回页面节点),`dumpsys notification` 里也没有 toast 段。所以"提示有没有弹出来"仍然只能眼看;而 enqueue 本身已由日志证明生效。<br>**设备状态已还原**:两条队列项各自 `移出队列`(`upNext` 回 0)、`played` 改回 false、正在播那一集与 `listTag` 全程未动(158.家宴 / `dl` / 暂停),`/sdcard` 上的临时 dump 已删。<br>**这次逐字读到 3 个共享键两端的措辞漂移**(`mark_played` / `mark_unplayed` 差一个「为」、fr 是 `lu` 对 `écouté`、`queue_empty` 整句不同),判读与"为什么不在 1.0.4 前改"记在 **H156 的第二条补记** |
| **Android 本轮三项(分段条通栏 / 播放按钮+播放模式 / 换 tab 卡顿)** | **换 tab 卡顿:✅ 2026-09-28 差分定位到真根因并装机复验通过**。2026-09-27 那次"拇指确认已不卡"(当时仪器给不出前后差,见 H108 教训②)**第二天就复发**,第三份报告才对:内层 NavHost 只组合当前 entry,切走那一页被整个 dispose ⇒ 每次切换从零重建,改前量到 `Choreographer: Skipped 31 frames ≈ 517 ms`,而"换分段 / 点已选中的 tab"两条对照都是 0。修法是把内层 tab 栈拆掉、两页常驻叠层(`tabKept` 不画+不进无障碍树、吸收层挡空白漏点、四层 `zIndex`),装机复验 **8 轮来回落点全对且 `Skipped` = 0**,同一批 `gfxinfo` 985 帧 / jank 3.25%,并做过"摘掉吸收层"与"摘掉栏的显式 z"两个对照(见 H117)。**残留**:第一次进音阁仍付一次整页 compose。**播放按钮 → 播放模式按钮:同日深夜装机跑通之后又推翻重做**(判据取应用自己落盘的日志, `adb exec-out run-as … cat files/logs/reverb.log`;logcat 那条 `-s Player` 的写法是错的,tag 实为 `Reverb/Player`,见 H110)。 装机验过的中间两版:图标口径与全 App 相反(H115 的 `listPlayUsed` 门面的反面)、长按切模式 + tooltip 气泡 (气泡装机后判定不要,整块删)。**定稿**:那颗按钮**只切模式**(顺序 / 单曲循环 / 随机),起播靠点列表里的某一集, `listPlayUsed` 与 `activeListTag` 两个会话状态一起删,「列表循环」这一档换成「单曲循环」(见 H118)。**同日深夜又改一轮**:"模式全局一份"被装机反馈推翻(「在最新切了随机,收藏也变随机」)⇒ 改成**每列各一份**:按 tag 存一张表、旧 `play_mode` 键降级成回落值,`PlayModeButton(tag)` 读写本列那一格;`activeListTag` 以"改的是不是正在播那一列"这个**当场生效判据**的身份回来(与 H118 删掉的那个用途无关)。这一轮**同日 22:12 已装机验通**(三格互相独立、起播取本列那份、`(生效)` 与 `(未生效:正在播 '…')` 按预期分流),装机还抓到一处解析缺陷:频道列的 tag 就是 feedUrl 而 URL 可能自带 `=`,按第一个 `=` 切会让那一列"写进去读不回来"⇒ 解析改成按**最后一个** `=` 切(见 H119 修法 1)。 装机时留下的两条判据仍然有效:`playQueue count=… tag='inbox'`(行内点某一集也带 tag)、 `playMode A -> B`(切模式不重起播)。 **已装机验到**(Pixel 3):三态图标与 content-desc 一一对上、连点五格只出 `playMode` 不出 `playQueue`、两处挂载(音阁段条 `[926,311][992,377]` 与频道主页「共 73 集」行 `[937,1150][1003,1216]`)、点列表行起播仍带 tag。**没验的**:单曲循环自然播完原地重播(判据 `advanceQueue repeat-one index=…`)、随机走完表停、单曲循环下手动「下一集」照常前进且列表末尾该灰、老设备存过 `play_mode=1` 升级后直接进单曲循环。**每列各一份已装机验通**(三格互不传染 / 起播取本列那份 / `(生效)` 与 `(未生效:正在播 '…')` 分流),判据见 H119。**2026-09-29 更新**:上面那四项里前三项(单曲循环原地重播 / 随机走完表停 / 单曲循环下手动下一集 + 末尾置灰)**鸿蒙侧已真机验通**,判据与"拖到集尾"的省时手法见下面自动续播那一行;**Android 侧 2026-10-05 也已真机验通**(逐条判据与造长音频夹具的手法在那一行的补记里,夹具的坑见 H129) |
| **Android 长按透镜「相对栏置底」:几何已排除,剩拇指覆核** | 装机报「透镜看起来沉在栏底边,不纵向居中」。把三处 y 摊开算、又翻回上一轮的像素记录 ⇒ 几何推不出偏心;夹具新加的**差分框**在 Pixel 3 上给出「上鼓出 4 px / 下鼓出 3 px、与栏中线偏离 −1 px」,**都在 ±2 px 地板内 ⇒ 走"几何没问题、病在对比度"那条判读路径**(H109)。所以本轮留下的修复是"栏的 8dp 方向光投影 spot 归零",而它是按嫌疑下的、不是按证实下的 —— 数只能证明上下对称,不能证明"看着不沉"。**待拇指覆核**;若仍读到沉,下一个动的是玻璃自身的上亮下暗渐变(H109 候选 2) |
| **鸿蒙端「同一条病灶」的对应物:两处向下偏移的 shadow,等 Android 拇指定案后再决定** | H109 的病是"往下甩的那层暗带把下缘对比度吃掉",Android 的载体是 `Modifier.shadow` 的 spot 层(已归零)。鸿蒙没有 ambient/spot 之分,但 `GlassTabBar.ets` 里有两处**形状相同**的东西:`:872` 透镜本体 `.shadow(radius 18, offsetY 4)`、`:1002` 静止底 `.shadow(radius 24, offsetY 5)`。**先不动**:① 它是当初真机验收过的观感,② Android 这条也还停在"按嫌疑改的、数只证明上下对称"这一步。按「一端验收后再同构移植」的规矩,等拇指在 Android 上确认"不沉了"再照搬,否则是拿一台没验的机器去改另一台已验收的 |
| **鸿蒙分段条:排列按钮不显示 / 收口压在 chip 上 —— ✅ 2026-09-28 真机验通** | 第一次把 debug hap 装上真机(BRA-AL00 / 1216×2688 / 3.25)。**装机路径本身是这轮才打通的**:签名 profile 只覆盖 `com.yuyin.reverb`,所以把 `AppScope/app.json5` 的 bundleName **临时**改成 `com.yuyin.reverb.glasstest` 装成一个独立应用(不覆盖在架包、不碰用户数据),验完改回去 —— **这个临时值绝不能进提交**。结果:① #30(订阅段右端没有排列按钮)**已修复**,按钮 `[1059,331][1125,396]`、垂直居中;② 但装机新暴露一处重叠,`ChipsRow` 按 Android 定稿改成"恒通栏 + chips 段 `layoutWeight(1)` 占位",并删掉整套"量了再缩条宽"的状态(见 H111);③ #29(首帧通栏闪要不要同构约束路线)**失去需求方**,量→setState 那条路整条没了,不用复现了。**没验的**:字号对齐(#31)只做了定位。(「鸿蒙端还没有播放模式」这一条已在 2026-09-29 消掉,见下条) |
| **播放模式 + 分段条播放按钮:鸿蒙 ✅ 2026-09-28 真机验通;macOS 已同构移植、未运行验收** | 与 Android 同构(`PlayMode` 枚举同序、`play_mode` 存 ordinal、`ListPlayButton` 同名同语义、tag 同式)。真机判据仍走应用自己的日志(`hdc shell "hilog -x -e '\[Player\] (playQueue\|playMode)'"`):频道主页 `playQueue count=64 index=0 tag='podcast:https://feeds.simplecast.com'`(URL 由 Logger 统一收成 host,不落到具体地址)、音阁最新段 `count=12 index=0 tag='inbox'`、**行内点某一集**`count=12 index=1 tag='inbox'`(这就是 Android 那轮找到的洞:少了 tag,段条那颗按钮认不出正在播的是这一列);连点只出 `playMode SEQUENTIAL -> REPEAT -> SHUFFLE -> SEQUENTIAL` 不再重起播;**跨进程重启恢复**验到(杀进程后 pid 变,`mode=REPEAT` 照旧)。**没验的**:① 收藏 / 下载两段的 tag(测试机上这两列都空,按钮按"没内容不摆动作"正确隐藏,但点亮路径没走);② 播完自动连播(要等一集自然结束);③ `ListPlayButton` 上的 `.accessibilityText()` 是 Android `contentDescription` 的对等物,已设但**没验能不能被读屏取到** —— `uitest dumpLayout` 里 SymbolGlyph 的 `description` 恒为空,分不清"没生效"与"不报",要开无障碍实听一次 。**2026-09-28 深夜 Android 侧把那颗按钮推翻重做**(一颗按钮只切模式、起播交给列表行、「列表循环」换成「单曲循环」,见 H118),同日又改成**每列各一份**(见 H119);**鸿蒙 2026-09-29 把这两轮一起同构移植并真机验通** ⇒ 两端口径重新一致。上面那条「旧口径的鸿蒙验收」因此作废(`ListPlayButton` / `listPlayUsed` / `REPEAT` 三样都没了)。**新验收**(BRA-AL00,`aa force-stop` + `aa start` 之后刻意只做读、不做写):最新=顺序 / 收藏=随机 / 下载=单曲循环 三列各自读回、没存过值的频道列读**回落值** 单曲循环、日志**零条** `playMode` 写而只有一条 `playQueue count=3 index=0 tag='fav' mode=SHUFFLE`(取的是 fav 自己那一格)、正在播 fav 时点 fav 那颗 `(生效)` 点最新那颗 `(未生效:正在播 'fav')`。**两处平台差异**:存储用 JSON 对象串(`@ohos.data.preferences` 无 StringSet)⇒ Android 那个「tag 里带 `=`」的解析坑在鸿蒙结构上不存在;`SymbolGlyph` 在 `dumpLayout` 里 text/description 全空 ⇒ 判据只能靠截屏裁剪,而分段条会随选中项滚动,**每次点击前必须重新 dump 取 bounds**(按旧坐标连点曾读出彼此矛盾的三格,差点误判成按列存储没生效)。**两端同批未验**:自动续播三项(见 #47)—— **鸿蒙侧 2026-09-29 已验通,Android 侧仍待装机**(见下面两行)。**macOS 同日已同构移植,但桌面端一帧都没跑起来看过**(本机跑不了构建,见本节最后一行)|
| **鸿蒙装机反馈四项(宫格首行被盖 / 长按阈值 / 删除无确认 / 播放按钮首点不变):鸿蒙 ✅ 2026-09-28 真机验通;Android 两条同构改动待装机** | 2026-09-28 用户实机报,逐条见 H112–H115。装机走的是**临时 bundleName**(`com.yuyin.reverb.glasstest`,独立测试包,不碰在架包与用户数据,验完改回、**绝不入库**)。结果:① 宫格首行三张封面回到第一列,真实封面顶边 y=545 与分段条底边 435 **不相交**(H112);② 长按阈值用 `uinput -T -d … -i <ms> -u …` 逐毫秒量:**300/400 ms 不出菜单、600/800 ms 出**,且整个测量过程 `playQueue` 日志只有一条(来自主动点击)—— **没有误触发播放**;贴右缘按下(940 / 1150)菜单仍完整在屏内(H113)。**但同一条里"菜单贴着按下点"那句是误读** —— 当时按 x=1150 而菜单左缘在 65,那是钉在屏幕左缘,次日由 H121 修掉;③ 两处删除入口都出确认框,正文含集名,取消不删、删除当场生效(H114);④ 播放按钮首点亮像素 33→5579(⏸→▶),连点三下日志 `SEQUENTIAL→REPEAT→SHUFFLE→SEQUENTIAL`,`force-stop` 冷启后回到 0(⏸ 回来了,标志没落盘)(H115)。**没验的**:Android 侧 ③④ 两条同构改动只编译过(签名与设备另一轮再说);鸿蒙「收藏 / 下载」两段的按钮 tag 与频道主页那颗未逐一点过(共用同一组件,但 tag 是逐入口的事) |
| **鸿蒙分段条末颗 chip 被右端按钮切一半** | 用户 2026-09-28 看截屏报「历史被清空盖住一部分,向右滑动 tab 整体并没有往右滑」。**取证过程先误判了一次**:dumpLayout 里「历史」只有 106px(其他 chip 182px),据此判成"被压缩",给 chip 加 `flexShrink(0)`、给 chips 段与 Stack 钉显式宽 —— **三种改法装机后布局一像素没动**,而且钉宽那一版把横滚彻底弄坏了,已全部回退。真相:五段标签内容宽 1081px > 视口 964px,那颗是被**视口右缘裁掉**,而裁剪边正好贴着按钮左缘,看起来像"压在按钮底下";"向右滑不动"是因为当时已在滚动起点(offset 0),要**向左拖**才露得出末颗(实测向左拖之后「历史」满宽 182px 完整可见)。**所以这不是布局 bug,是缺"这里还有内容"的视觉提示** —— 待做的是右缘渐隐 / 与按钮之间留缝这一类 affordance,Android 侧同形(H111 的验收里已经记过两端都截断)。教训本身记进 H116。**→ 同日已补渐隐带**:内容溢出且未滚到右端时,在 chips 视口右缘画一条 `CHIPS_EDGE_FADE_W = 36` 的渐隐,收到玻璃条自己的染色;判据与"为什么两个量都要"见 H116 补记。**鸿蒙侧 2026-09-29 真机量过条件成立**(见下两行),**Android 未同构** |
| **鸿蒙「字号与 Android 对齐」的最后一格:外壳按占屏比例收小 —— ✅ 2026-09-29 真机逐节点量过(观感待拇指)** | 装机反馈「底部 tab 和图标文字相对 Android 有些大了…顶部的也是,明显偏大」。**先量再改,结论与直觉相反:两端代码数值完全相等**(栏 48 / 图标 19 / 标签 11+0.5 字距 / 分段条 44 / 留白 24 / 内收 22),系统字体缩放也确认是 1.0(改前单字宽实测 11.54vp ≡ 11fp+0.5)。偏大的是**画布**:鸿蒙逻辑宽 374.2vp vs Android 427.6dp,而两台的物理面板宽几乎相同 ⇒ **1vp ≈ 1.18 标准 dp**,同一个绝对值在鸿蒙占屏多 14%、物理上大 18%。**按用户选的口径「外壳 + tab 文字一起收」**:外壳整体乘 0.876 —— 栏 48→42、图标 19→17、标签 11→10fp、静止底 44→38、留白 24→21(栏宽占屏 87.2%→88.8% ≡ Android)、内收 22→19、分段条 44→38、胶囊 34→30、页头金线 40→35;圆角两处写死的 21 改成 `CHIPS_STRIP_H / 2`,`CHIPS_RESERVE_H` / `barFootprint` / `underBarPad` 自动跟着。**两处刻意没收**:chip 本身(实测 29.8vp = 8.0% 屏宽,Android FilterChip 34dp = 7.9%,本来就等比例)、正文与列表字号(同一把尺子它们也偏 14%,但那会推翻 H51 那张按占屏调好的 TypeScale 表且可读性有下限 —— 本轮只让 tab 标签跟着外壳走)。**验收**(`dumpLayout`,14 项全对):栏 137px = 42.2vp、栏宽占屏 88.8%、图标 17.2vp、标签行高 11.7vp、药丸 72.3×38.2 与内容块同心(上下呼吸 3.7vp)、条 38.2vp、chip 29.8vp 未变、胶囊 30.2vp 且与 chip **同宽**、右端按钮中心 = 条中心、渐隐带贴 chips 视口右缘、列表顶部占位 46.2vp(首行没被盖)、金线 35.1vp、列表末尾不空不压(栏底距屏底 56px 未变 —— 栏是向上收的)。按住透镜两张截帧:原地放大、上下对称鼓出栏外 2.2vp 未被画布切、内容零形变。**取证踩坑**:标定夹具 `glass-shot.sh` 里"摆背景"的 `click 300 2490` 是按旧栏高选的,栏变矮后同一坐标落到列表行上,把页面点进了频道页 —— **夹具里写死的坐标也是一次改动的下游**。**同日第二轮反馈「顶部的 tab 字体也小一点」** ⇒ 分类 chip 的字 14→12fp(新增 `CHIP_LABEL_FP`)、横向 padding 14→12、圆角 16→14、胶囊 30→28;**竖向 padding 7 不动**(chip/条占比 28/38 = 0.737 已经贴上 Android 的 34/44 = 0.773,再乘系数就空得发飘)。真机复量:chip 27.7vp、胶囊与 chip 同宽同位、上下呼吸 5.2vp、一屏从六颗半变七颗;音阁「订阅」段五颗内容宽 289.5vp < 视口 296.6vp ⇒ **这一段当场不再裁切**(19 个分类那条本来就要横滚,#43 不算结)。逐条见 **H122 补记**。**没验的**:① **拇指覆核**(数只能证明比例对上,不能证明"协调");② 字号档 0.9 / 1.15 / 1.3 下标签与外壳是否仍协调(只验默认 1.0);③ 横屏 / 折叠外屏;④ 迷你播放条(60vp)与 Android 侧对应值都没按同一把尺子重算 —— 它是内容卡不是外壳,先不动。逐条见 **H122**(含 H51 那条「fp 与 sp 同数值即同物理大小」前提的撤回) |
| **鸿蒙长按菜单「太靠下了」:✅ 2026-09-29 真机验通(锚点替掉失效的 `offset`)** | 装机反馈「贴着卡片底部弹出来,应该在触摸位置向上/向下弹,就像 Android」。差分三步判死:**状态驱动的 `bindContextMenu(isShown,…)` 不读 `options.offset`**(两个不同 x 的按下点给出同一个菜单矩形;写成常量 `{x:30,y:-50}` 还是那个矩形),而它的 `placement` 默认 `Placement.BottomLeft` ⇒ 菜单顶边恒贴节点下沿。修法与 Android 同构:`build()` 包一层 `Stack`,菜单挂在 1×1、`.position(按下点)`、`hitTestBehavior(None)` 的锚点上,两处站点(`EpisodeListItem` / `ContinueCard`)一起换。**验收**(`dumpLayout` 读 `Menu` bounds,八档按下点):卡片与整宽行的菜单左缘都**等于**按点 x、顶边恒在按点下方 29px(≈9vp,框架间距,不叠补偿);贴右缘(900 / 1150)自动翻转后右缘落在按点、整块在屏内;**此前记为「翻转后横向不再跟手」的未验项实测是好的** —— 跟手的是节点位置。回归:点行/点卡照常起播(`playQueue count=87` / `count=4`),锚点没吃掉触摸。逐条见 **H121**(含 H113 那条误读的更正) |
| **自动续播三项 + 后台换集:鸿蒙 ✅ 2026-09-29 真机验通(1.0.3 debug 包);Android 三项 ✅ 2026-10-05 真机验通(1.0.3-debug)** | **装机方式先说清,因为它决定了"数据没动"**:机上原本就是 1.0.2 的 **debug 侧载包**(`bm dump -n com.yuyin.reverb` 读出 `versionCode 1000002` / `appProvisionType debug` / `appDistributionType none`),所以 `hdc install -r` 是同类覆盖,**没有卸载、用户数据完整**(装后 31 条订阅与「继续收听」都在)。市场包那条路依旧不通(9568322),这轮验的不是市场包本体。<br>**三项全过**,判据都取应用自己的日志(`hilog` 再接 `grep -a Reverb`):① **单曲循环自然播完原地重播** —— `advanceQueue repeat-one index=…` 命中三次(单集列 `index=0`、多集列 `index=1` 与 `index=2`,同一集重起、`resume=0ms`、界面归零);② **随机走完表停** —— 末集播完出 `AudioSession 已撤销` + `长时任务已释放`,进度钉在 1:55:22/1:55:22 不再动;③ **单曲循环下手动「下一集」照常前进**(Vol.284 → 504 林行止),且队末那颗按钮按设计置灰 —— 截屏裁剪的**最小亮度** 199(灰)对 95 / 27(可点),差一个量级,不靠肉眼。<br>**让"等一集播完"变成 3 秒的关键手法**:全页 `Slider` bounds `[78,2107][1138,2237]`,用 `uitest uiInput swipe 100 2172 <x> 2172 800` 把进度直接拖到集尾,`completed` 当场就到。**x 要按剩余秒数算,别按"拖到最右"** —— 拖满会让 `completed` 在松手瞬间触发,人还在前台,后台那一档就白测了(第一轮就是这么错过的)。<br>**后台换集这一档是本轮新加的判定**(问题:换集时长时任务被放了 0.8~1.2 秒,系统会不会趁空窗掐掉后台播放)。做法:拖到约 97% → `keyEvent Home` → 等 `completed` 在后台触发。结论**两次都没断**:自动续集那一次空窗 792 ms、通知栏 `playNext` 那一次 237 ms,而通知栏进度节点读出 `66973 ms` 与本地起播时刻 **1:1 对得上**(没有丢时长)。系统侧日志同时证明**空窗是真的**,不是日志错觉:`resource_schedule_service/CONTINUOUS_TASK: All continuous task has stopped of uid 20020215, so notify related subsystems` + `audio_server/AudioBackgroundTaskListener: DeleteTaskId` + `SUSPEND_MANAGER: CreateMaliciousContinuousTaskActivityCheck`。<br>**由此留下的隐患(如实记,不当已修)**:`AvSessionBridge.sync` 是按 `player.isPlaying` 决定申请/释放的,换集时新建的播放器还没进 `playing`,于是**先把长时任务放了**再重新申请;而 `bgRunning` 是在 `await` **之后**才置位,同一轮里两次重叠 tick 会重复调用,第二次抛 `BussinessError 9800005`(日志里那两条"释放失败"就是它 —— 无害,但说明缺一个 in-flight 守卫)。**本轮刻意不改**:1.0.3 市场包已签好待上传(2026-10-01 它已上架并通过审核),动播放路径要重打包重验;修法(换集期间视为仍在播 + 置位在 await 之前)留到 1.0.4 那一批。<br>**→ 2026-09-30 已按那条修法改完(1.0.4 批次)**:判据换成 `PlayerController.wantsPlayback()`(两个条件「在播 或 期望在播」,换集全程为真、明确暂停立刻为假),长时任务改成「目标态同步置位 + 已确认态 + `bgTask` 串行链 + 代次丢过期意图」,`destroy` 也走这条链;释放失败认它没了(否则下次想播会静默跳过申请)。**编译过(debug hap BUILD SUCCESSFUL 18 s)。<br>→ ✅ 2026-10-06 真机复验:空窗没了**(BRA-AL00 / 6.1.0.135 / debug hap)。方向换成**播中手动切集**(同一条 `播放 … generation=N+1` 重建路径,更好复现):上一集 `gen=4→5` 的 736 ms 窗口与下一集 `gen=5→6` 的 723 ms 窗口里**零 `[Background]` 行**;负控制是同一次会话里做一次明确暂停,系统侧当场打出 `RecentContinuousTask --> onContinuousTaskStop`(继续时打 `Start`),而两次切集 **Stop/Start 一条都没有** —— 任务全程没被放过;`释放失败 9800005` 归零。复验判据与手法逐条见 **H125**(含"上一轮把'没断'当证据"那条更正,以及两条新账:队末那颗灰按钮点下去日志一条不出,先量亮度带再打坐标;`snapshot_display` 出的 **PNG 是整屏发白的坏图**,量像素必须用 JPEG)。<br>**同一台机器上顺带验掉的两条**:#43 渐隐带的**条件性**成立(溢出且未滚到右端时 x=1088..1136 有 240→245 的斜坡;滚到右端或装得下时整段平 237-238,不是常驻装饰);#49「tag 里带 `=`」判死为 **Android 特有** —— 鸿蒙 `play_mode_map` 存 JSON 对象串(`@ohos.data.preferences` 无 StringSet),结构上没有"按 `=` 切"这一步,无需装机。**⇒ Android 那一半已于 2026-10-07 真机验通**:机上 12 个 feedUrl 一个都不带 `=`,而搜索框被中文输入法把 `:` `.` `?` `=` 全折成全角(打不进 ASCII),所以夹具走盘侧 —— 把 自我进化论 的 feedUrl 原样加一份 `?t=1` 后缀写进 `subscriptions.json`(小宇宙 feed 服带任意 query 仍回同一份 XML,实测 200 / 471899 B,频道页照常出集)。于是盘上是两个**只差一个 query 的同源 tag**:`podcast:...mxh=1` 与 `podcast:...mxh?t=1=2`;`lastIndexOf(=)` 把它们各读成 (key=`podcast:...mxh`, 1) 与 (key=`podcast:...mxh?t=1`, 2)。**真冷启动**(pid 31419 → 31568;⚠️ 第一次 `force-stop` 之后 `pidof` 仍返回旧 PID,那一次是假重启 —— 判据照旧只看 PID 变没变)之后两个频道页各自读回自己那一格:带 query 那颗 `content-desc=随机播放`、不带 query 那颗 `单曲循环`⇒ **同前缀的两个 tag 没有互相覆盖,也没有被丢成回落值**;而这正是旧口径(按第一个 `=` 切)会撞的样子 ——两条会算成同一个 key、值 `1=2` 解析失败整条丢掉。**夹具已清干净**:`subscriptions.json` 回到 2 条,`play_mode_map` 里那一格已从 prefs 删掉并重启确认不被写回。**没验的**:老设备存过 `play_mode=1` 直接进单曲循环这条升级路径 —— 这台机器的 preferences 里压根没有 `play_mode` 键(1.0.3 才引入播放模式),要造只能手改盘文件,不打算做。<br>**收尾状态**:测试改掉的播放模式已还原(`playMode tag='inbox' -> SEQUENTIAL`、`tag='dl' -> SEQUENTIAL`),盘上 `play_mode_map` = `{"dl":0,"inbox":0}`。**与测试前唯一的差别**:测试前这个键**不存在**(读出来同为顺序),现在多两格显式 0 —— 行为等价,但如实记下。播放已暂停离开,设备侧临时文件(`_q.json` / 四张截屏)已删<br>**→ 2026-10-05 Android 侧三项也已在真机验通(Pixel 3 / Android 16 / `1.0.3-debug`)**,手法与鸿蒙同一套"把进度拖到集尾让 `ENDED` 当场到",只是造夹具的方式不同 —— 用一份 2 分钟的本机合成音频(filesDir + `file://` URL,`asset://` 不解析 filesDir,见 H129 补记 ③)当"能随便拖到末尾的长节目",真实列的续播则用 收藏/最新 两段:① **单曲循环原地重播** —— `state ENDED` → `advanceQueue repeat-one index=0` → 同一 id 再起 `play … auto=true` + `source stream seekTo=0`;② **随机走完表停** —— `playQueue count=2 index=0 tag='fav' mode=SHUFFLE` → 第一集 `ENDED` 后接 `play id=…auto=true`(落 `ctx=2@1`)→ 第二集 `ENDED` 之后**日志再无任何 `play`**,进度钉在 1:51:36/1:51:36、按钮回到 播放;③ **单曲循环下手动「下一集」照常前进** —— `next radio=false queueIndex=1 radioPos=-1 mode=REPEAT_ONE` 之后直接换到列里的下一集(不原地重播),`auto` 那道闸门只在自然结束时生效;队末那颗按钮的置灰与上面 ⑥ 用的是同一对像素特征值(灰 71 / 亮 238)。**顺带验掉的一条**:睡眠「本集结束」**优先于**用户队列与单曲循环 —— 带标志位那次 `ENDED` 后只有 `markPlayed`、没有续播(当时 upNext=3、mode=REPEAT_ONE),不带标志位的对照立刻 `play from userQueue … remaining=2`;三端实现同形(Android `STATE_ENDED` 里 `stopAfterThis` 排在最前,鸿蒙 `PlayerController.ets:664`,macOS `PlayerController.swift:626`),且**都没有**"提前 75 秒跳点"那种机制。**没验的**:Android 的后台换集空窗那一档(鸿蒙那一条已于 2026-10-06 复验通过,见 H125;Android 侧 `MediaController`/`MediaSession` 与长时任务通知是另一套机制,要单独量)与"播放中锁屏/后台被系统回收后队列还在"这一路,需要另一台机器或真实后台场景。<br>**#43 Android 侧已同构(2026-09-30,未装机)**:`GlassChipsRow` 把 chips 段包进 `Box(Modifier.weight(1f))`,渐隐带作为这层的 `Alignment.CenterEnd` **覆盖层**(不占位,所以不会把右端按钮推走;鸿蒙同处用的是 Stack,语义一致),宽 36dp 与 `CHIPS_EDGE_FADE_W` **同值同式**。判据 `scroll.maxValue > 0 && scroll.value < scroll.maxValue - 2` —— Compose 里 `maxValue` 本身就等于"内容比视口宽",**不必像鸿蒙那样量两个宽回填**,也就没有"首帧量不到"那一档;外面套 `derivedStateOf`,让这一层只在布尔翻转时重组(等价鸿蒙"只在翻转时 setState")。**三条判据已于 2026-10-07 在 Pixel 3(`1.0.3-debug`,1080×2160@440dpi)真机量过**(量法:取 y=672 这一行 —— 它在 chip 文字下沿之下、药丸之内,读到的是**纯填充色**,不会被字形污染;chip 填充恒 45、条背景恒 32):① **溢出且未滚到右端 ⇒ 有雾** —— 发现页 19 个分类那条,最右那颗 chip 的填充从 45 一路降到 40(x 972..1026,约 96px ≡ 35dp,与 36dp 同量级);**滚到最右 ⇒ 雾没了** —— 同一行最右 chip 的填充回到 45,且视口右缘的背景与左端逐像素同值(32);② **装得下 ⇒ 恒不出现** —— 音阁六段(末颗 批注 右缘 ≈966、视口右缘 ≈1026)那行选中 chip 的填充 69 一路平到边缘,无斜坡;③ **雾带不吞手势** —— 从 x=980(正落在雾带里)起手向左拖,chip 行照常滚过整屏(文化/知识 从 x 806/984 移到 33/167)⇒ Compose 侧那层覆盖的 `HitTestMode.None` 等价性**成立,不再是代码推断**。**顺带一条判读经验**:这层雾的叠色**接近条自己的背景**,所以在纯背景上几乎不可见、只在 chip 填充上显形 —— **只看背景平不平会误判成「没有雾」**,判据必须落在有内容的像素上。 |
| **鸿蒙「跟随系统」的深色模式:✅ 2026-10-06 真机复验(②③④ 过;① 只到"两段拼接",原始形状没造出来)** | 2026-10-01 应用市场审核反馈「音阁-设置-主题:点击跟随系统,切换深色模式需要重新进入应用后生效」(Mate 80 Pro Max / HarmonyOS 6.1 / API 6.1.0(24))。**属实且已定位**:`Index.aboutToAppear` 只在启动时读过一次 `context.config.colorMode`,全仓没有任何订阅系统环境变化的地方(改前 grep `onConfigurationUpdate` 零命中)。已改成深浅态走 AppStorage(`Theme.SYSTEM_DARK_KEY`),由 `EntryAbility.onConfigurationUpdate` 跟着系统翻,启动那一次也走同一表达式;`@Watch` 补状态栏/导航条图标色。**→ 真机复验(BRA-AL00 / 6.1.0.135 / debug hap)**,判据两条并行:背景色(水墨 `(20,30,32)` 对 宣纸 `(237,237,227)`)+ **状态栏时钟区亮暗像素互换**(深色态 `bright=1807/dark=6861` ↔ 浅色态 `1605/6986`,这一格才是 `@Watch→applySystemBar()` 的专属判据,背景色对了不代表图标也翻了)。<br>**③ 先做**(它要的是"不该动"):应用设成**浅色·宣纸**、系统切到深色 → 应用**仍是 `(237,237,227)`**、图标**仍是深字压浅底**(`bright=7039`),三档不取 `systemDark` 成立;**②** 应用设成跟随系统后退到系统设置切深浅再回前台 → 背景与图标都跟着翻,**不需要重进**;**④** 系统深色下 `force-stop` 冷启动,日志时序 `[App] 启动 29.953` → **`[UI] 设备深色态 → true 29.979`** → `[Settings] 加载 30.087`(**排在页面数据之前 108 ms**,与代码里"排在 `loadContent` 之前"一致),首帧到稳定**全程无浅色帧**;同一次冷启动顺带又读到 `启动读回播放态 cur=xmly_track_1017190729` → `restore cur='恨海情天…'`(H129 与深浅恢复互不干扰)。<br>**① 为什么只算"拼接覆盖"**:这台机器造不出字面判据 —— **控制中心没有深色模式磁贴**(磁贴全列过、编辑页可选列表里也没有),而 深色模式→定时开启 自带系统提示「定时开启时,系统会在重新亮屏后才切换深色模式」,所以定时也不会在眼睛看着时翻。于是拆成 (a) **前台可见**时把主题从「深色·水墨」改成「跟随系统」→ 一屏内立刻 `(20,30,32)`(证明 `AppStorage→@StorageLink→整树重建` 在前台当场生效)与 (b) 系统触发的变化能进到活着的进程(=②)。**但没有一次是"用户眼睛看着应用、在系统设置里切深浅"那个最原始形状**,留作装机观感复核项。<br>**取证踩的坑(最值钱的一条)**:第一次跑 ④ 打出 `设备深色态 → false`,形状像"启动快照是旧的"这个新 bug —— 实际是**人那一枪打空了**:系统设置「显示模式」两张卡的可点区在 `y≈1047`,而当时人已在**「深色模式」子页**上(标题栏一样、页面不同),同一坐标落到空白处,深浅根本没切。**判据改成读 `dumpLayout` 里那两颗 `Radio` 的 `checked`**(动手前一次、切完一次)。应用那行日志是诚实的,它把"系统确实浅色"如实报了出来,误判才能被日志纠正。**收尾**:应用主题回到深色·水墨、系统回到浅色(两处都复量过),播放态回到 `恨海情天` 并停在暂停(`落盘播放态 cur=xmly_track_1017190729 ctx=7@1`);**改动了真实数据的一处** = 该集的**续播位置现在是测试播出来的 `109474 ms`(约 1:49)**,而原本那一秒在更早一轮 force-stop 里已被覆盖成 `播放 … resume=0ms`、覆盖不回 —— **下次装机看到这一集从 1:49 起播是测试痕迹,不是 bug**。逐条与教训见 **H126**(新增教训 ④:「我操作了」不是状态,读到的 `checked` 才是状态) |
| **鸿蒙 1.0.3 debug 包仍在机上**(`versionCode 1000003`,debug 签名、非市场包) | 这轮验收把它覆盖了 1.0.2 的侧载包,**没有再换回去**。用户如果之后要装市场版,是同类覆盖、不丢数据;但**别把它当成"上架版本验过了"** —— 市场包的签名 profile 与 debug 包不同,后台长时任务与备份扩展这类系统行为严格说要以市场包复跑一次为准 |

| **macOS 播放模式 + 列表自动连播:代码已同构移植(2026-09-29),桌面端一行都没跑起来验过** | **移植了什么**:`PlayMode`(ordinal 与两端一致:0 顺序 / 1 单曲循环 / 2 随机)、`ListTag`(同四个值,`podcast:<channelKey>` 前缀同式)、按列的模式表(`SettingsStore.playModeByTag` 走 UserDefaults **dictionary**,所以 Android 那个「tag 里带 `=`」的解析坑在这里结构上不存在,同鸿蒙)、`nextQueueIndex()` / `prevQueueIndex()` / `advanceQueue(auto:)` 三件套(`hasNext` 与手动切集共用同一个判据),以及**桌面端原本压根不存在的那条自动续播分支**(`AVPlayerItemDidPlayToEndTime` 里过去只在电台 / up next 时接下一集,列表播完就停)。**四处挂载**:音阁分段行右端各一颗(最新 / 收藏 / 下载;订阅与历史两段没有,后者右端已是「清空」)、频道主页「单集」行右端一颗;四语 `Localizable.strings` 各补三键(顺序播放 / 单曲循环 / 随机播放,译法与 Android `values-*` 同源)。<br>**验收只做到这一层**(`cd macos && swiftc -typecheck -sdk $(xcrun --show-sdk-path) -target x86_64-apple-macos13.0 $(find Sources -name '*.swift')`):**错误集与改动前的 HEAD 基线逐条相同**(4 条,全在没碰过的 `UI/TranscriptPage.swift`,是 SDK 太旧而非本次改动 —— 基线是用 `git archive HEAD macos` 解到 /tmp 单独 typecheck 出来的,不是推测)。**这句判据后来发现有覆盖洞,2026-10-01 修正:`swiftc -typecheck` 在第一个报错的文件之后就不再有意义地继续,"两边都是 4 条"证明不了其余文件被检查过;正确做法见 H128(两份树都中性化到 0 + 三道阳性对照)。**`.strings` 四份 `plutil -lint` 全 OK,键数 182→185 四语一致,繁体三条写法核对过(順序 / 單曲循環 / 隨機播放)。<br>**为什么只能这样(2026-09-29 试图出包时的三层实测,逐层独立)**:① `Package.swift` 是 `swift-tools-version:5.9`,而本机 SwiftPM 报 installed version **5.7.1**(`swift --version` 自己写 5.7.2)⇒ `swift build -c release` 直接挡回;② 全机 SDK 只到 **13.1**(`/Library/Developer/CommandLineTools/SDKs/` = 12 / 12.3 / 13 / 13.1),而 `TranscriptPage.swift` 那四处双参数 `onChange` 要 macOS 14 SDK —— 这正是上面基线里那 4 条错误的来源;机器上**没有 Xcode 而且装不上**(Xcode 15+ 要 macOS 13+,本机 `sw_vers` = **12.7.6**);③ **这一层最容易漏:即使前两层都好办,这台机器也验收不了运行。** 2026-09-30 实测更正过拦点(原先写成"minos 高于宿主 ⇒ 加载即拒"是**错的**):`minos 13.0` 的**命令行二进制在本机照跑、退出 0**;真正拦下 `.app` 的是 LaunchServices 读 `Info.plist` 的 `LSMinimumSystemVersion 13.0`(`open` → `error -10825`);而就算把那道门降下去,一份 minos 13 的 `NavigationStack` 程序在本机 `dyld: Symbol not found: _$s7SwiftUI14NavigationPathVMn` → SIGABRT。所以"换台机器编一下就行"在这里不成立,**运行验收从来就不可能在本机做**。⑤⑥ 两层是「只有 CLT、没完整 Xcode」的专属坑:CLT 的 `ManifestAPI/` 里没有 `.swiftmodule` ⇒ SwiftPM **连最小 manifest 都编不了**(`no such module 'PackageDescription'`);而 `--arch arm64 --arch x86_64` 走 **xcbuild**,只随完整 Xcode 分发,CLT 报 `xcbuild ... does not exist`(且该检查排在 tools-version 门之前)。旁证:`macos/build/` 里那个 1.0.2 dmg 解出来是 `arm64 / sdk 26.5`,由另一台机器所打(已归档 `dist/余音-Reverb-1.0.2-arm64.dmg`)。<br>**顺带补掉的两个流程洞**:macOS 的包此前**不落 `dist/`**(`package.sh` 写的是 `build/`,且 `macos/.gitignore` 没有 `dist/` 条目),且**打完没人解包核对**(硬规矩 1 在桌面端是空文)。现在 `package.sh` 末尾自带一段验收:处理量(二进制字节数 / `.lproj` 套数 / Resources 项数)→ 判据词逐个计数(2026-10-01 起 **11 个**:播放模式那八个 + `notes.json` / `批注` / `记下这一秒`)→ 四语 `.strings` lint → 版本号与 `minos`/`sdk`/架构 → ad-hoc 签名身份。**这段验收本身是拿那个 1.0.2 旧包空跑验出来的**(如实报出全 0、`1.0.2`、`arm64`,即负控制成立);补批注那三个词时**又拿归档包重跑了一次负控制**(`notes.json` / `批注` / `记下这一秒` 在二进制与四份 `.strings` 里全 0,处理量 4,443,392 B + 29,446 B),所以它们报非 0 才算数;但**产出新包的那几步仍未跑过**,脚本改动的证据只到这一层。逐条见 H124 补记。<br>**没验的**:① **UI 一帧没看过** —— 两颗按钮的实际位置/间距(`HStack(spacing: 12)` 挂在 440pt 分段右侧、频道页标题行右端)与窄窗会不会挤;② 自动续播三项(单曲循环原地重播 / 随机走完表停 / 单曲循环下手动下一集且队末置灰);③ 跨启动读回那张表;④ 与睡眠「本集结束」、电台模式、up next 的优先级只在代码上对齐;⑤ `.help()` 能否被 VoiceOver 读到(等价于 Android 的 `contentDescription`,已设未验)。<br>**顺带值得记的规律**:移植一个"模式开关"类功能,UI 与枚举是最容易的部分,**真正缺的是"自动推进"那条分支** —— 两端 1.0.3 的随机/单曲循环全靠它成立,而 macOS 那边它压根没写过;只把按钮抄过去会得到三态图标齐备、播完照样停的 App。<br>**出包那台机器上的架构口径已定(2026-09-30 落进脚本,#59 只剩"在那台机器上跑")**:`package.sh` 默认 `--arch arm64 --arch x86_64` 出 **universal**,并在组装 .app 之前用 `lipo -archs` 做**产物级硬断言**(少一个架构就 exit 1、不出 dmg);dmg 文件名改为 `dist/余音-Reverb-<版本>-universal.dmg`。背景:历史包是 arm64 单架构,Intel Mac 装了起不来(Rosetta 只翻译 x86→arm 单向),而 `swift build` 不带 `--arch` 时默认跟随宿主芯片 —— 1.0.2 就是这么变成单架构的。断言不许省,因为 SwiftPM 的多 `--arch` 有静默失败前科(swift-package-manager#8013),判据只能落在产物上;CLT-only 的机器上这条命令连跑都跑不起来(xcbuild),要退回「分别 `--arch` 编两次 + `lipo -create`」。**本机跑不到这一步,所以"真产出 universal 包"仍是未验项**。<br>**2026-09-29 分工已定(用户决定)**:这台 `MacBookPro11,4` 到此为止只承担 Android / 鸿蒙的开发与真机取证,加 macOS 的「读代码、改代码、整模块 typecheck 差分」;**macOS 的出包与运行验收固定交给另一台 Xcode 15+ / macOS ≥ 13 的机器**。补上第四层证据:除了编译器与 SDK,系统上限本身封死了 —— `softwareupdate --list-full-installers` 在这台机器只列出 12.7.6 / 11.7 / 10.15 / 10.13(无 Ventura+),所以既升不了系统也装不上 Xcode 15;而**靠降级源码换兼容也不通**:`RootView.swift:20`、`ListenStatsView.swift:16`、`FootprintView.swift:15` 用的是 macOS 13+ 的 `NavigationStack` 且无降级分支,要让包在 12.7.6 上跑得重写整个根导航。下次别再在这台上试第四遍 |
| **macOS:「装旧版 Xcode 迁就本机系统」—— 2026-09-30 评估结论:否掉,不再重开** | 这台 `MacBookPro11,4`(12.7.6)能装的最高是 **Xcode 14.2**(Swift 5.7.2 / SDK 13.1)。它能修掉的只有本机六层里的后两层:⑤ CLT 缺 `PackageDescription.swiftmodule`(Xcode 自带完整 SwiftPM 资源)、⑥ 缺 xcbuild。**修不掉的**:② SDK 天花板仍是 13.1,那四处双参数 `onChange` 要 macOS 14 SDK —— 要么改源码降到 `onChange(of:perform:)` 旧签名(那是**为迁就一台构建机去改要交付的源码**),要么继续让 typecheck 挂着这 4 条基线错误;① tools-version 5.9 vs 5.7 还得降 `Package.swift`;③④ **两层一点没变**:包自己声明 `LSMinimumSystemVersion 13.0`、SwiftUI 用了 13+ 的 `NavigationStack` 且无降级分支 ⇒ **编得出来也起不来,要能起就得重写整个根导航**;而产物只会是 x86_64 单芯片(与要交付的 universal 相反)。**投入 ≈15 GB 下载 + 必须登录 Apple ID 才能从 developer.apple.com 取旧 dmg,产出 = 零验收收益**,只多一个"typecheck 之外的编译器"当证据 —— 不值。判据留在这里:**换构建能力要换的是"能跑产物"的机器,不是往旧机器上加装工具链**。 |
| **批注(「写下这一秒」):三端代码都已完成;Android(2026-10-05)与鸿蒙(2026-10-06/07)已真机跑过,macOS 一帧没看过(验收等级三端各不相同,见下)** | **已完成的**:数据层 `NoteStore`(`notes.json`,整条单集快照 + `positionMs` + `noteId`,空文字不落盘、位置在数据出口夹进 `[0, 时长]`,见硬规矩 10);播放页「更多」第三项与弹窗(标题时间是**按下瞬间冻结**的值,因为 `position` 每约 500ms 重算,打字期间会一路漂);音阁第 6 段(全局时间线,点一行走 `PlayerController.playAt` 而不是 `playOrToggle`);`PlayerController` 新增 `pendingSeekExplicit` —— **明确跳转与续播用两套容差**, 否则写在片尾 8 秒处的批注永远点不开(续播那条"距片尾 10 秒内不如从头播"的启发式会把它落回 0:00);手动备份新增 `NOTES` 分区(默认勾选,恢复按 `noteId` 去重合并);系统级备份白名单三处都加了 `notes.json`(backup_rules.xml + data_extraction_rules 的 cloud-backup / device-transfer)。验收方式目前只到 `compileDefaultReleaseKotlin` + `compileStoreReleaseKotlin` + `processReleaseResources` 全绿。<br>**鸿蒙 2026-10-01 同构完成**:`store/NoteStore.ets` 落的是**与 Android 逐字同构的一份格式**(嵌套 `episode` + 外层 `noteId`,毫秒口径见 H86 那个坑);播放页「更多」入口 + `bindSheet` 弹层;音阁第 6 段;`PlayerController.playAt` + 同一套 `pendingSeekExplicit` 双容差 —— **一次性 override 的消费点放在取续播处**,放在入口清会被「代次不匹配就早退」那条路径吞掉(**注意这条只挡早退、挡不住装载重试**,重试那一轮仍回落续播,见 A2-3#12);手动备份 8 分区的**枚举与 Android 一一对应**(⚠️ 这里原先写的"跨端互通靠的就是这个顺序"**已被证伪** —— 三端都按键名读,Android 的 `JSONObject` 本就不保证写出顺序,见 A2-4;同序的真实价值在勾选框列表的界面一致性),系统备份 `backup_config.json` 加 `notes.json`;五语各 +9 键、关于页与同意页五语同步。验收方式只到 `hvigor assembleHap` BUILD SUCCESSFUL(两遍)。<br>**macOS 2026-10-01 同构完成(代码 + 类型层)**:入口形态按桌面端习惯 —— **它没有「更多」菜单**,所以是播放页动作行上 `square.and.pencil` 那一颗(与印记、剪藏并列),弹层是 popover;音阁 `Segment.notes` 加在**末尾**(与前两端六段同序);`Data/Models.swift` 的 `EpisodeNote` 与两份同构(嵌套非摊平,见 H127),**`createdAt` 三端实测都是毫秒**(逐端核过写入点:Android `System.currentTimeMillis()` / 鸿蒙 `Date.now()` / macOS `timeIntervalSince1970 * 1000`),而 macOS 解码**刻意不做秒/毫秒归一** —— 没有一端写秒,归一只会把真正的单位 bug 悄悄吃掉(要改口径按硬规矩 11 加版本号)。备份 `Section.notes` 落在第 4 位,**顺序与 JSON 键名两处已逐字核对过三端源码**(这才是 `reverb-backup.json` 跨端能读的前提,运行层面未验)。`PlayerController` 那两套容差带过来了:消费点在 `playEpisode` 取续播处,macOS 这边吃掉它的不是代次早退而是 **`handleLoadFailure` 的自动重试会再进一次 `playEpisode`**;并且**没有**给桌面端补那条 10 秒片尾启发式(它本来就没有),只补显式跳点的 `dur - 2000` 上限。<br>**待装机/待运行的六条判据(三端同一份)**:① 暂停在句中写一条,列表里那条显示的时间与暂停点一致,且**打字期间继续播放不会让它漂移**; ② 点那条 → 从那一秒起播(日志判据 `playAt …ms id=…`),而不是上次听到的位置;③ **落在片尾 8 秒内的批注也跳得进去**(这条是 `pendingSeekExplicit` 的唯一理由,必须实跳一次);④ 删除出二次确认、正文含被删的那句话、取消不删; ⑤ 导出含「批注」分区 → 卸载重装(桌面端是删掉 Application Support 里那份 `notes.json`)→ 恢复,条数与文字一致;⑥ **【仅 Android / 鸿蒙】`bmgr backupnow` 的载荷里能查到 `notes.json`**(macOS 无系统级备份,这一条不适用)。**⑦ 2026-10-05 新加的第七条(H133)**:写批注期间让本集正好播完接下一集,保存后到音阁看那一行 —— 标题应当是**上一集**的名字 + 按下时的那一秒(改前三端都会挂到下一集上,而时间戳看着还是对的)。这条**已在三端代码上修掉**,凑出这一格需要"编辑器开着而换集正好发生",移动端两端已于 2026-10-07 各自真机跑到(手法与残余见下面那行「真机已跑到的位置」);macOS 那一端仍在构建机待验。<br>**没验的 / 已知风险**:音阁分段条从五段变六段,窄屏那一段会不会开始裁切(与 #43 同一条待验);批注行的删除是行内图标、没有长按菜单(与另五段不同形),观感待拇指;「一段没有段尾动作」是刻意设计,装机时别当成漏做。**鸿蒙侧另有三条**:① `bindSheet` 的 `height: 320` 是固定值,键盘弹起会不会盖住输入框(装机判据:输入框可见且能看见自己打的字);② 删除图标用的 `sys.symbol.trash` 只核过 SDK 的 `id_defined.json` 里**有这个名字**,实际字形装机才看得见(鸿蒙的 `sys.symbol.*` 写错不报错、直接画空白);③ 六段在这台机上分段条是否裁切(与 #43 同一条待验)。**macOS 侧另有三条**:① popover 里那个多行输入框用的是 **ZStack 自叠占位文字**,因为 `TextEditor(text:prompt:)` 的 `prompt:` 要 macOS 14 —— 本机 SDK 13.1 编不过(报 `extra argument 'prompt' in call`),而写进 `minos 13.0` 的包里更是运行时缺符号;占位与输入文字的层叠、光标位置只对了几何上说得通,一帧没看过;② 六段 `Picker` 的 `.frame(maxWidth: 440)` 在 fr / es(Annotations / Anotaciones)长标签下会不会开始截断,**只有跑起来才看得见**;③ 批注行的图标恒为 `play.circle.fill` 不画暂停(H118 那条口径),实际观感未看。<br>**macOS 这一端验收方式本身被修过一次(重要)**:先前记的判据"错误集与基线逐条相同"是**有洞的** —— `swiftc -typecheck` 在**第一个含错误的文件之后就不再有意义地继续**,所以"两边都是 4 条"从来没证明过其余文件被检查过。这次的做法:把 base 与 cur **两份树都中性化到 0 错误**(本机对 HEAD 源码需要中性化 **7 类 / 18 处调用点 + 1 个整文件**的 14+/26-only 依赖:双参 `onChange` ×4、轮播那 6 处 14-only modifier、`focusEffectDisabled`、`SettingsLink` ×2、`MainActor.assumeIsolated` ×4、`nonisolated(unsafe)` ×1(**语法级,连解析都过不了**)、整个 `@available(macOS 26)` 的 `Transcriber.swift`),再跑**三道阳性对照**(在 `LibraryView` 的 `body`、`NoteStore.add`、`playAt` 各注入一个语义错,每次只留一个,各自都必须报出来),最后 base 0 条 / cur 0 条。逐条见 **H128**。<br>**真机已跑到的位置(2026-10-07 汇总)**:上面那六条 + 鸿蒙另三条,**Android 侧 #66 已于 2026-10-05 走完**(含 ③ 片尾 8 秒内实跳);**鸿蒙侧走完 ①②④⑤ 与另三条** —— ① 冻结时间在 66 秒持续播放里一位没动、保存日志 `pos=910542ms`;② 点该行 `playAt 910542ms` 同一个毫秒;④ 确认框正文带被删那句、取消不删;⑤ 见 H141 验收 ⑦ 那一整圈;鸿蒙另三条 = 键盘弹起时整张弹层被抬上去、输入框没被盖(判据"能看见自己打的字"过)、`sys.symbol.trash` 画得出真实字形、六段在这台 1216 宽机上不裁。**2026-10-07 补:③ 与 ⑦ 鸿蒙侧都验过了,拦路的不是平台能力而是工具延迟。** ③ 的夹具:在 E6(`dur=5843900`)上用滑杆落到剩约 2 分钟,再用 +30 / +10 连点压进片尾,05:33:19 按下「写下这一秒」(编辑器打开、时间冻结),05:33:22.785 `state=completed generation=4` 自动续到 E5(`[State] 落盘播放态 cur=6a4d1141…`),打字 82 秒后保存;05:35:32.590 在音阁批注段点那一行 → `[UI] 播放批注 @5840981ms` + `[Player] playAt 5840981ms id=6a5f4f20…` —— **挂的是上一集、跳的是按下那一刻**,而 5840981 距片尾只有 **2919 ms**(8 秒内,也在"明确跳转"那道 `dur-2000` 容差内);3.7 秒后 `state=completed generation=6` 说明真从那儿播了出去而不是落回 0:00。全程 `跳点落空` 7 条**全部 `explicit=false`**(续播路径 seek=0/303 的空跳),没有一条来自这次显式跳转。⑦ 的判据正是上面这条链子的前半段:换集发生在编辑器开着的时候,保存目标仍是按下时那一集。<br>为什么先前判成"鸿蒙侧不可验":`uitest dumpLayout` 一次往返实测 **1.05 秒**,而按下之后的窗口只有 6~8 秒,"边看界面边点"这条路根本走不通 —— 改成**先把剩余时间压到 9~20 秒、再按固定坐标盲点**(长按 → 菜单项),把 dump 从关键路径里挪出去就够了。另一条误导:这台机上**暂停时 Slider 不回读**(`SeekBar` 只在播放中每 250 ms 采样一次),所以早期那批"落点没生效"的读数是假的,落点判据必须在播放中读。<br>**设备末态如实记**:测试批注已删(`[Store] 删批注 … total=0`),E5/E6/E7 的 `played` 都归位 false;E7 原始进度 160496 ms 被"播完"路径写成 0(`completed` 分支会 `updatePosition(id, 0, dur)`),**这一条回不来**,已用滑杆重放到 171299 ms 让它重新出现在「继续收听」。⑥ 在鸿蒙**没有入口** —— 本端不存在 `bmgr backupnow` 这种主机侧备份路径。(⚠️ 这一格原先写的理由是「`hdc shell` 读不到沙箱」,**那句太宽、已在 2026-10-07 更正**:应用自己的沙箱文件可读,只是 `Download` 那份导出副本在沙箱外读不到 —— 因此字节层面的比对**做得了而且已经做了**,两端 `notes.json` 外层 5 键 + `episode` 内层 11 键逐键同序,详见 **H138 验收**。)**⑦(编辑器开着跨集)两端都已于 2026-10-07 验过** —— 鸿蒙(证据链在上面那段:换集发生在编辑器打开期间,保存目标仍是按下时那一集 E6、毫秒数仍是按下那一刻的 5840981,而那一秒距片尾仅 2919 ms,顺带把「片尾 8 秒内实跳」一起验了);**Android(Pixel 3 / `1.0.4-debug`)没有等到片尾**,凑法是把三个已记录的机制拼起来:① 播放素材用**已下载的那一集** —— `PlayerController.kt:628` 的 `useLocal` 会走 `Uri.fromFile`,进度真实跳动而**完全不碰网络**(这台机器的 VPN 隧道当天正好断了上游、流式一律报 `onPlayerError code=2001`,与应用无关 —— 所以离线素材不只是方便,它是当天唯一可用的夹具);② 换集用**媒体键** `input keyevent 87`(= `KEYCODE_MEDIA_NEXT`;误按的 88 是上一首,那一跳集没变,正好留作负控制),它落在 `NavForwardingPlayer.seekToNext` → `PlayerController.next()`,**与 App 内那颗「下一集」按钮同一条路**;③ `next()` 优先走用户队列,而 `play(episode)` 只有单元素队列 ⇒ 什么都不做,而 `AlertDialog` 是模态的、弹层开着就点不到列表 —— 所以**目标集必须在打开编辑器之前**用「下一个播放」排进队列。判据是**两个互相区分的数**:落盘的 `episode.id=6aabe3db…`(按下那一集·家宴)与 `positionMs=65219`(弹层标题那一刻的 01:05),而保存那一刻 `current` 已是 `6a950510…`(No.82)、它的续播落点是日志里的 `seekTo=215579` —— 若保存重取当前集,这两个数都会变成后那一集的;界面侧同一时刻音阁「批注」那行标题仍是**家宴**,迷你条显示的已是 **No.82**。**取证方式上记一条平台差异**:Compose 的 `AlertDialog` 开着时 `uiautomator dump` 只吐弹层自己那几个节点,底下整棵树不在(鸿蒙 `dumpLayout` 没这个限制)⇒ 背景态证据只能取 `playback_state.json` + logcat。测试那条批注已删(行内图标 → 确认框正文含被删那句),设备状态按测试前快照 `run-as` 逐字节回写(md5 全等)并重启核对过 `cur`/`ctx`/`tag` 回到原值。**同一日(2026-10-07)又把"手动换集 ≠ 自动续播"那一寸补掉了**,而它不需要网络也不需要等真片尾:合成一段 **90 秒 WAV**(1,440,044 B)`run-as` stdin 推进沙箱、夹具那集的 `audioUrl` 直接写 `file:///data/user/0/<pkg>/files/tail_probe.wav`、收藏列模式点成**顺序播放**(随机也会续播,但下一集不确定 ⇒ `ctx=4@1` 写不死),而**下一集故意指向一个不存在的文件** —— 这一条是手法的关键:自动续播立刻 `onPlayerError code=2001` → `state IDLE`,播放链停在原地不再往后跳,于是"编辑器开着而 `current` 已换"这一格从一闪而过撑成稳定窗口。时刻链:`06:54:09.168 playQueue count=4 index=0 tag='fav'` → `06:54:09.367 state READY dur=90000` → 开弹层(显示 `00:36`)→ `06:55:39.531 state ENDED id=h157jia` → `06:55:39.535 markPlayed` → `06:55:39.537 play id=h157yi auto=true` → `06:55:39.541 落盘 cur=h157yi ctx=4@1` → **48 秒后** `06:56:27.757 NoteStore add pos=36679ms … total=1`,盘上 `episode.id` 仍是**甲**、`positionMs` 仍是开弹层那一刻的 36679,批注行标题「H157 甲 · 离线 90 秒夹具 / 00:36」而迷你条已是「H157 乙」⇒ **判据是这两个数,不是界面看起来对:若保存重取当前集,`id` 会变乙、`positionMs` 会变乙的续播落点。** **A2-3#14 的读盘归一(第 ⑦ 类判据)已在 Android 真机跑通**(六条乱序 + 负值 + 两条无效 → 四行、顺序对、负值显示 00:00),**鸿蒙侧 2026-10-07 用同一份夹具复现出同一张表**(⚠️ 这一格原先写的"鸿蒙侧因沙箱只读而不可注入"**是错的** —— 那句只在 release 签名包上成立,debug hap 的沙箱可写,夹具直接 `hdc file send` 推进去即可;逐条见 H138 验收)。**设备末态**:两端测试批注都已删除,批注段是空的;`Download/reverb-backup.json` 是只含批注分区的那一份 |

| **播放态跨启动(队列 + 正在播那一集):Android ✅ 2026-10-05 真机九条全过;鸿蒙 ✅ 2026-10-06 同构并真机验过 6.5 条(九条里 ⑦⑨ 本机造不出、⑤ 只到一半,逐条见下);macOS 未同构** | 用户反馈两条:「加入队列的节目下次打开 App 就消失了」「可不可以增加正在播放栏,每次都从历史点进去不方便,系列节目名称相似容易找错」。**两条同根**,第二条例缺的是那条栏的前置状态而不是栏本身(三端 `MiniPlayer` / `MiniPlayerBar` / `NowPlayingBar` 早已存在,显示条件是「有正在播的一集」,冷启动后整条不出现)。已定口径与逐条理由见 **H129**,移植时照抄的清单在 `docs/ARCHITECTURE.md` 第五节。**装机判据(全表以此行为准,逐条打勾)**:① 排队 3 集 + 正在播第 4 集 → 上滑杀进程 → 冷启,迷你条在且显示的是那一集;② 待播队列条数一致、顺序一致;③ 点迷你条**直接出声**(判据是「按下到出声」的时长,不是重下一单 —— 预载的意义全在这儿);④ 杀掉前那一集的进度**没被抹成 0**(专防预载自造的坑,判据落在「继续收听」那条位置);⑤ 「下一集 / 上一集」仍在原来那一列里走、播完自动接那一列的下一集(判据 `playQueue count=… tag='…'` 的 tag 与杀进程前一致);⑥ **冷启动后什么都不按**,那两颗按钮就是可点的(恢复走直接装载,漏刷 flag 就会灰着,按下播放才亮);⑦ 只有队列、从没播过(重启后 `current` 为空)时**不崩、不闪、进度不丢**;⑧ 电台模式杀掉后重启**不**恢复 `current`(判据是那一条 `restore cur=` 日志压根没打,而 `restore upNext=` 那条有);⑨ 盘上挂着引导音频时播放条**不出现**,且日志多出 `restore 忽略引导音频,重写播放态`。日志三行是贯穿全表的取证口:`启动读回播放态 …` / `restore cur=… ctx=…@… tag=…` / `落盘播放态 …`。<br>**✅ 2026-10-05 逐条实测(Pixel 3 / Android 16 / `1.0.3-debug` 侧载包,`am force-stop` + `am start` 之间只做读)**:① `启动读回播放态 cur=6a950510… ctx=24@3 upNext=3 tag='inbox'` → `restore cur='自我进化论｜No.82…' ctx=24@3 tag='inbox' mode=SEQUENTIAL` → `play … auto=false`,迷你条显示同一集;② 队列页三颗标题与顺序与盘上 `upNext` 的 id 逐一对齐(S9E9 / S9E8 / S9E7);③ **点迷你条到出声 232 ms**(判据是时长不是"有没有响");④ 杀掉前那条进度在原位(没被抹成 0);⑤ tag 与杀进程前一致且播完接的是那一列的下一集;⑥ 冷启后未触碰任何按钮,像素量到 上一集/下一集 都是**亮**(maxlum 238),而 index=0 那次 上一集 是 **71 / 亮像素 0** —— 同一对特征值在队首队末两个方向各出现一次,判据可复现;⑦ 只留队列不带 `current` 时**不崩不闪**,重启后 `启动读回播放态 cur=- ctx=0@0 upNext=3` + `restore upNext=3`,队列页三颗完好;⑧ 电台分支同样只打 `restore upNext=3`、**不打** `restore cur=`(顺带验到 `persistState()` 那条电台分支确实落成了 `current` 缺省:`cur=- ctx=0@0 upNext=3 tag=''`);⑨ 手写快照把 `current` 换成引导音频 → `restore 忽略引导音频,重写播放态`,且**盘上那一格被收敛掉了**(重启后读回 `current` 缺省、`upNext=3` 仍在),迷你条节点数 0。<br>**这次顺带定死的两条口径**:预载**不恢复播放意图**(`auto=false` 全表可见)且在 Pixel 3 上没有出现"某些 ROM 把 `playWhenReady=false` 翻成自动开播"的现象 —— **只验了这台机器,别当全平台结论**。**仍只能真机定的**:预载拉流的实测流量(没测)。**取证手法的四条新账(Compose 按钮读不出禁用态 / 只有 `force-stop` 杀得掉 / `asset://` 不看 filesDir / 改盘要重启复查)写在 H129 的装机补记里,造夹具前必读**。<br>**已知边界(不是 bug,⑦ 里实测到了它的下一层)**:「只排队没播过」时迷你条仍不出现 —— 要做「待播栏」需要五语新文案,另议。这一条装机还顺带量出一个连带后果:**那种状态下队列页没有任何 UI 入口**(队列页的两条入口 `onOpenQueue` 分别挂在迷你条与播放页,都以「有当前集」为前提),队列本身在盘上完好、播上一集之后立刻可见可点 —— 也就是说"队列活了但看不见"和"用户找不到入口"是同一个缺口的两面,记在这里免得下一轮当成 bug 修。<br>**鸿蒙侧 2026-10-06 已同构并装机(BRA-AL00 / HarmonyOS 6.1.0.135 / debug hap),逐条对到上表**:
①✅ `启动读回播放态 cur=xmly_track_1017190729 ctx=42@1 upNext=2 tag='podcast:http://www.ximalaya.com'`
→ `restore cur='恨海情天…'` → 迷你条显示同一集;②✅ 队列页两行标题与盘上 `upNext` 顺序一致;
④✅ 播放页一进来就是 `02:03` / `1:14:20`(Slider 值 `123075.000000`),按播放从那儿往上走 —— 预载没把历史抹成 0;
⑥**✅ 2026-10-06 补齐,并且当场揪出一个真 bug**:「下一集」冷启后未触碰即可点(按下 → `play from userQueue … remaining=1` 并当场换集);
「上一集」当时判据凑不齐(只验了行为的一侧),这次双向量过 —— 修好的形状是 `@Builder` 值参冻结
(`iconBtn(…, this.player.hasPrev, …)` 那个布尔同时管颜色与 `if (enabled)` 那道门),
**症状是「有上一集,但图标不亮、按了没反应」**;队列页上移/下移同族而更糟(`ForEach` 只按 `e.id` 做 key,
重排后行不重建 ⇒ 行里的 `idx` 冻结 ⇒ 动的是别人的条目)。两处一起改(闭包传到底 + key 带上 idx),
真机复验数字逐条在 **H145**(播放页 亮墨 355 → 到 `@0` 变 暗墨 472 → `@0` 按下无日志 → 回 `@1` 重新亮 355;
队列页首行 up 0/212、末行 down 0/216,两次重排后亮暗与新位置逐行对齐且顺序换得回来)
③✅ **2026-10-06 补量**(冷启恢复后点迷你条那颗播放键,判据取应用自己的日志):
`AudioSession 已激活 21:52:48.936` → `state=playing 48.974`(**38 ms**);第二次(暂停→继续)`03.031 → 03.061`(**30 ms**)。
两次 `state=playing` 都打在 `uitest` 注入命令返回**之前**(uitest 自身开销 337 ms)⇒ 应用侧响应小于那个数;
而**全程没有 `播放 … 源=网络` 这一行** —— 这才是这一条的正判据:没有重下一单,预载的那台播放器直接被唤起。
⚠️ 与 Android 的 232 ms **不是同一个数** —— 那边量的是"按下到出声"的墙钟,本端这两条只是应用侧日志区间,
所以只说"本端也成立",不做两端数值比较;
⑤✅ 只到「tag 与杀进程前一致」,**"播完自动接那一列下一集"本轮没等完**;
⑧✅ **2026-10-06 补验**:`[Radio] 开台 mode=随机 region=cn` → `电台候选 count=30` → `state=playing generation=2`
→ `aa force-stop` → 冷启(新 pid)`启动读回播放态 cur=- ctx=0@0 upNext=0 tag=''`,**新进程零条 `restore cur=`**、
`dumpLayout` 里迷你条节点数 0 —— 电台的 `current` 没被恢复,与 Android 第 ⑧ 条同口径
(顺带一条如实记下:这一轮把**上一轮的 `恨海情天` 那一格覆盖掉了**,电台自己那一次落盘写的是 `cur=-`)。
⑦⑨❌ 仍构造不出 —— ⑦「只有队列从没播过」要清应用数据(那是真数据);⑨设备上已订阅,引导卡不显示。
**这两条是下次装机的待办,别当已过。**
另加一条 Android 表里没有的:**往返第二轮**(下一集之后立刻 force-stop,再起 → 读回 `ctx=1@0 upNext=1`,
与上一次落盘逐字段相同)✅ —— 它证明 slim 十键的上下文在"窗口只有一集"时也能原样读回。
本端三处不是照抄的地方(标志名、恢复判据、调用点落在 `startGated` 末尾而不是 `boot`)记在 **H129 的鸿蒙同构补记**;
**鸿蒙侧移植要留神硬规矩 7** —— 播放态是三个对象字段,别挂进被整页观察的对象里(本轮已按这条把
`playbackStarted`/`stateStore` 设为 `private` 普通字段,恢复只走一次性装载,不进 ticker)。
**macOS 未同构**,本机只到 typecheck 差分(判据见 H128) |
| **追更「全部订阅频道的全部单集」(2026-10-10):✅ 装机数字双端都读了** | 代码 + 五语文案 + 双端构建 + **门 2 双端真机**(用户批准两台都装)都过了;判据与读数按「命令 + 期望值 + 读数」写在上面【2026-10-10 第三批】那节的门 2 里,这里只留结论四条:
① **截断真拆了** —— Android 同机差分 `episodes=24`(本轮包之前)→ `episodes=160 persisted=160`(与两源 `curl` 的 73+87 对上)→ 挂第三个源 `episodes=550 persisted=300`;鸿蒙 `源=1 得到 390 条 落盘 300 条`(= 同一 feed `curl` 的 390 个 `<item>`)。
② **键表有效** —— `sort` 1→3 ms 几乎不随 N 涨,`parse` 93→261 ms 随 N 线性(H168 那笔算术量级因此不必再当未知)。
③ **翻到底** —— 两端末行都是 `女孩子的潜台词到底是什么 / Tue, 18 Dec 2018`(三源里最早的一集)。
④ **冷启动仍秒开** —— Android `am start -W` 2,564 / 2,291 / 2,283 ms(160→300→回 160,抖动大于差值),鸿蒙 `[Inbox] 加载 300 条` 在启动后 16 ms ⇒ **"首帧若变慢先降到 100"降级为观察项**。
**两条要眼睛看过但结论已改口径的**:发现页首屏那一节 **20 条这一刀在当前渠道不渲染**(挂在 `!CATALOG` 分支,两端 CATALOG 恒 `true`)⇒ 那条装机判据本身写错了,不是漏改;
落盘前缀的**已知代价**(深滚之后杀进程,重进要从头显)是代码事实,没在真机上刻意复现。
**没验的还有**:几千行下鸿蒙这一页有没有滚动卡顿 —— 只有一条**弱证据**(Android `gfxinfo` 1,128 帧 / jank 7.36%,取证窗口混着 `uiautomator dump` 自身的停顿),
`List` + `ForEach` 只建可见行这件事有 H137 的真机否证背书,但那是逐字稿页、不是这一页。**另有一条未解释**:第一次改夹具那一轮日志读到 `subs=2`,重做才是 `subs=3`,没复现第二次。
**macOS 完全没跟这一轮** —— 它的 inbox 仍是每源 12 / 全局 100,见下面 D 节那一行
| **播放缓存 + 封面磁盘缓存(2026-10-12,1.0.5 主线):⚠️ 只过到编译,装机一条没跑** | 代码 + 五语文案(关于页两套 × 两端、同意页、设置副标题与确认框)+ `docs/{FEATURES,PRODUCT,PRIVACY}.md` + 官网隐私页 + `CHANGELOG.md` 1.0.5 节 + `ARCHITECTURE.md` 五节新段 + H170/H171 都写完了;两端编译过(Android 两渠道 `compile*KotlinRelease` exit 0 / 鸿蒙 `assembleHap` BUILD SUCCESSFUL)。**下面每一条都要"命令 + 期望 + 读数",别当已过**:<br>① **断网浏览**(核心诉求的一半)—— 先在有网时把发现页 / 追更 / 一个频道详情滚过一遍,再开飞行模式重进:榜单与频道列表的**文字**应来自 `feed_cache.json` / `popular_cache.json`(这条旧已有),**封面**应来自新的图片缓存而不是空白格。鸿蒙侧判据是 `[Artwork] 就绪 N 张` 与非空目录 `filesDir/artwork_cache/`。<br>② **播过的集下次不联网** —— 第一次在线播某集 → 等日志出现 **Android `cache done id=… bytes=…`**(`AudioCacheManager.kt:211`)/ **鸿蒙 `缓存完成 "…" xxxKB`**(tag `AudioCache`)→ 杀掉进程、**断网**、再点同一集:期望鸿蒙 `缓存命中 id=`;**Android 这一端没有"命中缓存起播"这条日志**(`PlayerController.kt:633-637` 静默取 `localPath` 后只记一次 LRU),所以本端判据只剩两条可读数 —— **该 URL 没有新的网络请求** + 断网下按一下就出声。⚠️ **原文这里写的 `source=cache` 在 Android 不存在**(全仓 `grep 'source='` 零命中),那是鸿蒙侧的措辞 —— 拿它当判据会跑成"缓存没生效"的假阴性。淘汰侧同一条更正:Android 是 `evicted id=… bytes=…`(:236)、蜂窝闸门是 `cache skipped on metered net id=`(:109),**也都是英文串**。<br>③ **缓存与下载互不影响** —— 先点名下载一集(落 `downloads/`),再点「清除缓存」:期望 `downloads/` 与 `downloads.json` **一个字节都不变**、「清除下载」那行的用量不变;反过来清下载不应让缓存目录变小。<br>④ **预算淘汰真的发生**(300 MB / 按最久没听)—— 造 >300 MB 需连续播完 6–8 集;可用 `adb`/`hdc` 往缓存目录塞同名大文件 + 伪造账本来快进,判据是日志 `预算淘汰 id=` 与被淘汰那集下次起播回落到流式。**造不出来就如实写"未触发"**。<br>⑤ **蜂窝闸门拦得住自动缓存**(设置默认开 = 不允许蜂窝)⇒ 期望 `cache skipped on metered net`(Android)/ `蜂窝闸门拦下 id=`(鸿蒙)。**这台 Pixel 3 无蜂窝数据、鸿蒙机无 SIM ⇒ 与 H166 同一寸,本机造不出**,别为此翻判据。<br>⑥ **H170 那三处在途竞态**(清除缓存 × 在途写盘 / 封面 `gen` 代号 / 断网 60 秒冷却)全是**代码审查产物,一次都没复现过**;要复现得在下载中途点「清除缓存」,再核对数字是否归零且不回升。<br>⑦ **未申请 `dataTransfer` 长时任务**是这轮的取舍(不扩权限面)⇒ 代价是"App 挂起时补齐缓存会停",**同样没实测**;若实测发现中途停得太频繁,再评估要不要申请(它会同批影响隐私页与商店申报口径)。<br>⑧ **包里有 / 没有按硬规矩 1 解包 grep**:**Android 侧已跑**(2026-10-16,对象 = `android/dist/` 里两份 1.0.5 release 包)。处理量:default 渠道 168 条目 / `classes.dex` **6,417,876 B**、store 渠道 165 条目 / 单 dex **6,402,296 B**。读数:`AudioCacheManager` 在**两渠道 dex 各命中 3 次**(`LC_ALL=C grep -ao` 计次,不是 `grep -c` 计行 —— 二进制里"行"没有意义);阴性对照 `NotARealClassXyz` = **0**(证明 grep 有牙齿);`resources.arsc` 里中文 `清除缓存` 两渠道各 **1**;**`ArtworkCache` 在 Android 是 0,而且必须是 0** —— 封面磁盘缓存只有鸿蒙自研那一份,Android 复用 Coil,拿它当 Android 侧判据会跑成假阴性。权限面 store 渠道 **10 行含 package 头 = 9 条**、**没有** `RECORD_AUDIO` 与 `MODIFY_AUDIO_SETTINGS`(default 渠道 12 行 = 11 条,`RECORD_AUDIO` = 1,那是语音识别那条旧链路,与本轮无关)⇒ **零新增成立**。**鸿蒙侧:代码在包里已验过,但验的是 debug hap**(20 个文件 / `modules.abc` 1,676,916 B,`AudioCacheManager` / `ArtworkCache` / `audio_cache` / `artwork_cache` 各 2/2/2/1,权限面三条 `INTERNET`/`GET_NETWORK_INFO`/`KEEP_BACKGROUND_RUNNING`,`RECORD_AUDIO` 全树 0)⇒ **按硬规矩 20 这不代表发布物**,`harmony/dist/reverb.app` 仍是 **10-10 09:26**(1,098,727 B)、比 43 个源文件旧(见 A8 与 #166),**拿旧包 grep 出来的是上一版的口径**,所以 release 侧那一半要等重打包之后一起补。`dataTransfer` 权限两端都没出现过(Android 已按 release 包验,鸿蒙按 debug 验)。<br>⑨ **界面动了**:设置页存储区两行副标题与确认框文案变 ⇒ 按**硬规矩 20**,截图整套重拍、kit 与 `dist/` 那份 release 包**同批重建**,不是改完文案就算完 |

### A2. 2026-10-02 三端全局复核(**只核不改**,逐条都拿 `文件:行号` 反查过)

起因是两条用户反馈(播放态跨启动,见 H129)之后做的一轮全仓复核:七路并行只读排查 + 逐条反查。
分三级的判据是「会不会让功能不成立 / 政策说的话与包或代码不一致」,不是改动大小。
**编号口径(2026-10-06 写死,免得下一轮又当成漏做或错位)**:A2-1 用表格的 1–5,A2-2 用 6–12,
A2-3 用 11–19 —— **两个小节的号段有重叠**(A2-2#11「macOS 备份导出没有勾选」≠ A2-3#11「批注挂错集」;
A2-2#12「日志四行」≠ A2-3#12「override 被重试吃掉」),所以**引用必须带小节前缀**,单说「#11」没有意义。
这两条后来追加的条目各归了自己该在的小节(批注挂错集是「三端同形的窄窗口」,在 A2-3;日志四行是「三端实现不一致」,在 A2-2)。
**处理进度(2026-10-06 更新)**:A2-1#1/#2(日志与政策对齐,H131)、A2-1#4/#5(政策页两处失真,**两份文本 + 站点全部到位**)
—— ✅ **2026-10-06 已上线**,但过程里挖出两件事,都记进 H144:
① **rsync 的源目录 `/Users/liang/Documents/web/` 是 9-20 的手工快照,比仓库少一整轮改动** ——
按维护者给的那条命令原样跑,线上一行都不会变而退出码是 0。所以上线前必须先把仓库那份
`site/reverb/privacy.html` 覆盖进部署目录(旧的那份已备份到 `/Users/liang/Documents/web-deploy-backups/`)。
② 覆盖前逐字读了新页面,发现**「批注进系统备份」这句对在架的鸿蒙 1.0.3 不成立**(解包实测白名单 8 项、
不含 `notes.json`),照发就是让线上页替旧版本承诺旧版本没做的事 —— 已补「自 1.0.4 起才进入这份白名单」
的限定(`docs/PRIVACY.md` 与 `site/reverb/privacy.html` 两份同步),然后才发。
**验收 = 三方 SHA-256 逐字节相同**:仓库 = 服务器文件 = `curl` 回来的线上页(最终那份 `379e606026e874…` / 17,277 B,前一次 `7c93008c91ae55…`),
线上正文「自 1.0.4 起」三处各命中 1、权限表里 `开机广播` 那一 `<tr>` 命中 0 而「也不申请开机广播」命中 1。
再补一处**页面自己违反自己**的失真:顶部「最后更新」还写着 9-13,而 10-05/10-06 已改过四组正文,
而第十节承诺"如有更新就改这个日期" —— 已改成 2026-10-06 并第二次上线(应用内没有政策快照,同意页是摘要+链接,
所以只有这两处;逐条见 H144 教训 ⑤)。部署流程与主机信息写进了 `docs/STORE-OPS.md` 第四节(不入库那份),#74 结案。
**2026-10-08 被要求「部署网站」时按三方哈希复核过:隐私页无待部署增量**(仓库 = 服务器 = 线上,
`379e606026e874…` / 17,277 B,两个域名均 200;三处政策口径在线上逐条 grep 到),
所以 `CHANGELOG.md` 1.0.4 待办里那条「官网隐私页还有一次重新部署要做」当时已过期,已改口。
**这一轮站点真正的动作在首页,而且方向相反**:`index.html` 线上写「HarmonyOS NEXT 已上架」而仓库仍写「已发布」
(鸿蒙 10-01 过审,线上才是对的)⇒ 这次是**把线上回写进仓库**(哈希与线上/服务器一致的 `3d7a96ab…` / 129,537 B),不是上传。
**规律:「仓库是上游」只规定权威源,不规定时间顺序 —— 手工部署的副本漂移是双向的,
所以第一步永远是取线上哈希 + 读 diff 判方向;三方全等时"执行部署"是一次零字节变化的空动作。**
逐条见 **H144 的 2026-10-08 补记**。1.0.4 若要发布,真正的发布动作是往**公开仓** `revert-cast` 的 Releases
传新资产(首页那个链接已核过是指向它,不是私有的 git remote,别改)、以及鸿蒙在应用市场提交新版本。
A2-2#6/#8(macOS 逐字稿的 version 门与出口不变式,H134)、A2-2#9(鸿蒙睡眠倒计时,H132)、A2-2#12(日志四行两端双向补齐,H142)、A2-3#11/#13(批注那一集 + 备份幂等,H133)、
A2-3#15(macOS 频道缓存走去抖通道,H135)、A2-3#17(macOS 出包验收从"只打印"改成"断言 + 退出码",本机自检 pass=9 fail=0,H136)、
A2-3#16(鸿蒙逐字稿渲染路径的整表回溯换成 O(1) 判据,等价性 fuzz 17,603,485 次 0 不一致,H137)、
A2-3#14(批注的读盘与恢复三端同形归一:倒序 + 负值归 0,H138)**已改掉**;
A2-2#10 与 A2-3#12 是**查过之后判定"不该照原方案改"**(理由写在码旁与 `ARCHITECTURE` 第五节,别再当漏做加回去)。
**剩下的**:A2-1#3(要产品选路线:移出编译树 or 改政策措辞)、A2-2#7(macOS 读官方稿 —— 整块功能移植,排在构建机出包之后)、
A2-3#18/#19(#16 与 #14 已于 2026-10-06 改掉,见 H137 / H138;#16 改完后**留在原地的两问**——ForEach 是否给不可见行也建 ListItem、macOS 每行读一次计算属性——已挪进三-A2 表;2026-10-07 前者**已经有答案**——`uitest dumpLayout` 在 1400 句稿那一页只数到 15 个稿行节点,`ForEach` 不给不可见行建 `ListItem`,见 H137 验收段与 H149;后者要真机跑 macOS 产物,本机拿不到证据,仍留在表里)。第 1、2 条那种"三行级改动"的估计在真动之后仍然成立。

#### A2-1 政策与包内容不一致(**优先级最高,因为它对应用户读到的那句话**)

| # | 现象 | 证据 | 为什么成立 |
|---|---|---|---|
| 1 | 隐私政策写「日志不记录搜索词」,**Android 与 macOS 两端**都把搜索词原文打进了日志(2026-10-05 修;原记「Android 单端破口、另两端没有」是**漏检得出的错方向**,本行右列写了错法) | `docs/PRIVACY.md:50` ↔ `data/remote/PodcastRepository.kt:44` `search query='$q'`、`:87` `searchEpisodes query='$q'`;macOS 侧是 `PodcastRepository.swift:30/:47` 的 `search \"\(q)\"` | 日志可一键导出/发开发者邮箱 ⇒ 用户主动分享时把自己的检索词带走了。鸿蒙那一端**确实是干净的**(只记命中条数),这一句经过复查才敢留<br>**✅ 2026-10-05 已修,但修的过程中先错了一次,错法值得记**:当时按 `query=` 搜全仓,得到「另两端没有 ⇒ Android 单端破口」——那是**格式偏差造成的漏检**,macOS 写的是 `search \"\(q)\"`,同一个破口换了个形状就搜不出来。修法是两端一起把原文换成**词数**(`queryWords=N`),而不是只修搜到的那一端。<br>**判据教训**:跨端"某一端没有"的结论,词表要按**每一端的书写习惯**给多个形态(单引号 / 转义引号 / 变量名),否则会得出"这是单端破口"这种错到方向上的结论。逐条见 H131 |
| 2 | 同一条政策说「不记录完整 URL」,**macOS 端不成立** | `docs/PRIVACY.md:50` ↔ `macos/.../Data/Log.swift` 里没有任何脱敏函数;整串 URL 落日志的点:`DownloadManager.swift:34`、`RssParser.swift:9/11/20/26/68`、`HTTPClient.swift:18/24/29`、`InboxStore.swift:127`、`PlayerController.swift:381` | 另两端都在**写盘前集中收成 `scheme://host`**:Android `util/Logger.kt:62`(配合 `:52 endpoint()`)、鸿蒙 `util/Logger.ets:55 sanitize`。订阅地址的集合就是收听行为,这条不是形式问题<br>**✅ 2026-10-05 已修**:没有去改那 12 个调用点,而是在 `Log.write` 里加**同一个集中脱敏**(`sanitize()` + `endpoint()`),这样"新加日志的人不需要知道这条规矩",且与另两端同形。**顺带把 error 那半截也过了脱敏** —— `URLError` 的 description 会把失败地址整段带出来,Android 那边早就对堆栈做过这件事。判据:函数从 `Log.swift` **逐字取出**单独编译跑 10 例(URL 带 path/query/fragment、带端口、带 userinfo、IPv6 字面量、大写 scheme、一行两个 URL、`<>` 包裹、非 http 的 scheme 不动、无 URL 的原样)全过,加上整模块中性化到 0 错误的差分与两道阳性对照,逐条见 H131 |
| 3 | 政策说「大陆应用商店版本**不含**离线语音识别」,而鸿蒙 release 包里**有**这套实现 | 解包实测 1.0.3 市场包 `harmony/entry/build/release/outputs/default/entry-default-signed.hap`(**处理量 2,357,035 B / 18 个文件**):`ets/modules.abc`(**741,152 B**)里 `speechRecognizer`×1、`SpeechTranscriber`×2、`PcmReader`×2;`libs/arm64-v8a/libreverb_pcm.so` 57,888 B 也在包里 | `Features.LOCAL_ASR=false`(`playback/…`→`AppContainer.ets:96` 门住实例化)⇒ **运行时永不执行**,但 ArkTS 没有 DCE(硬规矩 2,`docs/ARCHITECTURE.md:237` 与 `harmony/shelved/README.md` 记的正是这条),所以「不含」按硬规矩 1 的解包口径不成立。<br>**需要产品决定**:① 把 `SpeechTranscriber.ets` + `PcmReader.ets` + `cpp/` 那条链移出编译树(照 `shelved/` 的做法,代价是换引擎时要搬回来) ⇒ 政策那句话保持原样;或 ② 不动代码、把政策措辞改成「不会在本机执行识别」。两种都能收敛,不能只做一半 |
| 4 | 政策列了一个**已经不申请**的权限 | `docs/PRIVACY.md:84`(开机广播)↔ `AndroidManifest.xml:24-26` 用 `tools:node="remove"` 显式移除(H120 那轮为避灰色软件启发式做的) | 多声明不危险,但政策页是逐字被读的东西;删该行即可。`site/reverb/privacy.html` 同步 —— **与预载那条一起走一次重新部署**(本就在待办里;**2026-10-06 已随那次部署一起上线**)<br>**✅ 2026-10-06 两份文本已同步改掉**:权限表里那行删除,并在「本应用不申请…」那句后面**点名写明不申请开机广播**(静默删行会让下一个人以为"从来没申请过",而它是显式 `tools:node="remove"` 移除的 —— 那句话同时解释了原因)。**站点已于 2026-10-06 重新部署**(三方 SHA-256 一致,流程与坑见 H144) |
| 5 | 政策把 macOS 的识别写成「内置开源离线识别组件、识别模型随安装包提供」 | `docs/PRIVACY.md:25/:72` ↔ `macos/Sources/Reverb/Data/Transcriber.swift:20-22` 用 Apple `SpeechAnalyzer` / `SpeechTranscriber`,模型由**系统**按需联网下载(`:55 downloadAndInstall`)、不在包内 | 该下载目的地也没进政策第三节清单。macOS 没有同意页也没有 `privacy_url`,而政策页尾(`PRIVACY.md:138`)自称适用三端<br>**✅ 2026-10-06 两份文本已按端拆开写清**:①「内置开源组件、模型随安装包」限定为 **Android 自分发版**;② macOS 单列一条 —— 用系统自带语音识别框架、模型**不在包内、由系统按需下载**;③ 第三节网络表补上「macOS 语音识别语言模型」这一行(注明由系统发起、本应用不指定地址、不附加音频与身份);④ 顺带修了一处**比代码乐观**的旧句:原文「若发布方提供官方逐字稿,本应用会直接请求该文件」对 macOS 不成立(桌面端压根没有 `transcriptUrl`,见 A2-2#7),已改成「Android 与 HarmonyOS 版会直接请求;macOS 版当前只在本机生成」。**站点已于 2026-10-06 重新部署**(见上一行与 H144);另:#3(鸿蒙"不含识别"那句)**没动**,那条要产品先定路线 |

#### A2-2 三端实现不一致 / 会让功能不成立

6. **macOS 的逐字稿缓存没有版本号** —— `TranscriptStore.swift:37` 的 `Cached{localeId, complete, segments}` 既不写也不校验 version,而 Android `TranscriptStore.kt:319` / 鸿蒙 `TranscriptStore.ets:74` 都是 `CACHE_VERSION=2` 且读时比对 ⇒ **硬规矩 11 在 macOS 落空**:改了组行或时间轴算法,用户设备上已生成的旧稿永远不作废,而且没有自救入口。`docs/FEATURES.md:104` 那句「三端同一格式,带 `version`,口径变了自动作废重转」比代码乐观(文档失真)。<br>**✅ 2026-10-06 已补**:新增类外 `enum TranscriptFormat { static let version = 2 }`,`Cached` 加**可选** `version`(v2 之前写出的文件压根没这个键 ⇒ 缺省按 v1 判),读缓存时 `(cached.version ?? 1) < version` 就整份丢弃返回 nil、走手动重转;写缓存带上版本号。校验刻意放在**已有的那个 `Task.detached` 解码块里**(与鸿蒙/Android 同口径:解码 + 校验 + 收敛一趟后台跑完),也因此 `TranscriptFormat` 不能是 `@MainActor` 的成员。三端现在同值同义(都是 2),`docs/FEATURES.md:104` 那句由"比代码乐观"变成"如实"。验收=两份树中性化整模块 typecheck 各 0 错误 + 从源文件逐字抽出该 enum 跑的 10 条断言(含"缺 version 判成 v1 后丢弃")、变异对照有牙齿;**macOS 一帧没跑过**,所以"旧稿真的作废重转"在真机上未验。逐条见 H134
7. **macOS 不读发布方的官方逐字稿** —— 全仓 grep `transcriptUrl` 在 `macos/Sources` **零命中**,`Models.swift:18-28` 的 `Episode` 连这个字段都没有,也没有 `TranscriptFetcher` 的对应物 ⇒ `docs/TRANSCRIPT.md:19` 那条「顺序永远是先官方稿、后本机识别」对 macOS 不成立:有现成稿的英文集也要跑几分钟本机识别、发热耗电,而官方稿又准又快。这是**功能缺口**不是文档漂(与 A2-1#5 是同一片地)。<br>**2026-10-05 定路线:这条不是"补一处判断",是整块功能移植** —— 要动 `Episode` 模型 + `RssParser` 的 `podcast:transcript` + 三种格式(Podcast Index JSON / WebVTT / SRT)的 fetcher + 状态机里"官方稿优先、失败回落本机识别" + UI + 五语文案(Android 的对应物是 `data/remote/TranscriptFetcher.kt`,可照搬口径)。**而本机对 macOS 的最强验收只有 typecheck 差分(见 H128/H130),拿不到任何运行证据** —— 三格式解析器这种恰好是最需要拿真实稿子跑一遍的代码。所以排在 #59(在构建机上出包 + 运行验收)之后做,不做"编得过就当验过"的移植
8. **macOS 词级时间没有出口不变式** —— `Transcriber.swift:67-77` 把各 run 的 `audioTimeRange` 直接 append,不排序不钳制;渲染侧用的是「从后往前找第一个 `startMs<=now`」(`TranscriptPage.swift:32`,还有 `:250` 的 while)⇒ **硬规矩 10 的教科书场景**:队尾一个异常小的值就让高亮钉死。Android 有两层(C++ `reverb_asr.cpp:86-103 tidyWords` + `TranscriptLines.kt:109`),鸿蒙走 `TranscriptLines.ets:148 monotonic`,只有 macOS 裸奔。<br>**✅ 2026-10-06 已补,并且刻意放在与另两端同一个位置(数据出口)而不是渲染侧兜底**:同一个 `TranscriptFormat.monotonic` 用在两处 —— 定稿入库那一句夹一次(下限取上一条起点,于是链一次性有序),以及读缓存时整份收敛一次(覆盖旧文件 + 将来官方稿这两条来路)。与 #6 是同一个 enum、同一批改动。**没做"已有序就原样返回"的快路径**,因为这条不在渲染路径上(硬规矩 6 管的是每秒跑两次的代码)。验收同上(10 条断言含词级乱序 / 负值 / 终点早于起点,变异对照改坏钳制后 3 条失败);**真机上"高亮钉死"这个现象本身没能造出来** —— 它取决于 Apple 是否真会给出乱序 `audioTimeRange`,而这正是这条要防的那类不可假定。逐条见 H134
9. **鸿蒙 `sleepRemainingMs` 挂在被整页观察的对象上、睡眠定时期间每秒写** —— 字段 `playback/PlayerController.ets:89`,每秒赋值 `:1206-1214`,而**只有** `view/PlayerPage.ets:439/447` 那颗睡眠 chip 读它。`@Observed` 的观察粒度是对象(H64 那条老账),`@ObjectLink player` 的页面有 8 处(TranscriptPane / Components / PodcastDetailPage / DiscoverPage / PlayerPage / LibraryPage / QueuePage / MiniPlayerBar)⇒ **硬规矩 7**:开了睡眠定时,**当下挂着的那些界面**(播放页 + 迷你条 + 底栏组件)播放中每秒整页重建一次;那 8 处里不在前台的页要不要跟着重建,取决于框架的挂载策略,**这一层没实测**(本机无设备)。`positionMs` 当年正是为这个搬进 `PlaybackClock.ets` 的,这一条是漏网的同类。Android / macOS 同字段同形状(`PlayerScreen.kt:89` 顶层 collect、`PlayerController.swift:65 @Published` + 1Hz Timer),但两端没有 V1 那种"对象级观察 + 整页 build"的放大,危害面不同。<br>**✅ 2026-10-05 已按 `positionMs` 那套现成手法收敛**:数值本体搬进非观察的 `PlaybackClock.sleepRemainingMs`,被观察对象上只留**每秒不变**的 `sleepTimed` 标志位(设时 / 取消 / 到点这三处写);ticker **不再每秒 notify**,只在"到点"那一格通知一次;显示侧新增 `view/SleepCountdownText.ets`,自己按秒轮询、**且只在定时真开着时起表**(照 `SeekBar` 的 `@Watch` 门)。验收只到 `hvigorw assembleHap` BUILD SUCCESSFUL —— **未装机**,所以"挂着的那些页面不再每秒重建"这一条**仍未实测**(判据手法在 H64:静置某页、播放 10 秒数 jank 帧)。<br>**✅ 2026-10-07 装机量过了**,而且用的不是数 jank(H64 那套手法在这里不够用:jank 恒为 0,证明不了"没白重建")—— 临时属性计数器(`.opacity(Probe.op('pp-const'))` + `.saturate(Probe.op('pp-dep', this.<@State>))`,每秒一条 `[Probe]` 进 hilog)实测:定时**关着**时播放页 `pp-*` / `mini-*` 全程缺席(阳性对照 `seek-const=4` 每秒都在),定时**开 15 分钟**时只有 `sleep-const=1 sleep-dep=1` 每秒、`pp-*` 与 `mini-*` 仍是 0 ⇒ **重建只发生在 `SleepCountdownText` 那一个组件,没有扩散到整页**,正是这条想要的结论。探针手法、合成素材的坑与撤除验收见 H149;数字与逐档读数见 H132 验收段。逐条见 H132 |
10. **鸿蒙退出时不释放播放链** —— `entryability/EntryAbility.ets:82-87` 的 `onDestroy` 既不调 `PlayerController.release()`(`:1341` 有完整的 `unbindSourceEvents` / `off('timeUpdate')` / 清 tick·fade·sleep 定时器),也不 destroy `AvSessionBridge` ⇒ 收敛只靠进程死亡。<br>**✅ 2026-10-05 复核结论:这条不是漏做,而是「不该照它改」** —— `release()` 把 `released` 置真而**全仓没有一处复位**,`startEpisode` 开头就因此早退;PlayerController / AvSessionBridge 又是进程级单例,而「ability 销毁」≠「进程死亡」(系统回收 ability 保进程、划卡片后热启动都是),所以放进 `onDestroy` 的后果是**整个 App 再也播不出声**;而销毁时仍在放音恰恰是长时任务要的行为,release 等于"从任务中心划掉就把正在听的这集掐了"。判据与前提已写进那段代码的注释里(要补显式释放得先给 `released` 一条复位入口,并装机验「后台播放中划卡片」+「热启动后再播」两格)。**这条从待修转成"已判定 + 已把判断写码旁"**,不再排队
11. **macOS 的备份导出没有分区勾选** —— `SettingsView.swift:233` 实测写死 `BackupManager.build(env, Set(BackupManager.Section.allCases))`,只有**恢复**侧有勾选 sheet(`:361/:380`)。Android 两个方向都弹 `BackupSectionDialog`,鸿蒙 2026-10-06 把两个方向都补齐了 (见 H141)⇒ 现在是**三端里 macOS 少一半**。差距不大(导出全量不多不少,用户顶多是备份里多带了不想要的分区),而桌面端本机一行运行证据都拿不到(见 AGENTS.md macOS 那节),所以排在 #59 构建机出包之后一并做 —— **要补的是给 macOS 加勾选,不是把另两端删掉**。

12. **设置页「日志」段两端各有各缺**(2026-10-06 核对):Android 有 分享 + 邮件而**没有「导出日志为文件」**(它的 `shareLog` 只把文件交给 `cacheDir/shares` 再分享,用户手上不落一份),鸿蒙有 分享 + 导出而**没有邮件反馈、且开发者邮箱在鸿蒙端任何界面都读不到**(全仓 grep `woooxooom` 只有 Android 的 `SettingsScreen.kt` 与 macOS 的 `SettingsView.swift`)。顺带一条真的坏了:`Files.shareText` 用 `PLAIN_TEXT + content` **内联**整份日志,而 Android 是 `EXTRA_STREAM` **附件** —— 几十 KB 的运行日志走内联会被多数目标截断,连文件名都没了。<br>**✅ 2026-10-06 双向补齐,方向是各加一条而不是把另一端那条删掉**:Android 新增 `logExportLauncher`(`CreateDocument("text/plain")` → `reverb-log.txt`,失败用 `saved_fail` 而不是复用 `backup_failed` —— 那一行不在备份段里,弹「备份失败」会让人以为刚导出的备份坏了);鸿蒙新增 `mailLog()` 行并把 `shareText` 改成**写 `cacheDir/reverb-log.txt` 后按文件 uri 分享**(与 `shareImage` 共用 `fileUri.getUriFromPath` 那条规矩)。两端行的顺序统一为 分享 / 邮件 / 导出 / 清空,`set_share_log`/`set_mail_log`/`log_export`/`log_done` 等 8 键 × 5 语**脚本逐字比对全等**。<br>**一处做不到的差异如实写在界面上**:鸿蒙的 `SharedRecord` 没有收件人字段、面板也不接受"定向到邮件应用"的参数 ⇒ 那行的副标题直接把地址写出来要用户自己填(照抄 Android 那句「通过邮件发给开发者」就是在承诺一件本端做不到的事)。macOS 四行齐全但顺序是 导出/分享/邮件/清空,没动(本机拿不到运行证据,与 #11 同片地一起排 #59)。**但本轮造失败时顺手查出 macOS 那一端是同一族的第三种缺**:`prepareShareLog` / `exportLog` / `mailLog` 三处的写盘都是 `try?`(`SettingsView.swift:294 / :306 / :316`)吞掉错误 —— 失败既不弹提示也不写日志,比 Android 修好之前还安静一档。<br>**✅ 2026-10-07 已补(#118),而补的范围比这句更大**:按「枚举所有落盘点」而不是「枚举有 catch 的地方」重扫三端 —— macOS 实际是**五处**(`exportBackup` / `exportOPML` / `exportLog` / `mailLog` / `prepareShareLog`);同一次扫另抓出两件事:**Android 的 OPML 那一格成功失败都不出声**(它压根没有 catch,所以不在 H142 那轮的清单上),以及更坏的一条 —— **Android 三条导出共用的 `runCatching { openOutputStream(uri)?.use{…} }.isSuccess` 在 `openOutputStream` 返回 null 时照样为 true ⇒ 弹「备份完成」而文件里什么都没有**。三端各补自己缺的那一侧(鸿蒙那一格本是参照端,未动):Android 收进 `writeTextViaSaf`(null 明确 `error`),macOS 加 `Prompt` 枚举 + `writeText(_:to:) async -> Bool`(标题即三端那句短语,所以只给标题不给正文),提示取值与两端**按渲染值逐字对齐**、四套 `.strings` 各 +6 键(共 199 键/套,键集合两两差 0)。代价照旧是运行证据:**macOS 一帧没跑起来,仍排 #59**;而 **Android 这三条的失败分支也没在真机上走过**(SAF 落点在应用沙箱之外,H155 那套 `run-as chmod cache/` 的杠杆不适用),两条缺口都记在 **H157** 与任务 #122,而不是默默留着。<br>验收=✅ Android 两渠道 compile 全绿 + 鸿蒙 `assembleHap` BUILD SUCCESSFUL(WARN 仍是 19 条、无新增)+ 两端 8 键 × 5 语逐字比对;**❌ 一次都没点过**。装机判据(并入 #84/#98 那批):①鸿蒙分享日志 → 面板里应当是**一个 .txt 附件**而不是贴一大段文本,收到的文件能打开且末尾不被截;②鸿蒙邮件行 → 落到邮件应用后主题=「余音 HarmonyOS 日志反馈」、正文带版本行,收件人**空着**(这是本端能力上限,不是 bug);③Android 导出日志 → SAF 里改名后保存,内容与「分享日志」那份一致,空日志时是 `(暂无日志)`;④两端各造一次失败(无邮件应用 / 取消后再断)看提示文案对不对 —— **✅ 2026-10-07 Android 真机跑过,而它查出来的不是"文案对不对",是 Android 根本不出声**:两个入口的 `catch` 里只有 `Logger.e`,失败时面板不弹、界面一个字都不变 ⇒ 补 `onFailed` 参数、写进与导出/备份同一个 AlertDialog;鸿蒙那三条原先统一用 `backup_failed`(「操作未完成」,太泛),现改为 `log_send_failed`(分享 / 邮件)与 `saved_fail`(导出),两端 × 5 语逐字全等(10 组)。**鸿蒙这一格在真机上造不出失败**(沙箱 `cache/` 的 chmod、`hdc file send`、媒体区 `mkdir` 三条杠杆实测全被拒),所以它只到编译级。手法与那条「**目录只读挡不住覆盖写**」的注入陷阱见 **H155**,逐条见 H142 ④

#### A2-3 窄窗口 / 纪律 / 观感(记下来,不当必修)

11. **批注编辑器打开期间换集 ⇒ 那条批注挂到下一集**(三端同形,不是漂移):位置是按下瞬间冻结的(`PlayerScreen.kt:200` / `PlayerPage.ets:543` / `PlayerView.swift:327`),而单集是保存那一刻取的(`PlayerScreen.kt:347` 用重组后的 `episode` / `PlayerPage.ets:665-674` 重取 `player.current` / `PlayerView.swift:455` 用弹层参数)。要成立得"弹层开着的时候恰好自然播完接下一集",概率低但一旦发生就是"我明明写的是上一集那一句"。<br>**✅ 2026-10-05 三端一起把「那一集」也冻在按下瞬间**:Android 新增 `noteEpisode`(与 `noteAtMs` 同句写入,保存路径改读它)、鸿蒙同名字段但**刻意是普通成员而非 `@State`**(这个值不参与渲染,挂成状态等于白添一个重渲触发源,硬规矩 7)、macOS 新增 `@State noteEpisode: Episode?` 并让 popover 内容只认它。验收只到两端编译 + macOS 整树 typecheck 差分 —— **三端都没跑起来验过这条窄窗口本身**(要成立需要"编辑器开着时恰好接下一集",装机时按 `ROADMAP` 批注那六条判据之外的独立一条验:写批注期间让上一集播完,保存后那条挂在**旧集**上)。逐条见 H133
12. **明确跳点的 override 会被装载重试吃掉一次**:消费点在取续播处(`PlayerController.kt:613-616` 转存进 `pendingSeekMs`,所以 Android 重试还在;鸿蒙 `:347` / macOS `PlayerController.swift:364-367` 首轮就清,而 `handleLoadFailure` 的重试不带 override ⇒ 那一轮回落续播)。文档里"不被重试吃掉"这句只对代次早退成立。<br>**✅ 2026-10-05 定的是「改口径」而不是「改代码」**,理由写在 `docs/ARCHITECTURE.md` 第五节那条里:三端行为差别的根不在处理优劣,而在 **Android 压根没有自动重试**(`onPlayerError` 只记日志)⇒ 它的 `pendingSeekMs` 自然活到 STATE_READY;鸿蒙与 macOS 有重试(H 号那批为睡眠唤醒后网络异常加的),要给显式跳点续命就得各加一份"这一集还没落地的跳点"状态,而**改的是播放链最敏感的一段,本机既装不了鸿蒙也跑不了 macOS**,拿不上证据的改动不该动它。代码方案留在原地备查:鸿蒙在 `playEpisode` 取点处加一条「`pendingSeekExplicit` 且 `pendingSeekMs` 对应的还是这一集」的沿用分支(需一个 id 字段判集),macOS 同形。**这条口径本身未实跳验证过**(重试恰好撞上显式跳点的场景没能造出来)
13. **Android 备份恢复对缺 `noteId` 的条目用随机 UUID 兜底**(`BackupManager.kt:162`),鸿蒙是 `${createdAt}-${i}`(`BackupManager.ets:256`)、macOS 是 `legacy-<ts>`(`Models.swift:176`)⇒ 只有 Android 重复恢复同一份备份会把批注**翻倍**(破坏幂等)。前提得是数据里没有 noteId,概率很低,但确定值兜底是免费的。<br>**✅ 2026-10-05 已按鸿蒙那个形态收敛**:`ifBlank { "$createdAt-$i" }`,恢复按 id 去重因此可重复执行。只到 Android 两渠道编译,**没有真的做两次恢复**去验(那条需要一份手工造的、缺 `noteId` 的备份,判据见 H133 的「怎么自己验」)
14. **三端 load / 恢复侧都不夹 `positionMs`、不排序** —— 夹只在 `add`(Android `NoteStore.kt:57` / 鸿蒙 `:78` / macOS `Stores.swift:221-223`),排只在 `addAll`(`:86` / `:106` / `:241`)⇒ 跨端来的越界值照样落盘并显示。另:三端都用 **RSS 元数据时长**夹上限(不是真实播放器时长),这一条是共同设计而非某一端独有。<br>**⚠️ 2026-10-06 先把这条原句改准**:「恢复侧不排序」**不准确** —— 三端 `addAll` 一直都排(A2-4 那条证伪就是靠这点判它误报)。真正一条门都没守的是 **`load()` / `init()`(冷启动读盘)** 和 **系统级备份还原**:后者是把 `notes.json` **整份文件覆盖回来,压根不经过 `addAll`**,而还原后的唯一读取路径就是那个不排序、不夹值的 `load()`。"恢复"这个词把两个入口混成了一个,于是一句正确的证伪替另一句漏掉的盖了章(见 H138 教训 ②)。<br>**✅ 2026-10-06 三端各加一条同口径的 `normalize`,接在读盘与恢复两处**:Android `load()`/`addAll`、鸿蒙 `load()`/`addAll`、macOS `init()`/`addAll`,内容 = 按 `createdAt` 倒序 + `positionMs < 0` 归 0(三端用的都是稳定排序,同一毫秒的两条不打乱先后:Swift `.sorted` 与 JS `sort` 本机各跑一份 200 条同刻样本实测保持,Kotlin `sortedByDescending` 走自然序稳定)。**读盘侧刻意不套 `add` 那条上限夹** —— 那里夹得住是因为手上有播放器实时位置作真值,而读盘时唯一可比的 RSS 时长是自报近似值、常比真实音频短;用近似上限改写用户早写下的那一秒比留着越界值更糟(时间戳自己跳位而用户不知道谁改的),越界值到播放那步由播放器按真实时长夹。**格式一字未动 ⇒ 按硬规矩 11 不需要版本号**。<br>验收=Android 两渠道 compile 全绿 + 鸿蒙 `assembleHap` BUILD SUCCESSFUL + macOS 两份树中性化整模块 typecheck 各 0 错误(39 文件 ×2,中性化点数改前改后都是 14)+ 三道阳性对照各自命中。**❌ 改完当天三端都没跑起来** ⇒ **2026-10-07 Android 真机跑通了**:六条手写 `notes.json`(甲 `createdAt=2000` / 乙一·乙二**同刻** 3000 / 丙 `positionMs=-90000` / 丁缺 `episode` / 戊 `audioUrl` 空)经 `cat` 管道写进 debug 沙箱(`run-as` 读不到 `/sdcard`,只能走 stdin),`force-stop` 后冷启动 ⇒ 批注段四行:乙一 02:03 / 乙二 03:42 / 甲 10:54 / 丙 **00:00**,丁戊不出现 ⇒ **倒序、同刻稳定、负值归 0、无效条目跳过四条一次全中**(末态已逐条删回 `notes.json` 为 `[]`)。**~~鸿蒙侧这条不可注入~~ ⇒ 2026-10-07 已跑通**:原先那句"沙箱对 `hdc shell`(uid=2000)只读"只在 **release 签名包**上成立,debug hap 双向可进 —— 同一份乱序六条 `hdc file send` 写进 `haps/entry/files/notes.json` 冷启动,日志 `批注加载 4 条`、批注段四行与 Android 逐行同字同序(乙一 02:03 / 乙二 03:42 / 甲 10:54 / 丙 00:00),末态推回 `[]` 并复验过仍是 0 条。**macOS 未跑**。系统级还原本身仍未验(需要 `bmgr`/云端环境)。逐条见 H138
15. **macOS 频道缓存落盘在 MainActor 上同步跑** —— `PodcastRepository.swift:5` 是 `@MainActor`,`:116` 调 `feedCache.put` → `FeedCacheStore.swift:93-100` 把整份 ~1-2 MB `JSONEncoder().encode` + `.atomic` 写盘,**无去抖也无线程切换**;刷新"最新"时逐源命中。鸿蒙同类当初是用 `writeJsonDebouncedLazy` 搬走的(H65 那笔账)。<br>**✅ 2026-10-06 已改走仓库里现成的那条通道**:`AppSupport.save(fileName, raw)` —— 它就是为这件事写的(去抖 0.4s + 后台队列编码与写盘 + 退出前 `flushPending()`),`history`/`inbox` 这些 store 早就在用,只有 `FeedCacheStore.persist` 漏在外面没接。于是「刷新最新」那一轮 15 个源 = 15 次 `put`(逐源都过 MainActor,`InboxStore.swift:115` → `PodcastRepository.feed` → `put`)从「主线程编 15 份 1-2 MB」变成「只落最后一份、且不在主线程编」。<br>**顺带修了一条同通道的坑**:`clear()` 原本 `removeItem` 删文件,走去抖后会被 pending 里那份"清空前的快照"在 0.4 秒后原地复活(内存清了、盘上还有 1-2 MB,下次启动全装载回来)⇒ 改成往同一条通道写一份空字典,天然覆盖那份待写。另把 `init` 自建的目录改成与写盘通道同源(`AppSupport.dir`)—— 它原来那条"取不到就回落临时目录"的兜底,在走通道写盘之后正好会造成读写的目录分叉。<br>验收=两份树中性化整模块 typecheck 各 0 错误 + 阳性对照;**"卡一下消失了"没有实测**(本机跑不了 macOS 产物),而且这轮**没做改前/改后的耗时对照**——所以这条给的是"机制挪走了"的证据,不是"快了 X 毫秒"的证据。另:该文件顶原有两句「计入设置页缓存大小」比代码乐观(macOS 设置页只展示日志体积,`sizeBytes()` / `clear()` 当前无调用方),已就地改成如实说明。逐条见 H135
16. **鸿蒙逐字稿当前行是 O(词²)** —— `TranscriptPane.ets:242/245` 每个词各调一次 `spokenIndex(seg)`(每次整句从后往前扫),而这一页在播放可见时 80ms 重建一次(`:88`)。复查时还发现**同一条更重的**:`lines()` 里每个 `ListItem` 各调一次 `currentIndex()`(整张表从后往前扫,一集长稿实测 1345 句)⇒ "这一行是不是当前行"这个布尔量每档被算 (行数 × 句数) 次。<br>**✅ 2026-10-06 渲染侧换成等价的 O(1) 判据**:`isCurrentLine(i)` = 「本行起点已过去 **且** 下一行起点还没到」(表尾没有下一行 ⇒ 最后那句一旦过去就是当前句),词级同形 `isSpokenWord`。`currentIndex()` 留给 `autoScroll` —— 它要的是下标本身(`scrollToIndex` 入参),每档一次整表扫描是必要成本;`spokenIndex()` 再无调用方,删掉。<br>**为什么不是"照 Android 那样在顶层算一次往下传"**:ArkUI 的 `@Builder` 里**不能声明局部变量** —— 实测 `const cur = this.currentIndex();` 直接编译失败(`10905209 Only UI component syntax can be written here`),而存成字段就变成"每个改 `nowMs`、每个换稿的地方都要记得失效它"的缓存问题(`prepare` 是"先清成 [] 再整份装上",两次赋值可能长度相同)。**Android 那边没这层**:它是顶层一次 `remember(segments, nowMs / 100)` 算好传进 `TranscriptList`。<br>验收=①等价性 fuzz(单调数组,含重复时刻/负起点/空表/`now` 落在首尾之外,20 万轮):17,603,485 次逐行判定与旧写法**0 处不一致**;②`hvigorw assembleHap` BUILD SUCCESSFUL。**❌ 未装机、没量过帧率,所以这条的证据只到"渲染路径里的整表扫描去掉了",不到"这一页快了"**(2026-10-07 已补,见下)。<br>**✅ 2026-10-07 真机量过**(临时属性计数器,手法与撤除验收见 H149;素材是一份合成的 1400 句官方 SRT,因为本机 7 源 343 集的 `transcriptUrl` 全空、`Features.LOCAL_ASR=false` 又让第三页压根不出现):这一页开着、播放中静置,`pane-const=12 pane-dep=12` 每秒(**与 80 ms 心跳的 12.5 次/秒对上 ⇒ 重建次数就是心跳次数,一行都没有多**)、`line`(当前行判定)=1/s;手动滚动时 `line` 涨到 6 与 3,而 `pane-const` 仍是 12 ⇒ **代价随可见行数走,不随总句数走**;全程 `jank=0`。⚠️ **没量到的那一半要说清**:`word`(词级高亮那一支)全程为 0 —— SRT 没有时间词标注,`isSpokenWord` 的 Span 分支一次都没被执行,要验它得换 Podcast Index 的 JSON 稿。**另记两条没动的**:见三-A2 的「鸿蒙 `ForEach` 会不会给不可见行也生成组件」(**2026-10-07 已答:不会** —— `uitest dumpLayout` 在 1400 句那一页只数到 15 个稿行节点,首屏 9 个)与「macOS `row()` 每行读一次计算属性」(仍未测,本机跑不了 macOS 产物)。逐条见 H137

17. **`macos/package.sh` 的验收只打印不断言** —— 判据词计数(`:95-98`)与 `minos`/`sdk`/架构(`:106-107`)都只展示,"报非 0 才算数"靠人眼;dmg 文件名写死 `-universal`(`:122`)而 `ARCHS` 是可改的(`:21-22`)⇒ 正是 1.0.2 那个"名字叫 universal、实际单架构"的形状。<br>**✅ 2026-10-06 验收段抽成独立脚本 `macos/verify-bundle.sh`,每条判据改成累计 + 非 0 退出**:`package.sh` 只调用它(`set -e` ⇒ 断言不过直接不出 dmg),dmg 的架构标记改由 `EXPECTED` 推导(多于一个才写 `universal`)。判据形状也做了两处收紧:架构与语言都改成**集合相等**(缺 x86_64 要拦,只期望 arm64 却编出 universal 也要拦),签名从 `codesign -dvv`(只读描述)换成 `codesign --verify`。<br>**为什么单独成文件**:断言写在 `package.sh` 里就永远要走过 `swift build` 才执行得到,而这台开发机走不通(AGENTS.md 那六层)⇒ 它的有效性会一直停在"等下次出包顺便看看"。拆出来之后配 `macos/tools/selftest-verify.sh`(**只依赖 CLT 自带的 clang/lipo/codesign/plutil**,本机可跑):手搭假 bundle 跑正向,再把八类失败形状逐个弄坏 —— 少一个判据词、`.strings` 语法坏、**整套 .lproj 少一门**、单架构冒充 universal、反向(多架构)、缺 `CFBundleVersion`、签完名再改二进制。<br>验收=本机 `pass=9 fail=0`;外加一个**真产物对照**:拿归档的 `dist/余音-Reverb-1.0.2-arm64.dmg` 跑,报 12 条不通过(缺 x86_64 + 11 个词全 0)、版本号与四套 `.strings` 全过、exit 1。<br>写变异的时候**先抓出四条我自己写错的断言**(可执行文件按 `.app` 目录名猜而非读 `CFBundleExecutable`;语言判据覆盖不到"少拷一门";`plutil -extract` 在键缺失时把报错打到 stdout,于是"非空即通过"把报错文本当成了版本号)—— 逐条见 H136。<br>**没跑过的**:"package.sh 全程 + 一个真 universal 包过断言",本机无 xcbuild,这一半要等 #59 在构建机上第一次跑。
18. **Android 渲染形状**(不是缺陷):`PlayerScreen.kt:86` 在顶层作用域 collect `position` ⇒ 播放中整屏 2Hz 重组(无解析,成本可接受);`components/Components.kt:396-399` 每次 `formatPubDate` new 一个 `SimpleDateFormat`。
19. `android/app/build/` 里有 `huaweiRelease` 残留产物(flavor 早已改名 `store`)—— 只在本地 build 目录,不进包;换机重建时按 `docs/LOCAL-ASSETS.md` 走。
20. **macOS 剪藏海报的保存是本族最后一处静默**(H157 那轮枚举时**留下没改**,任务 #121):`ShareCards.swift:238` 的 `saveWithPanel` 仍是
    `try? png.write(to: url)`,而同函数 `renderPNG` 返回 nil 时四个调用方(`FootprintView.swift:42/54`、`PlayerView.swift:376/380`、
    `PodcastDetailView.swift:171`)直接 return —— 于是"点了没反应"在这一格仍然成立。两端同位置都有提示
    (Android `PodcastDetailScreen.kt:146` 用 `share_failed`「分享图片生成失败」)。<br>**✅ 2026-10-07 已改完,但改法与当初预写的不同**:
    原句写的是"复用设置页那轮的 `Prompt` 枚举",实际把 `saveWithPanel` 的返回从 `Void` 换成
    `enum ShareCardOutcome { saved, cancelled, failed }` —— 因为这一格多一个两端没有的结局:**面板弹了而用户按取消**,
    它必须与失败分开(H147 / #99 同一条坑),而 `Prompt` 那套是"调用方自己判成败",承载不了"取消要静默"。<br>
    两条 tap-time 调用点各挂一句 `.alert`(标题即本地化 key):`FootprintView.swift:46/56`、`PlayerView.swift:387/57-59`;
    三处**后台预渲染**(`PodcastDetailView.swift:171`、`FootprintView.swift:61`、`PlayerView.swift:382`)**只写日志、不弹提示**
    —— 那一次渲染不是用户发起的动作,它自带的反馈是"分享按钮没出现"。渲染不出来时**不弹面板**(没有可写内容,弹了等于让用户白选一次)。
    `分享图片生成失败` 补进四套 `.strings`(199→200 键 × 4,`plutil -lint` 全 OK,键集两两 `comm -3` 0 差异),
    五语取值与两端逐字一致(含 en/fr 的弯撇号,按 H156 教训 ④)。<br>
    验收=`bash macos/tools/typecheck-diff.sh`:两棵树各 38 文件 / 同一份中性化各 9 类 / **两边都 0 错误** + 三个改动文件各注入一次阳性对照全部命中。
    ⚠️ **运行时一条也没有**(本机六层不够,见三-A)⇒ "失败会弹、取消不弹"这两条挂在 **#59**;逐条见 **H159**。<br>
    **顺带一条体检发现**:四套 `.strings` 里 `重试` 各出现两次(en 的 94 / 170 行),两处值相同 ⇒ 无影响、且 HEAD 就如此,不是本轮引入 ——
    记下来是因为下次键集体检看到 `dup=1` 会误判成新加的。
21. **「本机对 macOS 的最强验收」从此是脚本,不是手跑**(A2-3#17 的同一族:验收只打印就会漂)。
    `macos/tools/neutralize-sdk13.py` 把 9 类 14+/26-only 依赖的中性化固化下来(**每条规则不命中就 MISS 退出**),
    `macos/tools/typecheck-diff.sh` 强制「两棵树都 0 错误 + 类数相等 + 每个改动文件各注入一次阳性对照 + 打印未覆盖范围」。
    写的时候抓出三条自伤(见 H157):`/dev/stdin` 被回显成类数使"两边相等"恒真、`set -u` + 空数组在 bash 3.2 下炸、
    BSD sed 不认 `\s` 使轮播那三条 modifier 一条没删。**它仍然只证明类型**,运行证据依旧在构建机上(三-A / #59)。

#### A2-4 本轮**证伪**的子代理结论(留在这里,免得下轮又被当证据)

- 「macOS 批注上限独用 RSS 元数据、另两端用真实时长」→ 三端 `add` 都按 `durationSec*1000` 夹(见 A2-3#14)。
- 「批注三端出口都没排序」→ 三端都在 `addAll` 排;但**这句只对应用内手动恢复成立** —— 系统级备份还原是整份覆盖 `notes.json`,不经过 `addAll`,而冷启动的 `load()` 当时也不排序(2026-10-06 补,见 H138 与 A2-3#14);「`EpisodeNote.id` 键名漂移破坏互通」→ Android 序列化成 `noteId`,三端逐字一致。
- 「macOS 批注行的 `playAt` 没挂载」→ `LibraryView.swift:319` 挂着。
- 「鸿蒙 `bgFailed` 永久锁死」→ 全仓源码**无此符号**(只在 build cache 命中)。
- 「Android 恢复会让上/下一集错位」→ `next()/previous()/advanceQueue()` 全走内存 `queue/queueIndex` + `setMediaItem`,不依赖播放器 timeline。
- 「macOS 导出 history 用秒 ⇒ 跨端恢复不一致」→ 单位差异是 H86 记录过的既有事实,**三端解码各自归一**(Android `BackupManager.kt:160/190`、鸿蒙 `BackupManager.ets:253`、macOS `Models.swift:62`),不构成分叉。
- 「备份文件里分区的出现次序是跨端契约」→ 三端都按**键名**读,次序不参与解析;Android 走 `org.json.JSONObject`(HashMap)本来也不保证写出顺序。这句说法在 `BackupManager.swift:7-8` / `BackupManager.ets:12-13` 的注释里写重了。

**这一节的验收方式**:每条都是「读源码 + 行号」级,唯一跑到包内取证的是 A2-1#3(解包 grep,处理量已随结论一起给出)。
**没覆盖的范围**:没跑任何一端的应用、没看 UI、鸿蒙那条没解 `reverb.app`(只有 release hap);`docs/HISTORY.md` 与两份中文关于页文案没有逐字复读。

### B. 平台限制导致的功能缺口(**短期不打算解决**)

| 项 | 原因 |
|---|---|
| macOS / 鸿蒙无**真实频谱** | 无等价的系统混音抓取能力。鸿蒙的 `SOURCE_TYPE_PLAYBACK_CAPTURE` 自 API 12 废弃,官方改用需录屏授权的 `OH_AVScreenCapture` —— **为一个封面动效索取录屏权限不成比例** |
| macOS 无**后台更新巡检** | 无 WorkManager 式机制;靠「最新」手动刷新 |
| 鸿蒙无**本机语音转写** | 系统 Core Speech Kit 的离线档是给短语音输入设计的,实测 10 分钟单集只出 14 行碎片(见 `TROUBLESHOOTING.md` H62)。`Features.LOCAL_ASR = false`,**换引擎之前不要打开** |
| 无**应用内升级** | 需要 CDN 托管分发 |

### C. 产品层面的现实约束

- **中文播客基本没有官方逐字稿**:实测 15 个中文 feed,`podcast:transcript` **零命中**。
  这意味着大陆商店版与鸿蒙端的逐字稿功能**对中文内容实际可用率很低** ——
  文案已如实限定为「发布方提供逐字稿的单集」,但这是个真实的体验落差。
- **自分发版 64 MB 的体积**几乎全是语音模型。对「一个安静的小工具」来说偏重,
  但去掉它中文用户就没有可用的逐字稿。
- **零后端 ⇒ 没有跨设备实时同步**:迁移靠两条路 —— 手动备份文件(合并语义),
  以及 1.0.2 起的**系统级备份**(数据进用户自己的云,由操作系统执行,仍是
  备份/恢复而非同步;见 H84)。不引入账号体系的约束没有松动。
- **不是所有节目都搜得到、更不是都适合内置**:个别节目因版权/合规原因不适合进
  任何商店包或官网 OPML(备查结论与RSS地址记在本地运营手册,不在此文)。
  手工精选机制本身是 `gen-seed.py` 的 `MANUAL_PODCASTS`(唯一事实源,重抓榜单时保留),
  手工条目仅进 Android default 渠道与 macOS 的种子清单。

### D. 技术债

| 项 | 何时会疼 |
|---|---|
| **鸿蒙「发现页分类排序」** —— 排序本体 + 备份那一半 ✅ 已移植(2026-10-06) | 排序框、`CategoryStore.ets`、`category_order` 落盘都已与 Android 逐句对齐(`loadOrdered`/`saveOrder` 两条口径含"空顺序不覆盖已有" —— 鸿蒙侧原先是 `save('')` 写空串,行为分叉,已改成早退),分类条右端 `Tune` 入口同位同图标。**备份侧也已接**:`categoryOrder` 两端都导出、恢复都消费(空数组=不动本机顺序),见下一行。鸿蒙还有一条已知差别如实留着:排序框的遮罩只覆盖发现页区域,底部玻璃 tab 栏仍在遮罩之上(Android `AlertDialog` 是整窗)。<br>✅ **2026-10-07 真机走完**(慢速 `uiInput drag`、velocity 200 同时满足 `LongPressGesture{500ms}` + `PanGesture`):首行下移一行、再拖第二行上移两行 ⇒ 草稿过半才换位且两次都对;「完成」→ `[Category] 保存顺序 19 项` + chip 行当场变序;冷启动(force-stop 后 `pidof` 由空到新 PID)读到 `[Category] 自定义顺序 19 项`、chip 序保持;「取消」那一路丢弃草稿 ⇒ 设备末态已拖回默认序。**两处图标当场截图核过字形**(鸿蒙 `sys.symbol.*` 写错不报错、直接画空白):分类条右端的「排列」入口 = 两颗滑钮、排序框行末把手 `line_2_horizontal` = 两条横线,均正常渲染。待验清单里只剩那条已知差别(遮罩只覆盖发现页区域) |
| **手动备份 settings 分区跨端互通** —— ✅ 两端逐键对齐,**且双向恢复真机跑完(2026-10-07,28 项断言 0 ✗)** | **改前两端各有一份"自己导出、对方读不到"的键**:Android 不导 `language` / `subsGrid` / `contextualRadio`(本端三项早就有,只是从没写进备份 ⇒ 从 Android 换到鸿蒙时语言、订阅排列、电台模式全部回到默认);鸿蒙不导 `fontScale` / `allowCellularDownload` / `updatesEnabled` / `categoryOrder`(存的是本地编码 `font_index`,且那四项压根没进分区)。**改后两端 SETTINGS 段键集逐键相同**,恢复侧也都读全(见 `docs/FEATURES.md` 九节那条键清单)。四条口径值得记住:<br>① **契约是键名与类型,不是本地存储格式** ⇒ 字号同时写 `fontScale`(倍率,跨端键)与 `fontIndex`(给已发布的旧鸿蒙回落),恢复时**倍率优先、下标兜底**(先后反了会让同一份文件在两台机器上落出两档字号且谁都不报错);② **键名以已发布的那一端为准**(Android 1.0.2 在外是既成事实;鸿蒙 1.0.3 在架但它的 settings 分区此前只有本端读写过,改它不破坏现存备份);③ **"自动"的两端表示法不同**(Android `regionOverride` 是 JSON `null`、鸿蒙是 `""`),靠 `J.str` 对 null 返回 `""` 天然桥接,没加特判;④ **语言标签词表两端本来不同**(Android `zh-CN`/`zh-TW` vs 鸿蒙 `zh-Hans`/`zh-Hant`)⇒ 统一到 Android 那一套,并在**读盘 + 写入两处归一**,否则升级后 1.0.x 老用户的语言在界面上显示成「跟随系统」。<br>同批还改掉:鸿蒙恢复备份后**不重排订阅更新任务**(原先 `applyRoot` 的返回值被丢掉 ⇒ 备份里开着提醒、本机没开时,Toggle 显示开而 workScheduler 里压根没那个任务,界面承诺了一件不会发生的事),现在与 Android `SettingsScreen.kt:461-464` 逐字同构地按新值 schedule / cancel。<br>✅ **2026-10-07 真机走完这一条**,而它一跑就跑出**两条只在真机上看得见的缺陷**(细节在 H152 / H153,这里只登记结论与没覆盖的部分):<br>① **`cancel()` 从第一天起就没生效过** —— `workScheduler.stopWork` 在本机 SDK(6.0.2(22))上**五种参数形状全部 401 `The workinfo condition cannot be empty`**(原生层每次都是 `Set none conditions`),所以"关掉提醒"以前只改了显示;改用唯一实测有效的 `stopAndClearWorks()`(只读探针数在册任务:调用前 1、调用后 0)。**它清的是本应用全部延迟任务 ⇒ 成立前提是"本端只注册这一个 work"**,该前提写在 `schedule()` 上方。<br>② **恢复备份会弹系统通知授权框并把刚导入的值改回去** —— ArkUI 的 `Toggle.onChange` 对**程序化赋值**同样回调(硬规矩 9 在控件回调层的形态),于是恢复 → 重渲 → `onChange(true)` → 走进用户路径 → 索取授权 → 被拒 → 回写 false → 又一次回调 → 取消任务;两个回调实测相差 8 ms。修法是在 `onChange` 里先与存储值比一次、相等即视为程序化翻转(不加 `suppress` 标志位)。<br>验收取证:恢复 ue=true → `已注册`、prefs 变 true;恢复 ue=false → `已取消`、prefs 回 false;整段无 401;同一份 ue=true 连恢复两次第二次打 `已在册,无需重复注册`(原生层同毫秒 `970000501`);恢复那一路 `requestEnableNotification` **0 次**;手指手拨那颗开关仍照常走到授权请求。**没覆盖**:Android 侧 `WorkManager.cancelUniqueWork(UPDATE_WORK)`(`ReverbApp.kt:155`)本轮没重跑(不同接口,这条 401 不迁移过去,但"关掉之后任务真的不在了"在 Android 上同样只有实跑才知道)。<br>✅ **跨端恢复那一步已双向真机跑完(2026-10-07),28 项断言 0 条 ✗**。此前挂"未跑"的卡点**不是工具不足,是选路选错了**:恢复走 `Files.pickText` → `DocumentViewPicker`,它浏览的是**媒体库 Docs**(`/storage/media/100/local/files/Docs/`)而不是应用私有沙箱,所以把备份塞进沙箱选择器看不见;`hdc file send <本地> /storage/media/100/local/files/Docs/` 直接落得进去(属主 `20001006`,与选择器自己写出的那份同属主),选中后应用**真的读到了内容** —— 日志 `[picker] document select … errorcode is = 0` + 返回 URI,28,930 行 hilog 里 `恢复解析失败` **0 次**;内容只有 `{"probe":"send-test"}` 的探针文件走的是「无法识别的备份文件」那一支,**"文件读不出/解析失败"与"读出但不是备份"在日志上分得开**,这一支才是"通了"的证据。**跑法**(两端原本设置完全相同,直接交叉恢复验不出东西 ⇒ 先把每端各 ≥2 个键改成与对方不同的值,再拿对方那份恢复,然后**逐键**核对 —— 本端自产自读永远测不出"导出少写了一个键"):Android 导出 14 键 → 鸿蒙恢复 → 读 `preferences/reverb_settings`;鸿蒙导出 14 键 → Android 恢复 → 读 `reverb_settings.xml` **+** `reverb_prefs.xml`(**Android 有两个 prefs 文件**,`category_order`/`region_override` 落在后者,鸿蒙只有一个);界面侧当场同步生效 —— 鸿蒙转深色,Android 整页转浅色·宣纸 + 字号「特大」+ 快进 30 秒并弹「恢复完成」。<br>**两条跨端口径实测确认**:① 字号**两端都优先 `fontScale`、下标 `fontIndex` 回落**(见 `BackupManager.kt:237-246` / `BackupManager.ets:339-351`),所以同一份文件不会在两台机器上落出两档字号;② `categoryOrder: []` 在两端都是**"不动本机顺序"的有意语义**(`save()` 对空数组早退),核对时不要当失败。三个操作坑(选择器「文档」芯片查的是媒体库索引、SAF 宫格 `dump` 的 text/bounds 会错一格、Android 两个 prefs 文件)记在 **H149 的第三层补记**。<br>判据原文 = 拿一份 Android 导出的 `reverb-backup.json` 在鸿蒙恢复,逐项核对深色态、字号档、语言、仅 Wi-Fi 开关、更新提醒开关、发现页分类顺序;反向(鸿蒙导出 → Android 恢复)同样要跑一遍 —— 两侧都跑了。**两端共有一条窄窗口**:恢复路径都不重新索取通知授权 ⇒ 备份来自另一台机器时可能排上了任务而通知发不出去 —— 两端一致就不算漂移,要修得两端一起修。(⚠️ **这句在 H153 之前其实不成立**:恢复会经由 `Toggle.onChange` 的级联"替它"索取一次授权,还顺带把刚导入的值改回去。修完之后它才是真话 —— 恢复那一路日志里授权接口 0 次调用。)<br>✅ **同一天把最后一格「分区勾选对话框」补齐(#90)**:鸿蒙导出与恢复各加一个 `BackupSectionDialog`(交互逐项对齐 Android:导出**先弹框再选保存位置**、恢复**先选文件→探测分区→再勾**、打开即全选、点行翻转、一个都不勾时「备份/恢复」不可点、探测不到分区报 `backup_invalid`)。**这是"给鸿蒙加",不是"把 Android 的勾选删掉"。**<br>同批两处顺带对齐:① **取消文件选择与"读不出来"分成两条路**(改前两者共用 `backup_failed`,于是按了取消也会看到"操作未完成";Android 的 `uri == null` 本来就是静默的)⇒ `Files.pickText` 的返回值从 `string` 或 `null` 改成 `PickedText{cancelled,text}`,OPML 导入同口径;② 分区名从复用各功能页标题改成专键 `backup_row_*`,**13 个新键 × 5 语种与 Android 逐字比对通过**(2026-10-06 装机之后把这条判据换成了"按白名单逐语种比值"的脚本:本分支鸿蒙侧新增 **33 键 × 5 语种 = 165 次比对,32 键五语全等**,唯一偏差 `set_mail_log_sub` 是有意的能力差异、`backup_done`/`backup_failed` 两端同键不同值也是有意的,逐条见 **H147**。顺带否掉一种看着更省事的做法:**两端键名从来不是一套**(整表键名差集实测 93 / 89 个,绝大多数是 `cat_*` vs `genre_*` 这种同名不同键),所以整表差集在本仓库不是有效判据)(复用旧键会让同一格出现"下载"vs"下载(仅节目链接)"、"听觉足迹"vs"听觉印记")。<br>**一条有意保留的差异**:Android 把勾选结果记在页面状态里、下次打开还在;鸿蒙每次打开回到全选 —— 少一处看不见的"上次勾了什么"。<br>❌ ~~同样只过到编译,一次都没点过~~ ⇒ **2026-10-06 已装机全部点过,六条判据全过**(逐条证据在 H141 的验收段:8 行两轮、半透明那颗的 `opacity` 实测 1.0→0.38 且零日志、`导出 分区=2`、旧备份恢复框 `rows=2` 无「批注」行、取消两条路均无提示、fr/es 各 8 行无裁切)。判据原文:① 只勾「收藏」导出 → 文件里应只有 `favorites`,日志 `导出 分区=1`;② 只勾「设置」恢复 → 日志不该出现「恢复订阅/恢复历史」那些行,本机订阅数不变;③ 全不勾时确认那颗是半透明、点了不弹保存面板也不写数据;④ 拿一份不含批注的旧备份,框里不该出现「批注」那一行;⑤ 取消选择器 → 界面没有任何提示;⑥ fr/es 长标签下 8 行不裁切、不顶到按钮。**③⑤⑥ 与 ①②④ 中"文件里到底有哪些分区"这一半是同日在真机上取的证;② 的"恢复不该出现别的行"未单独取证**(本轮只做了导出侧与恢复框的可选集,没做真实恢复 —— 恢复会改本机订阅数据,属不可逆动作,留作下一次装机窗口)。**同一轮另外修掉两条真机才暴露的:H146(「跟随系统」当场与冷启动都不生效)与 #99(取消保存被折成失败提示)。** |
| 一堆小 JSON、整体读入内存 + 整体落盘 | 订阅上千 / 历史上万条时;当前规模无感。**2026-10-10 其中一份已经动了**:`inbox.json` 改成「内存全量 / 落盘只留最新 300 条」,因为它的 `load()` 在 Application 主线程上,而内存侧的列表刚从 100 条变成数千条(见 H168)。**其余几份仍是整读整写** —— `history` / `favorites` / `notes` 的体量口径没变 |
| **追更那一列的「标记已播完」对没播过的集静默无效**(2026-10-10 全量化之后成为常态) | Android `markPlayed` 的实现是"在收听历史里找到那一集再改它的 played",找不到就 no-op;旧截断下这一列几乎全是带进度的新集,所以从没暴露。**现在整栏里"没播过的集"是多数**,于是那颗按钮点下去对多数行什么都不发生(无提示、无状态变化)。鸿蒙追更页压根没挂这颗按钮,所以本端症状不同但同根。**修法要定口径**:是"补一条已播完的历史"还是"这一列不摆这顆按钮",两个都要动五语,所以没在本轮顺手改。**何时会疼**:用户在这页找"怎么把它从这一列去掉"而点了没反应 |
| **macOS 的 inbox 没跟 2026-10-10 这一轮**(仍是每源 12 集 / 全局 100 条) | `macos/Sources/Reverb/Data/InboxStore.swift` 的 `perFeedCap=12` / `maxCount=100` 已 grep 确认还在 ⇒ **"追更 = 全部订阅频道的全部单集"这句在桌面端不成立**,而 `docs/PRODUCT.md` / `docs/FEATURES.md` 现在写的是两端口径(macOS 那一列已在两处用 ⚠️ 点名)。**为什么不在本机改**:本机出不了包也跑不了产物(AGENTS.md「macOS」一节六层实测),而这一条要验的是"几千行列表在桌面上滚起来怎样"——改了也证明不了。**何时会疼**:macOS 下一次出包时要么一起改、要么文档再漂一次 |
| **换 tab 后上一格的内容「松手闪」一下** —— 观感缺陷,**机制未定位**,只登记现象与取证方案(2026-10-09 用户指出) | **现象**:底部三格里从一格切到另一格,**手指抬起的那一瞬间**,上一格的内容会闪一下。**目前只有手指报告,没有一帧仪器证据** —— 所以这一行不许写成因,只能写"已经读过的那三层机制 + 两个待排除的候选"。<br>**读到的现状**(Android,`ReverbRoot.kt`):三格不走导航栈、叠在同一个 `Box` 里(H117 那轮为了"切走即销毁 ⇒ `Skipped 31 frames`"改的),隐藏那一页由 `Modifier.tabKept(hidden)` 实现 = `drawWithContent { }`(**直接不画**,注释里明确写了它比 `graphicsLayer{alpha=0f}` 省,因为后者仍要把整棵子树画一遍再乘 0)+ `clearAndSetSemantics{ }`;谁在上面由 `.zIndex(if (selectedTab==i) Z_VISIBLE else Z_HIDDEN)` 决定;手势由夹在内容与栏之间那道**吸收层**(`Z_SHIELD`)挡。**⇒ 这条链里压根没有 alpha 动画**,所以"闪"不可能是淡入淡出没做完。<br>**两个必须逐帧才能分开的候选**(都还是猜):① **同帧内 `zIndex` 换档与 `drawWithContent` 生效的先后** —— 若某一帧两张页都还在画,就会被看成"上一格闪回来一下";② **该页自己那一帧的内容变化**(切格会连带 `LocalGlassBottomPad`、分段条滚动位置、迷你播放条 `AnimatedVisibility` 这些共享外壳的量,可能让刚显示那页重排一帧)—— 两者修法完全不同,不能凭观感选。<br>**取证方案(修它之前必须先跑通)**:松手前后连续截图并**保证文件名唯一**(H167 第三条就是这条:第一版脚本每帧都写同一个名字,读出来的"逐帧不变"是假象)、按帧号排好再差分相邻帧,判据写成"从按下到抬起之后 N 帧里,隐藏那页的像素集合不该出现在任何一帧"。**这一条上报时没说是哪一端在场,所以两端都要按各自机制查**(不要当成"某端专属"):Android 的隐藏是「叠层 + `drawWithContent{}` + `zIndex` 换档」;鸿蒙走的是 `Tabs` + `TabContent`(`Index.ets:431`,`barHeight(0)` 隐掉系统 bar,底部栏由 `GlassTabBar` 悬浮)—— **两套隐藏机制完全不同,"闪"的成因也就不是同一个候选**,取证第一步是先在其中一端复现出来,再谈修法。<br>**为什么不塞进 1.0.4**:这是观感类改动,判据只能是拇指(与 #31 / #35 / #36 / #37 同批等待),而 1.0.4 已为末轮改动重打到第十二次并整条复跑过解包验收 ⇒ 排 1.0.5,和那几条"待拇指"一起在一个装机窗口内做掉 |
| **中文串的半角标点 + 三个共享键两端的措辞漂移**(2026-10-07 数出来,刻意排在 1.0.4 之后) | 同口径扫(含 CJK 且串里有 `, : ; ? !`,排除 `%s`/长数字后逐条回读)量出来:**鸿蒙 zh 两套各 18 条、Android zh 两套各 6 条**,最该改的一条是鸿蒙的 `privacy_consent_asr`(隐私同意页正文,用户会逐字读)。同批读到 3 个共享键的措辞漂移:`mark_played`/`mark_unplayed` 简繁差一个「为」(该改鸿蒙)、fr 是 `lu` vs `écouté`(**该改 Android**,播客不是书)、`queue_empty` 五语整句不同。**为什么现在不动**:全是标点与措辞,**零功能差异**,而按出包门第 5 行的口径改了就要两端三包各重打并复跑整套解包判据 —— 为一串逗号把已经九次验收过的 1.0.4 发布包再走一遍不值,这一版正卡在上传前。**1.0.5 那一批怎么做**:`H156 补记二` 里有逐条清单与判读,口径要先形态归一再按同句分层(原口径那半条已被 `queue_empty` 推翻,它同时属于两层)。**会疼的时机**:下次有人改这些键时会照着现有的半角写法继续加,数量只会更多 |
| **鸿蒙从未订阅 `AVPlayer.on('audioInterrupt')`** —— 「被对方打断」这一路在应用侧没有任何处理(2026-10-07 读码定位,与三-A 焦点那一行同源) | 现状是:只在自家播放生命周期内 activate/deactivate `AudioSession(CONCURRENCY_PAUSE_OTHERS)`(`PlayerController.ets:584-602`),`audioInterruptMode` 设 `SHARE_MODE`(`:561`;H80 已写明它只管**进程内**中断单元,不是跨应用并发策略)。事件侧只绑了 `timeUpdate` / `stateChange` / `durationUpdate` / `bufferingUpdate` / `error`(`:626-642`)。**后果**:对方把焦点拿走时,停不停由系统的会话策略决定,而余音**不知道自己为什么停了**,更没有"对方释放后接着放"的路径 —— 用户只能回页面再按一次。对照端**有库兜底且解包可验**:Android 本仓库零自写焦点代码,`AudioFocusManager` 在两个渠道 dex 里各命中 4 次、`onAudioFocusChange` 各 2 次(见三-A 那一行)。**接口可用性已核**:`@ohos.multimedia.media.d.ts:3592`,`@since 9`,本工程 `compatibleSdkVersion 6.0.2(22)`。<br>**动它之前必须先有一次真机的被抢占取证**,否则任何写法都是猜 —— 现在连「系统打断时 AVPlayer 自己会不会进 `paused`、`stateChange` 有没有跟着上报」都不知道;而这条决定了要不要区分「因焦点而停」与「因用户而停」两个状态(不区分就会和 `playbackDesiredPlaying` 打架,H80 那套代次串行可以照搬)。<br>**取证的卡点不是工具,是设备**:第二家应用要既能被 `uitest` 驱动、又读得到本机音频,而 `hdc shell` 写不进媒体库(`/storage/media` Permission denied)、`/data/local/tmp` 对方应用读不到、`anco_audio` Permission denied ⇒ 需要一台已登录、可直接播放的对照设备,或两台机器。**Android 侧「重新拿到焦点会不会自动续播」我没有逐行读库源码**(只核到类与方法在包里),所以"该不该照 Android 对齐"这句话还不到能写的时候 |
| **fr/es 真机通读(2026-10-08,H160)读出来三条:① ② 当天已改完并重新出包,只剩 ③** | ① **许可页与数据来源的中文硬编码 —— ✅ 已拆成资源键 × 五语(两端)**。Android:`LicensesScreen.kt` 的顶层 `val LIBS/SOURCES` 改成 `@Composable fun libs()/sources()`(顶层 val 拿不到 `stringResource`),需要变种的四条走 `lic_whisper` / `lic_whisper_model` / `src_publisher_rss` / `src_site_opml` 五套 `main/res`;**并且 `src/store/res` 五套各覆盖成空串** —— 因为资源**不参与 R8 的 DCE**,只靠 `HAS_ENGINE=false` 那一支删不掉 arsc 里的文案,于是 store 包会同时"没有识别功能"和"许可页写着 whisper.cpp(离线语音识别)"(H161 根因①)。鸿蒙:`LicensesPage.ets` 的顶层 `const` 改成 `buildLibs()/buildSources()` 并在 **`aboutToAppear` 取一次存字段**(顶层求值时 `L.init` 还没跑,`L.s` 的失败回落会把**键名**摆上界面;在 `build()` 里调则每帧过一边 resourceManager)。两端共用的 `src_*` 两条按渲染值**逐字比对过**(10 处全等;Android 那侧要先把它自己的反斜杠撇号还原成裸撇号再比,否则每条带撇号的都误报漂移)。**解包验收**(数字见 H161 验收表):`whisper` 裸词在 store 是 arsc **0** / dex **0**,在 default 是 **11 / 4** —— 两渠道同源、只差那五个空串覆盖,这个对照本身就证明了覆盖生效,不必再造一个"不覆盖"的包。② **两端 fr/es 小数分隔符不一致 —— ✅ 已对齐(改的是鸿蒙)**。新增 `harmony/entry/src/main/ets/util/NumberFmt.ets`,按 `i18n.System.getAppPreferredLanguage()`(空=跟随系统,回落 `getSystemLocaleInstance`)构造 `intl.NumberFormat`,**实例按语言 tag 缓存**(调用点在播放页,播放中约 500ms 一次重渲,硬规矩 6),三个调用点(播放页 chip、倍速菜单、设置默认倍速列表)改完。方向选的是"把鸿蒙拉到 locale"而不是"把 Android 强改成点":非整数倍速在法/西里本来就该带逗号。①② 共同的欠账:**只过了编译 + 解包 grep,界面一屏没看、真机一个串没取** —— 要装本轮的包(两台机器上现在都还是本轮之前的包)。③ **两条需要母语者判断、机器给不出结论**的同形词仍在:`genre_truecrime` 法文写作 `True Crime`(Apple Music 用 *Histoires vraies*)、`region_short_auto` 西文写作 `Auto`。同轮的两条结案一并记在这儿,免得下次又被当缺陷重开:非本地格式的日期**两端同形**(既有口径)、西语 `Huella de escucha` / `sellos` **双名三端一致**(设计) |
| **官网隐私页只有一份简体中文,而五语的 `privacy_url` 都指向它**(2026-10-08 从界面反查 URL 才发现) | 实测 `site/reverb/privacy.html` 是 `<html lang="zh-CN">`、`hreflang` **0 个**;而两端**五语 × `privacy_url` 共 10 处命中的是同一个 URL**(逐条读过)⇒ 法/西/英用户从隐私同意页与关于页点开的政策正文是中文。界面侧完全看不出来(链接渲染正常),**判据只能从"资源里的 URL"反查到"站点文件的语言"** —— 这个方向以后固定下来。**为什么不在本轮改**:这是站点工程 + 部署的活,而部署那一步有三个副本、`rsync` 那条命令原样跑一遍线上一行都不会变(见 H144);要么补四语页面并按语言分流 `privacy_url`,要么先在英文页里给出可得语言的最小说明。两条路都要维护者点头 |
| 鸿蒙 `PcmReader.read()` 是**同步阻塞**的 | 目前跑在 `await` 链上、后面紧接更慢的识别会话,观感可接受;真发现掉帧要把整条转写搬进 TaskPool(注意 native 句柄不能跨线程传)。**取源与 RSS 解析已在 TaskPool 里**(见 H65),可照 `net/FeedTask.ets` 的写法 |
| 子线程里的日志进不了 App 内「分享日志」 | `Log` 的内存环形缓冲是每线程一份。RSS 解析搬进 TaskPool 之后,那些行只在 `hdc shell hilog` 里看得到 —— 用户导出的日志会缺这一段,排查用户报障时要知道 |
| 鸿蒙其它 `@Observed` store 未逐个复核观察粒度 | 这轮按现象定位到了 `PlayerController` 与 `ListenStatsStore`(H64),但**没有系统排查剩下的 store 有没有同类的高频字段**。判据:一秒变多次的字段不能留在被观察对象上。<br>**2026-10-02 复核补了一处同类**:`PlayerController.sleepRemainingMs` 每秒写(`:89` + `:1206-1214`)而只有睡眠 chip 读它 ⇒ 见 A2-2#9。其余 store 仍未逐个查 |
| **macOS 逐字稿的三处硬规矩落空**(缓存无 version / 不读官方稿 / 词级时间无出口不变式) | 见 A2-2#6⑦⑧。**2026-10-06 已修掉 #6 与 #8(同一批改动,见 H134),剩 #7「读发布方官方稿」——它已定路线:整块功能移植,排在 #59(构建机出包 + 运行验收)之后,不在本机做"编得过就当验过"的版本**。会疼的时机:改了组行或时间轴算法之后(旧稿永新作废不掉 —— 这条已经不疼了)、以及拿 macOS 听有官方稿的英文集时(白烧几分钟 CPU —— 这条仍在) |
| **鸿蒙逐字稿用 `ForEach` 而不是 `LazyForEach`** —— 每档重渲要为整个数组跑一遍 itemGenerator(长稿实测 1345 句) | A2-3#16 已把 itemGenerator 内部的成本从 O(句) 压到 O(1),而**"每档到底生成多少个 ListItem"这件事 2026-10-07 在真机上有答案了:不是全量**。两条互相独立的证据:<br>① **控件树计数** —— `uitest dumpLayout -p /data/local/tmp/x.json` + `hdc file recv`,在那份 1400 句稿的页面上数到 **15 个稿行节点**(首屏 9 个),而 `List` + `ForEach` 的源有 1345+ 条 ⇒ itemGenerator **并没有**给不可见的行建 `ListItem`;② **重建计数器**(H149 那套) —— 这一页每秒重建 12 次(=80 ms 心跳本身)而"当前行"判定只跑 1 次/秒,手动滚动时也只有 3~6 次/秒,`jank=0`。<br>所以"换 `LazyForEach` 是结构性改法、需要给 `TranscriptStore.segments` 配 DataSource"这一层**在这条证据下不需要动**。仍要留意的是**它只覆盖 SRT 那一支**:词级高亮(Span)分支一次都没跑过,量词级的成本要换 Podcast Index 的 JSON 稿再测。与另两端对照:Android 是 `LazyColumn`、macOS 是 `LazyVStack`,都只构建可见行 |
| macOS `TranscriptPage.row(idx:seg:)` 里 `let cur = currentIndex` 是**每行读一次计算属性**(`segments.lastIndex(where:)` = O(句)) | 与鸿蒙改前同形状,只是被 `LazyVStack` 的"只求值可见行"挡住了,量级是 (可见行 × 句) 而不是 (句 × 句),所以不构成待修。**为什么不动**:本机对 macOS 的最强验收只有 typecheck 差分(见 H128/H130),这种"成本形状"的改动拿不上任何运行证据,改了也无法证明 —— 排在 #59 之后与 A2-2#7(官方稿移植)同一片地里一起处理更划算 |
| whisper.cpp 固定 commit | 升级后**必须重新在真机上量速度**,并复核 `token_timestamps` 行为 |
| 逐字稿缓存不进备份 | **有意为之**(可重生成、体积大),但换机后要重转一遍 |
| 鸿蒙有一部分是「补偿代码」 | native 解码模块、图标映射表 —— 不产生功能,只为对齐,升级 SDK 时要跟着维护 |

### E. 发布截图与物料

UI/文案一变,截图与对外物料就会过期 —— 但它们是本地运营物料,**不在仓库里**;
重拍口径与逐版记录见本地运营手册。仓库内只需记住:**改界面时把「物料要重做」计入影响面**。

---

## 四、演进方向

### 先说筛选标准

这个项目的性格是靠**拒绝**维持的。任何候选功能先过三道闸:

1. **要后端吗?** 要 ⇒ 不做。
2. **要接三方 SDK 吗?** 要 ⇒ 不做(系统能力不算)。
3. **不联网时还有意义吗?** 没有 ⇒ 降优先级。

已经因此明确**放弃**的:「余音 · 此刻」(实时在听人数 / 弹幕)—— 需要后端;
账号与云同步;推荐算法与信息流;第三方登录与分享 SDK。

### 近期(把已有的做扎实)

| 方向 | 说明 | 代价 |
|---|---|---|
| **鸿蒙接 whisper.cpp** | native 解码链已就绪且真机验过,换掉 `SpeechTranscriber` 即可;`Features.LOCAL_ASR` 一处开关 | 包体从 952 KB 涨到 ~60 MB。**这是鸿蒙端体验的最大单点提升** |
| 补齐没验过的路径 | 尤其鸿蒙的官方稿路径(见三-A) | 低 |
| 逐字稿**全文搜索与跳转** | 有稿之后自然的下一步:搜一句话直接跳到那一刻 | 低,纯本地 |
| 逐字稿**导出**(文本 / Markdown) | 走系统分享,符合既有约束 | 低 |
| **章节支持**(`podcast:chapters`) | 与逐字稿同一性质:发布方在 RSS 里给的结构化数据,拿来用即可 | 中 |

### 中期(体验纵深)

- **单集内书签**:与「剪藏」互补 —— 剪藏是对外分享,书签是给自己回看
- **订阅分组 / 标签**:订阅到几十个之后按分类分页已经不够用
- **持久化播放列表**:现在的队列是临时的,关掉就没了
- **静音跳过 / 语音增强**:纯 DSP,不需要联网;但要小心别把播客的呼吸感处理掉
- **均衡器**:平台原生能力,三端都有

### 长期(平台与形态)

- **iOS / iPadOS**:macOS 那套 Swift 数据层与播放层**可复用大部分**,UI 需重做。
  是投入产出比最高的一次平台扩展
- **CarPlay / Android Auto**:播客的重要场景;但会引入新的平台合规面
- **手表端**:只做播放控制,不做浏览
- **零后端前提下的跨设备同步**:系统级备份(1.0.2)已把「用户自己的云」这一档
  覆盖掉;剩下的方向是**文件级**同步
  (iCloud Drive / 共享目录 / 局域网直传备份)。macOS + iOS 之间最自然,
  Android 与鸿蒙受沙箱限制大。**不引入账号体系是硬约束**

### 一条与政策相关的分支

大陆商店版当前约 85% 的功能范围**不是单一总开关**:首版已恢复在线分类榜、关键词检索与电台,
但仍不打包内置种子、本机转写与真实频谱。这样做是一次分发策略选择,不是合规风险消失:
若分发渠道明确要求纯 RSS 工具口径,只回退 `CATALOG`,不要连带改变 `SPECTRUM` / `LOCAL_ASR`。

Android 可通过 `BuildConfig.CATALOG` + R8 回退目录代码,但字符串 source set 仍要逐项核对;
鸿蒙**没有 DCE**,不能只关 `Features.CATALOG` —— 必须把目录实现移出 `Sources.ets`
所在的编译树。无论恢复还是回退,都要按 H70 解包 grep 验证期望值。

---

## 五、如果只做一件事

**接鸿蒙的 whisper.cpp。**

理由:鸿蒙是三端里唯一只经商店分发的,也是当前功能最少的一端;
而它缺的那一项(本机转写)恰好是中文用户唯一能真正用上逐字稿的方式
——毕竟中文播客几乎没有官方稿。而且这件事的**前置工作已经做完了**:
native 解码链写好、真机验过、迁移路径写进了 `TRANSCRIPT.md`,
剩下的是把引擎链进同一个模块。
