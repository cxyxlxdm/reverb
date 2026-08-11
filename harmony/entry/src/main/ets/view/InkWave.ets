import { withAlpha } from '../theme/Theme';

/// 水墨声波:3 条正弦色带 + 中心墨晕,双相位驱动(6200ms / 9700ms)叠出自然流动。
/// 移植自 Android `ui/components/InkWave.kt`。
/// 吸取本项目性能教训:**仅在可见且播放时才跑动画**(animating=false 时收束成近静止细线)。
interface Ribbon {
  ampFactor: number;
  freq: number;
  phase0: number;
  dir: number;
  alpha: number;
}

const RIBBONS: Ribbon[] = [
  { ampFactor: 1.0, freq: 1.6, phase0: 0.0, dir: 1, alpha: 0.22 },
  { ampFactor: 0.7, freq: 2.3, phase0: 1.1, dir: -1, alpha: 0.16 },
  { ampFactor: 0.45, freq: 3.1, phase0: 2.4, dir: 1, alpha: 0.11 }
];

const SEGMENTS = 56;

@Component
export struct InkWave {
  @Prop color: string;
  @Prop animating: boolean;

  @State private phaseA: number = 0;
  @State private phaseB: number = 0;
  @State private amp: number = 0.12;
  private timer: number = -1;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.applyAnimating();
  }

  aboutToDisappear(): void {
    this.stop();
  }

  /// animating 变化时启停(Prop 变更后 build 会重跑,这里在 onAreaChange 兜不到,故用 getter 检查)
  private applyAnimating(): void {
    this.amp = this.animating ? 1.0 : 0.12;
    if (this.animating) this.start(); else this.stop();
  }

  private start(): void {
    if (this.timer >= 0) return;
    const t0 = Date.now();
    // 30fps:低于 Android 的连续动画但足够顺,且明显省电(与 macOS 降频到 24fps 同一取舍)
    this.timer = setInterval(() => {
      const dt = Date.now() - t0;
      this.phaseA = (dt % 6200) / 6200 * Math.PI * 2;
      this.phaseB = (dt % 9700) / 9700 * Math.PI * 2;
      this.draw();
    }, 33);
  }

  private stop(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.draw();   // 收束后再画一帧静态
  }

  private draw(): void {
    const c = this.ctx;
    const w = c.width;
    const h = c.height;
    if (w <= 0 || h <= 0) return;
    c.clearRect(0, 0, w, h);

    // 中心墨晕
    const grd = c.createRadialGradient(w / 2, h / 2, 0, w / 2, h / 2, w * 0.55);
    grd.addColorStop(0, withAlpha(this.color, 0.10 * this.amp));
    grd.addColorStop(1, withAlpha(this.color, 0));
    c.fillStyle = grd;
    c.fillRect(0, 0, w, h);

    const midY = h / 2;
    for (let r = 0; r < RIBBONS.length; r++) {
      const rb = RIBBONS[r];
      const phase = r % 2 === 0 ? this.phaseA : this.phaseB;
      c.beginPath();
      c.lineWidth = 2.2;
      c.strokeStyle = withAlpha(this.color, rb.alpha);
      for (let i = 0; i <= SEGMENTS; i++) {
        const fx = i / SEGMENTS;
        const x = fx * w;
        const y = midY + h * 0.13 * this.amp * rb.ampFactor
          * Math.sin(rb.freq * fx * Math.PI * 2 + rb.dir * phase + rb.phase0);
        if (i === 0) c.moveTo(x, y); else c.lineTo(x, y);
      }
      c.stroke();
    }
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.applyAnimating();
        this.draw();
      })
      // Prop 变化时 build 重跑,借 onAreaChange 之外的时机同步启停状态
      .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, _ratio: number) => {
        if (isVisible) this.applyAnimating(); else this.stop();
      })
  }
}
