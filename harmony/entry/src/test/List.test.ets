import dateParseTest from './DateParse.test';
import htmlTextTest from './HtmlText.test';
import liveStreamTest from './LiveStream.test';
import transcriptLinesTest from './TranscriptLines.test';
import chaptersTest from './Chapters.test';
import transcriptSearchExportTest from './TranscriptSearchExport.test';
import senseVoiceTextTest from './SenseVoiceText.test';
import lanSyncLiveTest from './LanSyncLive.test';
import radioStationsTest from './RadioStations.test';

/**
 * 本地单测入口。`hvigorw test` 会生成 `.test/testability/pages/Index.ets`,
 * 它 import 的就是这个默认导出。
 *
 * 只测**纯逻辑**(不碰 UI、不发网络请求):时间解析、HTML 清洗、逐字稿时间轴不变式。
 * 界面与播放链路要真机跑,不在这里假装覆盖。
 */
export default function testsuite(): void {
  dateParseTest();
  htmlTextTest();
  liveStreamTest();
  transcriptLinesTest();
  chaptersTest();
  transcriptSearchExportTest();
  senseVoiceTextTest();
  lanSyncLiveTest();
  radioStationsTest();
}
