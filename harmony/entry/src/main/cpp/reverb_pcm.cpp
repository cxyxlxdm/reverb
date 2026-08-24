// 余音 · 鸿蒙端音频解码(**给系统语音识别喂 PCM 用**)。
//
// 为什么必须写 native:ArkTS 层**完全没有解封装/解码 API** —— `@ohos.multimedia.media` 只有
// AVPlayer(拿不到 PCM)、AVRecorder 与 AVTranscoder(只能输出 AAC)。而系统的语音识别
// (Core Speech Kit)只吃 16kHz/16bit/单声道的裸 PCM。所以这一层不可省。
//
// 做的事就一件:把本地音频文件解成 **16kHz 单声道 s16le PCM**,按需分块交给 ArkTS。
// 不做识别、不做分窗、不落盘 —— 那些都在 ArkTS 侧(`playback/SpeechTranscriber`)。
//
// 用的是 API 20 起提供的**同步**编解码接口(`OH_AudioCodec_QueryInputBuffer` 那一套):
// 不注册回调即为同步模式。这样整条链是一个普通的循环,没有回调线程、没有条件变量 ——
// 音频解码这种地方每多一个线程就多一处没有栈可看的崩溃。

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include <hilog/log.h>
// `napi_module` / `napi_module_register` 在这个头里,`js_native_api.h` 里没有
#include <napi/native_api.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avsource.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

// hilog 自己先定义了一个 LOG_TAG(值是 NULL),要先撤掉才能换成我们的
#undef LOG_TAG
#define LOG_TAG "ReverbPcm"
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, 0xF001, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, 0xF001, LOG_TAG, __VA_ARGS__)

namespace {

/// 等一个可用 buffer 的上限。解码一帧远快于这个数,取大只是为了在系统忙时不误判成结束。
constexpr int64_t kTimeoutUs = 2'000'000;
/// 连续多少轮"喂了也没出东西"就认定解码走不下去。见 Read 里的死循环闸。
constexpr int kMaxIdleRounds = 40;

/**
 * 一次解码会话。
 *
 * `pending` 是**已经重采样成 16k 单声道 s16 的**待取数据:ArkTS 一次要 20 秒,
 * 而解码器一次只给几十毫秒,中间必须有个攒的地方。
 */
struct Session {
    int fd = -1;
    OH_AVSource* source = nullptr;
    OH_AVDemuxer* demuxer = nullptr;
    OH_AVCodec* codec = nullptr;
    uint32_t track = 0;

    int32_t srcRate = 0;
    int32_t srcChannels = 0;
    /// 解码器实际输出的采样格式(`OH_BitsPerSample`)。S16LE 与 F32LE 都要能吃
    int32_t sampleFormat = SAMPLE_S16LE;
    int32_t targetRate = 16000;

    bool inputDone = false;      // 已经把 EOS 推给解码器
    bool outputDone = false;     // 解码器已经吐出 EOS
    /// 重采样的小数相位,**必须跨 buffer 保留** —— 每个 buffer 重新从 0 开始会周期性丢/重样本
    double phase = 0.0;

    std::vector<int16_t> pending;
};

/// 把解码器输出的一段 PCM 下混成单声道并线性重采样到目标率,追加到 pending。
void appendResampled(Session* s, const uint8_t* data, int32_t bytes) {
    if (s->srcChannels <= 0 || s->srcRate <= 0 || bytes <= 0) return;

    const bool isFloat = (s->sampleFormat == SAMPLE_F32LE);
    const int32_t bytesPerSample = isFloat ? 4 : 2;
    const int32_t frameBytes = bytesPerSample * s->srcChannels;
    if (frameBytes <= 0) return;
    const int32_t frames = bytes / frameBytes;
    if (frames <= 0) return;

    // 线性插值对语音识别足够:识别侧自己会做梅尔谱,重采样的微小失真远小于模型本身的误差
    const double step = static_cast<double>(s->srcRate) / static_cast<double>(s->targetRate);
    double pos = s->phase;
    while (pos < frames) {
        const int32_t i0 = static_cast<int32_t>(pos);
        if (i0 >= frames) break;
        double acc = 0.0;
        for (int32_t c = 0; c < s->srcChannels; c++) {
            const int32_t idx = i0 * s->srcChannels + c;
            if (isFloat) {
                float v = 0.0f;
                std::memcpy(&v, data + idx * 4, 4);
                acc += v;
            } else {
                int16_t v = 0;
                std::memcpy(&v, data + idx * 2, 2);
                acc += static_cast<double>(v) / 32768.0;
            }
        }
        double mono = acc / static_cast<double>(s->srcChannels);
        if (mono > 1.0) mono = 1.0;
        if (mono < -1.0) mono = -1.0;
        s->pending.push_back(static_cast<int16_t>(mono * 32767.0));
        pos += step;
    }
    s->phase = pos - frames;
}

/// 往解码器推一帧压缩数据。返回 false 表示这条流已经没有更多输入了。
bool pumpInput(Session* s) {
    if (s->inputDone) return false;
    uint32_t index = 0;
    if (OH_AudioCodec_QueryInputBuffer(s->codec, &index, kTimeoutUs) != AV_ERR_OK) return true;
    OH_AVBuffer* buf = OH_AudioCodec_GetInputBuffer(s->codec, index);
    if (buf == nullptr) return true;

    if (OH_AVDemuxer_ReadSampleBuffer(s->demuxer, s->track, buf) != AV_ERR_OK) {
        // 读不到就当流结束:给解码器一个 EOS 标记,让它把内部缓存吐干净
        OH_AVCodecBufferAttr attr;
        std::memset(&attr, 0, sizeof(attr));
        attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        OH_AVBuffer_SetBufferAttr(buf, &attr);
        OH_AudioCodec_PushInputBuffer(s->codec, index);
        s->inputDone = true;
        return false;
    }
    OH_AudioCodec_PushInputBuffer(s->codec, index);
    return true;
}

/// 取一帧解码结果。返回 false 表示已经收到 EOS。
bool pumpOutput(Session* s) {
    if (s->outputDone) return false;
    uint32_t index = 0;
    const OH_AVErrCode rc = OH_AudioCodec_QueryOutputBuffer(s->codec, &index, kTimeoutUs);
    if (rc == AV_ERR_STREAM_CHANGED) {
        // 输出格式变了(极少见,但发生了就必须重读,否则后面按旧格式解会全是噪声)
        OH_AVFormat* f = OH_AudioCodec_GetOutputDescription(s->codec);
        if (f != nullptr) {
            OH_AVFormat_GetIntValue(f, OH_MD_KEY_AUD_SAMPLE_RATE, &s->srcRate);
            OH_AVFormat_GetIntValue(f, OH_MD_KEY_AUD_CHANNEL_COUNT, &s->srcChannels);
            OH_AVFormat_GetIntValue(f, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &s->sampleFormat);
            OH_AVFormat_Destroy(f);
            LOGI("输出格式变更 %{public}d Hz %{public}d ch fmt=%{public}d",
                 s->srcRate, s->srcChannels, s->sampleFormat);
        }
        return true;
    }
    if (rc != AV_ERR_OK) return true;

    OH_AVBuffer* buf = OH_AudioCodec_GetOutputBuffer(s->codec, index);
    if (buf == nullptr) return true;
    OH_AVCodecBufferAttr attr;
    std::memset(&attr, 0, sizeof(attr));
    if (OH_AVBuffer_GetBufferAttr(buf, &attr) == AV_ERR_OK) {
        if (attr.size > 0) {
            uint8_t* addr = OH_AVBuffer_GetAddr(buf);
            if (addr != nullptr) appendResampled(s, addr + attr.offset, attr.size);
        }
        if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) s->outputDone = true;
    }
    OH_AudioCodec_FreeOutputBuffer(s->codec, index);
    return !s->outputDone;
}

void destroySession(Session* s) {
    if (s == nullptr) return;
    if (s->codec != nullptr) {
        OH_AudioCodec_Stop(s->codec);
        OH_AudioCodec_Destroy(s->codec);
    }
    if (s->demuxer != nullptr) OH_AVDemuxer_Destroy(s->demuxer);
    if (s->source != nullptr) OH_AVSource_Destroy(s->source);
    if (s->fd >= 0) close(s->fd);
    delete s;
}

// ── NAPI ──

/// `open(path: string, targetRate: number): number` —— 返回句柄,0 表示失败。
napi_value Open(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
    std::string path(len, '\0');
    napi_get_value_string_utf8(env, argv[0], path.data(), len + 1, &len);

    int32_t rate = 16000;
    if (argc > 1) napi_get_value_int32(env, argv[1], &rate);

    napi_value out;
    Session* s = new Session();
    s->targetRate = rate > 0 ? rate : 16000;

    s->fd = open(path.c_str(), O_RDONLY);
    if (s->fd < 0) {
        LOGW("打不开文件");
        destroySession(s);
        napi_create_int64(env, 0, &out);
        return out;
    }
    struct stat st;
    if (fstat(s->fd, &st) != 0 || st.st_size <= 0) {
        destroySession(s);
        napi_create_int64(env, 0, &out);
        return out;
    }
    s->source = OH_AVSource_CreateWithFD(s->fd, 0, st.st_size);
    if (s->source == nullptr) {
        LOGW("建 AVSource 失败");
        destroySession(s);
        napi_create_int64(env, 0, &out);
        return out;
    }
    s->demuxer = OH_AVDemuxer_CreateWithSource(s->source);
    if (s->demuxer == nullptr) {
        destroySession(s);
        napi_create_int64(env, 0, &out);
        return out;
    }

    // 找音频轨,顺带把采样率/声道数记下来(重采样要用)
    int32_t trackCount = 0;
    OH_AVFormat* sf = OH_AVSource_GetSourceFormat(s->source);
    if (sf != nullptr) {
        OH_AVFormat_GetIntValue(sf, OH_MD_KEY_TRACK_COUNT, &trackCount);
        OH_AVFormat_Destroy(sf);
    }
    bool found = false;
    std::string mime;
    /**
     * **音频轨的格式要原样留着交给解码器**,不能自己拼一个只有采样率/声道数的最小格式。
     *
     * 真机上撞过:自己拼的格式缺 `aac_is_adts` 与 `OH_MD_KEY_CODEC_CONFIG`
     * (MP4 里的 AudioSpecificConfig / esds),解码器于是报
     * `CheckAdts: aac_is_adts parameter is missing` + 每一帧
     * `Invalid data found when processing input`,一个采样都出不来。
     * 轨道格式里这些键都是齐的,直接用它最省事也最不容易漏。
     */
    OH_AVFormat* trackFmt = nullptr;
    for (int32_t i = 0; i < trackCount; i++) {
        OH_AVFormat* tf = OH_AVSource_GetTrackFormat(s->source, static_cast<uint32_t>(i));
        if (tf == nullptr) continue;
        int32_t type = -1;
        OH_AVFormat_GetIntValue(tf, OH_MD_KEY_TRACK_TYPE, &type);
        if (type == MEDIA_TYPE_AUD) {
            const char* m = nullptr;
            if (OH_AVFormat_GetStringValue(tf, OH_MD_KEY_CODEC_MIME, &m) && m != nullptr) mime = m;
            OH_AVFormat_GetIntValue(tf, OH_MD_KEY_AUD_SAMPLE_RATE, &s->srcRate);
            OH_AVFormat_GetIntValue(tf, OH_MD_KEY_AUD_CHANNEL_COUNT, &s->srcChannels);
            s->track = static_cast<uint32_t>(i);
            found = true;
            trackFmt = tf;         // 交给 Configure 用,别在这里销毁
            break;
        }
        OH_AVFormat_Destroy(tf);
    }
    if (!found || mime.empty()) {
        if (trackFmt != nullptr) OH_AVFormat_Destroy(trackFmt);
        LOGW("文件里没有音频轨");
        destroySession(s);
        napi_create_int64(env, 0, &out);
        return out;
    }
    OH_AVDemuxer_SelectTrackByID(s->demuxer, s->track);

    // **不注册回调 ⇒ 同步模式**,后面才能用 QueryInputBuffer/QueryOutputBuffer
    s->codec = OH_AudioCodec_CreateByMime(mime.c_str(), false);
    if (s->codec == nullptr) {
        LOGW("建解码器失败 mime=%{public}s", mime.c_str());
        OH_AVFormat_Destroy(trackFmt);
        destroySession(s);
        napi_create_int64(env, 0, &out);
        return out;
    }
    // 轨道格式原样拿来当配置(含 codec config / aac_is_adts 等必需键),只补一个同步模式开关
    OH_AVFormat* cfg = trackFmt;
    /**
     * **同步模式必须显式打开。**
     *
     * 我一开始以为"不注册回调"就等于同步模式(头文件里 Query* 那几个函数只说了
     * "not permitted in asynchronous mode"),真机上的结果是每次 Query 都返回
     * `{QueryInputBuffer} not in sync mode`,而且外层循环因为一直取不到数据就空转,
     * 把日志刷了几千行。正解是配置阶段给这个键置 1(默认 0),
     * 且**置了之后就不能再注册回调** —— 两者互斥。
     */
    OH_AVFormat_SetIntValue(cfg, OH_MD_KEY_ENABLE_SYNC_MODE, 1);
    const bool okCfg = OH_AudioCodec_Configure(s->codec, cfg) == AV_ERR_OK;
    OH_AVFormat_Destroy(cfg);
    if (!okCfg || OH_AudioCodec_Prepare(s->codec) != AV_ERR_OK
        || OH_AudioCodec_Start(s->codec) != AV_ERR_OK) {
        LOGW("解码器启动失败");
        destroySession(s);
        napi_create_int64(env, 0, &out);
        return out;
    }

    // 实际输出格式以解码器为准(轨道声明的可能与实际不同)
    OH_AVFormat* of = OH_AudioCodec_GetOutputDescription(s->codec);
    if (of != nullptr) {
        int32_t v = 0;
        if (OH_AVFormat_GetIntValue(of, OH_MD_KEY_AUD_SAMPLE_RATE, &v) && v > 0) s->srcRate = v;
        if (OH_AVFormat_GetIntValue(of, OH_MD_KEY_AUD_CHANNEL_COUNT, &v) && v > 0) s->srcChannels = v;
        if (OH_AVFormat_GetIntValue(of, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &v)) s->sampleFormat = v;
        OH_AVFormat_Destroy(of);
    }
    LOGI("打开成功 %{public}d Hz %{public}d ch fmt=%{public}d → %{public}d Hz mono",
         s->srcRate, s->srcChannels, s->sampleFormat, s->targetRate);

    napi_create_int64(env, reinterpret_cast<int64_t>(s), &out);
    return out;
}

/**
 * `read(handle: number, maxSamples: number): ArrayBuffer` —— 取最多 maxSamples 个
 * 16k 单声道 s16 采样;返回**空 ArrayBuffer 表示到头了**。
 *
 * 这是个**同步**调用,会阻塞调用它的线程直到攒够或流结束。ArkTS 侧一次要 20 秒音频,
 * 解 20 秒在真机上是几十毫秒量级 —— 放在 UI 线程会掉帧,所以 ArkTS 侧应在 TaskPool/Worker
 * 里调它(见 `PcmReader` 的注释)。
 */
napi_value Read(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int64_t handle = 0;
    napi_get_value_int64(env, argv[0], &handle);
    int32_t want = 0;
    if (argc > 1) napi_get_value_int32(env, argv[1], &want);

    napi_value out;
    void* data = nullptr;
    Session* s = reinterpret_cast<Session*>(handle);
    if (s == nullptr || want <= 0) {
        napi_create_arraybuffer(env, 0, &data, &out);
        return out;
    }

    /**
     * 攒到够或者流结束。**必须有个"一直没有进展就放弃"的闸** ——
     * 否则解码器一旦进了不出数据的状态(配置错、编解码器被回收、文件坏),
     * 这个循环就是死循环:每轮都失败、每轮都打一行错误日志,几千行刷屏,
     * 而调用它的线程再也回不去。真机上就这么撞过一次(同步模式没打开)。
     */
    const size_t target = static_cast<size_t>(want);
    int idle = 0;
    while (s->pending.size() < target && !s->outputDone) {
        const size_t before = s->pending.size();
        pumpInput(s);
        pumpOutput(s);
        if (s->pending.size() != before) {
            idle = 0;
            continue;
        }
        // 这一轮既没进新数据也没收到 EOS。偶尔一轮是正常的(解码器还在攒),
        // 连续多轮就说明走不下去了(配置错、编解码器被回收、文件坏)
        if (++idle > kMaxIdleRounds) {
            LOGW("解码连续 %{public}d 轮没有进展,放弃(已攒 %{public}zu 采样)",
                 kMaxIdleRounds, s->pending.size());
            break;
        }
    }
    const size_t give = s->pending.size() < target ? s->pending.size() : target;
    napi_create_arraybuffer(env, give * sizeof(int16_t), &data, &out);
    if (give > 0) {
        std::memcpy(data, s->pending.data(), give * sizeof(int16_t));
        s->pending.erase(s->pending.begin(), s->pending.begin() + static_cast<long>(give));
    }
    return out;
}

/// `close(handle: number): void`
napi_value Close(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int64_t handle = 0;
    napi_get_value_int64(env, argv[0], &handle);
    destroySession(reinterpret_cast<Session*>(handle));
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"open", nullptr, Open, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"read", nullptr, Read, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "reverb_pcm",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterReverbPcmModule() {
    napi_module_register(&g_module);
}
