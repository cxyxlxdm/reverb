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

`view/GlassTabBar.ets` 挂在这里,**不参与编译**。现行底部栏是系统 `Tabs` 自带 bar +
一个悬浮的迷你播放条,几何与动画全在 `view/BottomBar.ets`(判据与实测表写在那份文件顶部)。

## 为什么退

用户反馈两条:**栏太矮**、**内容太靠下**。两者都是自绘版的结构问题,不是数值问题:

- 矮:自绘版 `BAR_H = 42` 是把 Android 的 48dp 按屏幕比例换算过来的(`×0.876`,见 H122),
  而这一轮的要求恰恰是"用系统组件",系统 bar 的既定高度是 56vp,换算前提就不成立了。
- 靠下:自绘版只手势避让区里留 `INSET_KEEP = 0.62` 倍,栏底几乎贴到小白条;
  改成宿主容器 `padding({bottom: bottomInset})` 之后,栏整体抬到避让区上方,
  与参照物(预装音乐 app)实测的"栏下沿→屏底 = 91px = 整个手势区"对上。

另外**ArkTS 没有 DCE**(硬规矩 2):留着不 import 也算留在包里,`modules.abc` 里
那套 canvas 折射 / `FrameCallback` 逐帧弹簧 / `image` 取背影像素全都在。所以必须物理移出。

## 复原步骤(如果哪天要换回自绘栏)

1. 把 `shelved/GlassTabBar.ets` 移回 `entry/src/main/ets/view/`;
2. `pages/Index.ets` 的 `shell()`:删掉 `Tabs` 上的 `.tabBar(...)` / `.barHeight` /
   `.barOverlap` / `.barBackgroundBlurStyle` / `.barBackgroundColor` / `.divider(...)`
   这六个系统属性(连同 `TabContent` 上的 `.tabBar(this.slotX())` 三处),
   把 `.barHeight(0)` 那套旧写法装回来,并在 Stack 的悬浮 `Column` 里放回 `GlassTabBar({...})`;
3. 放回 `.id('glassBackdrop')`(折射取源挂在内容 Column 上,**不是** Navigation;
   理由见 GlassTabBar 顶部注释),否则镜里没有内容可糊;
4. `import` 从 `../view/BottomBar` 换回 `../view/GlassTabBar`,
   **`barReserve` 换回 `barFootprint` + 手拼的迷你条高度** —— 两个函数不同源:
   `barFootprint` 两边同名同义,`barReserve` 是这一版新增的(且**故意不含收束标志**,见注释);
5. `view/MiniPlayerBar.ets`:去掉 `@Prop collapsed` 与 `HomeSlot`,封面宽度回到单值
   `MINI_COVER_WIDE`,内边距回到单值 —— 收束态是这一版才有的,自绘栏没有左槽;
6. `view/Widgets.ets` 的 `Sym.feed` / `Sym.home` 可以留着(`Sym.feed` 是追更那枚图标,
   和栏的实现无关);`resources/base/media/ic_tab_*.svg` **没有删**,自绘版吃的就是这三枚
   `app.media.*`(系统版改用 `sys.symbol.*` 所以不再引用它们)。

`theme/Theme.ets`、`view/Components.ets`、`view/Widgets.ets` 里那几处提到
`GlassTabBar.BAR_H` 的注释是**历史换算的出处**,复原时不需要动。