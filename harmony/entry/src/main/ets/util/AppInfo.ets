import bundleManager from '@ohos.bundle.bundleManager';
import { Log } from './Logger';

/// 应用自身 versionName。设置页 / 关于页 / 足迹海报三处都要展示版本,
/// 以前各自写死 '1.0.0',发版不记得同步就漂移(1.0.1 提交复核前对齐审计发现)。
/// 进程内读一次缓存:同步接口开销小,但没必要每次组合界面都查包管理器。
let cached: string | null = null;

export function appVersionName(): string {
  if (cached !== null) return cached;
  try {
    const info = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    cached = info.versionName;
  } catch (e) {
    Log.w('AppInfo', `读取 versionName 失败 ${(e as Error).message}`);
    cached = '';
  }
  return cached;
}
