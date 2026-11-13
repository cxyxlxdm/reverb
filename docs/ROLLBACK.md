# 回滚预案

> 2026-11-13 起草。此前 `AGENTS.md` 只登记了「回滚预案目前没有」这个缺口
> (`docs/REVIEW-2026-10-18.md` P0 第 7 条),没有正文。本文是那份预案。
>
> **它没有演练过。** 下面每一步的机制都来自代码与各平台的分发规则(行文处标出处),
> 但"照着这份文档真的把 1.0.8 退回过一次"这件事还没发生 —— 见 §八。

---

## 一、先定"什么算该回滚"

回滚是**贵**的:Android 要走商店重审、鸿蒙要重新提交、iOS 要重传一次 TestFlight。
所以先按判据决定,不要因为一条差评就退版本。

| 触发 | 例子 | 处置 |
|---|---|---|
| 装不上 / 起不来 | 启动即崩、签名不符、ABI 缺失导致全量设备无法启动 | **回滚** |
| 数据损坏或不可逆丢失 | 升级后订阅/批注被清空、备份恢复失败 | **回滚**,并尽快出修复版 |
| 大面积功能性故障 | 播放、订阅刷新、同步在多数设备上不可用 | 先看能否用服务端无关的热修(重建包)解决;不行才回滚 |
| 合规 / 审核问题 | 商店以权限、自更新、隐私披露为由拒审或下架 | 按渠道处置:商店侧整改重提,自分发侧不一定要退 |
| 单设备 / 偶发 | 某一型号的显示错位、一个源偶发失败 | **不回滚**,进 `TROUBLESHOOTING` 修在下一版 |

---

## 二、唯一口径:回滚 = 用旧代码出一个**版本号更高**的包

四端都按「版本更高才提示更新」工作,所以**不能**靠"把下载页指回旧包"来让已装新版的用户退回去:

- Android 应用内更新读公开仓的 release **列表**(不是 `latest` 指针),按版本名逐段比大小,
  只有**远端更高**才提示(`SelfUpdate.isNewer`, `android/.../update/SelfUpdate.kt:655`);
  同版本名不同字节另有 digest 兜底(`isRepublished`)。
- macOS 自更新同样取列表里**有 dmg 资产的最高版本**,并且只对更高版本提示
  (`macos/Sources/Reverb/Update/SelfUpdate.swift:177-208`)。
- 商店(Android 大陆市场 / AGC)只接受**更高 versionCode** 的提交;已上架的版本收不回来。
- iOS 只能上传**更高 build number** 的构建,TestFlight 的构建号不可复用。
- 鸿蒙**没有应用内更新**,只走商店;release 包 hdc 侧载会被签名信任边界拒绝(见 H216),
  所以回滚包只能经市场渠道下发,本地验证用 debug 包。

**因此回滚的正确形态是**:取上一版源码(或上一个 tag)→ 把四处版本号改成
**比坏版本更高** → 出包 → 按正常发版流程上传。例如 1.0.9 坏了,回滚包就是
"1.0.8 的代码 + `1.0.10` 的版本号",不是"把 1.0.9 换成 1.0.8"。

⚠️ 这样做的代价必须写在 `CHANGELOG.md` 里:那个版本号对应的代码与序号不对应,
下一个人读代码史会以为 1.0.10 带来了 1.0.9 之后的新功能。

---

## 三、各端"上一版"从哪取

| 端 | 现役发布物 | 上一版取处 | 校验 |
|---|---|---|---|
| Android(GitHub 自分发) | `android/dist/reverb.apk`(上传到公开仓 `revert-cast`) | 公开仓对应的 tag:`gh api repos/cxyxlxdm/revert-cast/releases/tags/<tag> --jq '.assets[]\|"\(.name) \(.size) \(.digest)"'` | 资产 `digest` 与下载后 `shasum -a 256` 逐字相同(字节数相等不算) |
| Android(大陆商店) | 同一份 apk 的商店侧副本 | **只能从商店后台取**,公开仓那份与商店那份不是同一个文件(合并 flavor 后是同一份代码,但分发各存一份历史) | 商店后台的包体摘要;本地 mapping 另见下一行 |
| Android 的 mapping | `android/dist/` 里只留最后一次构建 | `android/dist/_archive/`(每次重打前按日期归档,见 §五) | 文件名带版本 / versionCode / 时间戳;与那次构建同批 |
| 鸿蒙 | `harmony/dist/reverb.app` + `reverb-symbol.zip` | **市场后台**;本地归档可能在 kit zip 里:`harmony/dist/_backup-*kit*/*.zip`(`unzip -l` 数得见 `reverb.app` 与 `reverb-symbol.zip` 两个条目) | 以上架后台的摘要为准;kit zip 不是"素材",按发布物待遇核(H204) |
| macOS | `macos/dist/余音-Reverb-<版本>-universal.dmg` | 本地 `macos/dist/` 保留了历史 dmg(如 `…-1.0.6-universal.dmg`、`…-1.0.7-universal.dmg`)与 `_backup-…-published-*`;官网下载页当前指向的也是其中一份 | 架构断言(`lipo -archs` 必须是 `x86_64 arm64`)+ `codesign --verify` |
| iOS | `ios/dist/reverb-ios-<版本>-<构建号>.ipa` | 本地 `ios/dist/` 历史 ipa;TestFlight 侧旧构建 **90 天过期**,过期后不可再提供给测试员 | 构建号与工程设置一致;`embedded.mobileprovision` 在、`codesign --verify` 过 |

**公开仓的 release 不删。**坏版本那份留着:它的 `digest` 是诊断"用户装的是不是那一份"的唯一凭据;
应用内更新读的是列表里的最高版本,删掉坏 release 并不会让已装它的用户自动降级(见 §二)。

---

## 四、按渠道的动作

### Android(GitHub 自分发)

1. 确认坏版本已经上过公开仓(否则用户装不到它,不需要回滚)。
2. `git checkout <上一个好的 tag 或 commit>`;在**分支上**改四处版本号中的 Android 那两处
   (`android/app/build.gradle` 的 `versionCode` / `versionName`),**只升不回**。
3. **先归档当前 `dist/` 的 mapping**(`build-release.sh` 会 `rm -f` 它,H204/H205):
   把 `dist/mapping.txt` 与在架包摘要复制进 `dist/_archive/`,文件名带版本、versionCode、时间戳。
4. `./build-release.sh` → 解包验收(`aapt2 dump permissions` 现算条数、`unzip -l` 四类条目、
   `apksigner` 证书 DN 不是调试证书)。
5. 打一个**更高的 tag**(如 `1.0.10`)传到 `cxyxlxdm/revert-cast`,资产名仍是 `reverb.apk`
   (应用侧按名字挑,不是取 `assets[0]`)。
6. 传完两条必查:`releases/latest` 等于新 tag;资产 `digest` 等于本地 `shasum -a 256`。
7. 用一台装着坏版本的设备实跑一次:冷启动 → 应用内更新提示 → 下载 → 安装器覆盖安装成功。
   ⚠️ 覆盖安装要求签名相同(本项目唯一 release 签名,`CN=Yuyin Reverb`),换签名会变成"必须先卸载"。

### Android(大陆商店)

1. 商店侧**没有"下架即回滚"**:已放量的版本只能以更高 versionCode 的新包覆盖。
   如果商店支持分阶段发布,先**停止放量**,把影响面锁在当前比例。
2. 用 §四-A 第 2~4 步的回滚包重新提交审核;审核期间商店在架的仍是坏版本,要在商店文案里
   写清"本版本修复了 X,请尽快升级"。
3. 商店可能要求说明"为什么版本号跳了一格" —— 在提交备注里写明回滚原因,不要改版本号去凑。

### 鸿蒙

1. 同 Android:只能提**更高 versionCode** 的回滚包(`harmony/AppScope/app.json5`)。
2. `./build-release.sh` 出 `reverb.app` + `reverb-symbol.zip`;**两份一起传**,否则市场侧还原不了崩溃栈。
3. 出包前后各查一次模型在不在(脚本自带),并解一层嵌套 hap 再数模型 / native(外层 `.app`
   里只有一个 `.hap` 条目,直接 grep 恒 0,见 H272)。
4. 本地**不要**试图 hdc 侧载 release 包验证(NEXT 的签名信任边界,见 H216);
   功能验证用同代码的 debug 包,发布口径验证走市场/云真机。

### macOS

1. 回滚包 = 上一版源码 + **更高的 `CFBundleShortVersionString` / `CFBundleVersion`**
   (`macos/Info.plist`),`./package.sh` 出 universal dmg;架构断言缺一个就不出 dmg。
2. 上传到官网下载页与(如沿用)公开仓 release;资产名保持 `Reverb.dmg` 或任意 `.dmg`
   (更新器先认 `Reverb.dmg`,再退到任意 `.dmg` 后缀,见 `SelfUpdate.swift:186-187`)。
3. 官网下载链接指向新 dmg 属于**站点部署**,按硬规矩需要先确认再发布。
4. 自更新只对更高版本提示,所以第 1 步的版本号必须真的更高,不能复用坏版本号。

### iOS(TestFlight)

1. 回滚包 = 上一版源码 + **更高的 `CURRENT_PROJECT_VERSION`**(构建号),`MARKETING_VERSION`
   按对外版本走(通常高于坏版本)。
2. `DEVELOPMENT_TEAM=… ./build-ios.sh --archive --export --upload`;每个构建号只能上传一次。
3. 在 App Store Connect 里可以让坏构建**停止测试 / 过期**,但已经装上的测试员不会被自动降级 ——
   他们要靠下一个构建覆盖。
4. 外部测试员首次要过 Beta App Review;内部测试员不需要。构建 90 天过期这条不因为回滚改变。

---

## 五、回滚包自身的验收(与发版同一套)

回滚包是"旧代码",但它仍然是一次**新的发布**,硬规矩 20 全部适用:

- 发布物是 `dist/` 里那份最终 release 包,不是 debug / 中间产物;
- 报"已就绪"要带字节数、`ls -lT` 时间戳,并用带括号的 `-newer` 判据证明它晚于源码
  (`find <src> \( -name '*.kt' -o -name '*.xml' -o -name '*.json' -o -name '*.py' \) -newer <artifact>`);
- 解包 grep 的期望值按**这个回滚包实际包含的功能**重新数 —— 回滚把某些功能退掉了,
  硬规矩 1 的读数就会变,别拿坏版本的期望值套;
- `CHANGELOG.md` 追加一段,写明这是回滚版本、退掉了什么、版本号为什么跳过。

## 六、数据与备份

- **Android 发布包不能降级安装**(安装器按 versionCode 单调递增;`adb install -d` 只对
  debuggable 包放行)。所以"给用户一个旧 apk 让他自己装"这条路等于**卸载重装、丢数据**,
  除非先导出完整备份。
- 回滚包的版本号更高,所以正常路径是**覆盖安装**,数据保留;真正要担心的是
  "新版本已经写过存档,旧代码能不能读":
  - 备份 JSON 是 v1 六分区格式,四端互通;完整备份/恢复走设置页。
  - 逐字稿缓存有自己的 `CACHE_VERSION`,口径一变旧稿自动作废重转(可再生成,不丢用户输入)。
  - 同步身份 `lan_sync.json` 带 `version`,读不出会**重建身份**(只影响对端列表里的名字)。
  - 其余 JSON store 用宽容解析;若这次坏版本动过某类存档的**结构**,回滚前先拿一份真实
    备份在旧包上试恢复一次,别把"应该能读"当成"能读"。
- 卸载前必须走「完整备份 → 确认文件非 0 字节 → 卸载 → 装回滚包 → 恢复备份 → 核对订阅与设置
  分区」,这是硬规矩 12 的 release 分支。

## 七、不要做的

- **不要**把 tag 或 release 的指向改回旧提交 / 旧资产来"回滚" —— 已装用户不会收到任何提示,
  版本号还停在坏的上面。
- **不要**降低任何一端的版本号(store 拒收、iOS 拒收、自更新不提示)。
- **不要**删掉坏版本那份 release 或它的 mapping:诊断要看它的 digest,商店也可能要它做对比。
- **不要**在回滚包里顺手改签名、改 bundle id、改包名 —— 覆盖安装会失败,数据也接不上。
- **不要**在签名材料上做任何操作(代理层面:只读)。

## 八、演练状态

| 项 | 状态 |
|---|---|
| 回滚包能出、能过解包验收 | 机制上等于正常发版,发版流程已多次跑通 |
| GitHub 侧"新 tag 覆盖坏版本"的指针 / digest 检查 | 发 1.0.5 时有过一次有读数的样板(见 `REVIEW-2026-10-18.md` P0 第 7 条) |
| 真正从坏版本回滚一次 | **未演练** |
| 商店侧停止放量 / 重新提交 | **未操作过**,后台入口与审核话术以各市场当期界面为准 |
| TestFlight 让坏构建过期 | **未操作过** |

**下一次发版前若要补这条**,最小演练是:出一份"版本号 +1、代码不变"的包传到公开仓,
在一台旧设备上确认应用内更新能提示并覆盖安装,然后把它作为正常版本留下(而不是删掉)。
它顺带验证了"回滚包 = 更高版本"这条口径本身。
