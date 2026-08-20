/**
 * 编译期功能开关。对应 Android 的 flavor + buildConfigField。
 *
 * 鸿蒙端**只经应用市场分发**(不支持自由侧载),不像 Android 那样需要"同一份代码打两种包",
 * 所以这里用常量而不是 hvigor 的 product —— 少一层构建配置,将来要放开也只是改一行。
 */
export class Features {
  /**
   * 是否提供**内容目录**:分类热门榜、随机/情境电台、内置精选清单。
   *
   * 置 false 的理由(与 Android 商店渠道同):合规口径把「内置内容目录 / 分类浏览 /
   * 内容推荐」判定为提供视听节目服务,需《相应内容分发许可资质》—— 个人主体拿不到;
   * 而「用户自行添加 RSS 源」的纯工具不需要。
   *
   * 因此本端:
   *   - 首屏只有「导入推荐订阅」(联网拉官网的一份 OPML)+ 手动粘贴 RSS 地址
   *   - 搜索**不做关键词检索**(关键词返回的是节目列表,同样构成动态目录)
   *   - rawfile 里不打包种子清单(见 shared/seed/sync.sh)
   */
  static readonly CATALOG: boolean = false;
}
