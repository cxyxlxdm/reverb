package com.yuyin.reverb.sync

import android.content.Context
import android.os.Build
import com.yuyin.reverb.data.local.JsonWriter
import com.yuyin.reverb.util.Logger
import org.json.JSONObject
import java.io.File

/**
 * 本机在局域网里的**长期身份**:只有一串设备 id 与显示名。
 *
 * 为什么要稳定身份:设备 id 跟服务名与去重判据挂钩,每次打开同步都换一个名字,
 * 对端列表里会出现一串"幽灵设备"。
 *
 * ⚠️ **这里不存密钥**。旧版本曾把一对长期 P-256 密钥也写进来并直接拿去做 ECDH,
 * 结果同一对设备每次配对的六位码都一样、也没有前向保密(H278)。现在密钥对在
 * **每次会话里现生成**(见 [LanSyncSession.greet]),身份只负责"我是谁"。
 *
 * 文件是应用私有目录下的 `lan_sync.json`,与其它 store 一样走 [JsonWriter.writeAtomically]
 * (先写 `.part` 再 rename):半截文件解析失败时宁可按"没有身份"重建,也不要把坏文件留在那儿。
 * 旧文件里多出来的 publicKey/privateKey 会被忽略,下次写入时自然消失。
 * 它不进任何备份、不上传、不写日志(BackupManager 的分区是白名单)。
 */
class LanSyncIdentity(context: Context) {

    data class Material(
        val deviceId: String,
        val name: String,
        val createdAt: Long
    )

    private val file = File(context.applicationContext.filesDir, "lan_sync.json")
    private val lock = Any()

    @Volatile
    private var cached: Material? = null

    /** 首次访问时才读盘/生成。 */
    val material: Material
        get() = cached ?: synchronized(lock) {
            cached ?: loadOrCreate().also { cached = it }
        }

    private fun loadOrCreate(): Material {
        read()?.let { return it }
        val material = Material(
            deviceId = LanSyncCrypto.randomBytes(8).joinToString("") { "%02x".format(it) },
            name = defaultName(),
            createdAt = System.currentTimeMillis()
        )
        persist(material)
        Logger.i(TAG, "生成新的同步身份 id=${material.deviceId} name=${material.name}")
        return material
    }

    private fun read(): Material? {
        if (!file.exists()) return null
        return runCatching {
            val o = JSONObject(file.readText())
            if (o.optInt("version", 0) != VERSION) return@runCatching null
            val id = o.optString("deviceId")
            if (id.length != 16) return@runCatching null
            Material(
                deviceId = id,
                name = o.optString("name").ifBlank { defaultName() },
                createdAt = o.optLong("createdAt")
            )
        }.onFailure {
            // 读坏就重建 —— 身份里只有展示用的名字与去重用的 id,没有不可再生的东西。
            Logger.w(TAG, "lan_sync.json 读取失败,重建身份:${it.message}")
        }.getOrNull()
    }

    private fun persist(material: Material) {
        val json = JSONObject()
            .put("version", VERSION)
            .put("deviceId", material.deviceId)
            .put("name", material.name)
            .put("createdAt", material.createdAt)
        JsonWriter.writeAtomically(file, json.toString(2))
    }

    private fun defaultName(): String {
        val model = Build.MODEL?.trim().orEmpty()
        return if (model.isBlank()) "Android" else model
    }

    private companion object {
        const val TAG = "LanSync.Identity"
        const val VERSION = 1
    }
}
