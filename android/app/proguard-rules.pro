# Media3 / ExoPlayer
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# WorkManager 自定义 Worker（由框架反射实例化）
-keep class * extends androidx.work.ListenableWorker {
    <init>(android.content.Context, androidx.work.WorkerParameters);
}

# Application（Manifest 已引用，保险起见保留）
-keep class com.yuyin.reverb.ReverbApp { *; }

# OkHttp / Okio（一般自带规则，补充 dontwarn 以防万一）
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
