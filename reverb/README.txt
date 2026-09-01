余音 Reverb 官网 / 发布物料
================================

【网站】上传到 cxyxl.cn/reverb/  ← 域名已定为 cxyxl.cn(登记主体域名)
  index.html          官网首页(图标已内联,只依赖 shots/web/)
  privacy.html        隐私政策(分发平台填的 URL 指向它)
  shots/web/*.jpg     官网用截图(已压缩,32–68 KB),4 张:
                        01-discover / 03-player / 09-settings / 10-licenses
                        均取自当前目录版真机界面;收听时长与听觉足迹两张**不上官网**
                        (含个人收听数据)。

  站点地址示例:
    https://cxyxl.cn/reverb/
    https://cxyxl.cn/reverb/privacy.html
  注意:index.html 页脚的隐私链接写的是相对路径 privacy.html,
  若你把隐私页放在别处,记得同步改那一处。

【应用市场素材】不要上传到官网
  shots/*.png         原始截图 1216×2688(留档),10 张 + _spare-privacy-consent
  shots/store/*.png   ★ 发布用:1512×2688,比例正好 9:16,PNG 均 <5MB
                        (左右各补 148px #141E20 底色,与页面底色一体、无接缝)
  命名与 Android 那套(reverb-android/shots/)**同名同序**,改一端时便于对照另一端:
    01-start 02-detail 03-player 04-library 05-inbox 06-history
    07-listen-stats 08-footprint 09-settings 10-licenses
    _spare-privacy-consent(备用,首启同意页)

【其他发布物料】
  应用图标   harmony/store/appicon-216.png(备用 512 / 1024)
  安装包     harmony/dist/reverb.app          ← 跑 harmony/build-release.sh 生成
  符号文件   harmony/dist/reverb-symbol.zip
  文案       harmony/store/发布文案.txt
  包名       com.yuyin.reverb
  版本       versionCode 1000000 / versionName 1.0.0

【重要:目录结构不要改】
    App 里的这两个 URL 是**写死在安装包里**的,挪一次就得重新打包提交:
      https://cxyxl.cn/reverb/privacy.html        隐私政策(同意页外链 + 设置页入口)
      https://cxyxl.cn/reverb/recommended.opml    推荐订阅清单(首屏「导入推荐订阅」)
    因此:
      - 用**子目录** /reverb/,不要用子域名 —— 子域名在阿里云可能要另加一条站点登记
      - 以后加别的应用就放 /app2/,主体登记与服务器复用同一份

【备案号】
    登记通过后要在两处填:
      1. 网站底部 —— index.html 与 privacy.html 末尾各有一段注释掉的备案号区块,
         取消注释并填入即可(必须链到 beian.miit.gov.cn)
      2. App 关于页 —— 文案键 beian_number:
         Android  android/app/src/main/res/values*/strings.xml (5 个语言)
         鸿蒙     harmony/entry/src/main/resources/*/element/string.json (5 个语言)
         留空则关于页不显示该行;填了要**重新打包**
