// 余音 · Android 离线语音识别的 JNI 胶水层(**只随默认渠道分发**)。
//
// 只做三件事:把模型读进来、对一段 16k 单声道 float PCM 跑一次识别、把结果句子读出去。
// 不做解码(那在 Kotlin 侧的 PcmDecoder 里)、不做分块(在 WhisperEngine 里)——
// 这里越薄越好:C++ 每多一行,崩溃就多一处没有栈可看的地方。
//
// 与 whisper.cpp 的版本绑定关系写在 tools/build-asr.sh 里(固定 commit)。

#include <android/log.h>
#include <jni.h>
#include <string>
#include <vector>
#include <whisper.h>

namespace {

/// 一个词单元:**保证是合法 UTF-8**的文本 + 它开始被说出的毫秒。
struct Word {
    std::string text;
    int startMs = 0;
};

// 一次识别会话:模型上下文 + 上一句拼好的词单元(供 Kotlin 侧逐个取)。
struct Session {
    whisper_context* ctx = nullptr;
    std::vector<Word> words;
};

/**
 * `s` 是否以**完整的** UTF-8 字符结尾。
 *
 * 为什么需要:whisper 用的是字节级 BPE,**一个汉字(3 字节)可能被劈到两个 token 里**。
 * 把半个字符交给 `NewStringUTF`,JVM 会判定为非法 Modified UTF-8 并**直接 abort 整个进程**
 * (debug 包开着 CheckJNI 时必崩;release 下则是悄悄给出一段坏字符串)。
 * 所以这里逐字符走一遍,末尾不完整就先攒着,等下一个 token 补齐。
 *
 * 返回 false 有两种情况:末尾截断(继续攒),或遇到非法起始字节(调用方丢弃)。
 */
bool endsWithCompleteUtf8(const std::string& s, bool* illegal) {
    *illegal = false;
    size_t i = 0;
    while (i < s.size()) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        size_t need;
        if (c < 0x80) need = 1;
        else if ((c & 0xE0) == 0xC0) need = 2;
        else if ((c & 0xF0) == 0xE0) need = 3;
        else if ((c & 0xF8) == 0xF0) need = 4;
        else { *illegal = true; return false; }   // continuation byte 或 0xF8+ 起头:非法
        if (i + need > s.size()) return false;    // 末尾被截断,等后续 token
        for (size_t k = 1; k < need; k++) {
            if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) { *illegal = true; return false; }
        }
        i += need;
    }
    return true;
}

/// 只把**验过的** UTF-8 交给 JVM;万一还是不合法就给空串,绝不让它 abort 进程。
jstring safeString(JNIEnv* env, const std::string& s) {
    bool illegal = false;
    if (!endsWithCompleteUtf8(s, &illegal)) return env->NewStringUTF("");
    return env->NewStringUTF(s.c_str());
}

inline Session* asSession(jlong h) { return reinterpret_cast<Session*>(h); }

/**
 * 把 whisper/ggml 自己的日志接到 logcat。
 *
 * **这一步不是锦上添花。** 上面那个 flash_attn 关掉 DTW 的坑,库里是打了 WARN 的
 * (`dtw_token_timestamps is not supported with flash_attn - disabling`),但库默认写 stderr,
 * 在 Android 上等于扔掉 —— 于是表面现象只是"时间戳全是 -1",查了很久。
 * 有了这个回调,以后库里任何一句抱怨都能直接看见。
 */
void logToAndroid(ggml_log_level level, const char* text, void*) {
    int prio;
    switch (level) {
        case GGML_LOG_LEVEL_ERROR: prio = ANDROID_LOG_ERROR; break;
        case GGML_LOG_LEVEL_WARN:  prio = ANDROID_LOG_WARN;  break;
        default:                   prio = ANDROID_LOG_INFO;  break;
    }
    __android_log_write(prio, "whisper.cpp", text == nullptr ? "" : text);
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeInit(JNIEnv* env, jobject, jstring modelPath) {
    whisper_log_set(logToAndroid, nullptr);
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
    /**
     * **必须关掉 flash attention** —— 库里一句
     * 「dtw_token_timestamps is not supported with flash_attn - disabling」
     * 就把 DTW 静默关了,而 `whisper_context_default_params()` 里 flash_attn **默认是 true**。
     * 症状是词级时间戳全是 -1(t_dtw 与 t0 都没人填),界面上就是逐字高亮不动。
     */
    cp.flash_attn = false;
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
    // 整句一般是完整的,但没理由在 JNI 边界上留一个不验的出口
    return safeString(env, t == nullptr ? std::string() : std::string(t));
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

/**
 * 把一句的 token 拼成**词单元**,返回个数;之后用 `nativeWordText/StartMs` 逐个取。
 *
 * 做成两段式(先 prepare 再逐个读)而不是"每次调用都现算",有两个原因:
 * - 拼接必须是有状态的 —— **一个汉字可能被劈在两个 token 里**,得攒够字节才算一个字;
 * - 这样 JNI 边界上传出去的每个字符串都已验过是合法 UTF-8,不会把进程 abort 掉。
 *
 * 顺带跳过特殊 token(`<|zh|>`、时间戳这些)与空文本。
 * 时刻取 **`t_dtw`**(DTW 对齐结果)—— `t0/t1` 是解码器的粗略区间,做逐字高亮会明显抖;
 * DTW 不可用时回退到 t0。攒字节期间**用第一个 token 的时刻**,那才是这个字开始发音的位置。
 */
JNIEXPORT jint JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativePrepareWords(
        JNIEnv*, jobject, jlong handle, jint segment) {
    Session* s = asSession(handle);
    if (s == nullptr || s->ctx == nullptr) return 0;
    s->words.clear();

    const int n = whisper_full_n_tokens(s->ctx, segment);
    const whisper_token eot = whisper_token_eot(s->ctx);
    std::string pending;
    int pendingStart = 0;

    for (int i = 0; i < n; i++) {
        const whisper_token_data d = whisper_full_get_token_data(s->ctx, segment, i);
        if (d.id >= eot) continue;                       // 特殊 token
        const char* t = whisper_full_get_token_text(s->ctx, segment, i);
        if (t == nullptr || *t == '\0') continue;
        if (pending.empty()) {
            const int64_t at = d.t_dtw >= 0 ? d.t_dtw : d.t0;
            pendingStart = static_cast<int>(at * 10);     // whisper 的单位是 10ms
        }
        pending += t;

        bool illegal = false;
        if (endsWithCompleteUtf8(pending, &illegal)) {
            s->words.push_back({pending, pendingStart});
            pending.clear();
        } else if (illegal) {
            pending.clear();                              // 拼不出合法字符,丢掉这几个字节
        }
        // 否则:末尾截断,继续攒下一个 token
    }
    // 收尾:仍然不完整就丢弃,**绝不把半个字符交出去**
    return static_cast<jint>(s->words.size());
}

JNIEXPORT jstring JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeWordText(
        JNIEnv* env, jobject, jlong handle, jint index) {
    Session* s = asSession(handle);
    if (s == nullptr || index < 0 || static_cast<size_t>(index) >= s->words.size()) {
        return env->NewStringUTF("");
    }
    return safeString(env, s->words[index].text);
}

JNIEXPORT jint JNICALL
Java_com_yuyin_reverb_playback_asr_WhisperEngine_nativeWordStartMs(
        JNIEnv*, jobject, jlong handle, jint index) {
    Session* s = asSession(handle);
    if (s == nullptr || index < 0 || static_cast<size_t>(index) >= s->words.size()) return 0;
    return s->words[index].startMs;
}

}  // extern "C"
