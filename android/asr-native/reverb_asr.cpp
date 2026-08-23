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
        JNIEnv* env, jobject, jlong handle, jfloatArray pcm, jstring language,
        jstring initialPrompt, jint threads) {
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
    /**
     * 语言。**两个坑,都踩过**:
     *
     * 1. `language` 不能传 nullptr —— 要"让模型自己判断"就传字符串 `"auto"`;
     * 2. **`detect_language` 千万别打开**。它的语义不是"顺便自动判断语言",而是
     *    **「只检测语言就返回」** —— 打开后 whisper_full 一句都不转、立刻返回 0 句。
     *    实测症状:120 秒音频 1.6 秒就"跑完"了(75 倍实时),0 句,且不报错。
     *    界面语言是「跟随系统」时 Kotlin 侧传的是空串,正好踩上。
     */
    wp.language = lang.empty() ? "auto" : lang.c_str();
    wp.detect_language = false;

    /**
     * 提示词。**中文必须给** —— whisper 对中文默认偏向**繁体**输出,
     * 简体界面下出来一屏繁体字,看着就是坏的。业界通行的办法就是用一句简体提示词把它带过去
     * (「以下是普通话的句子。」),由 Kotlin 侧按目标语言决定内容,C++ 这层不做判断。
     * 与 `no_context = true` 不冲突:那个清的是**跨块上下文**,提示词是每块都重新给的。
     */
    std::string prompt;
    if (initialPrompt != nullptr) {
        const char* p = env->GetStringUTFChars(initialPrompt, nullptr);
        prompt = p;
        env->ReleaseStringUTFChars(initialPrompt, p);
    }
    wp.initial_prompt = prompt.empty() ? nullptr : prompt.c_str();

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
