import { describe, it, expect } from '@ohos/hypium';
import { PodcastRepository } from '../main/ets/net/PodcastRepository';
import { SettingsStore } from '../main/ets/store/SettingsStore';

export default function catalogRegionTest(): void {
  describe('CatalogRegion', () => {
    it('关闭目录时保留设备地区或显式覆盖', 0, () => {
      expect(PodcastRepository.catalogRegion(false, '', 'CN')).assertEqual('cn');
      expect(PodcastRepository.catalogRegion(false, 'HK', 'US')).assertEqual('hk');
      expect(PodcastRepository.catalogRegion(false, '', '')).assertEqual('us');
    });

    it('开启目录时空值与港澳台回落美国', 0, () => {
      ['', 'hk', 'TW', 'mo'].forEach((selected: string) => {
        expect(PodcastRepository.catalogRegion(true, selected, 'CN')).assertEqual('us');
      });
    });

    it('中国内地只有显式选择时才生效', 0, () => {
      expect(PodcastRepository.catalogRegion(true, 'CN', 'US')).assertEqual('cn');
      expect(PodcastRepository.catalogRegion(true, '', 'CN')).assertEqual('us');
    });

    it('其它明确选择的非中文地区保留并归一大小写', 0, () => {
      expect(PodcastRepository.catalogRegion(true, 'JP', 'CN')).assertEqual('jp');
      expect(PodcastRepository.catalogRegion(true, 'gb', 'US')).assertEqual('gb');
    });

    it('备份里的未知地区码回落自动并在开启时使用美国', 0, () => {
      ['zh', 'zh-CN', 'xx', ' unknown '].forEach((selected: string) => {
        expect(SettingsStore.normalizeRegionOverride(selected)).assertEqual('');
        expect(PodcastRepository.catalogRegion(true, selected, 'CN')).assertEqual('us');
      });
      expect(SettingsStore.normalizeRegionOverride(' CN ')).assertEqual('cn');
    });
  });
}
