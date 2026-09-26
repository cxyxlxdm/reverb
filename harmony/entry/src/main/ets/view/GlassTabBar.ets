import { Scheme, TypeScale, Tracking, withAlpha } from '../theme/Theme';
import { Log } from '../util/Logger';
import { FrameCallback } from '@kit.ArkUI';
import image from '@ohos.multimedia.image';

/// tab 项规格:图标与文案。数量由父级决定(当前恒为 2)。
export interface TabSpec {
  label: Resource;
  icon: Resource;
}

/** smoothstep:两端斜率为 0,所以环带之间的接缝在中心和镜缘都最窄。 */
function smooth01(t: number): number {
  return t * t * (3 - 2 * t);
}

/**
 * 位移场的径向分布:**内圈 RIM_FLAT 之前完全不动**,之后才 smoothstep 到镜缘那一档。
 * 直接拿 smooth01(r) 的话中心区已经开始拉扯,整颗镜子读起来是一块"均匀放大的贴片",
 * 而不是参考片那种"厚的边、薄的芯"。
 */
function rimWeight(r: number): number {
  const t: number = Math.max(0, Math.min(1, (r - RIM_FLAT) / (1 - RIM_FLAT)));
  return smooth01(t);
}

// —— 玻璃胶囊的手感参数(装机实测值;演进与坑见 H96/H97/H98)——
/**
 * **软体透镜模型**(对着酷安录屏逐帧量出来的)。
 *
 * 参考片实测:被透镜压住的图标**逐帧零位移** —— 绿块右缘恒定在 258/259,同屏不动的
 * 加号按钮恒定 326..399 作对照,只有靠左那 19px 被冲淡。所以"图标边缘被扯动"是
 * **透镜把盖住的内容折射、洗白**造成的,图标本身根本没动。
 *
 * ⚠️ 三版"让内容形变"的做法全走过,全错,别再回去:
 * ① 副本绕自身中心 scaleX 拉长 —— 被否:"不是左右拉伸放大"(H97);
 * ② 整块内容跟着胶囊方向 translate —— 被否:"图标不应该动,现在图标在晃动";
 * ③ 一端钉住、另一端把内容边缘扯出去 —— 被否:图标压根不该有任何形变。
 *
 * 形变只属于透镜,而且**只在按下/松手那两下**:按下从灰底等比例长出一颗大玻璃(鼓出栏外),
 * 拖动期间它**尺寸恒定、只有位置 1:1 跟手**,落位靠位移过冲表达粘滞,松手缩回灰底。
 * 本体带**自己的 backgroundEffect**。
 *
 * 而且**透镜只在手指按着的时候存在**:静止时栏上只有一块扁的浅灰选中底([RestPill]),
 * 按下才从灰底长出这颗玻璃,松手缩没。上一版把玻璃常驻挂在选中项上,静止画面就成了
 * "一颗大白药丸占住栏",被否:"透镜不是常驻的啊"。
 */
/**
 * 按下时整条栏的放大倍率。
 */
const BAR_PRESS: number = 1.06;
/**
 * 按下时弹簧的目标倍率。透镜**只在按住时存在**,所以这个值只用来产生 0..1 的
 * "存在感"([lensAlpha]),尺寸由 LENS_SCALE 决定 —— 两者相乘就是看得见的那一档。
 */
const LENS_PRESS: number = 1.16;
/**
 * 透镜本体浓度。玻璃**不是白贴纸** —— 装机第一版用 0.26,结果透镜盖住的区域比栏还白,
 * 读起来是一颗不透明药丸。参考片里透镜内部是**看得见彩色内容**的,它靠的是
 * 「比周围更亮、更饱和」而不是「更白」。
 */
const LENS_TINT: number = 0.14;
/**
 * 透镜这一档的磨砂半径。它糊的是**折射层画出来的那份内容**(折射层在玻璃之下),
 * 所以这个数直接决定折射看不看得见:
 * - 24(纯磨砂那版的定稿值)⇒ 搬进来的位移被糊平,折射等于白做;
 * - 1 ⇒ 镜内清晰、镜外磨砂,接缝处像贴了一张贴纸,不像同一块玻璃;
 * - 10 是"读得出拉扯、又不刺眼"的那一档 —— 必须明显**小于**栏底的 BASE_BLUR,
 *   透镜相对整条栏才是"更透、更聚焦",否则只剩一块提亮的白。
 */
const LENS_BLUR: number = 10;
const LENS_SAT: number = 1.6;
const LENS_BRIGHT: number = 1.10;
/** 边缘高光的浓度。参考片那圈亮边占了"玻璃感"读感的一半,不能省。 */
const LENS_RIM: number = 0.8;
/**
 * 栏底(整条玻璃)的磨砂参数。
 *
 * ⚠️ 这里的 alpha 直接决定透镜有没有东西可折射:0.6 时栏底已经把页面内容洗成一片白,
 * 透镜再糊一遍就只是一块更白的白。参考片的栏是**透的** —— 能看清栏后面图标的颜色。
 */
const BASE_BLUR: number = 28;
const BASE_SAT: number = 1.35;
const BASE_TINT: number = 0.34;
/**
 * 两组弹簧(response 是**一次完整振荡的秒数**,越大越慢;damping < 1 才会过冲)。
 * ⚠️ 语义与 `curves.springMotion(response, dampingFraction)` 一致,但这两组参数现在喂给
 * JS 侧的 [GlassSpring] 自己积分,不再交给渲染侧 —— 原因见该类的注释。
 *
 * 生硬感的来源就是原先 0.22/0.8 与 0.3/0.75 这两档 —— response 短到看不见振荡,
 * damping 又接近临界,落位是"急刹"而不是"甩过头再回来"。
 *
 * ⚠️ 这里曾有**第三组**(RESP_TRAIL 0.55 / DAMP_TRAIL 0.6):后缘用一条更慢更松的弹簧去追
 * 前缘,两段之差当作拖动中的粘滞拽长。被否:"点击透镜变大是对的,滑动的时候就不能再变了,
 * 现在滑动的时候还在继续变大,很丑很不协调"。**尺寸只由按下那一下决定**,拖动只改位置;
 * 粘滞感全部交给落位时的位移过冲,不再用形变表达。
 */
const RESP_GROWTH: number = 0.42;
const DAMP_GROWTH: number = 0.68;
/** 位移弹簧:response 与生长同档(0.42)才对得上"同一个物体";阻尼 0.7 才有甩过头再回来。 */
const RESP_PILL: number = 0.42;
const DAMP_PILL: number = 0.7;
/**
 * **唯一的宽高比**。静止底和透镜共用这一个数 —— 这就是"等比例放大"的实现方式。
 *
 * ⚠️ 之前宽和高是两个独立常量(底 58×44 = 1.3,镜 95×53 = 1.8),
 * 于是从静止到拖动读起来是"一颗短椭圆被拉成长椭圆",被否:
 * "静止状态也是个长椭圆,从静止到拖动是等比例放大,而不是由短变长"。
 * 现在 `pillH() = pillW() / ASPECT`,形变只发生在**按下那一下**、且只改宽度,
 * 高度自动跟着等比例走,所以形状**恒为长椭圆**。
 *
 * 1.9 这一档是装机认可的"拖动时状态对"的那个比例,反过来定到静止底上。
 */
const ASPECT: number = 1.9;
/**
 * **常驻的选中底**:静止时唯一可见的标记 —— 扁的浅灰长椭圆,不鼓出栏外、不折射。
 *
 * ⚠️ 高度由**内容高度**倒推:内容块 = 图标 19 + 间距 2 + 文字 11 的行高 ≈ 36vp。
 * 之前灰底只有 38,上下各剩 1vp,装机反馈"相对图标和文字基本没有 padding"。
 * 44 给出 4vp 呼吸量,同时在 48 的栏里留 2vp 到边 —— 参考片里那颗灰底就是几乎顶满栏的。
 * 宽度不单独定,由 ASPECT 算出(≈84)。
 *
 * ⚠️ 透镜不是常驻件 —— 它是"手指按住才从灰底长出来"的东西,松手缩回灰底。
 * 更早一版把大玻璃一直挂在选中项上,静止画面就成了"一颗大白药丸",被否。
 */
const REST_H: number = 44;
const REST_W: number = REST_H * ASPECT;
/** 静止底的颜色浓度。再深就开始和玻璃抢戏。 */
const REST_TINT: number = 0.10;
/**
 * 透镜相对静止底的整体放大倍数(宽和高**同一个数**,所以形状不变)。
 * 1.22 → 按住期间恒为 102×54,比 48 的栏上下各出 3vp —— 这正是需求说的
 * "拖动时透镜放大,高度可以超出 tab"。
 *
 * ⚠️ 它是**按住期间的恒定倍率**,不是"拖得越远越大"。上一版宽度还乘了一段
 * 前后缘之差,于是滑动中持续变大,被否:"很丑很不协调"。
 */
const LENS_SCALE: number = 1.22;
/**
 * 栏高。**导出给 Index 的 underBarPad 用** —— 页面让出的底部余量必须跟着栏高走。
 * 44 → 48:内容放大到 19/11 之后 44 只剩 4vp 总余量。只加这一档 ——
 * 加到 56 被否("高度增加太多了,只需要增加一点点")。
 * 栏高**不**参与透镜尺寸:透镜超出栏是特性,不是要避开的边界。
 */
export const BAR_H: number = 48;
/**
 * 栏底到屏幕底的留白 = 手势避让区高度 × 这个系数。
 *
 * ⚠️ 之前是**整个避让区**留空(`BAR_H + inset`),装机量出来栏悬在半空:小白条在避让区里
 * 是**贴底**画的(实测其下沿距屏幕底 6.2vp、上沿距屏底 11.4vp),而栏被顶到避让区上沿,
 * 于是"栏到小白条"16.9vp ≈ "小白条到屏底"的三倍,两道间距不对称,读起来栏浮得太高。
 * 0.62 把留白收到 17.5vp,让栏底到小白条的距离**等于**小白条到屏底的那 6.2vp。
 * 用系数而不是写死 vp:避让区高度随机型(有虚拟导航键的机器更大)变,比例才跟得上。
 *
 * **导出给 Index 的 [underBarPad] 用** —— 页面让出的底部余量必须跟着栏的落点走,
 * 只改这一处会让列表末尾多出一条空白。
 */
export const INSET_KEEP: number = 0.62;
/**
 * 悬浮层从屏幕底往上占到多高 = 栏本身 + 下面那道留白。
 *
 * **Index 的 `underBarPad` 必须用同一个式子** —— 页面滚到底时要让出的余量得跟栏的落点一致,
 * 两处各算各的就会在列表末尾多出一条空白(或者末项被栏压住)。
 */
export function barFootprint(inset: number): number {
  return BAR_H + inset * INSET_KEEP;
}
/** 整条栏距屏幕左右:栏"太长"的直接修法(原 12)。胶囊放大后不能顶出屏幕。 */
const SIDE_PAD: number = 24;
/**
 * 两个 tab 的中心从栏边缘内收这么多 —— 间距收小的做法。
 * 注意槽位判定(中线)不受影响:两项对称,分界永远在 barW/2。
 */
const ITEM_INSET: number = 22;

// —— 折射层(实验,见 H98 之后)——
/**
 * 折射总开关。false 时退回 H98 定稿那版"只有 backgroundEffect 的纯磨砂"。
 *
 * 为什么需要开关:折射是"把镜内那块内容按位移场搬一遍",一旦位移场算错,
 * 症状是镜内内容整体偏移/重影,和"参数调坏"完全同形 —— 必须能一键回到已知好的状态对比。
 */
const REFRACT: boolean = true;
/**
 * 折射画布比栏**上下各多出**的余量(vp)。透镜按住时鼓出栏外,画布必须比栏高,
 * 否则超出那截被画布边界切掉。
 */
const CANVAS_PAD: number = 12;
/**
 * 径向放大环的**层数**:每一层裁一个"两圈长椭圆之间"的环带,再按该层的倍率重画整块内容。
 * 层数就是折射曲线的采样精度 —— 连续位移场在这个 SDK 里没有(shader 挂不进声明式树,
 * RenderNodeContainer 在本 SDK 不存在),只能用分段仿射逼近。
 */
const RINGS: number = 12;
/** 镜缘那一层的**取样**倍率:>1 = 镜缘把圈外的内容压进这一圈。1.0 = 不折射。 */
const RIM_MAG: number = 1.35;
/** 位移场的平坦内圈半径占比:这一段以内 1:1 不动,折射全部留给外圈。 */
const RIM_FLAT: number = 0.45;

/**
 * 阻尼振子。**为什么在 JS 里自己积分而不用 `animateTo`**:
 * `animateTo` 只把**目标值**写进状态,中间值由渲染侧插值,JS 永远读不到"现在"是多少。
 * 而折射层每一帧都要知道透镜现在多大、压在哪块背景上,才能把像素搬对位置 ——
 * 用 animateTo 的症状是按下那 ~0.3 秒里折射内容已按最终尺寸画好、玻璃还没长到那儿,
 * 镜缘外溢一圈不属于它的内容(位置弹簧同理:滑动中折射会抢在玻璃前面到位)。
 *
 * 参数语义与 `curves.springMotion(response, dampingFraction)` 一致,换过来观感不变。
 */
class GlassSpring {
  value: number;
  target: number;
  private vel: number = 0;
  private resp: number;
  private damp: number;
  /** 停住判据。倍率(量程 0.16)和位移(量程几百 vp)差几个数量级,不能共用一个常数。 */
  private eps: number;

  constructor(value: number, response: number, damping: number, eps: number) {
    this.value = value;
    this.target = value;
    this.resp = response;
    this.damp = damping;
    this.eps = eps;
  }

  /// 硬落到某个值并停住 —— 1:1 跟手的那些帧不走弹簧,但要让弹簧知道现在在哪
  snap(to: number): void {
    this.value = to;
    this.target = to;
    this.vel = 0;
  }

  /// 推进 dt 秒;返回是否已经停住
  step(dt: number): boolean {
    if (this.value === this.target && this.vel === 0) return true;
    const omega: number = 2 * Math.PI / this.resp;
    const accel: number = -omega * omega * (this.value - this.target) - 2 * this.damp * omega * this.vel;
    // 半隐式欧拉(先速度后位置)。显式版在 response 接近两帧时长时会发散。
    this.vel += accel * dt;
    this.value += this.vel * dt;
    if (Math.abs(this.value - this.target) < this.eps && Math.abs(this.vel) < this.eps * 30) {
      this.value = this.target;
      this.vel = 0;
      return true;
    }
    return false;
  }
}

/**
 * `postFrameCallback` 收的是一个 FrameCallback 实例,而且**本 SDK 没有 cancelFrameCallback**
 * —— 只能靠"不再续订"停下,所以实例要做成常驻的一个,每帧逻辑转交给组件的闭包。
 */
class GlassTicker extends FrameCallback {
  private fn: (frameNs: number) => void;

  constructor(fn: (frameNs: number) => void) {
    super();
    this.fn = fn;
  }

  onFrame(frameTimeInNano: number): void {
    this.fn(frameTimeInNano);
  }

  onIdle(timeLeftInNano: number): void {
  }
}

/**
 * 玻璃底部 tab 栏:悬浮长椭圆 —— 左右各收 [SIDE_PAD](栏不是铺满全宽,否则胶囊放大
 * 后顶到屏幕边)+ 一层投影给出 z 轴高度,视觉上浮在底部;
 * 背景实时模糊(backgroundEffect)+ 跟手切换(PanGesture)。
 *
 * **四层结构**:
 * 0. 静止底([RestPill]):**唯一常驻**的选中标记 —— 扁的浅灰圆角矩形,不鼓出栏外、不折射。
 * 0.5 折射层([RefractLayer]):按下才出现的一块 canvas,把栏背后那张快照按径向位移场
 *    搬进透镜里。**画布不跟随透镜移动,移动的是画布里的内容** —— 这样拖动帧只重画 canvas,
 *    不动布局。开关 [REFRACT] 关掉就退回"只有 backgroundEffect 的纯磨砂"那版。
 * 1. 透镜层([LensLayer]):一颗带自身 `backgroundEffect` 的玻璃,**画在折射层之上、内容之下**。
 *    **它不是常驻件** —— 透明度直接读 `pillGrowth`,静止时是 0(等于不存在),
 *    按下才从灰底"长"出来,松手缩没。参考片的开头/结尾帧里栏上只有那块灰底。
 *    玻璃在折射层**之上**是有意的:折射出来的内容也得再被玻璃糊一档,才和镜外的磨砂同构。
 * 2. 内容层([ContentLayer]):图标 + 文字,压在玻璃之上,**永远静止**。
 *    玻璃糊的是它**背后**的页面内容(栏下那行列表),不是自己的图标 —— z 序反过一次,
 *    结果 16vp 的图标被自己的折射糊成一团绿雾、文案直接消失(装机实测)。
 *
 * **手感口径(对着酷安录屏逐帧校准,别再改回去)**:
 * ① 内容(文字/图标)**零形变、零位移**。参考片实测:被玻璃压住的绿块右缘逐帧恒定
 *    在 258/259(同屏不动的加号按钮 326..399 作对照),只有靠左那 19px 被冲淡 ——
 *    所以"图标边缘被扯动"是玻璃洗白造成的错觉,不是图标在动;
 * ② 按下时整条栏放大([BAR_PRESS]),透镜再大一档([LENS_SCALE],高到鼓出栏外),
 *    但整条栏不能长到顶出屏幕;
 * ③ 形变只属于透镜,且**只由按下那一下决定**([lensScale]):前缘 1:1 跟手 = 位置跟手,
 *    宽度**不**随拖动幅度变化;粘滞感由落位时的位移过冲表达。
 *    **高度永远 = 宽 / [ASPECT]**,所以按下放大是等比例放大,形状恒为长椭圆(见 [pillH]);
 * ④ 动画要 iOS 那种带轻微过冲的弹簧,不要急刹(见下面两组 RESP/DAMP 常量注释);
 * ⑤ **玻璃只在触碰期间存在**。常驻一颗大玻璃 = 静止画面被一颗药丸占掉,
 *    与参考片"平时安静、按住才鼓出来"完全相反。
 * ⑥ 静止底与透镜**同一个宽高比**([ASPECT]),两者只差一个整体倍数:从静止到按住是
 *    **等比例放大**,不是"短椭圆被拉成长椭圆"。而且按住时高度允许超出栏 ——
 *    栏高只给内容留 padding,不承担"把透镜框在里面"的职责。
 *
 * 走过的八条弯路,不要再回去(前四条见 H97/H98):
 * - 静态"放大镜"(镜内一份 1.35 倍放大副本)→ 被读作"底部变形";
 * - 副本横向 scaleX 拉长 + 后退位移表达"拖影"→ 被否:"不是左右拉伸放大,是粘滞";
 * - 整块内容跟着胶囊方向 translate → 被否:"图标不应该动,现在图标在晃动";
 * - 一端钉住、另一端把内容边缘扯出去 → 被否:图标压根不该有任何形变;
 * - 透镜常驻挂在选中项上 → 被否:"透镜不是常驻的啊";
 * - 为了"透镜太大"把 88×46 收成正圆档 73×56、又把栏从 44 抬到 56 →
 *   被否:"圆滚滚的,跟视频里差很多""高度增加太多了,只需要增加一点点"。
 *   教训:**长椭圆的比例不是靠压宽度保住的,是靠别把高度加上去**;
 *   栏只抬到 48 给内容留 padding,鼓出栏外那部分交给透镜自己;
 * - 宽、高各写各的常量(底 58×44 = 1.3,镜 95×53 = 1.8)→
 *   被否:"静止状态也该是长椭圆,从静止到拖动是等比例放大,而不是由短变长"。
 *   **形状是一种不变量,就该只有一个常量。**
 * - 用「前缘 + 后缘两条弹簧之差」表达拖动粘滞,结果透镜**越拖越大** →
 *   被否:"点击透镜变大是对的,滑动的时候就不能再变了;现在滑动时还在继续变大,
 *   很丑很不协调"。教训:**一个观感只由一个状态量驱动** —— 尺寸归按下([lensScale]),
 *   位置归手指;要表达粘滞就动位置(落位过冲),不要动尺寸。
 *
 * 为什么不做"挖孔":本 SDK 的 mask 只剩 `maskShape(shape)` 的"只显示形内"语义
 * (MaskType.Exclude 那套挖孔 API 已不在 CommonMethod 里),挖不成孔。但这一版**也不需要**
 * 挖了 —— 口径变成"盖住的东西就该糊掉",于是底板 + 清晰副本那两层一起省掉。
 *
 * 为什么透镜不用 `clipShape`:H96 量过,带 clipShape 的子节点会被单独合成,栏的
 * backgroundEffect 在那一圈重算一遍,得到的不是折射而是**一圈提亮光晕**。所以裁剪走
 * 节点自身的 `borderRadius`,折射走节点自身的 `backgroundEffect`,一个节点两件事。
 *
 * 透镜要鼓出栏高,所以两层内容的宿主**不能 clip 到栏的圆角** —— 一 clip 就被栏的
 * 边界齐着切平,玻璃就"贴"在栏里而不是"浮"在外面。
 *
 * 为什么独立成组件而不留在 Index 的 @Builder:拖动期间透镜位置每帧都在变,
 * 这个状态若挂在 Index 上,ArkUI V1 的观察粒度是"对象",Index.build() 整棵树
 * (含两个 tab 页面)都会跟着每帧重建 —— 同 H64 让整页每秒重建十次的教训。
 * 收进子组件后,拖动帧只重建这一条栏。
 *
 * 玻璃能透出内容的前提:内容延伸到栏下(Index.shell 已重排为 Stack 叠层),
 * 且各页面的滚动容器用 bottomPad 留出了底部余量。
 *
 * 手感约定:药丸前缘 1:1 跟手;拖动中按接近度提前高亮目标项;
 * 松手按药丸当前位置吸附 —— 要切换时经 onSelect 回父级改 tab,
 * 药丸由 @Watch 统一吸附,不在手势回调里动画,避免两处动画打架。
 */
@Component
export struct GlassTabBar {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /** 当前选中 tab,由父级持有;点击/松手提交后经 onSelect 改回去 */
  @Prop @Watch('syncPill') tab: number;
  /** 底部手势条**避让区**高度(vp)。栏不空出整段,只空出 [INSET_KEEP] 倍 —— 见该常量注释 */
  @Prop inset: number;
  items: TabSpec[] = [];
  onSelect: (i: number) => void = () => {};

  /**
   * 静止底的左上角 x(同时也是透镜的锚点)。拖动帧直接赋值(1:1 跟手,无动画);
   * 松手经 animateTo 吸附 —— 落位那一下的**位移**过冲就是"粘滞/回弹"的全部表达。
   *
   * ⚠️ 这里曾并列一个 `trailX`(后缘,走第二条更慢更松的弹簧),两段之差当作拖动中的
   * 粘滞拽长。已删:宽度一旦跟拖动幅度挂钩,滑动中透镜就持续变大,被否"很丑很不协调"。
   */
  @State pillX: number = 0;
  /** 栏实测宽度;首次测量前药丸先藏着,避免闪现在左上角 */
  @State barW: number = 0;
  /** 拖动中按接近度高亮的项;-1 = 未在拖动(高亮跟 tab 走)。 */
  @State nearIdx: number = -1;
  /**
   * 触摸按在栏上期间为 true:整条栏放大、胶囊染色加深,松手回落。
   * 用 onTouch 而非 isScrollInProgress 之类的程序化信号 —— 只有触摸是只由人产生的
   * (同逐字稿自动滚动的教训,AGENTS 硬规矩 9)。
   */
  @State interacting: boolean = false;
  /**
   * 透镜当前的长大倍率(1 → LENS_PRESS)。
   *
   * 它是**状态量而不是 `.animation()`**:胶囊的尺寸、玻璃的透明度、栏的缩放、折射画布
   * 的取样窗口四处要读同一个值才同步。区别只在"谁来填中间值"——
   * 早先是 `animateTo`(渲染侧插值,JS 只见目标值),现在由 [GlassSpring] 逐帧写进来,
   * 因为折射层每帧都要知道透镜**现在**多大。见该类的注释。
   */
  @State pillGrowth: number = 1;
  /** 触摸按下时预选的 tab(-1 = 无):装机社区式「按下胶囊先过去,松手页面才切」。 */
  private previewIdx: number = -1;
  private dragging: boolean = false;
  private startPillX: number = 0;

  // —— 折射层状态 ——
  /**
   * 栏背后那块内容的快照。
   *
   * **只在按下时截一次**:拖动期间页面不会滚(手指压在栏上),所以背景是静止的,
   * 逐帧截图既没必要、也付不起(全屏 PixelMap 一次十几 MB)。
   */
  private shot: image.PixelMap | null = null;
  /** 画布上下文。坐标单位是 vp,与布局同系 —— 这是整层能对齐的前提。 */
  private gctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  /** 栏节点在**窗口**里的布局位(vp)。按下时量一次;不含 scale,所以另见 toScreenX */
  private gx: number = 0;
  private gy: number = 0;

  // —— 弹簧(折射层要逐帧知道透镜现在的位置与大小,见 GlassSpring)——
  /** 长大倍率。eps 按倍率量程(LENS_PRESS-1 = 0.16)收。 */
  private growSpring: GlassSpring = new GlassSpring(1, RESP_GROWTH, DAMP_GROWTH, 0.0005);
  /** 药丸左缘 x(vp)。 */
  private slideSpring: GlassSpring = new GlassSpring(0, RESP_PILL, DAMP_PILL, 0.05);
  private ticker: GlassTicker | null = null;
  private springing: boolean = false;
  private lastFrameNs: number = 0;

  /**
   * 整条栏的按下缩放。**从 pillGrowth 派生**,不再单独读 `interacting`:
   * 折射层要用同一个数把背景映射回屏幕位置,而 `interacting` 是个二值开关、
   * 中间过程 JS 拿不到 ⇒ 放大动画期间镜内内容和镜外对不上。
   */
  private barScale(): number {
    return 1 + (BAR_PRESS - 1) * this.lensAlpha();
  }

  /// 起弹簧循环(幂等:已经在跑就只改目标值)
  private startSpring(): void {
    if (this.ticker === null) {
      this.ticker = new GlassTicker((t: number): void => { this.tickSpring(t); });
    }
    if (!this.springing) {
      this.springing = true;
      this.lastFrameNs = 0;
      this.getUIContext().postFrameCallback(this.ticker);
    }
  }

  private tickSpring(frameNs: number): void {
    let dt: number = 0;
    if (this.lastFrameNs > 0) {
      dt = (frameNs - this.lastFrameNs) / 1e9;
      // 被系统打断(切后台、掉帧)之后 dt 会是一个巨大的值,不截断的话弹簧一步跨过头
      if (dt > 0.05) dt = 0.05;
    }
    this.lastFrameNs = frameNs;
    if (dt > 0) {
      const settledA: boolean = this.growSpring.step(dt);
      const settledB: boolean = this.slideSpring.step(dt);
      this.pillGrowth = this.growSpring.value;
      this.pillX = this.slideSpring.value;
      if (settledA && settledB) {
        this.springing = false;
        this.lastFrameNs = 0;
        // 缩回原位之后才丢快照:提前丢,折射会在玻璃还没缩完时"啪"地消失
        if (!this.interacting) this.dropBackdrop();
      }
    }
    if (REFRACT) this.repaint();
    if (this.springing && this.ticker !== null) {
      this.getUIContext().postFrameCallback(this.ticker);
    }
  }

  /**
   * 栏内局部坐标 → 屏幕坐标。
   *
   * ⚠️ 必须自己补那 1.06 倍:`getPositionToWindow()` 给的是**布局位**,不受 transform 影响,
   * 而透镜在按住时确实被整条栏放大着 —— 不补这一步,镜内内容会比镜外**小一号**,
   * 症状看起来像"折射方向反了"。轴心是栏的几何中心(`.scale()` 的默认轴心)。
   */
  private toScreenX(localX: number): number {
    const s: number = this.barScale();
    const c: number = this.gx + this.barW / 2;
    return c + (this.gx + localX - c) * s;
  }

  private toScreenY(localY: number): number {
    const s: number = this.barScale();
    const c: number = this.gy + BAR_H / 2;
    return c + (this.gy + localY - c) * s;
  }

  /// 截一次背景 + 量一次栏的窗口位。异步:回来再重画。
  private grabBackdrop(): void {
    const ui = this.getUIContext();
    const node = ui.getFrameNodeById('glassBar');
    if (node !== null) {
      const p = node.getPositionToWindow();
      this.gx = p.x;
      this.gy = p.y;
    }
    ui.getComponentSnapshot().get('glassBackdrop').then((pm: image.PixelMap) => {
      if (!this.interacting) {
        // 快速点按:快照回来时手指已经抬起,淡出那几帧由 tickSpring 收尾,这张图没地方用了。
        // 不立刻 release 就会一直攥着这 13 MB(下一次 drop 只认 this.shot)。
        this.releaseShot(pm);
        return;
      }
      if (this.shot !== null) {
        // 两次按下贴得太近:上一张还在手上、这一张又回来了。旧的那份从此没人引用,
        // 而 drop 只认 this.shot(= 新的那张),不当场放掉就是漏一份。
        this.releaseShot(this.shot);
      }
      this.shot = pm;
      this.repaint();
    }).catch((e: Error) => {
      // 截不到就退回纯磨砂(REFRACT 层画空),不要让一条栏把手势弄崩
      this.shot = null;
      Log.w('UI', `玻璃背景截图失败 ${e.message}`);
    });
  }

  /**
   * 重画折射层:**分段仿射逼近**连续位移场。
   *
   * 这个 SDK 里没有可用的 shader 挂载点(`RuntimeShader` 不存在;`RenderNode.draw` 能拿到
   * 真 canvas,但本 SDK 没有 `RenderNodeContainer`,自定义节点挂不进声明式树),
   * 所以折射只能用一串同心环带近似:每环裁出"两条长椭圆之间"的带子,把背景按
   * **该环的取样倍率**重画一遍 —— 源矩形绕镜心外扩、目的矩形固定。中心倍率 1、
   * 镜缘 [RIM_MAG],smoothstep 过渡 ⇒ 观感是"镜缘把圈外的内容挤进来,中心基本不动"。
   *
   * 每帧成本:RINGS 次 clip + drawImage,画布只有 326×72vp。
   */
  private repaint(): void {
    if (!REFRACT) return;
    const ctx = this.gctx;
    ctx.clearRect(0, 0, ctx.width, ctx.height);
    if (this.shot === null || this.barW <= 0 || this.lensAlpha() <= 0.001) return;
    const w: number = this.pillW();
    const h: number = this.pillH();
    // 画布节点挂在 host-y = -CANVAS_PAD,所以栏内坐标进画布要**加**这一段
    const x: number = this.pillLeft();
    const y: number = this.pillTop() + CANVAS_PAD;
    const cx: number = x + w / 2;
    const cy: number = y + h / 2;
    // 取源矩形左上角在**屏幕**上的位置(vp)。快照是全页,所以源坐标 = 窗口坐标,
    // 且要跟着整条栏的按下缩放走 —— 栏被放大后,透镜真正压在哪块背景上要重算。
    const sx: number = this.toScreenX(x);
    const sy: number = this.toScreenY(this.pillTop());
    // 底层:整颗先按 1:1 铺一遍。内圈本来就不动,外圈会被上面的环带逐层盖掉 ——
    // 有了这一层,位移场里"平坦"的那一段不用再画,接缝也少一处。
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(x, y, w, h, h / 2);
    ctx.clip();
    ctx.drawImage(this.shot, sx, sy, w, h, x, y, w, h);
    ctx.restore();
    for (let i = 0; i < RINGS; i++) {
      const r0: number = i / RINGS;
      const r1: number = (i + 1) / RINGS;
      const m: number = 1 + (RIM_MAG - 1) * rimWeight(r1);
      if (m <= 1.0005) continue;
      ctx.save();
      const p = new Path2D();
      p.roundRect(cx - w * r1 / 2, cy - h * r1 / 2, w * r1, h * r1, h * r1 / 2);
      p.roundRect(cx - w * r0 / 2, cy - h * r0 / 2, w * r0, h * r0, h * r0 / 2);
      ctx.clip(p, 'evenodd');
      // 源矩形按 m 外扩、目的矩形固定不动 ⇒ 这一环读到的是镜缘**之外**的内容,压进这一圈。
      // 反过来(目的外扩)是把镜心内容扯到缘上,那是放大镜不是透镜。
      const sw: number = w * m;
      const sh: number = h * m;
      ctx.drawImage(this.shot,
        sx - (sw - w) / 2, sy - (sh - h) / 2, sw, sh,
        x, y, w, h);
      ctx.restore();
    }
  }

  /**
   * 放掉一张快照。一次全屏 PixelMap ≈ 13 MB **原生**内存,不受 JS GC 管,
   * 所以凡是"这张没人用了"的场合都得显式走这里,不能等回收。
   */
  private releaseShot(pm: image.PixelMap): void {
    pm.release().catch((e: Error) => { Log.w('UI', `玻璃快照释放失败 ${e.message}`); });
  }

  /// 淡出走完:背景快照作废,画布清空(玻璃本来就靠 opacity 缩没)
  private dropBackdrop(): void {
    if (this.shot !== null) {
      const pm = this.shot;
      this.shot = null;
      this.releaseShot(pm);
    }
    this.gctx.clearRect(0, 0, this.gctx.width, this.gctx.height);
  }

  aboutToAppear(): void {
    this.pillTo(this.pillXFor(this.tab));
  }

  aboutToDisappear(): void {
    // 本 SDK 没有 cancelFrameCallback,只能靠这个标志让循环不再续订
    this.springing = false;
    this.dropBackdrop();
  }

  /// 栏的中线(= 两个槽位的分界)。两项对称,所以分界永远在 barW/2。
  private halfW(): number {
    return this.barW / 2;
  }

  /**
   * 第 idx 项内容块的中心。两项不再"半栏均分",而是对称地放进
   * [ITEM_INSET, barW - ITEM_INSET] 这条带里 —— 两个按钮之间的间距就是这么收小的。
   */
  private slotCx(idx: number): number {
    const band: number = this.barW - ITEM_INSET * 2;
    return ITEM_INSET + band * (idx + 0.5) / 2;
  }

  /**
   * 胶囊停在第 idx 项时**前缘**的 x。
   * 锚定在 REST_W(静止底宽)而不是透镜宽:这样 `pillX` 就是静止底的左上角,
   * 灰底和透镜共用同一个位置源,按下时透镜从灰底**原地**长大,不会先跳一下。
   */
  private pillXFor(idx: number): number {
    return this.slotCx(idx) - REST_W / 2;
  }

  /// 触摸点落在哪个 tab 上。x 是相对组件左上角的本地坐标(common.d.ts TouchObject.x)。
  private tabAtLocal(x: number): number {
    return x < this.halfW() ? 0 : 1;
  }

  /// 高亮跟随谁:拖动中跟手指(提前预告落点),平时跟选中项。
  private activeIdx(): number {
    return this.nearIdx >= 0 ? this.nearIdx : this.tab;
  }

  // —— 透镜矩形:宽度只由"按下"决定,高度永远 = 宽 / ASPECT ——
  /**
   * 按下那一下的整体放大:alpha 0 时正好等于静止底,1 时是 LENS_SCALE 倍。
   *
   * ⚠️ 拖动幅度**不在这个式子里** —— 这一行就是"滑动时不再继续变大"的实现点。
   * 上一版这里是「前后缘跨度 × 本倍率」,于是粘滞拽长直接表现为越拖越大。
   */
  private lensScale(): number {
    return 1 + (LENS_SCALE - 1) * this.lensAlpha();
  }

  private pillW(): number {
    return REST_W * this.lensScale();
  }

  private pillCx(): number {
    return this.pillX + REST_W / 2;
  }

  /// 绕静止底中心等比放大,所以透镜始终"套"在灰底正中,而不是往右长。
  private pillLeft(): number {
    return this.pillCx() - this.pillW() / 2;
  }

  /**
   * 高度**永远由宽度除以 [ASPECT] 得出** —— 这一行就是"等比例放大"的全部实现。
   * 按下放大只改宽度,高度自动跟着走,所以形状恒为长椭圆。
   * 之前这里读的是独立的 PILL_H 和一个 squeeze 系数,于是静止/按住两态比例不一致。
   */
  private pillH(): number {
    return this.pillW() / ASPECT;
  }

  /// 静止底的左上角 x:就是 pillX 本身(锚定见 pillXFor)
  private restX(): number {
    return this.pillX;
  }

  private pillCy(): number {
    return BAR_H / 2;
  }

  private pillTop(): number {
    return this.pillCy() - this.pillH() / 2;
  }

  /**
   * 透镜圆角:**恒等于半高**,也就是永远是一颗标准长椭圆(药丸形)。
   * 之前在拽长时把圆角收成 0.42 倍高,想读成"软玻璃被拽扁",结果整颗看起来是圆的 ——
   * 装机被否"不动的时候也应该是长椭圆,现在圆滚滚的"。形变量全交给宽度。
   */
  private pillR(): number {
    return this.pillH() / 2;
  }

  /**
   * 玻璃"受光量"系数:浅色 1,深色 0.42。
   *
   * 高光边和上缘那条白渐变是按浅色底校的。装机在深色模式下实拍:同一档白边压在墨底上
   * 不是玻璃而是**一圈硬白线** —— 深色玻璃本身不透光,边缘能接住的光少得多。
   * 所以把"受光"整体收一档,而不是给深色另起一组常量(两组值一定会漂)。
   */
  private glassK(): number {
    return this.scheme.isDark ? 0.42 : 1.0;
  }

  /**
   * 厚度渐变的**下缘**那一档:浅色压暗(给厚度),深色改成接一点光
   * (底下本来就是墨,再压黑等于没有)。
   * 写成方法而不是在 @Builder 里放三元:渐变色标是 `[ResourceColor, number]` 元组,
   * 两个分支的数组字面量在 ArkTS 下推不出同一个元组类型;@Builder 体内又不能声明局部量。
   */
  private lensEdgeLow(): string {
    return this.scheme.isDark ? withAlpha('#FFFFFF', 0.07) : withAlpha('#000000', 0.10);
  }

  /**
   * 玻璃的存在感:**0 = 静止时压根没有这颗透镜**,1 = 按到底。
   *
   * 不新开一个状态量,直接读 pillGrowth —— 它本来就是"按下 1 → LENS_PRESS、松手回 1"
   * 的弹簧值,透明度跟着它同一条曲线长大缩回,天然同步,也不用 `.animation()`
   * (在这个节点上加 `.animation()` 会把逐帧赋值的 width/position 一起拖进弹簧,
   * 前缘就不再 1:1 跟手了)。
   */
  private lensAlpha(): number {
    return Math.max(0, Math.min(1, (this.pillGrowth - 1) / (LENS_PRESS - 1)));
  }

  /**
   * 玻璃染色:跟着 pillGrowth 走而不是跟着 interacting 跳变 —— 否则弹簧刚起步颜色就
   * "啪"地深一档,和正在长大的透镜对不上。
   */
  private lensTint(): number {
    return LENS_TINT + this.lensAlpha() * 0.10;
  }

  /// 父级改了 tab(点击别处、松手提交)→ 药丸动画吸到新位置。
  private syncPill(): void {
    if (this.dragging) return;
    this.animatePill(this.pillXFor(this.tab));
  }

  /**
   * 松手吸附:**一条弹簧、只移动位置**。过冲由 damping 0.7 给(临界是 1,低于它才会甩过头),
   * response 与透镜长大同一档(0.42),两处一起动才像同一个物体。
   *
   * ⚠️ 曾经是两条(前缘紧 + 后缘松),用两段之差表达粘滞 —— 代价是宽度跟着拖动幅度长,
   * 被否。现在粘滞全部由这条位移曲线承担。
   *
   * ⚠️ 再早用 `animateTo`,但那样 JS 侧只有目标值、拿不到当前值,折射画布对不上帧
   * (见 GlassSpring)。现在两条弹簧都在 JS 里积分,每帧写回 @State 并重画 canvas。
   */
  private animatePill(x: number): void {
    if (this.slideSpring.target === x && !this.springing) return;
    this.slideSpring.target = x;
    this.startSpring();
  }

  /// 胶囊长大 / 缩回。倍率是状态量而不是 `.animation()`:见 pillGrowth 注释。
  private animateGrowth(target: number): void {
    if (this.growSpring.target === target) return;
    this.growSpring.target = target;
    this.startSpring();
  }

  /// 1:1 跟手的帧:不走弹簧,但要把弹簧的当前值对齐,否则下一帧它会从老位置往回补。
  private pillTo(x: number): void {
    this.slideSpring.snap(x);
    this.pillX = x;
  }

  /// 松手 / 被系统取消手势:按药丸当前位置吸附最近项。switchable=false(取消)只回弹。
  private settle(switchable: boolean): void {
    if (!this.dragging) return;
    this.dragging = false;
    this.nearIdx = -1;
    this.previewIdx = -1;
    const target = this.pillX < (this.pillXFor(0) + this.pillXFor(1)) / 2 ? 0 : 1;
    if (switchable && target !== this.tab) {
      // 药丸不在这里动:tab 一变 @Watch 会统一吸附
      this.onSelect(target);
    } else {
      this.animatePill(this.pillXFor(this.tab));
    }
  }

  /// tab 内容(图标 + 文案)。**只画一层,而且永远静止** —— 参考片逐帧量过:被玻璃压住的
  /// 图标零位移,形变全在玻璃自己身上(模型注释在文件头)。这里曾经挂过 scale/translate
  /// 表达"内容被粘住",三版都被否掉,不要再往这个节点上加形变。
  /// 命中统一走 layers 容器上的 onTouch(子项再挂 onClick 会和手势抢)。
  @Builder
  Items() {
    Row() {
      ForEach(this.items, (it: TabSpec, idx: number) => {
        // 图标与文字的间距收得很紧(space 2):间距一大,透镜要罩住整块内容就得
        // 跟着变高,观感发"胖"(装机社区的胶囊是贴合内容的扁长条)。
        Column({ space: 2 }) {
          Image(it.icon)
            .width(19).height(19)
            .fillColor(this.activeIdx() === idx ? this.scheme.primary : this.scheme.onSurfaceVariant)
          // caption(11) 原样。曾经为了收小整条栏压到 9,理由是"两个字的文案比图标还宽,
          // 透镜就得跟着变宽" —— 那条链已经不成立了:透镜 86 远大于内容块,
          // 而 9 号字在真机上读起来太小(装机反馈"图标和文字再大一点")。
          Text(it.label)
            .fontSize(TypeScale.caption * this.fontScale)
            .letterSpacing(Tracking.caption)
            .fontColor(this.activeIdx() === idx ? this.scheme.primary : this.scheme.onSurfaceVariant)
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }, (it: TabSpec, idx: number) => idx.toString())
    }
    .width('100%')
    .height(BAR_H)
    /**
     * 必须与 [slotCx] 用同一个内收量:两列是 layoutWeight 均分的,不加这层 padding
     * 内容中心就永远落在 barW/4 与 3barW/4,而透镜按 slotCx 走 —— 装机实测两者差了
     * 半个 ITEM_INSET,透镜压在字的一半上。
     */
    .padding({ left: ITEM_INSET, right: ITEM_INSET })
  }

  /**
   * 第 1 层:透镜本体。**一颗节点搞定折射 + 染色 + 高光边**,没有底板/染色层/副本那三层。
   *
   * 尺寸是**直接改 width/height**,不是 `.scale()`:缩放会把玻璃一起放大,
   * 而口径是"内容永远静止"。宽度只有一个来源 —— 按下放大([lensScale])× 静止底宽,
   * **式子里没有任何拖动量**;高度由 [ASPECT] 从宽度倒推,所以静止/按住两态比例一致。
   *
   * 折射靠透镜**自己**的 `backgroundEffect`:它糊的是"这个节点背后的一切"—— 栏的磨砂底
   * 和栏下那行列表文字。装机量过:半径 26 会把 16vp 的图标糊到完全消失,10 也只剩一团
   * 绿雾,所以内容**不能**画在玻璃之下(见 [ContentLayer] 的 z 序说明)。
   *
   * 为什么用 `.borderRadius` 而不是 `.clipShape`:H96 量过,带 clipShape 的子节点会被单独
   * 合成,栏的 backgroundEffect 在那一圈重算一遍,结果不是折射而是一圈提亮光晕。
   * borderRadius 走的是节点自身轮廓,不触发那条路径。
   */
  /**
   * 第 0.5 层(实验):**真折射**。一块画布,把栏背后那块内容按位移场搬进透镜里。
   *
   * 画布比栏上下各多出 [CANVAS_PAD](透镜鼓出栏外那截要画得下),且**不跟随透镜移动** ——
   * 移动的是画布里的内容。这样拖动帧只重画一次 canvas,不动布局。
   *
   * z 序:在 [RestPill] 之上、[LensLayer] 之下 —— 玻璃那层的 `backgroundEffect`
   * 会糊它,于是镜内读到的是"折射过 + 又糊一档"的内容,和镜外的磨砂同构。
   */
  @Builder
  RefractLayer() {
    Canvas(this.gctx)
      .width('100%')
      .height(BAR_H + CANVAS_PAD * 2)
      .position({ x: 0, y: -CANVAS_PAD })
      // 和玻璃同一条淡入淡出曲线:画布自己不会随玻璃缩没,不给它这个,
      // 松手时会看到折射先"啪"地消失、玻璃还在缩。
      .opacity(this.lensAlpha())
      .onReady(() => {
        this.repaint();
      })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  LensLayer() {
    Row()
      .width(this.pillW()).height(this.pillH())
      .position({ x: this.pillLeft(), y: this.pillTop() })
      .borderRadius(this.pillR())
      /**
       * 厚度感:参考片那颗玻璃**上缘进光、下缘压暗**,不是均匀一块白。
       * 画在 backgroundEffect 之上(节点自己的背景色会盖在糊好的底上),
       * 所以中间必须全透,否则又把内容洗白。
       * 深色下压暗那一段没有意义(底下本来就是墨),换成下缘也接一点光。
       */
      .linearGradient({
        angle: 180,
        colors: [[withAlpha('#FFFFFF', 0.20 * this.glassK()), 0.0],
                 [withAlpha('#FFFFFF', 0.0), 0.42],
                 [this.lensEdgeLow(), 1.0]]
      })
      .backgroundEffect({
        radius: LENS_BLUR,
        saturation: LENS_SAT,
        brightness: LENS_BRIGHT,
        color: withAlpha(this.scheme.surface, this.lensTint())
      })
      // 高光边:参考片那圈亮边占"玻璃感"读感的一半;深色下受光量另收一档(glassK)
      .border({ width: 1, color: withAlpha('#FFFFFF', LENS_RIM * this.glassK()) })
      .shadow({ radius: 18, color: withAlpha('#000000', 0.10), offsetY: 4 })
      // 静止时整颗玻璃不存在(参考片:没有手指时栏上只有一块扁灰底)
      .opacity(this.lensAlpha())
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 第 0 层:**常驻的选中底**。这才是静止时唯一可见的标记 —— 扁的浅灰圆角矩形,
   * 不鼓出栏外、不折射([REST_W]/[REST_H]/[REST_TINT] 按参考片静止帧定的)。
   *
   * 位置钉在 `pillX`(那条 1:1 跟手的边)上,所以拖动中它会跟着手指走;
   * 玻璃盖在它上面,松手后玻璃缩没,灰底停在新的选中项 —— 交接是连续的。
   */
  @Builder
  RestPill() {
    Row()
      .width(REST_W).height(REST_H)
      .position({ x: this.restX(), y: (BAR_H - REST_H) / 2 })
      .borderRadius(REST_H / 2)
      .backgroundColor(withAlpha(this.scheme.onSurfaceVariant, REST_TINT))
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 第 2 层:tab 内容,**画在玻璃之上**。
   *
   * z 序是这一层的全部意义:参考片里图标始终是清晰的,玻璃糊的是它**背后**的页面内容。
   * 把内容放到玻璃之下(上一版)会连图标一起糊掉 —— 16vp 的小图形在 radius 10 的模糊
   * 下就只剩一团雾,文案直接消失。所以这里只画一份,压在玻璃上,不需要"副本 + 裁剪"。
   */
  @Builder
  ContentLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.Items()
    }
    .width('100%')
    .height(BAR_H)
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        /**
         * 两层内容的宿主:手势(onTouch)挂在这一层。
         * **这里不能 `.clip(true)`** —— 透镜按下要鼓出栏外(需求指定),一 clip 就被栏的
         * 圆角齐着切平,玻璃就"贴"在栏里而不是"浮"在外面。两层各自不越界,不需要宿主裁剪。
         *
         * z 序是**玻璃在下、内容在上**,与直觉相反:参考片里图标清晰,糊的是玻璃背后的
         * 页面内容。反过来的话 16vp 的图标会被自己的折射糊成一团雾(装机实测,见 LensLayer)。
         */
        Stack({ alignContent: Alignment.TopStart }) {
          // 首次量宽之前 pillX 还是 0,两块都会闪现在栏左端
          if (this.barW > 0) {
            this.RestPill()
            if (REFRACT) {
              this.RefractLayer()
            }
            this.LensLayer()
          }
          this.ContentLayer()
        }
        .width('100%')
        .height(BAR_H)
        .onTouch((e: TouchEvent) => {
          if (e.type === TouchType.Down) {
            this.interacting = true;
            this.animateGrowth(LENS_PRESS);
            // 折射取源:按下截一次(拖动期间页面不动,不需要逐帧截)
            if (REFRACT) {
              this.grabBackdrop();
            }
            // 按下即预选:胶囊先滑到手指所在的 tab,页面等松手再切(对齐装机社区)
            const idx = this.tabAtLocal(e.touches[0].x);
            if (idx !== this.tab) {
              this.previewIdx = idx;
              this.nearIdx = idx;
              this.animatePill(this.pillXFor(idx));
            }
          } else if (e.type === TouchType.Up) {
            this.interacting = false;
            // 快照**不在这里放**:缩回是一次 ~0.4s 的弹簧,折射内容得活到淡出走完,
            // 否则镜内在松手那一帧"啪"地跳回栏底磨砂。释放交给 tickSpring 的停住分支。
            this.animateGrowth(1);
            // 纯点按(未演变成拖动)在这里提交;拖动的提交走 PanGesture 的 settle。
            // Up 与 onActionEnd 的先后不定,两边都以 previewIdx/dragging 判重,提交是幂等的。
            if (this.previewIdx >= 0 && !this.dragging) {
              const idx = this.previewIdx;
              this.previewIdx = -1;
              this.nearIdx = -1;
              if (idx !== this.tab) this.onSelect(idx);
            }
          } else if (e.type === TouchType.Cancel) {
            this.interacting = false;
            this.animateGrowth(1);   // 同上:淡出走完才放快照
            this.previewIdx = -1;
            if (!this.dragging) {
              this.nearIdx = -1;
              this.animatePill(this.pillXFor(this.tab));
            }
          }
        })
      }
      .id('glassBar')
      .width('100%')
      .height(BAR_H)
      .borderRadius(BAR_H / 2)
      /**
       * 按下整条栏放大(需求:长按时**整个底部 tab**都放大,不是只有被按的那个图标)。
       * 缩放的轴心取栏的几何中心,`centerY` 用默认 50% 即可 —— 下面另有的 inset 空隙
       * 在父 Column 上,不在这一层。
       *
       * ⚠️ 缩放值从 `pillGrowth` 派生([barScale]),**不再配 `.animation()`**:
       * 渲染侧插出来的中间值 JS 读不到,折射画布拿不到"栏现在放大到几",
       * 放大过程中镜内内容会和镜外错开一档。改成每帧由 JS 写值之后,动画自然逐帧生效。
       */
      .scale({ x: this.barScale(), y: this.barScale() })
      /**
       * 玻璃本体:实时模糊 + 一层半透明 surface 染色。
       * 半透明度 0.6:太透则浅色文字压在亮内容上读不清,太实则玻璃感全无;
       * radius / saturation 是首版凭观感取值,装机后按实机效果再调。
       * 投影给 z 轴高度:整条栏"浮"在页面之上,而非贴底的一块平面。
       */
      .backgroundEffect({
        radius: BASE_BLUR,
        saturation: BASE_SAT,
        brightness: 1.0,
        color: withAlpha(this.scheme.surface, BASE_TINT)
      })
      .border({ width: 0.8, color: withAlpha(this.scheme.outline, 0.45) })
      .shadow({ radius: 24, color: withAlpha('#000000', 0.16), offsetY: 5 })
      .onAreaChange((_o: Area, n: Area) => {
        const w = Number(n.width);
        if (w !== this.barW) {
          this.barW = w;
          // 首次测量 / 旋屏后按当前 tab 对位(aboutToAppear 时宽度还是 0,算不准)。
          if (!this.dragging) {
            this.pillTo(this.pillXFor(this.tab));
          }
        }
      })
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
          .onActionStart((_e: GestureEvent) => {
            this.dragging = true;
            // 从胶囊**当前位置**继续拖(按下预选可能已把它挪到目标 tab),不要回到选中位
            this.startPillX = this.pillX;
          })
          .onActionUpdate((e: GestureEvent) => {
            // offsetX 单位是 vp(gesture.d.ts 明确标注),与布局坐标同单位,直接相加
            const lo = this.pillXFor(0);
            const hi = this.pillXFor(1);
            /**
             * 前缘 1:1 跟手 —— 赋值,不起动画(动画会让它落后于手指)。
             * 这里**只写位置**:透镜宽度不读拖动量([pillW]),所以滑动中它保持按住时那一档,
             * 不再越拖越大。粘滞感落在松手后的 animatePill 上。
             */
            this.pillTo(Math.max(lo, Math.min(hi, this.startPillX + e.offsetX)));
            this.nearIdx = this.pillX < (lo + hi) / 2 ? 0 : 1;
            // 折射层不吃动画,只吃这个逐帧赋值 —— 所以必须在这里手动重画
            if (REFRACT) {
              this.repaint();
            }
          })
          .onActionEnd(() => { this.settle(true); })
          .onActionCancel(() => { this.settle(false); })
      )
    }
    .width('100%')
    .height(barFootprint(this.inset))
    /**
     * 悬浮长椭圆的左右留白:两侧有可见的缝,胶囊才"浮"得起来;下沿只空出 [INSET_KEEP] 倍的
     * 手势区 —— 让栏底到小白条的距离等于小白条到屏底,而不是悬在避让区上方。
     * 12 → SIDE_PAD(24) 是装机反馈"栏太长、放大后顶出屏幕"的直接修法:胶囊最大宽度
     * 由栏宽决定,留白加宽同时把两格中心收拢(ITEM_INSET),行程也短了。
     */
    .padding({ left: SIDE_PAD, right: SIDE_PAD })
  }
}
