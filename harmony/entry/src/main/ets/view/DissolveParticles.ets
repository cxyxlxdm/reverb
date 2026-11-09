import { Log } from '../util/Logger';

/**
 * 播放条点 X 的**粒子消散**层 —— 与 Android `DissolveParticles.kt` / macOS
 * `DissolveParticles.swift` 同一套物理(参考用户视频 2026-10-25 第二版结论):
 * 整条同时碎成小方块,向上抛射为主(70%,−120°~−60°)+ 随机四散,无重力、指数阻尼
 * 先快后慢,0.4~0.6s 内按寿命淡出缩小;**散尽之后**布局才收(由 Index 在 430ms 后
 * 才 close() 保证,见 closeMini)。
 *
 * 位移用解析式 `p(t)=p0+v0·(1−e^(−kt))/k`,k=3.2 —— 三端同一公式,免逐帧积分。
 * 颜色按位置分区近似(进度线=primary / 左端封面=深色簇 / 中段文字=灰),不采样位图,
 * 理由见 Android 侧组件头注。
 *
 * ⚠️ ArkUI 没有逐帧回调的 Canvas 动画 API,这里用 setInterval(16ms) 手画。
 * 粒子峰值 ~1200,fillRect 是 native 路径,真机实测前先按这个量级;
 * 若装机读出掉帧,第一刀砍 [SPAWN_STEP] 的密度(步长 8.5 → 10),不要砍粒子数以外的逻辑。
 */
class Shard {
  x0: number = 0;
  y0: number = 0;
  vx: number = 0;
  vy: number = 0;
  size: number = 3;
  color: string = '#8A8D93';
  lifeMs: number = 500;
  delayMs: number = 0;
}

const DAMP_K = 2.4; // 2026-10-26 调慢一档(原 3.2),与两端同步
const LIFE_MIN = 600; // 2026-10-26 调慢(原 380~620),与两端同步
const LIFE_MAX = 1000;
const TOTAL_MS = LIFE_MAX + 90;
const DARKS: string[] = ['#3A3F4A', '#2E333D', '#4A4E57'];
const GRAY = '#8A8D93';

/** 速度阻尼解析式的位移:∫v0·e^(−kt) = v0·(1−e^(−kt))/k。 */
function dampShift(v0: number, tSec: number): number {
  return v0 * (1 - Math.exp(-DAMP_K * tSec)) / DAMP_K;
}

/**
 * 消散请求的共享状态。**必须走 @Observed + @ObjectLink**(与 SettingsStore/PlayerController
 * 同一套):第一版用 @Prop @Watch 传 tick,装机实测 @Watch 从不触发(条子照常关,
 * 粒子一个都没画;红块/绿罩两级诊断定位)—— @Prop 的深拷贝同步在这条链上不回调。
 * @Observed 的字段赋值对 @ObjectLink 持有者是项目里验证过的通路(BottomBar 靠它刷新)。
 */
@Observed
export class DissolveState {
  tick: number = 0;
  rectX: number = 0;
  rectY: number = 0;
  rectW: number = 0;
  rectH: number = 0;

  burst(x: number, y: number, w: number, h: number): void {
    this.rectX = x; this.rectY = y; this.rectW = w; this.rectH = h;
    this.tick++;
  }
}

@Component
export struct DissolveParticles {
  @ObjectLink @Watch('onTrigger') state: DissolveState;
  /// 主题主色(hex),进度线与按钮区碎片用它。
  @Prop primaryColor: string = '#6750A4';

  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private shards: Shard[] = [];
  private timer: number = -1;
  private t0: number = 0;

  aboutToDisappear(): void {
    this.stop();
  }

  private stop(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.ctx.clearRect(0, 0, this.state.rectW + 4, this.state.rectH + 800);
  }

  private onTrigger(): void {
    if (this.state.tick === 0 || this.state.rectW <= 0 || this.state.rectH <= 0) return;
    this.spawn();
    this.stop();
    this.t0 = Date.now();
    // ⚠️ 首帧立刻画一次再起表,避免 setInterval 的 16ms 盲区里条子已隐身而粒子还没出现
    this.draw();
    this.timer = setInterval((): void => {
      this.draw();
      if (Date.now() - this.t0 > TOTAL_MS) {
        this.stop();
        this.shards = [];
      }
    }, 16);
  }

  private spawn(): void {
    const step = this.state.rectH / 8.5; // 条高 56vp ⇒ 步长约 6.6vp,与 Android 同密度(那边条高同为 56)
    const out: Shard[] = [];
    let seed = this.state.tick * 7919 + 1; // 可复现的伪随机(排障时同一 tick 同一碎片图)
    const rnd = (): number => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed / 2147483648;
    };
    for (let y = this.state.rectY; y < this.state.rectY + this.state.rectH; y += step) {
      for (let x = this.state.rectX; x < this.state.rectX + this.state.rectW; x += step) {
        const px = x + step * 0.5;
        const py = y + step * 0.5;
        const relX = (px - this.state.rectX) / this.state.rectW;
        const relY = (py - this.state.rectY) / this.state.rectH;
        const r = rnd();
        const s = new Shard();
        s.x0 = px; s.y0 = py;
        if (relY < 0.06) s.color = this.primaryColor;
        else if (relX < 0.30) s.color = DARKS[Math.floor(r * DARKS.length) % DARKS.length];
        else if (relX > 0.76 && r < 0.3) s.color = this.primaryColor;
        else s.color = GRAY;
        const up = rnd() < 0.7;
        const angDeg = up ? -(120 - rnd() * 60) : rnd() * 360;
        const ang = angDeg * Math.PI / 180;
        const speed = up ? 200 + rnd() * 360 : 100 + rnd() * 220;
        s.vx = speed * Math.cos(ang);
        s.vy = speed * Math.sin(ang);
        s.size = step * (relX < 0.30 ? 0.55 + rnd() * 0.45 : 0.35 + rnd() * 0.35);
        s.lifeMs = LIFE_MIN + Math.floor(rnd() * (LIFE_MAX - LIFE_MIN));
        s.delayMs = Math.floor(rnd() * 60);
        out.push(s);
      }
    }
    this.shards = out;
    Log.i('Dissolve', `spawn ${out.length} shards rect=${this.state.rectW}x${this.state.rectH}@${this.state.rectX},${this.state.rectY}`);
  }

  private draw(): void {
    const t = Date.now() - this.t0;
    // 粒子会飞出条子矩形上方几百 vp,清屏范围必须盖住整段轨迹(否则残影)。
    this.ctx.clearRect(0, 0, this.state.rectX + this.state.rectW + 400, this.state.rectY + 800);
    for (const s of this.shards) {
      const lt = t - s.delayMs;
      if (lt < 0 || lt > s.lifeMs) continue;
      const prog = lt / s.lifeMs;
      // (1−p)^2.5:前段稳、末段加速消失;尺寸随寿命缩到 65%
      const a = Math.pow(1 - prog, 2.5);
      if (a < 0.02) continue;
      const half = s.size * (1 - 0.35 * prog) / 2;
      const x = s.x0 + dampShift(s.vx, lt / 1000) - half;
      const y = s.y0 + dampShift(s.vy, lt / 1000) - half;
      this.ctx.globalAlpha = a;
      this.ctx.fillStyle = s.color;
      this.ctx.fillRect(x, y, half * 2, half * 2);
    }
    this.ctx.globalAlpha = 1;
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      .onReady((): void => {
        // Canvas 就绪前收到的触发画不出;就绪后若 tick 已非 0,补一轮
        if (this.state.tick > 0 && this.shards.length === 0 && this.timer < 0) this.onTrigger();
      })
  }
}
