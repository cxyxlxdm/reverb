# 内容目录的降级复原步骤

`net/Sources.ets` 原先挂在这里、**不参与编译**,因为大陆合规口径把「内置内容目录 /
分类浏览 / 内容推荐」判为提供视听节目服务(需《相应内容分发许可资质》)。
只保留官网 15 条推荐订阅 + 手填 RSS 的版本对普通用户基本不可用,首版现决定先按完整功能
提交复核,所以 `Sources.ets` 已移回 `entry/src/main/ets/net/`(见 H70)。

如果平台复核确实不通过,降级不能只把 `Features.CATALOG` 改回 false:

1. 把 `entry/src/main/ets/net/Sources.ets` 移回本目录;
2. 在 `net/PodcastRepository.ets` 移除 import,把 `search` 恢复为仅 RSS 直连、
   `searchEpisodes` 恢复为空、`refreshPopular` 恢复为空;
3. `Features.CATALOG` 改回 false;
4. 许可页、五语种关于页/隐私正文、对外文案与截图同步回退。

之所以必须**物理移出编译树**:ArkTS/hvigor 没有 Kotlin/R8 那样的 dead code elimination,
常量为 false 也照样把类和 URL 字符串编进 `modules.abc`。降级后必须解包确认:

```bash
strings modules.abc | grep -ciE 'itunes|marketingtools|fyyd|gpodder'  # 必须为 0
```

现在的完整版验收方向相反:同一命令必须**非 0**。方法不变,期望值由产品决策决定。

---

# 自绘玻璃 tab 栏(GlassTabBar)的退役与复原步骤

`view/GlassTabBar.ets` 挂在这里,**不参与编译**。

**现状(2026-10-14 第二次改口)**:底部栏既不是这份玻璃透镜,也不是自绘胶囊,而是
**系统 `HdsTabs` 的悬浮样式**(`view/BottomBar.ets` 的表头写了判据与取证)。这一页下面三段
按时间顺序留着,是为了说明**同一条需求(照预装音乐 App 做)在两天里被解成三种答案**:

1. `GlassTabBar`(自绘 + canvas 折射)→ 因"矮/靠下"退役;
2. 系统 `Tabs` 自带 bar(`git show b95bf47`、`cdd9984`)→ 因"通栏、不悬浮、没光晕"被推翻;
3. 自绘 `PillTabBar`(悬浮胶囊 + 拖动切换 + 光晕,`shelved/PillTabBar.ets`)→ 查证到系统
   内置这套设计之后换回 `HdsTabs`。**三段都在 git 历史里,复原步骤见下面各自的小节。**

所以这份 GlassTabBar 现在的定位是**折射 / 逐帧 JS 弹簧这条实验路线的存档**,
它里面仍然有当前栏没用的三样东西:canvas 径向位移场折射、`GlassSpring` + `postFrameCallback`
逐帧积分、`componentSnapshot` 取背景。哪天要真做折射,从这里取,不要从零想。

## 为什么退

当时(2026-10-13)的理由是两条用户反馈:**栏太矮**、**内容太靠下** —— 两者都当成自绘版的
结构问题:

- 矮:`BAR_H = 42` 是把 Android 的 48dp 按屏幕比例换算过来的(`×0.876`,见 H122),
  而参照物(预装音乐 app)的栏是 56vp。
- 靠下:只手势避让区里留 `INSET_KEEP = 0.62` 倍,栏底几乎贴到小白条;
  参照物实测"栏下沿→屏底 = 91px = 整个手势区"。

**第二天(10-14)被推翻了一半**:这两条是数值问题,不是"自绘 vs 系统"的问题 ——
把 56vp / 完整避让区 / 左右 23vp 拿回来之后,自绘那一版(`PillTabBar`)确实做出了悬浮形态。
**同一天又被推翻另一半**:查证到系统内置这套设计(`HdsTabs` + `barFloatingStyle`),
材质与光效不再是自绘能仿的档次 ⇒ 现行是系统悬浮栏。
唯一还站在自绘那一侧的是**"按住拖动切换 + 光晕 1:1 跟手"** —— HDS 没有这个入口,
要它就得回到 `shelved/PillTabBar.ets`(见下一节)。

另外**ArkTS 没有 DCE**(硬规矩 2):留着不 import 也算留在包里,`modules.abc` 里
那套 canvas 折射 / `FrameCallback` 逐帧弹簧 / `image` 取背影像素全都在。所以必须物理移出。

## 复原步骤(如果哪天要换回这份带折射的玻璃栏)

1. 把 `shelved/GlassTabBar.ets` 移回 `entry/src/main/ets/view/`;
2. `pages/Index.ets`:三个 `TabContent` 上的 `.tabBar(this.slotX())` 摘掉(系统栏的宿主没了),
   `HdsTabs` 的 `.barOverlap/.barFloatingStyle(...)` 摘掉、`.barHeight(0)` 装回来,
   并在 Stack 的底部悬浮层放回 `GlassTabBar({scheme, fontScale, tab, inset, items, onSelect})`
   (它的 `items` 是 `{label, icon}` 两枚 `app.media.*`,不是 `TabSpec` 的四字段);
3. 放回 `.id('glassBackdrop')`(折射取源挂在内容 Column 上,**不是** Navigation;
   理由见 GlassTabBar 顶部注释),否则镜里没有内容可糊;
4. `barReserve` 与 `barFootprint` 不同源:玻璃版的 `INSET_KEEP = 0.62` 会把栏压进避让区,
   页面让位量要跟着它那套式子走,别只换组件不换余量;
5. **折射画布的位移场参数**(`RINGS` / `RIM_MAG` / `RIM_FLAT` / `LENS_BLUR`)和
   `REFRACT` 开关都在文件里,装机调这两组才有意义;
6. `resources/base/media/ic_tab_*.svg` 没删,那份吃的就是这三枚 `app.media.*`
   (现行系统悬浮栏与 `PillTabBar` 都用 `sys.symbol.*`)。

`theme/Theme.ets`、`view/Components.ets`、`view/Widgets.ets` 里那几处提到
`GlassTabBar.BAR_H` 的注释是**历史换算的出处**,复原时不需要动。

---

# 自绘悬浮胶囊(PillTabBar)的退役与复原步骤

`shelved/PillTabBar.ets` 挂在这里,**不参与编译**(ArkTS 没有 DCE,留着不 import 也在包里 ——
硬规矩 2)。

**它是什么**:2026-10-14 那一版底部栏 —— 悬浮长椭圆 + `backgroundEffect` 近似磨砂 +
**按住横向拖动切格** + 光晕 1:1 跟手 + 亮核滞后弹簧。几何(56vp / 左右 23vp / 栏底到屏底
= 整个避让区)是从预装音乐 App 用 `hdc uitest dumpLayout` 量出来的,那套常量今天仍在用
(见 `view/BottomBar.ets` 的表)。

**为什么退**:同一天查证到系统内置这套设计 —— `@kit.UIDesignKit` 的 `HdsTabs`
+ `.barFloatingStyle()` 一次给出悬浮胶囊、**真材质**、按压点光源、底部渐隐与可收束的 mini bar。
自绘那三层(晕/核/内容)只是在近似前两项,而近似与真材质之间的差别恰好是需求里"按音乐 App 做"
最在意的那一层。

**代价(照实记)**:交互退回"点按切换"。**"按住拖动切换 + 光晕跟手"这一条在 HDS 里没有入口**
—— 取证两条:① `HdsTabsAttribute` 的全部属性没有任何拖动切格项;② 预置 `HdsComponent.hsp`
解出的 `modules.abc`(处理量 2 471 012 B / 21 185 条串)里 tab 相关手势串只有 click/longPress。
所以这份文件是**唯一一份把这三条全做出来并过编译的实现**,复核若要求"必须能拽着切",就从这里回去。

## 复原步骤

文件头部有同一份步骤的简版(贴在代码里,改代码的人先看见它)。这里补关键的三条判据:

1. `.barHeight(0)` 与摘掉 `.tabBar()` 必须**同时**做 —— 只改一处会出现"两条栏";
2. 宿主 `Column` 的 `.padding` **只留 top**:栏要浮在避让区上方,而内容必须铺到屏底,
   列表才滚得到胶囊背后(磨砂有东西可糊)。系统悬浮栏那版由 `barBottomMargin` 管这一段,
   换成自绘就要组件自己算总高(`barFootprint(inset)` = 栏高 + inset);
3. `MiniPlayerBar` 收束态底色保持全透,透的是这份文件的 `backgroundEffect`,不是系统材质。

另外**SDK 口径不用回退**:`barFloatingStyle` 是这一版唯一依赖 6.1.0(23) 的东西,
自绘胶囊只需要 6.0.2(22)。是否把 `compatibleSdkVersion` 降回去,取决于当时还想不想留
mini bar 那条路 —— 降回去之前先确认 `Index.ets` 里已经没有任何 23+ 的 API。