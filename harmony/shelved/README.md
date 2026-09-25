# 内容目录的降级复原步骤

`net/Sources.ets` 原先挂在这里、**不参与编译**,因为大陆合规口径把「内置内容目录 /
分类浏览 / 内容推荐」判为提供视听节目服务(需《相应内容分发许可资质》)。
只保留官网 15 条推荐订阅 + 手填 RSS 的版本对普通用户基本不可用,首版现决定先按完整功能
提交复核,所以 `Sources.ets` 已移回 `entry/src/main/ets/net/`(见 H70)。

如果平台复核确实不通过,降级不能只把 `Features.CATALOG` 改回 false:

1. 把 `entry/src/main/ets/net/Sources.ets` 移回本目录;
2. 在 `net/PodcastRepository.ets` 移除 import,把 `search` 恢复为仅 RSS 直连、
   `searchEpisodes` 恢复为空、`refreshPopular` 恢复为空;
3. `Features.CATALOG` 改回 false;
4. 许可页、五语种关于页/隐私正文、对外文案与截图同步回退。

之所以必须**物理移出编译树**:ArkTS/hvigor 没有 Kotlin/R8 那样的 dead code elimination,
常量为 false 也照样把类和 URL 字符串编进 `modules.abc`。降级后必须解包确认:

```bash
strings modules.abc | grep -ciE 'itunes|marketingtools|fyyd|gpodder'  # 必须为 0
```

现在的完整版验收方向相反:同一命令必须**非 0**。方法不变,期望值由产品决策决定。