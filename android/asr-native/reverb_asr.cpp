// 余音 · Android 离线语音识别的 JNI 胶水层(**只随默认渠道分发**)。
//
// 只做三件事:把模型读进来、对一段 16k 单声道 float PCM 跑一次识别、把结果句子读出去。
// 不做解码(那在 Kotlin 侧的 PcmDecoder 里)、不做分块(在 WhisperEngine 里)——
// 这里越薄越好:C++ 每多一行,崩溃就多一处没有栈可看的地方。
//
// 与 whisper.cpp 的版本绑定关系写在 tools/build-asr.sh 里(固定 commit)。

#include <jni.h>
#include <string>
#include <vector>
#include <whisper.h>

namespace {

// 一次识别会话:模型上下文 + 上一次的结果。结果留着让 Kotlin 侧逐句取。
struct Session {
    whisper_context* ctx = nullptr;
};

inline Session* asSession(jlong h) { return reinterpret_cast<Session*>(h); }

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeInit(JNIEnv* env, jobject, jstring modelPath) {
    const char* path = env->GetStringUTFChars(modelPath, nullptr);
    whisper_context_params cp = whisper_context_default_params();
    // 手机上不用 GPU:Adreno 的后端在 whisper.cpp 里还不稳,而 CPU 已经够快
    // (实测 base-q5_1 在 SM8845 上 4 线程约 4.6 倍实时)。
    cp.use_gpu = false;
    whisper_context* ctx = whisper_init_from_file_with_params(path, cp);
    env->ReleaseStringUTFChars(modelPath, path);
    if (ctx == nullptr) return 0;
    auto* s = new Session();
    s->ctx = ctx;
    return reinterpret_cast<jlong>(s);
}

JNIEXPORT void JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeFree(JNIEnv*, jobject, jlong handle) {
    Session* s = asSession(handle);
    if (s == nullptr) return;
    if (s->ctx != nullptr) whisper_free(s->ctx);
    delete s;
}

/// 对一块 PCM 跑识别。返回句子数,负数表示失败。
JNIEXPORT jint JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeTranscribe(
        JNIEnv* env, jobject, jlong handle, jfloatArray pcm, jstring language, jint threads) {
    Session* s = asSession(handle);
    if (s == nullptr || s->ctx == nullptr) return -1;

    const jsize n = env->GetArrayLength(pcm);
    jfloat* samples = env->GetFloatArrayElements(pcm, nullptr);

    whisper_full_params wp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wp.n_threads = threads > 0 ? threads : 4;
    wp.print_progress = false;
    wp.print_realtime = false;
    wp.print_special = false;
    wp.print_timestamps = false;
    wp.translate = false;
    wp.no_timestamps = false;
    // **按块识别就必须关掉跨块上下文**:块与块之间本来没有连续的 prompt,
    // 带着上一块的上下文反而会诱发"复读"(模型把上一句反复吐出来)。
    wp.no_context = true;
    wp.single_segment = false;

    std::string lang;
    if (language != nullptr) {
        const char* l = env->GetStringUTFChars(language, nullptr);
        lang = l;
        env->ReleaseStringUTFChars(language, l);
    }
    // 空串 = 让模型自己判断语言(Kotlin 侧「跟随系统」且拿不到明确语言时会这样传)
    wp.language = lang.empty() ? nullptr : lang.c_str();
    wp.detect_language = lang.empty();

    const int rc = whisper_full(s->ctx, wp, samples, static_cast<int>(n));
    env->ReleaseFloatArrayElements(pcm, samples, JNI_ABORT);
    if (rc != 0) return -1;
    return whisper_full_n_segments(s->ctx);
}

JNIEXPORT jstring JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeSegmentText(
        JNIEnv* env, jobject, jlong handle, jint index) {
    Session* s = asSession(handle);
    if (s == nullptr || s->ctx == nullptr) return env->NewStringUTF("");
    const char* t = whisper_full_get_segment_text(s->ctx, index);
    return env->NewStringUTF(t == nullptr ? "" : t);
}

/// 句子起点。whisper 的时间单位是 **10 毫秒**,这里直接换成毫秒交出去。
JNIEXPORT jint JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeSegmentStartMs(
        JNIEnv*, jobject, jlong handle, jint index) {
    Session* s = asSession(handle);
    if (s == nullptr || s->ctx == nullptr) return 0;
    return static_cast<jint>(whisper_full_get_segment_t0(s->ctx, index) * 10);
}

JNIEXPORT jint JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeSegmentEndMs(
        JNIEnv*, jobject, jlong handle, jint index) {
    Session* s = asSession(handle);
    if (s == nullptr || s->ctx == nullptr) return 0;
    return static_cast<jint>(whisper_full_get_segment_t1(s->ctx, index) * 10);
}

}  // extern "C"
