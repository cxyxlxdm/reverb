/**
 * 「误触盾」:长按菜单关闭那一下的**穿透点击**挡在页面之外。
 *
 * 为什么需要:ArkUI 的 `bindContextMenu` 菜单,点菜单外部区域关闭时,那一下点击
 * **同时也会派发给下面的组件** —— 于是「关掉菜单」顺手把另一条单集播起来、切了分段、
 * 跳了页面。Android 的 `DropdownMenu` 靠自带的一层透明 Popup 吃掉这一下,鸿蒙没有。
 *
 * 为什么做成整屏的盾、而不是在每个 onClick 里判一下时间戳:菜单是弹在列表上的,
 * 底下可能是单集行、频道行、分段 chips、「继续收听」卡、页头图标、搜索框、底部页签、
 * 迷你播放条…… 逐个加判断必然漏(实测第一版就漏了「继续收听」卡)。盾只有一处,
 * 挂在 `Index.build()` 的最外层 Stack 里,连 NavDestination 一起盖住。
 *
 * 时序上也更稳:盾在菜单**弹出时**就已经在了,不指望"消失回调早于点击派发"。
 *
 * 失效方向:盾自己的 onClick 会立刻把自己撤掉,所以即使某条路径没回调
 * `lowerSoon()`,最坏也只是吃掉一次点击,不会把界面永久点不动。
 */
export class TapGuard {
  /// AppStorage 键。Index 用 `@StorageLink(TapGuard.KEY)` 观察它。
  static readonly KEY: string = 'tapShield';
  /// 菜单消失动画约 150ms,留点余量;再长会吃掉用户真正的下一次点击。
  private static readonly LINGER_MS: number = 220;

  /// 菜单弹出 —— 升盾。
  static raise(): void {
    AppStorage.setOrCreate(TapGuard.KEY, true);
  }

  /// 菜单开始消失 —— 略等一手再撤盾,把穿透的那一下留在盾上。
  static lowerSoon(): void {
    setTimeout(() => { AppStorage.setOrCreate(TapGuard.KEY, false); }, TapGuard.LINGER_MS);
  }

  /// 盾接到了那一下点击 —— 任务完成,立刻撤。
  static lower(): void {
    AppStorage.setOrCreate(TapGuard.KEY, false);
  }
}
