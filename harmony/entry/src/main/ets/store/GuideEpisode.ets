import type common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { Episode } from '../model/Models';
import { L } from '../util/L';
import { Log } from '../util/Logger';

/// 随包内置的「新手引导」音频。
///
/// 为什么要有它:全新安装、又恰好没网时,播放链路一个字节都放不出来 —— 播放条、进度、
/// 倍速、后台继续放、锁屏控制,全都无从体验,也无从判断"是 App 坏了还是网络不通"。
/// 这段 30 秒的音频打在包里,任何时候点开都能走通完整播放流程。
///
/// 与另两端的差别在**取源方式**:AVPlayer 的 url 只收 fd:// 或网络地址,rawfile 不能直接播。
/// 与其在 PlayerController 里再开一条 getRawFd → fdSrc 的分支,不如首次启动时把 rawfile
/// 拷到 filesDir 一份(138KB,一次性),随后完全复用**已有的本地文件播放路径**
/// (AppContainer 里的 localFileProvider)—— 播放层零改动。
///
/// **它不是一集真正的播客**,因此刻意不进任何统计:见 PlayerController 里对 id 的判断
/// —— 不记历史、不计收听时长。否则"收听时长"第一条就是引导音频,很荒唐。
export class GuideEpisode {
  /// 稳定标识。用 reverb:// 前缀,确保不会与任何真实 RSS 的 guid 相同。
  static readonly ID: string = 'reverb://guide-intro';
  /// 与实际音频时长一致(见 make-guide.sh 输出),用于进度条刻度。
  private static readonly DURATION_SEC: number = 32;
  private static readonly RAW = 'guide_intro.m4a';

  /// 落地后的绝对路径;空串表示不可用(资源缺失/拷贝失败),此时不显示入口。
  private static localPath: string = '';

  /**
   * 把 rawfile 拷到 filesDir。已存在且大小一致则跳过。
   *
   * **全程异步**:138KB 的读 + 写如果同步做在 boot 里,会和其他 store 的同步读叠加,
   * 一起拖长首帧、加重 THREAD_BLOCK 风险。这份数据只有首次使用者会用到,
   * 晚几十毫秒就绪毫无影响(未就绪时 available() 返回 false,引导卡先不显示)。
   */
  static async prepare(ctx: common.UIAbilityContext): Promise<void> {
    const dest = `${ctx.filesDir}/${GuideEpisode.RAW}`;
    try {
      // 先看是否已落地:命中就完全不读 rawfile
      const bytes = await ctx.resourceManager.getRawFileContent(GuideEpisode.RAW);
      let needWrite = true;
      try {
        if (await fs.access(dest)) {
          const st = await fs.stat(dest);
          if (st.size === bytes.byteLength) needWrite = false;
        }
      } catch (e) {
        needWrite = true;
      }
      if (needWrite) {
        const f = await fs.open(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          await fs.write(f.fd, bytes.buffer as ArrayBuffer);
        } finally {
          await fs.close(f);
        }
        Log.i('Guide', `引导音频落地 ${bytes.byteLength} 字节`);
      }
      GuideEpisode.localPath = dest;
    } catch (e) {
      // 资源缺失不该影响任何其他功能,退化成"没有引导入口"
      Log.w('Guide', `引导音频不可用 ${(e as Error).message}`);
      GuideEpisode.localPath = '';
    }
  }

  /// 是否可用(资源已落地)。UI 据此决定显不显示入口 —— 不给点了没反应的按钮。
  static available(): boolean {
    return GuideEpisode.localPath.length > 0;
  }

  /// 供 localFileProvider 使用的本地路径。
  static pathFor(id: string): string | null {
    if (id !== GuideEpisode.ID || GuideEpisode.localPath.length === 0) return null;
    return GuideEpisode.localPath;
  }

  /// 是否为引导音频。播放层与统计层据此跳过记账。
  static isGuide(id: string): boolean {
    return id === GuideEpisode.ID;
  }

  static make(): Episode {
    return {
      id: GuideEpisode.ID,
      title: L.s('guide_title'),
      description: L.s('guide_desc'),
      // 走本地文件播放,不需要网络地址;localFileProvider 会给出真实路径
      audioUrl: '',
      artworkUrl: '',
      podcastTitle: L.s('app_title'),   // 注:鸿蒙端没有 app_name 这个键,是 app_title
      durationSec: GuideEpisode.DURATION_SEC,
      pubDate: '',
      feedUrl: '',
      // 引导音频没有官方稿。它是随包的本地文件,要文字就靠系统识别转 —— 正好是个不联网的试用样本
      transcriptUrl: '',
      transcriptType: ''
    };
  }
}
