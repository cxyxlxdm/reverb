// 余音 · 词级时间戳探针(**开发工具,不进任何 APK**)。
//
// 目的:在 mac 上用**与 Android 完全相同的 whisper 参数**跑一段音频,把每个 token 的
// `t_dtw` 与拼好的词单元连时刻一起打出来。
//
// 为什么需要它:词级时间戳这条链上出过两次"看现象猜原因"的错(见 TROUBLESHOOTING H59)。
// 真机上 DTW 的中间值根本看不见 —— 只能看到界面上高亮不动。有了这个探针,时间轴是对是错
// 在终端里一眼就能看出来,改完也能立刻验证,不必先打包再装机。
//
// 用法(见同目录 run.sh):
//   probe <model.bin> <16k-mono-wav> [语言] [提示词]

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <whisper.h>

namespace {

/// 与 reverb_asr.cpp 里同名函数**逐字相同** —— 探针的意义就在于跑的是同一套逻辑。
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
        else { *illegal = true; return false; }
        if (i + need > s.size()) return false;
        for (size_t k = 1; k < need; k++) {
            if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) { *illegal = true; return false; }
        }
        i += need;
    }
    return true;
}

/// 读 16 kHz 单声道 16-bit PCM 的 wav。探针专用,只认这一种(run.sh 用 ffmpeg 转好)。
bool readWav16k(const char* path, std::vector<float>* out) {
    FILE* f = fopen(path, "rb");
    if (f == nullptr) { fprintf(stderr, "打不开 %s\n", path); return false; }
    // 跳到 data 块:逐块扫,不假设 header 长度固定
    char id[4];
    uint32_t size = 0;
    fseek(f, 12, SEEK_SET);           // 越过 "RIFF"<size>"WAVE"
    while (fread(id, 1, 4, f) == 4 && fread(&size, 4, 1, f) == 1) {
        if (memcmp(id, "data", 4) == 0) break;
        fseek(f, (size + 1) & ~1u, SEEK_CUR);
    }
    if (memcmp(id, "data", 4) != 0) { fprintf(stderr, "没找到 data 块\n"); fclose(f); return false; }
    const size_t n = size / 2;
    std::vector<int16_t> pcm(n);
    if (fread(pcm.data(), 2, n, f) != n) { fprintf(stderr, "读 PCM 短了\n"); }
    fclose(f);
    out->resize(n);
    for (size_t i = 0; i < n; i++) (*out)[i] = pcm[i] / 32768.0f;
    return true;
}

void logCb(ggml_log_level level, const char* text, void*) {
    if (level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR) {
        fprintf(stderr, "[whisper] %s", text == nullptr ? "" : text);
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "用法: probe <model.bin> <16k-mono.wav> [语言] [提示词]\n");
        return 2;
    }
    const std::string lang   = argc > 3 ? argv[3] : "zh";
    const std::string prompt = argc > 4 ? argv[4] : "以下是普通话的句子。";

    whisper_log_set(logCb, nullptr);

    /**
     * 两档对照(靠环境变量切)。**默认那一档必须与线上一致**,否则量出来的偏差不是线上的偏差:
     * - 默认:flash attention 开、DTW 关,词级时刻用 whisper 自己的 `token_timestamps`(t0/t1)
     *   —— **这就是线上的配置**;
     * - `PROBE_DTW=1`:退回历史上的 DTW 那一档(`dtw_token_timestamps` 开、flash attn 必须关),
     *   留着是为了能随时复现"DTW 偏晚 0.4~0.9 秒"这个结论。
     */
    const bool useFlash = getenv("PROBE_DTW") == nullptr;
    whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = false;
    cp.dtw_token_timestamps = !useFlash;
    cp.dtw_aheads_preset = WHISPER_AHEADS_BASE;
    cp.dtw_mem_size = 32u * 1024 * 1024;
    cp.flash_attn = useFlash;          // 与 DTW 互斥:同开会把 DTW 静默关掉(H59)
    whisper_context* ctx = whisper_init_from_file_with_params(argv[1], cp);
    if (ctx == nullptr) { fprintf(stderr, "模型加载失败\n"); return 1; }

    std::vector<float> pcm;
    if (!readWav16k(argv[2], &pcm)) return 1;
    printf("音频 %.1f 秒\n", pcm.size() / 16000.0);

    // ── 与 Android 侧 nativeTranscribe 一致 ──
    whisper_full_params wp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wp.n_threads = 4;
    wp.print_progress = false;
    wp.print_realtime = false;
    wp.print_special = false;
    wp.print_timestamps = false;
    wp.translate = false;
    wp.no_timestamps = false;
    wp.no_context = true;
    wp.single_segment = false;
    wp.language = lang.empty() ? "auto" : lang.c_str();
    wp.detect_language = false;
    wp.initial_prompt = prompt.empty() ? nullptr : prompt.c_str();
    // 词级时刻的另一条来源:whisper 自己的启发式。免费,且与 flash attention 兼容。
    wp.token_timestamps = true;

    const int64_t wall0 = ggml_time_us();
    if (whisper_full(ctx, wp, pcm.data(), static_cast<int>(pcm.size())) != 0) {
        fprintf(stderr, "whisper_full 失败\n");
        return 1;
    }
    const double wall = (ggml_time_us() - wall0) / 1e6;

    const int nSeg = whisper_full_n_segments(ctx);
    printf("flash_attn=%d dtw=%d ⇒ 耗时 %.2f 秒(%.1f 倍实时),共 %d 句\n\n",
           (int)useFlash, (int)!useFlash, wall, (pcm.size() / 16000.0) / wall, nSeg);

    const whisper_token eot = whisper_token_eot(ctx);
    for (int s = 0; s < nSeg; s++) {
        printf("── 句 %d [%lld → %lld ms] %s\n",
               s,
               (long long)whisper_full_get_segment_t0(ctx, s) * 10,
               (long long)whisper_full_get_segment_t1(ctx, s) * 10,
               whisper_full_get_segment_text(ctx, s));

        /**
         * 三条候选时间轴并排,单位毫秒:
         * - `t0`   whisper 自己的启发式(免费,与 flash attention 兼容);
         * - `dtw`  DTW 原样 —— **当前线上用的就是这条**;
         * - `dtw⁻` DTW 往回挪一格。理由见 reverb_asr.cpp 里的长注释:
         *   库里把"token k+1 开口的时刻"写进了 token k,所以原样用等于**整体晚一格**。
         */
        const int n = whisper_full_n_tokens(ctx, s);
        int missing = 0;
        long long sumRaw = 0, sumShift = 0;
        int cmp = 0;
        int64_t prevDtw = whisper_full_get_segment_t0(ctx, s);

        printf("   %-10s %8s %8s %8s\n", "token", "t0", "dtw", "dtw⁻");
        for (int i = 0; i < n; i++) {
            const whisper_token_data d = whisper_full_get_token_data(ctx, s, i);
            if (d.id >= eot) continue;
            const char* t = whisper_full_get_token_text(ctx, s, i);
            if (d.t_dtw < 0) missing++;
            if (d.t_dtw >= 0 && d.t0 >= 0) {
                sumRaw   += llabs((long long)(d.t_dtw - d.t0) * 10);
                sumShift += llabs((long long)(prevDtw  - d.t0) * 10);
                cmp++;
            }
            // 默认只打前 24 个(够看清开头那段的错位,不刷屏);PROBE_N 可放宽
            if (i < (getenv("PROBE_N") != nullptr ? atoi(getenv("PROBE_N")) : 24)) {
                printf("   %-10s %8lld %8lld %8lld\n", t == nullptr ? "" : t,
                       (long long)d.t0 * 10, (long long)d.t_dtw * 10, (long long)prevDtw * 10);
            }
            if (d.t_dtw >= 0) prevDtw = d.t_dtw;
        }
        // 按 Android 侧 nativePrepareWords 的拼字规则给出词单元 + 选定的时刻(t0),
        // 便于挑几个锚点用切片法验证(见 run.sh 里的说明)
        {
            std::string pending;
            int pendingStart = 0;
            printf("   词单元(t0):");
            for (int i = 0; i < n; i++) {
                const whisper_token_data d = whisper_full_get_token_data(ctx, s, i);
                if (d.id >= eot) continue;
                const char* t = whisper_full_get_token_text(ctx, s, i);
                if (t == nullptr || *t == '\0') continue;
                if (pending.empty()) pendingStart = static_cast<int>(d.t0 * 10);
                pending += t;
                bool illegal = false;
                if (endsWithCompleteUtf8(pending, &illegal)) {
                    printf(" %s@%d", pending.c_str(), pendingStart);
                    pending.clear();
                } else if (illegal) {
                    pending.clear();
                }
            }
            printf("\n");
        }

        if (cmp > 0) {
            printf("   ⇒ %d 个 token,t_dtw 缺失 %d;与 t0 的平均差:dtw %lld ms,dtw⁻ %lld ms\n\n",
                   n, missing, sumRaw / cmp, sumShift / cmp);
        } else {
            printf("   ⇒ %d 个 token,t_dtw 缺失 %d(无可比对的 t0)\n\n", n, missing);
        }
    }

    whisper_free(ctx);
    return 0;
}
