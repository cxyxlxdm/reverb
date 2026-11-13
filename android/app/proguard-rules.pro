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

# sherpa-onnx（离线语音识别,Apache-2.0）
# 原生库在 JNI_OnLoad 里**按类名与方法名**注册 native 方法（RegisterNatives），
# AAR 自带的 proguard.txt 是空的。R8 一旦重命名这些类，注册就会失败 ——
# release 包的症状是 `UnsatisfiedLinkError: No implementation found for
# com.k2fsa.sherpa.onnx.OfflineRecognizer.newFromFile`，而 debug 包完全正常。
-keep class com.k2fsa.sherpa.onnx.** { *; }
-dontwarn com.k2fsa.sherpa.onnx.**
