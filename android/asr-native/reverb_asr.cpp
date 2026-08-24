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
    // (实测 base-q5_1 在 SM8845 上 4 线程约 8 倍实时)。
    cp.use_gpu = false;

    /**
     * **词级时间戳(DTW 对齐)**。开了它 `whisper_token_data.t_dtw` 才有值,
     * 逐词/逐字高亮才有据可依 —— 否则只有 `t0/t1` 那种句级时间。
     *
     * 两个必须配对的点:
     * - `dtw_aheads_preset` **要与模型档位一致**。我们内置的是 base,所以是
     *   `WHISPER_AHEADS_BASE`;换成 tiny/small 必须同步改,不然对齐结果是错的;
     * - `dtw_mem_size` 是一块预留的 scratch 内存。库里默认 128 MB,在手机上太奢侈;
     *   我们一次只喂 2 分钟的块,32 MB 够用(真机验过)。
     */
    cp.dtw_token_timestamps = true;
    cp.dtw_aheads_preset = WHISPER_AHEADS_BASE;
    cp.dtw_mem_size = 32u * 1024 * 1024;
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

/// 某句里的 token 数(词级高亮用)。
JNIEXPORT jint JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeTokenCount(
        JNIEnv*, jobject, jlong handle, jint segment) {
    Session* s = asSession(handle);
    if (s == nullptr || s->ctx == nullptr) return 0;
    return whisper_full_n_tokens(s->ctx, segment);
}

/**
 * token 文本。**原样返回,不去空格** —— whisper 的英文 token 自带前导空格
 * (" deal"),而子词 token 没有("prog" + "rammatic")。谁该带空格只有它自己知道,
 * 上层去 trim 再按规则补空格会把子词拼错。上层的约定是:把 token 文本直接拼起来
 * 就等于整句(见 Kotlin 侧 TranscribedSegment.words 的注释)。
 *
 * 特殊 token(`<|zh|>`、`[_BEG_]` 这类)由上层按 id 过滤,这里不做判断。
 */
JNIEXPORT jstring JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeTokenText(
        JNIEnv* env, jobject, jlong handle, jint segment, jint index) {
    Session* s = asSession(handle);
    if (s == nullptr || s->ctx == nullptr) return env->NewStringUTF("");
    const char* t = whisper_full_get_token_text(s->ctx, segment, index);
    return env->NewStringUTF(t == nullptr ? "" : t);
}

/// token 是否是特殊标记(语言标记 / 时间戳 / BEG / EOT 等),上层跳过它们。
JNIEXPORT jboolean JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeTokenIsSpecial(
        JNIEnv*, jobject, jlong handle, jint segment, jint index) {
    Session* s = asSession(handle);
    if (s == nullptr || s->ctx == nullptr) return JNI_TRUE;
    const whisper_token_data d = whisper_full_get_token_data(s->ctx, segment, index);
    return d.id >= whisper_token_eot(s->ctx) ? JNI_TRUE : JNI_FALSE;
}

/**
 * token 的时刻(毫秒)。取 **`t_dtw`** —— DTW 对齐出来的位置,才是"这个词什么时候被说出来"。
 * `t0/t1` 是解码器给的粗略区间,抖动大,做逐词高亮会明显跳。
 * DTW 不可用时(比如没开 dtw_token_timestamps)`t_dtw` 是 -1,这里回退到 t0。
 */
JNIEXPORT jint JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeTokenStartMs(
        JNIEnv*, jobject, jlong handle, jint segment, jint index) {
    Session* s = asSession(handle);
    if (s == nullptr || s->ctx == nullptr) return 0;
    const whisper_token_data d = whisper_full_get_token_data(s->ctx, segment, index);
    const int64_t t = d.t_dtw >= 0 ? d.t_dtw : d.t0;
    return static_cast<jint>(t * 10);
}

}  // extern "C"
