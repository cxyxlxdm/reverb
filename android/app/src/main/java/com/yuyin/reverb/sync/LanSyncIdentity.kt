package com.yuyin.reverb.sync

import android.content.Context
import android.os.Build
import com.yuyin.reverb.data.local.JsonWriter
import com.yuyin.reverb.util.Logger
import org.json.JSONObject
import java.io.File
import java.security.PrivateKey

/**
 * 本机在局域网里的**长期身份**:一串设备 id + 一对 P-256 密钥。
 *
 * 为什么要有稳定身份:虽然 P0 每次配对都重新做 ECDH(前向保密),但设备 id 要跨启动稳定 ——
 * 否则同一台机器每次打开同步都换一个名字,对端列表里会出现一串"幽灵设备"。
 *
 * 文件是应用私有目录下的 `lan_sync.json`,与其它 store 一样走 [JsonWriter.writeAtomically]
 * (先写 `.part` 再 rename):半截文件解析失败时宁可按"没有身份"重建,也不要把坏文件留在那儿。
 *
 * **私钥只在这台设备上**。它不进任何备份、不上传、不写日志 —— 备份里没有这个文件
 * (BackupManager 的分区是白名单),换机后重新生成一对密钥即可。
 */
class LanSyncIdentity(context: Context) {

    data class Material(
        val deviceId: String,
        val name: String,
        val publicKey: ByteArray,
        val privateKey: PrivateKey,
        val createdAt: Long
    )

    private val file = File(context.applicationContext.filesDir, "lan_sync.json")
    private val lock = Any()

    @Volatile
    private var cached: Material? = null

    /** 首次访问时才读盘/生成 —— 应用启动不该为这个功能付一次 EC 密钥生成。 */
    val material: Material
        get() = cached ?: synchronized(lock) {
            cached ?: loadOrCreate().also { cached = it }
        }

    private fun loadOrCreate(): Material {
        read()?.let { return it }
        val keyPair = LanSyncCrypto.generateKeyPair()
        val material = Material(
            deviceId = LanSyncCrypto.randomBytes(8).joinToString("") { "%02x".format(it) },
            name = defaultName(),
            publicKey = LanSyncCrypto.encodePublicKey(keyPair.public),
            privateKey = keyPair.private,
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
            val publicKey = LanSyncCrypto.unbase64(o.getString("publicKey"))
            val privateKey = LanSyncCrypto.decodePrivateKey(LanSyncCrypto.unbase64(o.getString("privateKey")))
            if (id.length != 16 || publicKey.size != LanSyncCrypto.PUBLIC_KEY_BYTES) return@runCatching null
            Material(
                deviceId = id,
                name = o.optString("name").ifBlank { defaultName() },
                publicKey = publicKey,
                privateKey = privateKey,
                createdAt = o.optLong("createdAt")
            )
        }.onFailure {
            // 读坏不等于"没有身份",但这里**只能重建** —— 私钥丢了没有任何别处能补。
            // 代价是旧的配对记录失效;P0 不持久化配对记录,所以影响只到下一次配对。
            Logger.w(TAG, "lan_sync.json 读取失败,重建身份:${it.message}")
        }.getOrNull()
    }

    private fun persist(material: Material) {
        val json = JSONObject()
            .put("version", VERSION)
            .put("deviceId", material.deviceId)
            .put("name", material.name)
            .put("publicKey", LanSyncCrypto.base64(material.publicKey))
            .put("privateKey", LanSyncCrypto.base64(LanSyncCrypto.encodePrivateKey(material.privateKey)))
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
