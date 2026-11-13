/**
 * 编译期功能开关。对应 Android 的 flavor + buildConfigField。
 *
 * 鸿蒙端**只经应用市场分发**(不支持自由侧载),不像 Android 那样需要"同一份代码打两种包",
 * 所以这里用常量而不是 hvigor 的 product —— 少一层构建配置,将来要放开也只是改一行。
 */
export class Features {
  /**
   * 是否提供**内容目录**:分类热门榜、随机/情境电台、关键词检索。
   *
   * 曾置 false(与 Android 商店渠道同):合规口径把「内置内容目录 / 分类浏览 /
   * 内容推荐」判定为提供视听节目服务,需《相应内容分发许可资质》—— 个人主体拿不到;
   * 而「用户自行添加 RSS 源」的纯工具不需要。
   *
   * 只剩官网 15 条推荐订阅 + 手填 RSS 的版本对普通用户基本不可用,因此首版决定先按
   * 完整功能提交复核,若平台复核确实不通过再降级(见 H70)。rawfile 仍不打包种子清单,
   * 榜单与电台内容池只来自在线目录(见 shared/seed/sync.sh)。
   */
  static readonly CATALOG: boolean = true;

  /**
   * 是否提供**本机语音转写**(没有官方逐字稿时,自己把音频转成文字)。
   *
   * **1.0.8 起为 true**:引擎换成了 sherpa-onnx + 随包的 SenseVoiceSmall int8
   * (实现见 `playback/asr/`,跑在 Worker 子线程)。原先 false 的理由是**真机实测的结论**:
   * 系统的 Core Speech Kit 离线档是给"短语音输入/命令词"设计的 —— 一次会话的 VAD
   * 检测到句末静音就收工,10 分钟的中文单集只出 14 行碎片(见 TROUBLESHOOTING H62)。
   * 换引擎之后同一段素材能出完整稿件,中文准确率也明显更好;代价是模型 228 MB 要进包
   * (与 Android 同一取舍,用户已拍板"只带 SenseVoice")。
   *
   * 翻成 true 意味着三条同时生效:
   *  - 播放页第三页对任何一集都出现(受设置里「逐字稿」总开关控制);
   *  - 设置里显示「逐字稿」总开关;
   *  - 首次转写把模型从 rawfile 拷到私有目录(之后按大小跳过)。
   *
   * 要再关掉:把这一行改回 false,界面三处门控会自动收掉。但**模型仍会打进包**
   * (与 Android 的 `HAS_ENGINE` 同一个性质:常量只关调用路径,不删文件,见硬规矩 3)。
   */
  static readonly LOCAL_ASR: boolean = true;
}
