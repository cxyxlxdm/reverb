import { describe, it, expect } from '@ohos/hypium';
import { PodcastRepository } from '../main/ets/net/PodcastRepository';
import { PopularCacheStore } from '../main/ets/store/Stores';
import { SeedCatalog } from '../main/ets/store/SeedCatalog';
import { FeedCacheStore } from '../main/ets/store/FeedCacheStore';
import { SettingsStore } from '../main/ets/store/SettingsStore';

export default function contentGateTest(): void {
  describe('ContentGate', () => {
    it('关闭时榜单缓存与种子入口都不可见', 0, () => {
      const cache = new PopularCacheStore();
      const seed = new SeedCatalog();
      const repo = new PodcastRepository(cache, seed, new FeedCacheStore(), () => false);
      expect(repo.cachedPopular(0, 'us').length).assertEqual(0);
      expect(repo.isSeedList(0, 'us')).assertFalse();
      expect(repo.seedGeneratedAt()).assertEqual('');
    });

    it('关闭时刷新榜单与随机电台直接返回空', 0, async () => {
      const repo = new PodcastRepository(new PopularCacheStore(), new SeedCatalog(),
        new FeedCacheStore(), () => false);
      expect((await repo.refreshPopular(0, 'us')).length).assertEqual(0);
      expect(await repo.randomEpisode('us', [1489], [])).assertNull();
    });

    it('关闭再开启后旧目录代次不得复活', 0, () => {
      let enabled = false;
      const repo = new PodcastRepository(new PopularCacheStore(), new SeedCatalog(),
        new FeedCacheStore(), () => enabled);
      expect(repo.directoryToken()).assertNull();
      enabled = true;
      const first = repo.directoryToken();
      expect(first !== null).assertTrue();
      enabled = false;
      expect(repo.directoryToken()).assertNull();
      expect(first === null || !repo.directoryCurrent(first)).assertTrue();
      enabled = true;
      const second = repo.directoryToken();
      expect(second !== null && second !== first).assertTrue();
      expect(first === null || !repo.directoryCurrent(first)).assertTrue();
    });

    it('卡片策略兼容旧标志并拒绝坏 revision', 0, () => {
      const legacy = SettingsStore.parseThirdPartyPolicyForWidget('1');
      expect(legacy.enabled).assertTrue();
      expect(legacy.revision).assertEqual(0);
      const off = SettingsStore.parseThirdPartyPolicyForWidget('0:42');
      expect(off.enabled).assertFalse();
      expect(off.revision).assertEqual(42);
      const bad = SettingsStore.parseThirdPartyPolicyForWidget('1:bad');
      expect(bad.enabled).assertTrue();
      expect(bad.revision).assertEqual(0);
      const empty = SettingsStore.parseThirdPartyPolicyForWidget('');
      expect(empty.enabled).assertFalse();
      expect(empty.revision).assertEqual(0);
    });
  });
}
