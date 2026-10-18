# 云端备份 / 换机恢复 —— 三端路线调研

> **状态:TODO,未开始实现**(2026-10-18 登记,任务 #204)。
> **原文照抄在下面「调研原文」分隔线之后,以原文为出处;本节是提炼出来的可执行结论。**
> 来源:`~/Desktop/backup.md`(5,799 B,mtime 2026-10-18 18:59)。
> 与 `docs/ROADMAP.md` 四「长期(平台与形态)」里那条「零后端前提下的跨设备同步」是同一件事的展开。

## 一句话结论

**存在一条四条约束全保的路线** —— 存储走系统(与「分享一律走系统」同构):macOS 直写 iCloud Drive 目录、
Android 走 SAF 目录导出、鸿蒙把已接入的 Backup Kit 收尾。代价是 UX 从「静默自动」变成
**「一键备份 + 装回一键恢复」**。
**要「装回即自动同步」就必须破约束一**(WebDAV / 鸿蒙 Cloud Kit),连带六处文档与同意门同步失真(硬规矩 5/19)。

## 先要拍板的一件事

| 选项 | 保住的约束 | UX | 动的面 |
|---|---|---|---|
| **A. 目录/系统备份线** | 四条全保,包里零上传代码 | 一键备份 + 装回一键恢复 | 只加各端一个入口与恢复流程 |
| **B. 自动云同步线** | ⚠️ **翻转约束一**(包里出现网络上传代码路径) | 静默自动、同账号多端一致 | 解包 grep 口径、`docs/FEATURES.md`、`docs/PRIVACY.md`、关于页五语、上架文案五语、隐私同意门 |

**这一条不由代理决定。** 未拍板前,下面所有 TODO 只按 A 线推进;B 线只做「核实」,不做实现。

## 分端路线与状态

| 端 | 可走路线 | 与约束的关系 | 现在到哪了 | 待办 |
|---|---|---|---|---|
| **macOS** | 直接写 `~/Library/Mobile Documents/com~apple~CloudDocs/余音/`(用户 iCloud Drive 根下固定目录),同步由系统的 iCloud Drive 进程完成 | **全保** ——包里没有任何网络上传代码;卸载重装无关,文件在用户自己的 iCloud 里 | 已确认本项目 entitlement 只有 `get-task-allow`(无 App Sandbox)、自分发 ad-hoc 签名 | ① **装机实测「直写该路径必然同步」这条前提**,验过才立项;② CloudKit 路线**已排除**(需正式签名 + entitlement,ad-hoc 做不了) |
| **HarmonyOS** | ① **Backup Kit(云备份)**:数据进用户的云备份记录,用户在 设置 > 华为账号 > 云空间 > 云备份 按数据项恢复 ② **Cloud Kit(云同步)**:ArkData / Core File Kit 端云同步,「装回即同步、同账号多端一致」 | ① 全保 ② 需核实配额归属 | ① **已接入一半**,卡点是「debug 包不出现在备份选项」,要等市场包验证 —— 1.0.5 市场包提交后即可验 ② 2026-06 HDC 才开放,**只覆盖 HarmonyOS 6.0+,在网大盘仍是 5.x** | 见下面「待人工核实」四条 |
| **Android(大陆)** | ① **SAF 目录导出**:应用只把文件写到用户经系统选择器指定的目录,上传由那个云盘应用完成 ② **WebDAV(坚果云)**:三端同协议,但要管凭据、且包里有 HTTPS 上传路径 | ① **全保** ② **翻转约束一** | 无实现 | Google Auto Backup 依赖 GMS,**大陆华为设备上不存在**;海外用户零改动天然享受。HMS Drive Kit 要引 Account + Drive 两套 SDK,**3.9 MB 的 store 渠道定位会被打破 ⇒ 不选** |

⚠️ **一个要避开的坑(两条线名字像,归属是反的)**:搜「端云同步」会撞到 AGC **云数据库的「端云协同」** ——
那条的数据落在**开发者自己的 AGC 项目存储**里(服务端可见用户数据、配额我们扛),实质就是自建后端,**直接违反约束一**。
它和上面 ② 的 Cloud Kit 不是一回事,别选错。

## 待人工核实(4 条,代理抓不到:官方文档站是 JS 渲染)

| # | 要核什么 | 怎么算核过 |
|---|---|---|
| 1 | 鸿蒙 Cloud Kit 的配额**是否计用户的云空间** | AGC 控制台 + 官方文档正文人工读,出处贴这里 |
| 2 | Cloud Kit 在**卸载重装**后的确切恢复语义(是不是「装回即同步」) | 同上,最好有真机一轮 |
| 3 | Cloud Kit 的 **AGC 控制台开通前提**(要不要上架、要不要企业认证) | AGC 控制台实际截图/步骤 |
| 4 | 坚果云是否**暴露 DocumentsProvider**(决定 SAF 目录导出在国内可用性) | 装机实测;OneDrive 已确定支持 |

## 实施顺序(拍板 A 线之后)

1. **macOS 先做** —— 成本最低、约束全保;前提是上面①的装机实测通过。
2. **鸿蒙**:先把 Backup Kit 的**市场包全链验证**做完(已投入大半),同时人工核实上面 1~3 条;
   核实通过才值得为 Cloud Kit 立项 —— 它才是「华为账号空间」的正主。
3. **Android**:若只要全保约束 ⇒ 只做 SAF 目录导出;若要国内可用的全量云方案 ⇒ WebDAV(坚果云)是 default 渠道唯一选项,
   但那一刻就要按硬规矩 5/19 把六处口径一起翻。

## 自证要求(做完才算数)

- **约束一没被写破**:声明「包里没有上传代码」也要**解包 grep 验**(网络库调用面、目标域名清单)。
- **五语一起改**(新增的备份/恢复入口文案):Android `\'` / 鸿蒙 JSON 直接写 `'`(H191)。
- **备份格式仍与既有「完整备份」JSON 互通** —— 不要另造一套格式(参见 Android 应用内「设置 → 完整备份」)。
- 换机/卸载重装恢复要留**真机判据**,并在装机前按硬规矩 12 先备份(卸载等于丢数据)。

---

## 调研原文(照抄,未改动)

macOS —— 有，而且是三端里最干净的

刚确认了本项目 entitlement 只有 get-task-allow（无 App Sandbox），自分发 ad-hoc 签名。这意味着：

- 直接把备份 JSON 写进 ~~/Library/Mobile Documents/com~~apple~CloudDocs/余音/（用户 iCloud Drive 根下的固定目录）。上传由系统的 iCloud Drive  
  同步进程完成——我们包里依然没有任何网络上传代码。卸载重装无关紧要，文件在用户自己的 iCloud 里；新 Mac 登录同账号文件就在。
- CloudKit 路线需要正式签名 + entitlement，ad-hoc 做不了，放弃。
- 这是唯一约束全保的方案，但「直写该路径必然同步」这条我建议装机实测一次再定案。

HarmonyOS —— 有「华为账号空间」，但两条路的恢复语义完全不同

1. Cloud Backup（云备份）——已开放两年，你们已接入一半。华为官方口径是「开发者只需极少量代码即可完成数据接入」；数据进用户的云备份记录，用户可在 设置 > 华为账号 > 云空间 > 云备份  
   里按数据项选择恢复。但恢复是用户手动发起的整机/按项恢复，不是卸载重装自动同步——它解决的是换机和整机恢复，不是你这次想要的那个 UX。你们卡的「debug 包不进备份选项、等市场包验证」正是这条链。
2. Cloud Kit（云同步服务）——2026 年 6 月 HDC 才开放，HarmonyOS 6.0+：应用通过 ArkData / Core File Kit  
   的端云同步把结构化数据和文件同步到华为云空间，「在登录同一华为账号的设备间保持同步」，官宣半天接入。这是唯一真正对应你描述的东西（装回即同步、同账号多端一致）。三个没钉死的点：官方文档站 JS 渲染我抓不到正文，①  
   配额是否计用户的云空间、② 卸载重装的确切恢复语义、③ AGC 控制台开通前提——需要你或我下次用 AGC 控制台/文档站人工核实；④ 只覆盖 6.0+ 设备，在网大盘还是 5.x。
3. 一个要避开的坑：搜「端云同步」会撞到另一条线——AGC 云数据库的「端云协同」。那条路数据落在开发者自己的 AGC  
   项目存储里（服务端可见用户数据、配额我们扛），实质就是自建后端，直接违反约束一，别选。两条线名字像，归属是反的。

Android —— 大陆没有公共服务级答案

- Google Auto Backup 本身就是你描述的理想形态：数据进用户 Google Drive、不占个人配额、25MB/应用上限、Android 9+ 端到端加密、APK 装完未启动前就自动恢复——但它依赖  
  GMS，大陆华为设备上不存在。海外用户会天然享受它（什么都不用做）。
- HMS Drive Kit（华为云盘）：技术上能给 huawei 渠道用（用户华为账号 + 云盘配额），但要引入 Account+Drive 两套 HMS SDK，3.9MB 极简渠道定位会被打破。
- 现实可选项：
  - WebDAV（坚果云）——用户自己的账号、纯 HTTPS 无 SDK、三端可用同一协议。代价：凭据管理、网络上传代码路径（约束一的声明要翻转）、用户得有坚果云。这是国内独立应用（阅读/RSS 类）的标配做法，坚果云官方文档也只教  
    FolderSync + WebDAV 这条路。
  - SAF 目录导出——应用只做「把文件写到用户经系统选择器指定的目录」，用户若选了 OneDrive 这类暴露 DocumentsProvider 的云盘，上传由那个云盘应用完成，我们包里仍然没有上传代码。坚果云是否暴露 DocumentsProvider  
    未能证实（帮助中心只提 WebDAV），需装机实测；OneDrive 确定支持。

约束影响（如果走「自动云同步」）

约束一的「没有任何上传数据的代码路径」按渠道翻转，连带解包 grep 口径、FEATURES 矩阵、PRIVACY、关于页、上架文案五语种、隐私同意门全部同步（硬规矩 5/19）。而「iCloud Drive 目录 / SAF  
目录」这条折中四条约束全保，只是 UX 从「静默自动」变「一键备份 + 装回一键恢复」——和「分享一律走系统」同构：存储也走系统。

建议排序

1. macOS：iCloud Drive 目录方案，成本最低、约束全保，可先做。
2. 鸿蒙：先把 Backup Kit 的市场包全链验证做完（已投入大半）；同时人工核实 Cloud Kit 的三个未定问题——核实通过就值得立项，它是「华为账号空间」的正主。
3. Android：接受 WebDAV（坚果云）作为 default 渠道唯一的全量云方案；不肯破约束就只做 SAF 目录导出。

Sources:

- Back up user data with Auto Backup — Android Developers (<https://developer.android.com/identity/data/autobackup>)
- 华为云空间 Cloud Kit 全新升级：开放 Web 端与云图库接入 — 中国日报 (<https://cn.chinadaily.com.cn/a/202606/17/WS6a323904a310d709c2fb89c6.html>)
- 恢复云空间中的云备份数据 — 华为官网 (<https://consumer.huawei.com/cn/support/content/zh-cn16010322/>)
- 端云数据同步 — HarmonyOS 开发文档 (<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/data-sync-with-cloud>)
- 同应用端云数据同步概述 — HarmonyOS 开发文档 (<https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/data-cloud-sync-overview>)
- 云数据库 — AppGallery Connect (<https://developer.huawei.com/consumer/cn/agconnect/cloud-base/>)
- 云空间服务 Drive Kit — 华为开发者联盟 (<https://developer.huawei.com/consumer/cn/hms/huawei-drivekit/>)
- 如何使用 FolderSync 在安卓手机上同步文件夹到坚果云 — 坚果云官方博客 (<https://blog.jianguoyun.com/?p=2731>)
- HarmonyOS 6 发布，华为云空间带来安心便捷的数据管理体验 — 品玩 (<https://www.pingwest.com/a/308482>)
