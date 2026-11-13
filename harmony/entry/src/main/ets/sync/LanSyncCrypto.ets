import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';

/**
 * 局域网同步的密码学底座(**ArkTS 版**,与 Android `sync/LanSyncCrypto.kt` /
 * Apple 共享层逐字节对齐)。
 *
 * 只使用系统自带的 EC / ECDH / HKDF-SHA256 / AES-GCM —— 不引任何三方库。
 * 跨端契约是**字节级**的,改任何一项都会让两端互相解不开,而且**不报错**,
 * 只表现为"配对码不一致 / 收到的都是乱码":
 *
 * - 公钥:`0x04 || X(32) || Y(32)` 的 P-256 未压缩点(65 字节),不是 X.509;
 * - 共享密钥:ECDH P-256 的 X 坐标(32 字节);
 * - 会话密钥:HKDF-SHA256(共享密钥, salt=SHA256(clientNonce||serverNonce), info="reverb-lan-v1", 32);
 * - 配对码:HKDF-SHA256(共享密钥, salt=32 个 0, info="reverb-sas", 4) 取大端整数 % 1_000_000;
 * - AES-GCM:12 字节随机 nonce,16 字节 tag,密文与 tag 拼接后整段传输。
 *
 * 两个平台差异都收在本文件里:
 * 1. 系统密钥对象只给 DER(`SubjectPublicKeyInfo` / `PKCS#8`),而跨端传的是 65 字节裸点
 *    —— 自己拼/拆那 26 字节头(见 [spkiFromRaw]),**不要**把 DER 直接传上线,对端不认;
 * 2. 鸿蒙 AES-GCM 解密要求把 tag **单独**放进 `authTag`,而加密返回的是密文+tag 拼接,
 *    所以 decrypt 里自己切那 16 字节(见 [decrypt])。
 */
export class LanSyncCrypto {
  static readonly PUBLIC_KEY_BYTES: number = 65;
  static readonly NONCE_BYTES: number = 12;
  static readonly SESSION_KEY_BYTES: number = 32;
  static readonly TAG_BYTES: number = 16;

  private static readonly CURVE: string = 'ECC256';

  /** P-256 SPKI 头:算法标识 OID 1.2.840.10045.2.1 + 曲线 OID 1.2.840.10045.3.1.7。 */
  private static readonly SPKI_PREFIX: number[] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
  ];

  static async generateKeyPair(): Promise<cryptoFramework.KeyPair> {
    return await cryptoFramework.createAsyKeyGenerator(LanSyncCrypto.CURVE).generateKeyPair();
  }

  /** 私钥的 PKCS#8 编码(系统给的 DER)。落盘时再套一层 Base64。 */
  static encodePrivateKey(key: cryptoFramework.PriKey): Uint8Array {
    return key.getEncoded().data;
  }

  static async decodePrivateKey(pkcs8: Uint8Array): Promise<cryptoFramework.PriKey> {
    const gen = cryptoFramework.createAsyKeyGenerator(LanSyncCrypto.CURVE);
    const pair = await gen.convertKey(null, { data: pkcs8 } as cryptoFramework.DataBlob);
    if (pair.priKey === null) throw new Error('私钥导入失败');
    return pair.priKey;
  }

  /**
   * 公钥只导出成 **65 字节未压缩点**,与 Android `encodePublicKey` / Swift
   * `rawRepresentation` 一致。系统给的是 SPKI DER(91 字节,末尾正好是那个点)。
   */
  static encodePublicKey(key: cryptoFramework.PubKey): Uint8Array {
    const der = key.getEncoded().data;
    if (der.length < LanSyncCrypto.PUBLIC_KEY_BYTES) {
      throw new Error(`公钥编码只有 ${der.length} 字节`);
    }
    const raw = der.slice(der.length - LanSyncCrypto.PUBLIC_KEY_BYTES);
    if (raw[0] !== 0x04) throw new Error('公钥不是未压缩点');
    return raw;
  }

  private static spkiFromRaw(raw: Uint8Array): Uint8Array {
    if (raw.length !== LanSyncCrypto.PUBLIC_KEY_BYTES || raw[0] !== 0x04) {
      throw new Error('P-256 公钥必须是 65 字节未压缩点');
    }
    const out = new Uint8Array(LanSyncCrypto.SPKI_PREFIX.length + raw.length);
    for (let i = 0; i < LanSyncCrypto.SPKI_PREFIX.length; i++) out[i] = LanSyncCrypto.SPKI_PREFIX[i];
    out.set(raw, LanSyncCrypto.SPKI_PREFIX.length);
    return out;
  }

  /**
   * ECDH。返回 32 字节 X 坐标。
   *
   * 系统实现可能给 32 / 33(带前导 0)/ 65(带 0x04)三种长度之一 —— 这里统一归一到
   * 32 字节的 X:契约是 Android 的 `KeyAgreement.generateSecret()`,它给的正是 X。
   * 不归一就会让 HKDF 的 ikm 差一个字节,而症状只是"配对码对不上"。
   */
  static async sharedSecret(privKey: cryptoFramework.PriKey, peerPublicRaw: Uint8Array): Promise<Uint8Array> {
    const gen = cryptoFramework.createAsyKeyGenerator(LanSyncCrypto.CURVE);
    const spki = LanSyncCrypto.spkiFromRaw(peerPublicRaw);
    const pair = await gen.convertKey({ data: spki } as cryptoFramework.DataBlob, null);
    if (pair.pubKey === null) throw new Error('对方公钥导入失败');
    const secret = await cryptoFramework.createKeyAgreement(LanSyncCrypto.CURVE)
      .generateSecret(privKey, pair.pubKey);
    const b = secret.data;
    if (b.length === 32) return b.slice(0);
    if (b.length === 33 && b[0] === 0x00) return b.slice(1);
    if (b.length === 65 && b[0] === 0x04) return b.slice(1, 33);
    throw new Error(`共享密钥长度 ${b.length} 不符合契约`);
  }

  static async hkdf(ikm: Uint8Array, salt: Uint8Array, info: string, length: number): Promise<Uint8Array> {
    const kdf = cryptoFramework.createKdf('HKDF|SHA256');
    // `spec.algName` 只写基名,不带摘要 —— 与 PBKDF2 的写法一致(`algName: 'PBKDF2'`)。
    // 写成 'HKDF|SHA256' 时系统在 `JsKdfGenerateSecret` 里建上下文就失败,
    // 报的是 **`build context fail.`**,看起来像网络或参数问题(H273)。
    const spec: cryptoFramework.HKDFSpec = {
      algName: 'HKDF',
      key: ikm,
      salt: salt,
      info: new util.TextEncoder().encodeInto(info),
      keySize: length
    };
    const out = await kdf.generateSecret(spec);
    return out.data;
  }

  static async sha256(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: data } as cryptoFramework.DataBlob);
    return md.digestSync().data;
  }

  static async sessionKey(shared: Uint8Array, clientNonce: Uint8Array, serverNonce: Uint8Array): Promise<Uint8Array> {
    const both = new Uint8Array(clientNonce.length + serverNonce.length);
    both.set(clientNonce, 0);
    both.set(serverNonce, clientNonce.length);
    const salt = await LanSyncCrypto.sha256(both);
    return await LanSyncCrypto.hkdf(shared, salt, 'reverb-lan-v1', LanSyncCrypto.SESSION_KEY_BYTES);
  }

  /** 六位配对码。两端各自算,不经过网络传输 —— 传的是"我算出来是多少"的证明,不是码本身。 */
  static async sasCode(shared: Uint8Array): Promise<string> {
    const b = await LanSyncCrypto.hkdf(shared, new Uint8Array(32), 'reverb-sas', 4);
    // **必须按无符号 32 位算**。`b[0] << 24` 在 JS 里是负数,`% 1_000_000` 会给出负码,
    // 而 Android 用的是无符号 —— 这个错不抛异常,只让两端屏幕上的六位数对不上。
    const n = (((b[0] << 24) >>> 0) + (b[1] << 16) + (b[2] << 8) + b[3]) % 1000000;
    const digits = `${n}`;
    return digits.length >= 6 ? digits : '0'.repeat(6 - digits.length) + digits;
  }

  /** 加密结果 = ciphertext || tag(系统 doFinal 的尾部就是 16 字节 tag,与 Android 同形)。 */
  static async encrypt(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array): Promise<Uint8Array> {
    if (nonce.length !== LanSyncCrypto.NONCE_BYTES) throw new Error('nonce 必须是 12 字节');
    const sym = await cryptoFramework.createSymKeyGenerator('AES256')
      .convertKey({ data: key } as cryptoFramework.DataBlob);
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: new Uint8Array(0) },
      authTag: { data: new Uint8Array(0) }
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, sym, params);
    const out = await cipher.doFinal({ data: plaintext } as cryptoFramework.DataBlob);
    return out.data;
  }

  static async decrypt(key: Uint8Array, nonce: Uint8Array, ciphertextAndTag: Uint8Array): Promise<Uint8Array> {
    if (nonce.length !== LanSyncCrypto.NONCE_BYTES) throw new Error('nonce 必须是 12 字节');
    if (ciphertextAndTag.length < LanSyncCrypto.TAG_BYTES + 1) throw new Error('密文太短');
    const cut = ciphertextAndTag.length - LanSyncCrypto.TAG_BYTES;
    const body = ciphertextAndTag.slice(0, cut);
    const tag = ciphertextAndTag.slice(cut);
    const sym = await cryptoFramework.createSymKeyGenerator('AES256')
      .convertKey({ data: key } as cryptoFramework.DataBlob);
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: nonce },
      aad: { data: new Uint8Array(0) },
      authTag: { data: tag }
    };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, sym, params);
    const out = await cipher.doFinal({ data: body } as cryptoFramework.DataBlob);
    return out.data;
  }

  static randomBytes(size: number): Uint8Array {
    return cryptoFramework.createRandom().generateRandomSync(size).data;
  }

  static randomHex(size: number): string {
    const b = LanSyncCrypto.randomBytes(size);
    let out = '';
    for (let i = 0; i < b.length; i++) out += (b[i] < 16 ? '0' : '') + b[i].toString(16);
    return out;
  }

  static constantTimeEquals(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= (a[i] ^ b[i]);
    return diff === 0;
  }

  // ── Base64url(无填充) ──
  //
  // 不用 `util.Base64Helper`:URL_SAFE 枚举的可用版本在各 SDK 上不一致,而两端契约
  // 本来就是"base64url 无填充"。自己写一张表,输出完全确定 —— 也便于对测试向量逐字节核。

  private static readonly B64: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  static base64(bytes: Uint8Array): string {
    let out = '';
    let i = 0;
    while (i + 2 < bytes.length) {
      const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += LanSyncCrypto.B64[(n >> 18) & 63] + LanSyncCrypto.B64[(n >> 12) & 63] +
        LanSyncCrypto.B64[(n >> 6) & 63] + LanSyncCrypto.B64[n & 63];
      i += 3;
    }
    const rest = bytes.length - i;
    if (rest === 1) {
      const n = bytes[i] << 16;
      out += LanSyncCrypto.B64[(n >> 18) & 63] + LanSyncCrypto.B64[(n >> 12) & 63];
    } else if (rest === 2) {
      const n = (bytes[i] << 16) | (bytes[i + 1] << 8);
      out += LanSyncCrypto.B64[(n >> 18) & 63] + LanSyncCrypto.B64[(n >> 12) & 63] +
        LanSyncCrypto.B64[(n >> 6) & 63];
    }
    return out;
  }

  static unbase64(text: string): Uint8Array {
    const clean = text.trim();
    const out: number[] = [];
    let acc = 0;
    let bits = 0;
    for (let i = 0; i < clean.length; i++) {
      const ch = clean.charAt(i);
      if (ch === '=') break;
      const v = LanSyncCrypto.B64.indexOf(ch);
      if (v < 0) throw new Error(`不是合法的 base64url:${ch}`);
      acc = (acc << 6) | v;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((acc >> bits) & 0xff);
      }
    }
    const bytes = new Uint8Array(out.length);
    for (let i = 0; i < out.length; i++) bytes[i] = out[i];
    return bytes;
  }
}
