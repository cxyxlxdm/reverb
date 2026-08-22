# 挂起的代码(**不参与编译**)

这个目录里的文件**故意放在 `entry/src/main/ets` 之外**,所以 hvigor 不会编译它们,
它们也不会进入 `.hap`。留在仓库里只为留档,不是"暂时注释掉"。

## net/Sources.ets —— 四路内容目录取源(Apple iTunes / Apple 榜单 / fyyd.de / gpodder.net)

**为什么挪出来**:大陆合规口径把「内置内容目录 / 分类浏览 / 内容推荐」判为提供视听节目服务
(需《相应内容分发许可资质》),所以本端 `Features.CATALOG = false`,
分类榜、关键词检索、电台一律不提供。

只在数据层加 `if (!Features.CATALOG) return ...` 是**不够的**:

- Android 侧够,因为 `BuildConfig.CATALOG` 是 `static final boolean`,R8 会把整段判死并删掉,
  产物里那四个接口地址各 0 次;
- **鸿蒙侧不够** —— ArkTS/hvigor **没有等价的 dead code elimination**,常量为 false 也照样
  把类和 URL 字符串编进 `modules.abc`。解包 `strings modules.abc | grep itunes` 一抓就有
  (实测 `ITunesSource` / `FyydSource` / `GpodderSource` / `rss.marketingtools.apple.com` 全在)。
  而申报写的是"仅作为 RSS 订阅解析工具" —— 复核人员解包就能看到目录接口的地址。
  验收标准是「包里没有」,不是「界面上点不到」,见 TROUBLESHOOTING H46 / H54。

**将来要放开内容目录**(比如上一个不受此约束的渠道)怎么做:

1. 把 `net/Sources.ets` 移回 `entry/src/main/ets/net/`;
2. 在 `net/PodcastRepository.ets` 里恢复 `import` 与三处降级链(`search` 的
   Apple→fyyd→gpodder、`searchEpisodes` 的 Apple、`refreshPopular` 的榜单三层),
   那三处都留了 `TODO(catalog)` 标记;
3. `Features.CATALOG` 改 `true`。

改完**必须解包复验**:`strings modules.abc | grep -ci itunes` 应当从 0 变成非 0 ——
以及反过来,任何声明"已删除"的合规删减,都以解包结果为准。
