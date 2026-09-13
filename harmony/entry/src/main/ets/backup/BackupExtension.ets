import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { Log } from '../util/Logger';

/// 系统备份(HarmonyOS「备份和恢复」/ 云空间 / 手机克隆)要求应用声明一个
/// type 为 backup 的扩展作为接入点 —— 没有它,系统备份会跳过本应用的数据。
///
/// 数据搬运与范围过滤全部交给系统 + backup_config.json(白名单,见
/// resources/base/profile/):这里刻意不做任何复制、上传或格式改写,
/// 避免再造一套与手动备份(BackupManager)不同的格式。见 TROUBLESHOOTING H84。
export default class BackupExtension extends BackupExtensionAbility {
  onBackup(): void {
    Log.i('Backup', '系统备份开始,数据由系统按 backup_config 白名单处理');
  }

  onRestore(bundleVersion: BundleVersion): void {
    Log.i('Backup', `系统恢复完成,来源版本 ${bundleVersion.name}(${bundleVersion.code})`);
  }
}
