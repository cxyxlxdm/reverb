package com.yuyin.reverb.update

import android.content.Context
import androidx.compose.runtime.Composable
import okhttp3.OkHttpClient

/**
 * 大陆商店渠道:**不含应用内更新**,`start` 什么都不做、界面渲染空。
 *
 * 两条理由,任一条单独都足以否掉这个功能:
 * 1. **更新归市场管**。这个渠道的安装包由应用市场分发与升级,自更新绕过了市场的版本审核;
 * 2. `REQUEST_INSTALL_PACKAGES`(「安装未知应用」)是市场清单里的敏感权限,需逐次举证 ——
 *    而举证换来的功能对本渠道用户本来就没有意义(他们从市场点更新更省事)。
 *    该权限因此**只声明在 `src/default/AndroidManifest.xml`**,本渠道合并结果里不出现它。
 *
 * **这份文件是空实现,不是"以后再补"** —— 与 `playback/asr/AsrFactory` 同一手法:
 * 只有 source set 级隔离才能保证这个渠道的包里连那段代码、那几串文案都没有
 * (`BuildConfig` 常量只能删代码,删不掉资源与权限声明,见 H70)。
 * 所以不要把这里改成"运行时判断一下再决定查不查" —— 那等于把功能打进了包里,
 * 而解包 grep 会立刻把这个说法戳穿(default 包里搜得到那条发布页地址,store 包搜不到)。
 */
object SelfUpdate {
    fun start(context: Context, http: OkHttpClient) {
        // 商店渠道:不检测、不下载、不装
    }
}

@Composable
fun SelfUpdateHost() {
    // 商店渠道:没有可渲染的界面
}
