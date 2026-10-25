import connection from '@ohos.net.connection';
import { SettingsStore } from '../store/SettingsStore';
import { Log } from './Logger';

/**
 * 「这次 App 擅自发起的大流量该不该被蜂窝闸门拦下」的**唯一判据**(本端)。
 *
 * 为什么要单独成一个东西(见 REVIEW-2026-10-25 中-3):同一段判据原先在本端**抄了两份**
 * (`DownloadManager.downloadGate()` 与 `AudioCacheManager.blockedByCellular()`),
 * 而第三条大流量路径 —— 本机识别前要下的那一整集音频(`SpeechTranscriber.downloadToCache`)——
 * 根本没接闸门。用户关了「仅在 Wi-Fi 下载」,下载与缓存都老实用 Wi-Fi,只有"转逐字稿"
 * 会在蜂窝上悄悄跑掉几十 MB。**判据抄第二份的时候漏掉第三个调用点是必然,不是偶然**
 * (体检 §4 模式 2「靠调用点自律的规矩必漏」)。
 *
 * 判据本体与 `DownloadManager.downloadGate()` 逐条同口径,取值过程一字未改:
 *  - **只有 bearer 是蜂窝才拦**。连着 Wi-Fi 时本设备实测 `bearer=[1]`、
 *    `networkCap=[12,15,16]` **不含 NOT_METERED(11)** —— 计费信号在 ArkTS 侧拿不到,
 *    所以 `networkCap` 只能当**放行**证据(含 11 一定不计费),不能当拦截依据。
 *    逐字取证与"为什么与 Android 刻意不等价、别去修一致"见 `DownloadManager` 上面的长注释与 H162、H166。
 *  - **三个兜底方向全是「拦」**:设置读不到按不允许、capability 数组缺失按未申报不计费、
 *    整个读取抛异常按没网。取向选拦的理由是代价不对称:拦了只是"这一次不缓存/不转写",
 *    放了是在用户明确关掉的开关上擅自花钱。
 *
 * **`DownloadManager` 仍然用自己那一份,不是漏改**:它要把"没网"和"需要 Wi-Fi"
 * 区分成两个结果码给界面提示,而这里只有布尔。那份的判据改动要同步到本文件,反之亦然。
 *
 * ⚠️ 本端这台设备 `LOCAL_ASR=false`,识别路径当前不启用(见 `AppContainer`),
 * 所以 `SpeechTranscriber` 这一侧现在是**潜伏**的 —— 但翻开关之前它必须是接好的,
 * 否则一翻就在计费网络上跑流量。这正是体检里"翻开关前必修"那句的意思。
 */
export async function blockedByCellular(settings: SettingsStore | null, tag: string): Promise<boolean> {
  try {
    const handle = await connection.getDefaultNet();
    const caps = await connection.getNetCapabilities(handle);
    const bearers = caps.bearerTypes;
    if (bearers.length === 0) {
      Log.w(tag, '当前无可用网络链路,本次不走这条流量路径(按拦处理)');
      return true;
    }
    if (settings !== null && settings.allowCellular) return false;
    const netCap = caps.networkCap;
    const declaredNotMetered = netCap !== undefined && netCap.length > 0
      && netCap.indexOf(connection.NetCap.NET_CAPABILITY_NOT_METERED) >= 0;
    // VPN 隧道挂在蜂窝上时 bearer 只给 4,这条会放行 —— 漏拦的情形写在这里,不装看不见。
    const isCellular = bearers.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0;
    if (declaredNotMetered || !isCellular) return false;
    // 拦下来时把系统给的两组值原样打出来:判据按 bearer 判,而提示文案历史上说过两次别的口径
    // (「不是 Wi-Fi」/「按用量计费」)—— 只有这两行能分辨"真连着蜂窝"与"设备上报得不对"(见 H162)。
    Log.i(tag, `闸门拦下 bearer=${JSON.stringify(bearers)} cap=${JSON.stringify(netCap)} 判定=蜂窝`);
    return true;
  } catch (e) {
    Log.w(tag, `读取当前网络失败 ${(e as Error).message},本次按拦处理`);
    return true;
  }
}
