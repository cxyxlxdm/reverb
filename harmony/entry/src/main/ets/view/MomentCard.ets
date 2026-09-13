import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import fileUri from '@ohos.file.fileuri';
import type common from '@ohos.app.ability.common';
import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { Episode, Podcast } from '../model/Models';
import { Artwork } from './Widgets';
import { formatTime } from './Components';
import { Log } from '../util/Logger';

/// 剪藏卡:封面 + 标题 + 频道 + 时间点 + 水墨底。
/// 用 componentSnapshot 把这个真实组件截成 PixelMap,再 ImagePacker 编码落盘。
/// 对应 Android `ShareCards.momentCard()`(Android 是纯 Canvas 位图合成)。
@Component
export struct MomentCard {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop episode: Episode;
  @Prop positionMs: number;
  @Prop seal: string = '';

  build() {
    Column({ space: 14 }) {
      Artwork({ scheme: this.scheme, url: this.episode.artworkUrl, dim: 150, corner: 16 })
      Text(this.episode.title)
        .fontSize(17 * this.fontScale)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.onBackground)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
      Text(this.episode.podcastTitle)
        .fontSize(13 * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
        .maxLines(1)
      Row({ space: 8 }) {
        if (this.seal.length > 0) {
          Text(this.seal)
            .fontSize(18 * this.fontScale)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.scheme.primary)
        }
        Text(formatTime(this.positionMs))
          .fontSize(13 * this.fontScale)
          .fontColor(this.scheme.primary)
      }
      .alignItems(VerticalAlign.Center)
      // 一道「梁金」细线 + 落款
      Row().width(40).height(3).backgroundColor(this.scheme.secondary).borderRadius(2)
      Text('余音 · Reverb')
        .fontSize(11 * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
    }
    .width(320)
    .padding(26)
    .backgroundColor(this.scheme.surface)
    .border({ width: 1, color: withAlpha(this.scheme.primary, 0.18) })
    .borderRadius(20)
    .alignItems(HorizontalAlign.Center)
  }
}

/// 频道分享卡:频道 Logo + 频道名 + App 落款,不携带可能含私有凭据的 RSS 地址。
@Component
export struct ChannelShareCard {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop podcast: Podcast;

  build() {
    Column({ space: 20 }) {
      Artwork({ scheme: this.scheme, url: this.podcast.artworkUrl, dim: 190, corner: 20 })
      Text(this.podcast.title)
        .fontSize(22 * this.fontScale)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.scheme.onBackground)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
      Blank()
      Text('余音 · Reverb')
        .fontSize(12 * this.fontScale)
        .fontColor(this.scheme.onSurfaceVariant)
    }
    .width(320)
    .height(410)
    .padding(26)
    .backgroundColor(this.scheme.surface)
    .border({ width: 1, color: withAlpha(this.scheme.primary, 0.18) })
    .borderRadius(20)
    .alignItems(HorizontalAlign.Center)
  }
}

/// 把某个组件(按 id)截图并存成 PNG。返回文件路径;失败返回 null。
export async function snapshotToPng(ui: UIContext, ctx: common.UIAbilityContext,
                                    componentId: string, name: string): Promise<string | null> {
  let pm: image.PixelMap | null = null;
  try {
    // 旧的全局 componentSnapshot.get 已废弃,改用 UIContext 上的实例
    pm = await ui.getComponentSnapshot().get(componentId);
  } catch (e) {
    Log.e('Moment', `截图失败 ${(e as Error).message}`);
    return null;
  }
  return await packPng(pm, ctx, name);
}

/**
 * 把一个 `@Builder` **离屏**渲染成 PNG(足迹海报用)。
 *
 * 为什么不能沿用按 id 截屏:足迹网格是可滚动的,内容通常比视口高,截屏只能拿到可见那一屏。
 * Android 侧是用 Canvas 程序化合成整张海报(`ShareCards.footprintPoster`),
 * 鸿蒙的对等手段是 `createFromBuilder` —— 把一棵不在界面上的子树按其自然尺寸渲染出来。
 */
export async function builderToPng(ui: UIContext, ctx: common.UIAbilityContext,
                                   builder: CustomBuilder, name: string): Promise<string | null> {
  let pm: image.PixelMap | null = null;
  try {
    pm = await ui.getComponentSnapshot().createFromBuilder(builder, 320, true);
  } catch (e) {
    Log.e('Moment', `离屏渲染失败 ${(e as Error).message}`);
    return null;
  }
  return await packPng(pm, ctx, name);
}

/// PixelMap → filesDir 下的 PNG。返回路径,失败 null。
async function packPng(pm: image.PixelMap, ctx: common.UIAbilityContext,
                       name: string): Promise<string | null> {
  const path = `${ctx.filesDir}/${name}`;
  let file: fs.File | null = null;
  const packer = image.createImagePacker();
  try {
    file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    await packer.packToFile(pm, file.fd, { format: 'image/png', quality: 100 });
    Log.i('Moment', `已生成 ${path}`);
    return path;
  } catch (e) {
    Log.e('Moment', `编码失败 ${(e as Error).message}`);
    return null;
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (err) {
        // 忽略
      }
    }
    packer.release();
    if (pm !== null) {
      try {
        await pm.release();
      } catch (err) {
        // 忽略
      }
    }
  }
}

/// 把 PNG 存进系统相册。
/// 用 `showAssetsCreationDialog`(弹系统确认框、**免申请受限权限**);
/// 直接 `createAsset` 需要 ohos.permission.WRITE_IMAGEVIDEO 这类受限权限,普通应用拿不到。
export async function saveToGallery(ctx: common.UIAbilityContext, pngPath: string): Promise<boolean> {
  try {
    const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
    // 源文件必须是沙箱 uri:手拼 "file://" + 路径不被接受,要用 fileUri 转换
    const srcUri = fileUri.getUriFromPath(pngPath);
    const cfg: photoAccessHelper.PhotoCreationConfig = {
      title: 'reverb-moment',
      fileNameExtension: 'png',
      photoType: photoAccessHelper.PhotoType.IMAGE,
      subtype: photoAccessHelper.PhotoSubtype.DEFAULT
    };
    const dstUris = await helper.showAssetsCreationDialog([srcUri], [cfg]);
    if (dstUris.length === 0) {
      Log.i('Moment', '用户取消保存');
      return false;
    }
    const dst = await fs.open(dstUris[0], fs.OpenMode.READ_WRITE);
    const src = fs.openSync(pngPath, fs.OpenMode.READ_ONLY);
    await fs.copyFile(src.fd, dst.fd);
    fs.closeSync(src);
    await fs.close(dst);
    Log.i('Moment', '已存入相册');
    return true;
  } catch (e) {
    Log.w('Moment', `存相册失败 ${(e as Error).message}`);
    return false;
  }
}
