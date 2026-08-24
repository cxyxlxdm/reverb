/**
 * native 音频解码模块的类型声明。实现见 `../../reverb_pcm.cpp`。
 *
 * 为什么要有这一层:ArkTS 不能直接 `requireNapi`,必须把 .so 声明成一个包
 * (本目录的 oh-package.json5 把包名定成 `libreverb_pcm.so`),然后
 * `import ... from 'libreverb_pcm.so'` —— 这样类型检查才过得去。
 */

/**
 * 打开一个本地音频文件,准备解成 16kHz 单声道 s16le PCM。
 * @returns 句柄;**0 表示失败**(格式不支持、文件坏了、没有音频轨…)
 */
export const open: (path: string, sampleRate: number) => number;

/**
 * 取最多 `maxSamples` 个采样(s16le 单声道)。**同步阻塞**。
 * @returns s16le 字节;**长度为 0 表示已到文件末尾**
 */
export const read: (handle: number, maxSamples: number) => ArrayBuffer;

export const close: (handle: number) => void;
