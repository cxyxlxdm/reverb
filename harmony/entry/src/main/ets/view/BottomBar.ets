import { Theme, Scheme, Tracking, withAlpha } from '../theme/Theme';
import { SettingsStore } from '../store/SettingsStore';
import { curves } from '@kit.ArkUI';
import { hdsMaterial, HdsTabsFloatingStyle } from '@kit.UIDesignKit';
import { L } from '../util/L';
import { Glyph, Sym } from './Widgets';

/**
 * 底部 tab 栏 —— **系统 `HdsTabs` 的悬浮样式**(`barFloatingStyle`),不再自绘。
 *
 * ## 为什么换(2026-10-14,路线 A)
 *
 * 需求从头到尾是同一条:"按预装华为音乐那个底部条的样式与交互做" —— 悬浮长椭圆 + 磨砂 +
 * 按下有光晕。自绘这条路人走了三轮(玻璃透镜 → 系统 Tabs → 自绘胶囊),每一轮都在**重新发明
 * 系统已经提供的东西**,而最关键的那层**真材质**始终仿不出来:自绘只能拿 `backgroundEffect`
 * (radius/saturation/tint 三个数)去近似,而音乐那条用的是 `systemMaterialEffect`。
 * 列表从它背后滚过去时,这两者读出来的差别就是"糊"与"糊得不像"。
 *
 * `HdsTabs` 在 UIDesign Kit(`@kit.UIDesignKit`)里,`barFloatingStyle` 一项给出:
 * 悬浮胶囊栏、左右边距、距屏底距离、底部渐变遮罩、**系统材质**、**点光源颜色**,
 * 以及和栏同排/同列的 **mini bar**(音乐里那颗"正在播放"的小栏就是它)。
 *
 * ## 前置条件(这不是风格,是硬门槛)
 *
 * `barFloatingStyle` / `HdsTabsMiniBar` / `hdsMaterial` / `HdsBarStyle` 全部是
 * **`@since 6.1.0(23)`**(只有 `HdsTabs` 本体是 6.0.0(20))。所以本工程的
 * `compatibleSdkVersion`/`targetSdkVersion` 从 **6.0.2(22) 提到 6.1.0(23)**
 * (`harmony/build-profile.json5`,该文件不入库)。
 * ⚠️ **代价:6.0.x 的设备装不上这一版**,商店侧"最低支持版本"口径跟着变 —— 这是路线 A
 * 事先认过的取舍,不是装机后才发现的意外。另外 `HdsTabs` 要求 Stage 模型
 * (声明里全部标 `@stagemodelonly`),本工程已是 Stage,无需改动。
 *
 * ## 得到什么、退回什么(照实记,不要以为换系统组件是全赢)
 *
 * - ✅ 真材质、点光源、悬浮几何(侧边距/距底/渐变遮罩)由组件管,不再逐帧自绘;
 * - ✅ mini bar 通道在 → 播放条的收束下一步可以整个交出去(见 `harmony/shelved/README.md`);
 * - ❌ **「按住某一格横向拖到另一格、松手切换」这一交互没有公开入口**。取证两条:
 *   ① `@hms.hds.hdsBaseComponent.d.ets` 里 `HdsTabsAttribute` 的全部属性(vertical/barPosition/
 *     barMode/barWidth/barHeight/animationDuration/onChange/onAnimationStart/divider/barOverlap/
 *     barBackgroundColor/barBackgroundEffect/barBackgroundBlurStyle/barBackgroundStyle/
 *     onContentWillChange/onTabBarClick/blurStrategy/barFloatingStyle/onSelected/onUnselected/
 *     cachedMaxCount)没有一个与"拖动切格"有关;
 *   ② 预置 `HdsComponent.hsp` 解出的 `modules.abc`(处理量 2 471 012 B / 21 185 条串)里,
 *     tab 相关的手势串只有常规 click/longPress,没有拖动或"光晕跟手"的入口。
 *   ⇒ 这一版交互**退回"点按切换"**,光晕是按下时的点光源,不是自绘版那层 1:1 贴手指横走的晕。
 *     若装机后认定拖动切换不可让步,回到 `harmony/shelved/PillTabBar.ets`(恢复步骤在那份文件头部)。
 *
 * ## 保留下来的几何(全是量出来的,不是观感)
 *
 * 取证对象:本机(BRA-AL00,密度 3.25,逻辑宽 374.2vp)预装华为音乐,`hdc uitest dumpLayout` 原始 bounds:
 *
 * | 部位 | 实测 bounds | 换算 |
 * |---|---|---|
 * | TabBar 整条 | `[75,2415][1141,2597]` | 高 **56vp**、左右各收 **23vp** |
 * | 单个 tab 项图标 | `[173,2443][252,2521]` | **24vp** |
 * | 单个 tab 项文案 | `[180,2527][246,2570]` | 行高 13.2 ⇒ 字号 ~10–11fp |
 * | 栏下沿 → 屏底 | `2688-2597 = 91px` | **28vp = 整个手势避让区** |
 * | 展开态播放条 | `[75,2259][1141,2389]` | 高 40vp,与栏之间留 `2415-2389=26px` = **8vp** |
 * | 收束态左槽 | `[75,2415][257,2597]` | **56×56vp** 方槽 |
 * | 收束态左槽里的**圆盘** | 中心 `(166,2506)`、直径 ≈172px | **53vp**,与栏同心 |
 * | 盘上图标 | `[126,2467][205,2545]` | **24vp**,强调色;形状 = **当前那一格**的图标 |
 * | 收束态封面 | `[302,2435][445,2578]` | **44vp**、正圆,中心 2506.5 = 栏中心 |
 *
 * ## 收束态那一行归谁(2026-10-15 第五轮)
 *
 * 参考片的收束态**只有一层容器**:一颗球 + 一条与栏等高的播放条胶囊,系统那条悬浮胶囊底**不在**
 * (它被播放条自己取代了)。我们先前两版都是"播放条嵌在系统栏胶囊里",差别就在多出的那一层底。
 * 所以这一轮两条一起改:① 播放条整块抬到 [MINI_H_COLLAPSED]=56(= 栏高),按钮**先**抬到 24
 * (与 tab 图标同档,不再被半高圆角削);② 收束态把系统栏的 `barOpacity` 打到 0,展开时回到 1。
 * **"按钮 24"这条下一轮就被推翻**,装机连降两档到 [MINI_SYMBOL]=16(24 → 20 肉眼读不出变化)。
 * ⚠️ ②还有一条装机才看得见的代价:`barOpacity` 淡掉的是**整条栏**,连带把系统那层磨砂底板一起撤了,
 * 于是收束态**球周围那一块**现在是清晰的列表内容在透 ⇒ 盘面透明度 0.10 → 0.45(见 [HomeSlot])。
 * ⚠️ 由此产生一条**要如实写下来的交互后果**:收束态那一行只有播放条与那颗球,
 * **三个 tab 点不动是这一形态的必然**,不是缺陷 —— 想切格先点那颗球展开。
 * (此前它记在 `docs/ROADMAP.md` 15c 的"待拍板"里,本轮按"就是设计"结案。)
 *
 * ⚠️ 与 Android 侧**不再追求"同一占屏比例"**(那套换算见 H51 补充、
 * `harmony/shelved/GlassTabBar.ets` 的 `BAR_H` 注释)。这一轮的要求是"向鸿蒙自己的手感对齐",
 * 56vp 就是鸿蒙的口径。Android 的玻璃栏 2026-11-09 也抬到了 56dp(见 H254)——
 * 两端现在数值相同,但那仍是"各自同语义"的结果,不是把一端的占屏比例算给另一端。
 */

/** 栏高。悬浮样式里仍由 `barHeight` 给,系统默认也是 56,显式写出来图个确定。 */
export const TAB_BAR_H: number = 56;
/** tab 图标边长(参考片实测 24vp;自绘版是 17)。 */
export const TAB_SYMBOL: number = 24;
/** tab 文案字号(fp)。沿用自绘版定过的 10fp —— 那档是按本机物理尺寸对齐 Android 11sp 来的。 */
export const TAB_LABEL_FP: number = 10;

/**
 * 播放条整块高度:**两态都是 56**(= 栏高,[TAB_BAR_H]),2026-11-09 统一。
 *
 * 旧口径是展开 48 / 收束 56(7 + 34 + 7 与 8 + 40 + 8)。那是按"展开浮在栏上方、
 * 收束落进栏里"推的,但**频道详情页没有 tab 栏、永不收束**,永远停在 48 ——
 * 于是同一个播放条在 tab 页是一条、在频道页矮一档。Android 那侧先被用户指出来
 * (`docs/TROUBLESHOOTING.md` H254),本端是同一形状:两个常量各管一态,页面档位一叠就露馅。
 * 用户口径是「每个页面的播放条保持一致」,所以两端一起收敛到**只有一档**:56。
 *
 * 这一改把 morph 里"块高 48→56"那一项整个删掉:收束时只剩球槽展开、整块下沉 64(= 栏 56 + 缝 8)
 * 与栏淡出。块高恒定也意味着封面不必两态两个数(见 [MINI_COVER_WIDE] 的瞬移代价到此为止)。
 *
 * ⚠️ **进度线不占这一档的高度**(2026-10-15 起):它是叠在胶囊上沿的覆盖层,不是行内的一格。
 * ⚠️ 下面的内边距、圆角、点击矩形全部从本常量推导,改这一个数就够 ——
 * 但 `MINI_PAD_EXPANDED` 的纵向是 (MINI_H − 封面) / 2,必须一起核;`barReserve` 也吃它。
 */
export const MINI_H: number = TAB_BAR_H;
/** 展开态播放条与栏之间的留白(参考片实测 26px = 8vp;装机本端同为 26px)。 */
export const MINI_GAP: number = 8;
/**
 * 胶囊圆角 = **该态块高的一半**(两态都是长椭圆)。
 * 两态同高(56,见 [MINI_H])⇒ 两态同 28,所以现在只有一个数 ——
 * 上一版按态各取一份(展开 24 / 收束 28),那条分叉正是"改了块高忘了改圆角"的来源。
 * 见 `MiniPlayerBar` 的 `.borderRadius(MINI_RADIUS)`。
 */
export const MINI_RADIUS: number = MINI_H / 2;
/**
 * 收束态整块高度 = **栏高 56**。
 *
 * 2026-11-09 起与 [MINI_H] **数值相同** —— 统一之后两态只有一档,这个常量留着是为了
 * 把「收束态必须与栏等高」这条约束写成名字(那一行要落进栏、盖住它),而不是让两个数
 * 各写一个 56 再慢慢漂开。若哪天 [MINI_H] 又变,**这条判据仍是栏高**。
 *
 * 历史:第五轮把这一态从 44 抬到 56 —— 旧口径胶囊**嵌在系统栏那条胶囊里**(两层容器),
 * 按钮按 44 那档配(22/19/20)也比 tab 图标小一圈、被半高圆角那道弧切着。
 */
export const MINI_H_COLLAPSED: number = TAB_BAR_H;
/**
 * 播放条里三枚按钮(播放/暂停、下一集、队列)的边长。**两态同为 16**。
 *
 * 这里改判了三次,三次都留下,因为**"多大算合适"在这条栏上只能靠眼睛定,数值推不出来**:
 * - 第五轮:旧值 22/19/20 是按"收束态只有 44 高"配的,块高抬到 56 之后跟着 tab 图标一起放到 24;
 * - 第六轮上半:装机复看读成"两种态都太大"⇒ 24 → 20(−17%);
 * - **第六轮下半:20 装机仍读成"没变化"** —— 实测确实生效了(节点 78px → 65px,盘内亮度
 *   patch 也从 43/50/45 抬到 61/69/70),但 13px 只占屏宽 1%,而且**播放/暂停那两枚是实心三角、
 *   不是描线**,实心形状按 bounding box 缩 17% 时肉眼几乎不动。所以这一步直接跨到 16(累计 −33%)。
 * ⚠️ 别把 16 当成"最终值"写死进别处:它是**观感档位**,下一轮装机很可能还要动。
 * 仍然**不做成两态两个数**:一个数只有一处要维护,而 16 在 56 这一档里不会被圆角弧削。
 */
export const MINI_SYMBOL: number = 16;
/**
 * 播放条三枚按钮的**命中框边长** = 节点边长 + 四周各 12 = 40。
 *
 * 图标降到 16 之后节点本身只有 16vp,而拇指目标是 40vp(栏那三格也是按这一档给的);
 * 且这三枚挤在标题与胶囊右缘之间,不外扩就会被左右两个大命中目标夹住点不中。
 * ⚠️ 三个数要一起动:偏移 [MINI_HIT_OFF] 恒为本常量与节点边长之差的一半,否则命中框偏心。
 */
export const MINI_HIT_EXT: number = MINI_SYMBOL + 24;
export const MINI_HIT_OFF: number = -12;
/**
 * 封面边长。**2026-11-09 起两态同为 40**(旧口径 34 / 40,第六轮那档)。
 *
 * 上一版两态不同是为了"展开更紧凑、收束更像胶囊",代价是 `Artwork` 的边长是它**内部**的
 * width、父层属性动画管不到,收束时那 6vp 是**瞬移**(见 `MiniPlayerBar` 头注那条 ⚠️)。
 * 统一块高之后这个代价没有理由再付:两态同 40 = 56 − 8×2,纵向留白两态都是 8vp,
 * 封面从展开到收束一个像素都不跳。两个常量仍分开留着 —— 语义是"两态的封面",
 * 只是这一轮起数值相同;要再分档,先想清楚那条瞬移代价。
 */
export const MINI_COVER_WIDE: number = 40;
export const MINI_COVER_NARROW: number = 40;
/**
 * 胶囊内边距。**两态各一份,整块给 `.padding()`** —— 纵向那三个数不是留白而是几何:
 *
 * - 展开:`8 + 40(封面)+ 8 = 56` = [MINI_H] = 栏高;
 * - 收束:`8 + 40(封面)+ 8 = 56` = [MINI_H_COLLAPSED] = 栏高。第五轮起整块**与栏等高**
 *   (旧口径纵向 0、块高只有 44,于是胶囊嵌在系统栏那条胶囊里面 —— 见那条的改判理由),
 *   外层那一行的高度球槽(56)与胶囊(56)一致,行内垂直居中 ⇒ 盘心、封面心、栏心三者同线
 *   (装机 2506.5 / 2506)。
 * ⚠️ **纵向必须由封面反推**(块高 − 封面)÷ 2,不能单独调:块高 56 是硬约束
 *   (与栏等高,见 [MINI_H_COLLAPSED]),封面一改 padding 不跟着改,整块高度就会漂。
 * - **两态纵向与左内距现在同一个数**(8 / 14),morph 里只剩右内距 16 ↔ 8 这一档在动。
 *   展开态那 14 是内容页边距,封面左缘要对齐列表文字;收束态它只管胶囊自己的头部留白 ——
 *   第六轮装机复看"收束态封面离胶囊左侧还是小",从 8 提到 14(改的是**观感档位**,不是"对齐展开态":
 *   因为同批的 24→20 只挪 13px 被读成"没变化",小步在这条栏上不成立)。
 *   ⚠️ **球 → 胶囊那道缝不能算在这 14 里** —— 上一版正是这么写的("收束态它同时就是那道缝"),
 *   装机复量出来球盘右缘 250、胶囊左缘 256,**外缝只剩 2vp**,两个圆头几乎相切,
 *   读起来仍是"胶囊左端鼓出一颗球"。参考片(`r4_ball.png`,2× 裁图)量的是
 *   **外缝 32px = 10vp + 内白 15px = 4.6vp**,总距离(盘 → 封面 ≈ 15vp)与我们相同,
 *   区别只是那道缝在胶囊**外面**。所以缝改由 [HOME_SLOT_GAP] 给。
 *   ⚠️ 左内距提到 14 之后**盘 → 封面总距变成 8 + 14 = 22vp,比参考片那 15vp 大**;
 *   这是明知代价选下来的 —— 想按参考片把总距压回去只能减小 [HOME_SLOT_GAP],而外缝一旦小到
 *   2~4vp 就复现"两个圆头相切"那条。**宁可口袋里空,不要外面贴。**
 *   也正因为收束态右缘仍锚在 8(三枚按钮离胶囊右 8vp 装机读着合适),**不能改成外层
 *   `Row({ space: 14 })`**:那条 space 会给零宽的球槽也插一道,展开态整条播放条被白右推
 *   14vp,封面左缘就和列表文字对不齐。
 */
export const MINI_PAD_EXPANDED: Padding = { left: 14, right: 16, top: 8, bottom: 8 };
export const MINI_PAD_COLLAPSED: Padding = { left: 14, right: 8, top: 8, bottom: 8 };
/** 收束态左侧小球的槽宽(参考片 56×56 方槽)。**球整个占在胶囊之外**,所以槽宽就是它占的宽度。 */
export const HOME_SLOT: number = 56;
/**
 * 球槽与胶囊之间的**外缝**(参考片 10vp)。
 *
 * 只能挂在槽的右边距上、并且**按收束态取**:挂在外层 `Row` 的 `space` 上会让展开态
 * 那个零宽的槽也吃一道缝,整条播放条右移(见 [MINI_PAD_COLLAPSED] 那段)。
 */
export const HOME_SLOT_GAP: number = 8;
/** 小球里那枚图标大小(与 tab 图标同档;参考片实测盘内图标 79px = 24.3vp)。 */
export const HOME_SYMBOL: number = 24;
/**
 * 收束态左端那颗**圆盘**的直径。
 *
 * 参考片量出来是 172px = **53vp**(装在 56×56 的槽里,几乎撑满,只留 1.5vp 呼吸)。
 * 这里取 52:槽仍 56,盘比参考小 1vp —— 因为我们的盘是**自绘的半透明色块**,
 * 不是系统材质,撑得太满会让它读成"一个洞"而不是"一颗球"。装机要调只调这一个数。
 */
export const BALL_DIAM: number = 52;
/**
 * 小球上显示的是**当前那一格**的图标,不是固定的"房子"。
 *
 * 取证:本机华为音乐,收束后点进"音乐厅"再收一次,盘上那枚就从房子换成了音乐厅
 * (`/tmp/r2_ball.png` vs `/tmp/r4_ball.png`)。所以这颗球的语义是
 * **"整条 tab 栏收在这里"**,而不是"回主页" —— 我们的动作也确实是把播放条展开、栏露回来。
 *
 * ⚠️ 顺序必须和 `pages/Index.ets` 里四个 `@Builder` 槽位一致(发现 0 / 电台 1 / 追更 2 / 音阁 3),
 * 且**取选中态那一枚**(实心变体)。没有实心变体的那一格仍用描边 + 加粗,与
 * [SystemTabItem.hasFill] 同一条规则。
 */
export const BALL_ICONS: Resource[] = [Sym.discoverFill, Sym.radio, Sym.feed, Sym.libraryFill];
/// 与 [BALL_ICONS] 同序:该格有没有实心变体(没有的用字重区分选中态)
export const BALL_ICONS_BOLD: boolean[] = [false, true, true, false];

/**
 * 悬浮栏到屏幕左右各收多少(参考片实测 `75px / 3.25 = 23.1vp`)。
 *
 * 悬浮感全靠这两道缝。写在这里而不是散在 Index 里:`barSideMargin` 与页面内容的左右边距
 * 是**两回事**,只有这一处定义"栏缩进多少",装机要调宽度时才只有一个地方可改。
 */
export const BAR_SIDE_MARGIN: number = 23;

/**
 * 播放条左右各收多少。**与悬浮栏同一道缝**,不是"内容页边距":
 *
 * 早先这一层是**通栏**(只有左右 14/16 的页边距),换悬浮页签之后装机发现两处对不上 ——
 * 展开态是一条通栏压在胶囊上,读起来像"两块不相干的板";收束态最右那颗队列按钮
 * 越过胶囊右沿约 7vp(节点实测右边界 1164 vs 胶囊 1141)。参考片两态都**恰好等于胶囊宽**。
 * 所以这里取 [BAR_SIDE_MARGIN]:宽度只有一个来源,栏改了播放条跟着改,不会各漂各的。
 * ⚠️ 声明位置在 `BAR_SIDE_MARGIN` **之后**是必须的 —— 模块级 `const` 有暂时性死区,
 * 写在前面的那次构建直接报 `10505001 Block-scoped variable used before its declaration`。
 */
export const MINI_SIDE_MARGIN: number = BAR_SIDE_MARGIN;

/**
 * 滚动累计多少 vp 翻转收束/展开。
 *
 * 40vp ≈ 手指移动 13mm —— 比"碰一下就收"钝,比"划半屏才收"灵。
 * 关键是**累计量**而不是单次量:一帧的 scrollOffset 只有 1–8vp,按单帧判阈值
 * 要么灵敏到乱翻、要么迟钝到不翻。
 */
export const MORPH_SLOPE: number = 40;

/**
 * morph 弹簧的两组参数(response 秒 / 阻尼)。**展开落点与收束落点共用同一档**,
 * 否则播放条自己缩、Index 把它往上托,两条曲线不同步会看出"散架"。
 * 数值取自本项目已装机认可的那档分段条胶囊(`Components.springTo` 用 0.45/0.95 是"跟页滑动",
 * 这里要的是"就地收放",response 短一档)。
 */
export const MORPH_RESP: number = 0.34;
export const MORPH_DAMP: number = 0.86;

/**
 * ⚠️ **0.86 是欠阻尼,落点会过冲 ≈0.5%(短暂越过终点再回)** ——
 * Android 同一条曲线在装机当天就崩了:那边是把分数**乘进 Dp** 再喂 `padding`,
 * `lift = 60dp × (1−f)` 在 f=1.005 时是 −0.3dp,而 Compose 对负 padding 直接抛
 * `Padding must be non-negative`(见 TROUBLESHOOTING **H180**,修法是几何出口钳一次)。
 *
 * **本端不同形,所以没照搬那条钳位**:这里从不手写"分数 × 长度",
 * 而是给 `.animation({curve: morphSpring()})` 两个**字面量**让框架自己插值
 * —— `.height(collapsed ? TAB_BAR_H : 0)`、`.margin({ right: collapsed ? HOME_SLOT_GAP : 0 })`、
 * `.opacity(collapsed ? 1 : 0)`(见本文件那两处 `.animation({ curve: morphSpring() })`)。
 * 残余风险只剩一条:**回到 0 的那一支**(展开时高度 56→0)按同一条曲线会瞬间算出负高度,
 * 而 ArkUI 布局层怎么处理负值没有公开说明。七轮装机没崩过是**经验证据,不是证明** ——
 * 所以这一条记在 ROADMAP 里作为**未验项**,而不是"已与 Android 对齐"。
 * 判据(要真机才能跑):在收放途中用 `hilog` 打 `getRectanglePosition` 的高,
 * 或直接看有没有 `height must be non-negative` 类异常。
 * **不能按硬规矩 2 反方向类推**("Android 要钳 ⇒ 鸿蒙也要钳"),两端动画值进布局的路径不一样。
 */

/**
 * 当前 tab 序号在 AppStorage 里的键。
 *
 * 为什么 tab 序号也要走 AppStorage 而不是 @Prop:栏项是 Tabs 用 CustomBuilder 生成的,
 * 父级的 build 重不重跑、builder 重不重跑都不是我们能掌握的;而"点了第二个 tab 第二个
 * 却不亮"这种症状很容易被误当成"动画没生效"。自己订阅就没有这一层不确定性。
 * 装饰器的参数位置能放常量(`Index.ets` 早就是这么写 `@StorageLink(Theme.SYSTEM_DARK_KEY)`),
 * 所以这里不必退成字面量。
 */
export const TAB_KEY: string = 'curTab';
/**
 * 当前 tab 的**稳定页号**在 AppStorage 里的键(发现 0 / 电台 1 / 追更 2 / 音阁 3)。
 *
 * `TAB_KEY` 存的是**可见下标** —— 设置里关掉直播电台之后底栏少一格,同一个下标会指向另一页。
 * 所以两者分开:栏项(按可见序列编号)读 `TAB_KEY`,收束态小圆球读这一格(图标表按页身份排)。
 * 与 Android `MainShell` 的 `selectedKind` / `selectedIndex` 是同一套解。
 */
export const TAB_KIND_KEY: string = 'curTabKind';
/** 播放条是否收束进 tab 栏。同一个 AppStorage 通道,理由见 [TAB_KEY]。 */
export const MORPH_KEY: string = 'miniCollapsed';

/// morph 曲线。两个宿主(MiniPlayerBar 内部属性 / Index 里整块的落点)必须调同一个式子。
/// **不配 duration** —— springMotion 的时长由 response 与初速度决定,官方文档明确
/// duration 在这条曲线上不生效(AnimateParam 注 5),写了是骗自己。
export function morphSpring(): curves.ICurve {
  return curves.springMotion(MORPH_RESP, MORPH_DAMP);
}

/**
 * 悬浮层从屏底往上占到多高 = 栏 + 它下面那道手势区留白。
 *
 * 自绘那版这个式子成立,悬浮样式下同样成立,因为判据本来就是"栏底到屏底 = 整个避让区"
 * (那一截现在由 `barBottomMargin` 给,见 [barFloating])。
 *
 * **两处共用这一条**:播放条的落点([Index.miniBottom])、以及页面滚动内容让出的底部余量
 * ([barReserve])。收小留白时最容易漏后一处,漏了列表末尾多出一条空白(或者末项被栏压住)。
 */
export function barFootprint(inset: number): number {
  return TAB_BAR_H + inset;
}

/**
 * 页面滚动内容要让出的底部余量。
 *
 * ⚠️ **播放条那一段按展开态(最高的那一档)算,与当前收没收束无关。**
 * 收束态整块 56vp 已经落进栏里,让位量本可以少 56vp(播放条高 + 缝)—— 但那意味着每次翻转都要
 * 重排整条列表(千行 List 的 measure 重新跑一遍),而翻转恰好发生在**滚动中**,
 * 每一帧都可能触发。省下的那 56vp 空白换一次滚动掉帧,不值。
 */
export function barReserve(inset: number, playing: boolean): number {
  return barFootprint(inset) + (playing ? MINI_H + MINI_GAP : 0);
}

/**
 * **频道页**那颗悬浮胶囊的落点(距屏底)。这一页没有 tab 栏,所以不走 [barFootprint],
 * 但也不能直接套 tab 页那式子里的 `inset + MINI_GAP`。
 *
 * 真机两侧各量过一次底边到屏底的距离:
 * - Android 那台 `navInset 16dp + 缝 8 = 24dp` = 66px,占屏高 **3.06%**;
 * - 本机 `bottomInset 28vp + 缝 8 = 36vp` = 117px,占屏高 **4.35%**。
 *
 * 缝两端都是 8,差的全在避让区 —— 鸿蒙这道指示器区比 Android 的导航栏高 12vp,
 * 于是"同一套式子"在两端不等高。用户口径是「跟 Android 差不多」,而按占屏比例算
 * Android 那一档正好就是 24vp,所以把**基准钳到 Android 那道 16** 再加同一档缝。
 *
 * 为什么钳而不是写死 24:三键导航 / 无指示器的设备 `inset` 是 0,写死会把胶囊抬到
 * 没必要的高度;而 `inset` 更大的机型(平板、带虚拟键)也不会把缝越垫越高。
 */
export const MINI_INSET_CAP: number = 16;

export function channelMiniBottom(inset: number): number {
  return Math.min(inset, MINI_INSET_CAP) + MINI_GAP;
}

/**
 * 悬浮栏的样式对象。
 *
 * **每次 build 现算**:`barBottomMargin` 取的是窗口避让区(`bottomInset`),旋转、进出全面屏
 * 都会变,做成一次性常量就会在某个姿态下贴住小白条。
 *
 * 只给这五项,其余一律留系统默认:
 * - `barSideMargin` / `barBottomMargin` —— 上面那张实测表里的 23vp / 整个避让区;
 * - `barWidth` 三档全给**同一个数值** = 窗口宽 − 2×23vp —— **这条是装机加回来的**:
 *   只给 `barSideMargin` 时栏会**按内容收缩并居中**(本机实测 pill
 *   `TabBar [224,2415][992,2597]`,左右各空出 69vp),而参照物是通栏减 23vp
 *   (`[75,2415][1141,2597]`)。也就是说 `barSideMargin` 只是**最小边距**(内容撑不满时
 *   用它),不是"栏宽 = 屏宽 − 2×它";宽度得自己说。
 *   ⚠️ **但不要给 `'100%'`**(第一版就是这么写的,装机否掉):百分比按**窗口宽**算,
 *   于是节点变成 `[0,2415][1216,2597]` —— 那 23vp 的侧边距被顶没了,胶囊铺到屏幕两侧,
 *   读起来就是"栏出头了"。**宽度是绝对量,侧边距才留白。**
 *   三档都要给:`HdsBarWidthRangeOptions` 按 tabs 宽度分档(小 <440vp / 中 440–600 / 大 >840),
 *   手机吃 `smallWidth`,但折叠屏与平板会落到另两档 —— 漏一档就是那一档上又变回收缩胶囊。
 *   三档同一个值不会错:`windowWidthVp` 本来就是**当前窗口**的宽,不管落在哪一档,
 *   "窗口宽减两侧留白"都是那一档上正确的宽度。
 * - `systemMaterialEffect.materialType` —— 由调用方传进来(见 [pickMaterialType]),
 *   因为**探测要做一次、不能每帧做**,而这一项直接决定栏是"有材质"还是"透明的";
 * - `barOpacity` **按收束态取**(2026-10-15 第五轮加进来的,不是风格调整):收束态播放条整块
 *   放大到与栏等高之后,**外层这条系统胶囊就不该再存在** —— 两条胶囊叠在同一带上读起来就是
 *   "播放条装在 tab 容器里面",而参考片收束态只有一层容器。所以收束时整条栏(材质底 + 三格)
 *   淡到 0,播放条自己就是那一行的容器;展开时回到 1。
 *   ⚠️ **这一条是瞬变,不是弹簧**:`barOpacity` 藏在样式对象里、不是节点的属性动画对象,
 *   所以翻转那一瞬栏底立刻没了/立刻回来,而播放条还在弹簧途中(≈0.5s)。
 *   装机若读出"翻转途中那一带空了一下",解法是把这个数改成**逐帧驱动的弹簧值** ——
 *   同一招在退役的自绘栏里用过(`harmony/shelved/GlassTabBar.ets` 的 `postFrameCallback` ticker),
 *   而不是把播放条的动画关掉。**本轮先按瞬变验几何,不同时改两处。**
 * - `gradientMask` / `miniBar` / `lightColor` / `adaptToHandedness` / `thermoCtrl` **先不动**。
 *   它们都有系统默认值,而默认值就是华为音乐自己那套参数。
 *   装机若读不出悬浮感,**一条一条加** —— 一次全开就不知道是哪一项起了作用。
 */
export function barFloating(inset: number, windowWidthVp: number,
  materialType: hdsMaterial.MaterialType, collapsed: boolean): HdsTabsFloatingStyle {
  const style: HdsTabsFloatingStyle = {
    barSideMargin: BAR_SIDE_MARGIN,
    barBottomMargin: inset,
    barOpacity: collapsed ? 0 : 1,
    systemMaterialEffect: {
      materialType: materialType,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
    }
  };
  // 窗口宽和避让区是同一次异步读取带回来的,启动首帧还是 0。这时宁可不给 `barWidth`
  // (退回"按内容收缩"那一档),也不能给 0 或负值 —— 后者在启动那一瞬把栏压成一条线。
  if (windowWidthVp > 2 * BAR_SIDE_MARGIN) {
    const pillWidth = windowWidthVp - 2 * BAR_SIDE_MARGIN;
    style.barWidth = { smallWidth: pillWidth, mediumWidth: pillWidth, largeWidth: pillWidth };
  }
  return style;
}

/**
 * 材质档位必须**运行时探测**,不能照参考设备上的那个值写死。
 *
 * `hdsMaterial.getSystemMaterialTypes()` 返回本机支持的档位。支持 IMMERSIVE 就用它
 * (华为音乐那条就是这一档:材质会随背后内容动,自绘那版最仿不出来的就是这一层);
 * 不支持就退 ADAPTIVE 让系统自己挑。**直接写 IMMERSIVE 的后果不是"效果差一点"而是
 * 整条栏透明** —— 官方示例专门点过这条,而透明栏在浅色列表上读起来像"栏没了"。
 *
 * 这一句在 `Index` 的字段初始化里跑一次(冷启动一次),不在 build 里。
 */
export function pickMaterialType(): hdsMaterial.MaterialType {
  const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
  return types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0
    ? hdsMaterial.MaterialType.IMMERSIVE
    : hdsMaterial.MaterialType.ADAPTIVE;
}

/**
 * 一个 tab 项:图标 + 文案。
 *
 * **为什么栏形状交给系统、内容却还是我们自己画的这一项**:`HdsTabs` 的默认栏项
 * (`BottomTabBarStyle` + `TabBarSymbol`)用的是**系统主题色**,而本 App 有自绘的强调色选择器
 * (`settings.accentIndex`)和"跟随系统之外"的手动深浅档。用系统项就等于把这两项设置丢掉 ——
 * 所以形状(悬浮胶囊、材质、光晕)交给系统,格子里的颜色与字号仍归我们的 `Scheme`。
 *
 * **为什么不直接把样式写进 Index 的 @Builder**:Tabs 的 CustomBuilder 什么时候重跑由框架掌握,
 * 而 @Builder 的按值参数本身不做响应式更新。于是"选中态""收束态"这两个会变的量若从父级
 * 按值传进来,就有**点了不亮 / 收了不淡**的风险(这正是 H26/H27 那一类"看着正常只是被别的
 * 状态顺带刷了"的形状)。所以做成 @Component,并让**会变的量全部自己订阅**:
 * - 选中 → `@StorageProp(TAB_KEY)` 读当前 tab 序号,和静态的 `index` 比;
 * - 收束 → `@StorageProp(MORPH_KEY)`;
 * - 配色/字号 → `@ObjectLink settings` + `@StorageProp(Theme.SYSTEM_DARK_KEY)`,自己现算。
 *
 * 静态量(第几项、文案、两枚图标)才用 @Prop。
 */
@Component
export struct SystemTabItem {
  /** 这一项代表第几个 tab(静态) */
  @Prop index: number;
  @Prop label: Resource;
  /// 未选中(描边)/ 选中(实心)两枚图标
  @Prop icon: Resource;
  @Prop iconFill: Resource;
  /**
   * 有没有实心变体。**没有**(追更那枚 `dot_radiowaves_left_and_right` 在 symbol 表里
   * 不存在 `_fill` 形式)时选中只换色 + 加粗,不要拿别的形状冒充。
   */
  @Prop hasFill: boolean = true;
  /** 外壳的观察对象:配色与字号只能从它现算(@ObjectLink 要求父级以 @State 持有同一个对象) */
  @ObjectLink settings: SettingsStore;
  @StorageProp(Theme.SYSTEM_DARK_KEY) systemDark: boolean = false;
  @StorageProp(TAB_KEY) curTab: number = 0;
  /**
   * 播放条是否收束进栏。收束时整项淡没 —— 淡没不等于消失,布局不许跟着塌,
   * 否则栏会在翻转变矮,播放条落进来的位置跟着抖。
   */
  @StorageProp(MORPH_KEY) collapsed: boolean = false;

  private scheme(): Scheme {
    return Theme.scheme(this.settings.themeMode, this.settings.accentIndex, this.systemDark);
  }

  build() {
    Column({ space: 2 }) {
      Glyph({
        symbol: (this.curTab === this.index && this.hasFill) ? this.iconFill : this.icon,
        dim: TAB_SYMBOL,
        color: this.curTab === this.index ? this.scheme().primary : this.scheme().onSurfaceVariant,
        // 无实心变体的那一枚靠字重区分选中态(见 hasFill 注释)
        bold: this.curTab === this.index && !this.hasFill
      })
      Text(this.label)
        .fontSize(TAB_LABEL_FP * Theme.fontScale(this.settings.fontIndex))
        .letterSpacing(Tracking.caption)
        .fontColor(this.curTab === this.index ? this.scheme().primary : this.scheme().onSurfaceVariant)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    /**
     * `.animation()` 必须挂在**这个**节点上:它吃的是"同一节点上、写在它之前的属性"的变化。
     * 收束标志从 AppStorage 落到这里时只有 opacity 在变,而 opacity 不参与测量,
     * 所以三项同时淡出/淡入不会带动任何重排。
     */
    .opacity(this.collapsed ? 0 : 1)
    .animation({ curve: morphSpring() })
  }
}

/**
 * 收束态左端那颗**小圆球** —— 整条 tab 栏收进来的地方。
 *
 * ## 为什么是"当前那一格的图标"而不是房子
 *
 * 第一版这里画的是 `sys.symbol.house`,理由是"点它回主页"。装机对着参考片复看发现口径错了:
 * 华为音乐收束后切到"音乐厅",盘上那枚**跟着换成音乐厅**(见 [BALL_ICONS] 取证)。
 * 也就是说那颗球读的是**"栏收在这里"**,不是"回首页" —— 我们的动作也确实只是把播放条展开、
 * 让三格重新露出来(并不改 tab)。所以图标随 `curTab` 取选中态那一枚,配色用 primary
 * 把"这是当前页"说出来;房子那枚在参考片里之所以出现,只是因为当时正停在首页那一格。
 *
 * ## 展开态它**也要在布局里占位**(宽度动画到 0),不能用 `if` 摘掉:摘掉会让整行内容
 * 一次性左移,而旁边的封面/文字正按弹簧滑过来 —— 两种运动叠在一起就是"抖"。
 * `.clip(true)` 是必需的:宽度 0 时里面那颗盘并不自动被裁掉。
 *
 * ⚠️ 这一颗**暂时仍是我们自己的**(随播放条叠在系统栏之上,见 Index 的 Stack)。`HdsTabs` 的
 * `miniBar`(`miniBarBuilder` + `applyMiniBarStyle`)正是为它准备的宿主 —— 和栏同一行、
 * 宽度随收束动画自己走。那是换完悬浮栏之后的**下一步**,不在这一轮:一次只换一个变量,
 * 否则装机读不出"抖"来自哪一侧。
 */
@Component
export struct HomeSlot {
  @Prop scheme: Scheme;
  @Prop collapsed: boolean;
  /** 当前页的**稳定页号**:盘上图标跟着它换。自己订阅,理由与 [SystemTabItem.curTab] 同一条。 */
  @StorageProp(TAB_KIND_KEY) curKind: number = 0;
  onTap: () => void = () => {};

  build() {
    Row() {
      /**
       * 中间这一层是**槽**(定宽 56),盘在槽里居中。
       *
       * ⚠️ 不能把盘居中到"槽 + 缝"那一整块上 —— 装机量出来盘心在 187.5px,而参考片是 166px,
       * 差了 6.6vp,整颗球读起来"往中间滑了一点"。
       * 参考片那道缝属于**槽和胶囊之间**(由 [HOME_SLOT_GAP] 给),不参与盘的定位。
       */
      Row() {
        Row() {
          Glyph({
            symbol: BALL_ICONS[this.curKind],
            dim: HOME_SYMBOL,
            color: this.scheme.primary,
            bold: BALL_ICONS_BOLD[this.curKind]
          })
        }
        .width(BALL_DIAM)
        .height(BALL_DIAM)
        .borderRadius(BALL_DIAM / 2)
        /**
         * 盘面是**中性半透明**,不是强调色半透明,也不是不透明。
         *
         * 参考片两张截图(亮封面 / 暗封面各一张)里盘都读成"比周围略亮或略暗的一层玻璃",
         * 颜色**不跟主题走** —— 强调色只在盘上那颗图标上出现一次。
         * 原先用 `primary` 16% 装机复看,盘在深色底上泛出一层绿,和图标同色之后读成"一个实心圆点",
         * 参考片那种"整条栏收在这里"的透镜感就没了。
         * `onSurface` 低透明度在深色态是浅 scrim、浅色态是深 scrim,两态都只提对比不带色相。
         *
         * **0.10 → 0.22 → 0.45(2026-10-15 第六轮)**:第五轮把系统栏的 `barOpacity` 打到 0 之后,
         * 盘底下**那层系统磨砂底板一起没了**,于是这 10% 直接叠在清晰的列表内容上 ——
         * 装机在追更页量到盘后面是封面 + "The Daily" + 时长,盘读成"内容上挖了个圆"而不是一个物体。
         * 提到 0.22 之后**盘内亮度实测从 43/50/45 抬到 61/69/70**(同一块 patch,1200 像素),
         * 数值上确实变了,但装机复看仍读成"没改"—— 深色态下 onSurface 那点增量被背后的封面吃掉了。
         * 所以这一步跨到 **0.45**,让盘读成"一层明确的灰板",图标浮在它上面。
         * ⚠️ 别再往回改成完全不透明 `surface`:那等于在收束态自己画一块板,正是这一轮要撤掉的
         * "两层容器"形状;而浅色态下不透明的 onSurface 是**近白**,会糊成一颗白斑。
         * 要动的是**这一档透明度**,不是形态。
         */
        .backgroundColor(withAlpha(this.scheme.onSurface, 0.45))
        .justifyContent(FlexAlign.Center)
      }
      .width(HOME_SLOT)
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width(this.collapsed ? HOME_SLOT : 0)
    /**
     * 收束态才有的**外缝**(见 [HOME_SLOT_GAP])。写成边距而不是把槽加宽:槽加宽会把
     * 居中在槽里的盘一起往右推,而参考片那颗盘的位置是由槽定的。
     */
    .margin({ right: this.collapsed ? HOME_SLOT_GAP : 0 })
    /**
     * 高度取**栏那一档 56**,不是封面那 44:盘是 52,放在 44 的行里会被 `clip(true)` 削成上下平的形状。
     * 第五轮起**两物体同高**(球槽 56、胶囊块高也 56,见 [MINI_H_COLLAPSED]),
     * 整行因此正好等于栏高 —— 播放条既不越出胶囊,也不再嵌在胶囊里面。
     */
    .height(this.collapsed ? TAB_BAR_H : 0)
    /** **左对齐**:外层宽就是槽宽 56,居中会把整颗球往右推(装机量出来 188 vs 参考 166)。 */
    .justifyContent(FlexAlign.Start)
    .clip(true)
    .opacity(this.collapsed ? 1 : 0)
    .animation({ curve: morphSpring() })
    .accessibilityText(L.s('a11y_expand_player'))
    .onClick(() => this.onTap())
  }
}
