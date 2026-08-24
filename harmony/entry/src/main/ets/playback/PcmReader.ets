import pcm from 'libreverb_pcm.so';
import { Log } from '../util/Logger';

/**
 * native 音频解码模块的 ArkTS 封装:把本地音频文件读成 **16kHz 单声道 s16le PCM**。
 *
 * 为什么要走 native:ArkTS 层**没有解封装/解码 API**(`@ohos.multimedia.media` 只有
 * AVPlayer 拿不到 PCM、AVTranscoder 只能输出 AAC),而系统语音识别只吃裸 PCM。
 * 实现见 `entry/src/main/cpp/reverb_pcm.cpp`。
 *
 * **`read()` 是同步阻塞的** —— 解 20 秒音频在真机上是几十毫秒量级,放在 UI 线程会掉帧。
 * 目前调用方(`SpeechTranscriber`)在 `await` 链上跑,每解一窗之后紧接着是一次识别会话
 * (那一步本来就要等更久),实测节奏上可以接受;真发现掉帧就把整条转写搬进 TaskPool
 * —— 那时要注意 native 句柄**不能跨线程传**,得把"打开—读—关"整段都放进同一个任务里。
 */
export class PcmReader {

  private static ok: boolean = false;
  private static probed: boolean = false;
  private static readonly TAG: string = 'PcmReader';

  private handle: number = 0;

  private constructor(handle: number) {
    this.handle = handle;
  }

  /**
   * 这台设备上模块能不能用。**失败不抛异常**:调用方据此如实告诉用户"本机识别用不了",
   * 而不是让整条流程崩掉。
   */
  /**
   * 探一次 native 模块在不在,结果记住。
   *
   * 为什么要探而不是直接用:.so 是随包的,理论上一定在;但**这一层是"用不了就如实告诉用户"
   * 的兜底** —— 万一某个机型上系统的编解码库缺失、或将来把 .so 拆成按需下载,
   * 这里返回 false 会让界面显示"本机识别用不了",而不是整条流程抛异常崩掉。
   */
  static available(): boolean {
    if (PcmReader.probed) return PcmReader.ok;
    PcmReader.probed = true;
    try {
      // 取一下函数本身就够:.so 没起来的话这里就会抛
      PcmReader.ok = typeof pcm.open === 'function' && typeof pcm.read === 'function';
    } catch (e) {
      Log.w(PcmReader.TAG, `native 模块加载失败:${e}`);
      PcmReader.ok = false;
    }
    return PcmReader.ok;
  }

  /// 打开一个音频文件。返回 null 表示打不开(格式不支持、文件坏了、没有音频轨…)
  static open(path: string, sampleRate: number): PcmReader | null {
    if (!PcmReader.available()) return null;
    try {
      const h = pcm.open(path, sampleRate);
      if (h === 0) return null;
      return new PcmReader(h);
    } catch (e) {
      Log.w(PcmReader.TAG, `打开失败 ${path}:${e}`);
      return null;
    }
  }

  /**
   * 取最多 `maxSamples` 个采样(16k 单声道 s16)。
   * @returns s16le 字节;**长度为 0 表示已经到文件末尾**。出错返回 null。
   */
  read(maxSamples: number): Uint8Array | null {
    if (this.handle === 0) return null;
    try {
      return new Uint8Array(pcm.read(this.handle, maxSamples));
    } catch (e) {
      Log.w(PcmReader.TAG, `读取失败:${e}`);
      return null;
    }
  }

  close(): void {
    if (this.handle === 0) return;
    try {
      pcm.close(this.handle);
    } catch (e) {
      // 忽略:关不掉也没别的办法
    }
    this.handle = 0;
  }
}
