余音 Reverb 官网 / 发布物料
================================

本目录 = 仓库根 site/ 下的 **reverb/ 子目录**。目录名对应部署路径 /reverb/,
App 包里写死的 URL 依赖这个路径,不能改(见下方「目录结构不要改」)。

【网站】上传到 cxyxl.cn/reverb/  ← 域名已定为 cxyxl.cn(登记主体域名)
  index.html          官网首页(图标已内联,只依赖 shots/)
  privacy.html        隐私政策(分发平台填的 URL 指向它)
  shots/*.jpg         官网用截图(已压缩,32–68 KB),4 张:
                        01-discover / 03-player / 09-settings / 10-licenses
                        由发布原图缩放而来(scale=407:900),生成口径见
                        AGENTS.md「截图」一节。收听时长与听觉足迹两张**不上官网**
                        (含个人收听数据)。本目录不入版本管理(.gitignore)。
                        ⚠ 01-discover 摄于 2026-09-10 的旧版界面,已过期:
                        部署官网前必须重拍(见 docs/ROADMAP.md 的截图记录)。

  站点地址示例:
    https://cxyxl.cn/reverb/
    https://cxyxl.cn/reverb/privacy.html
  注意:index.html 页脚的隐私链接写的是相对路径 privacy.html,
  若你把隐私页放在别处,记得同步改那一处。

【应用市场素材】不在本目录,也不要上传到官网
  发布用截图(原生分辨率直出、零黑边,1.0.2 起弃用 9:16 垫边):
    鸿蒙 → harmony/dist/store/*.png(8 张,1216×2688,01-start…09-settings)
    Android → android/dist/store/*.png(8 张,1272×2659,裁掉状态栏,命名同名同序)
  两处都已被 .gitignore 忽略,重拍口径见 AGENTS.md「截图」一节。

【其他发布物料】
  应用图标   harmony/store/appicon-216.png(备用 512 / 1024)
  安装包     harmony/dist/reverb.app          ← 跑 harmony/build-release.sh 生成
  符号文件   harmony/dist/reverb-symbol.zip
  文案       harmony/store/发布文案.txt(本地文件,不入版本控制,硬规矩 19)
  包名       com.yuyin.reverb
  版本       versionCode 1000002 / versionName 1.0.2

【重要:目录结构不要改】
    App 里的这两个 URL 是**写死在安装包里**的,挪一次就得重新打包提交:
      https://cxyxl.cn/reverb/privacy.html        隐私政策(同意页外链 + 设置页入口)
      https://cxyxl.cn/reverb/recommended.opml    推荐订阅清单(首屏「导入推荐订阅」)
    因此:
      - 用**子目录** /reverb/,不要用子域名 —— 子域名在阿里云可能要另加一条站点登记
      - 以后加别的应用就放 /app2/,主体登记与服务器复用同一份
      - 2026-09-20 整理:官网文件从仓库根 reverb/ 挪进 site/reverb/,仓库内路径变了,
        但**部署路径 /reverb/ 没变**,上面两个 URL 不受影响;上传时按新仓库路径取文件。

【备案号】
    两个备案号均已下发,页面页脚已启用(以登记系统实际下发为准):
      1. 网站底部 —— index.html 与 privacy.html 页脚
      2. App 关于页 —— 文案键 beian_number:
         Android  android/app/src/main/res/values*/strings.xml (5 个语言)
         鸿蒙     harmony/entry/src/main/resources/*/element/string.json (5 个语言)
