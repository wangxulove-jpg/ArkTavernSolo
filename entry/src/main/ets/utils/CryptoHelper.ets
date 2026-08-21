import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import util from '@ohos.util';
import { Logger } from './Logger';

const LOG_TAG: string = 'CryptoHelper';
const AES_256_GCM: string = 'AES256|GCM|PKCS7';
const AES_256: string = 'AES256';
const HMAC_SHA256: string = 'HMAC|SHA256';
const IV_LENGTH: number = 12;
const SALT_LENGTH: number = 16;
const KEY_LENGTH: number = 32;
const AUTH_TAG_LENGTH: number = 16;
const ITERATIONS: number = 1000;

export class CryptoHelper {
  static async encrypt(plaintext: string, password: string): Promise<string> {
    try {
      const encoder: util.TextEncoder = new util.TextEncoder();
      const salt: Uint8Array = CryptoHelper.generateRandomBytes(SALT_LENGTH);
      const iv: Uint8Array = CryptoHelper.generateRandomBytes(IV_LENGTH);
      const keyBytes: Uint8Array = await CryptoHelper.deriveKey(password, salt);
      const symKey: cryptoFramework.SymKey = await CryptoHelper.convertToSymKey(keyBytes);
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(AES_256_GCM);
      const gcmParams: cryptoFramework.GcmParamsSpec = CryptoHelper.createGcmParams(iv);
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams);
      const plainBlob: cryptoFramework.DataBlob = { data: encoder.encodeInto(plaintext) };
      const updateResult: cryptoFramework.DataBlob = await cipher.update(plainBlob);
      const finalResult: cryptoFramework.DataBlob = await cipher.doFinal(null);
      const authTag: Uint8Array = gcmParams.authTag.data;
      const combined: Uint8Array = CryptoHelper.concatArrays(
        CryptoHelper.concatArrays(CryptoHelper.concatArrays(salt, iv), updateResult.data),
        CryptoHelper.concatArrays(finalResult.data, authTag)
      );
      const base64: util.Base64Helper = new util.Base64Helper();
      return base64.encodeToStringSync(combined, util.Type.BASIC);
    } catch (e) {
      Logger.error(LOG_TAG, 'encrypt failed: ' + (e as Error).message);
      throw new Error('Encryption failed: ' + (e as Error).message);
    }
  }

  static async decrypt(ciphertextBase64: string, password: string): Promise<string> {
    try {
      const base64: util.Base64Helper = new util.Base64Helper();
      const combined: Uint8Array = base64.decodeSync(ciphertextBase64, util.Type.BASIC);
      const salt: Uint8Array = combined.slice(0, SALT_LENGTH);
      const iv: Uint8Array = combined.slice(SALT_LENGTH, SALT_LENGTH + IV_LENGTH);
      const ciphertext: Uint8Array = combined.slice(
        SALT_LENGTH + IV_LENGTH, combined.length - AUTH_TAG_LENGTH);
      const authTag: Uint8Array = combined.slice(combined.length - AUTH_TAG_LENGTH);
      const keyBytes: Uint8Array = await CryptoHelper.deriveKey(password, salt);
      const symKey: cryptoFramework.SymKey = await CryptoHelper.convertToSymKey(keyBytes);
      const cipher: cryptoFramework.Cipher = cryptoFramework.createCipher(AES_256_GCM);
      const gcmParams: cryptoFramework.GcmParamsSpec = CryptoHelper.createGcmParamsWithAuthTag(iv, authTag);
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams);
      const cipherBlob: cryptoFramework.DataBlob = { data: ciphertext };
      const updateResult: cryptoFramework.DataBlob = await cipher.update(cipherBlob);
      const finalResult: cryptoFramework.DataBlob = await cipher.doFinal(null);
      const decrypted: Uint8Array = CryptoHelper.concatArrays(updateResult.data, finalResult.data);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(decrypted);
    } catch (e) {
      Logger.error(LOG_TAG, 'decrypt failed: ' + (e as Error).message);
      throw new Error('Decryption failed: ' + (e as Error).message);
    }
  }

  private static async deriveKey(password: string, salt: Uint8Array): Promise<Uint8Array> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const passwordBytes: Uint8Array = encoder.encodeInto(password);
    let keyMaterial: Uint8Array = CryptoHelper.concatArrays(passwordBytes, salt);
    const symKeyGenerator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator(AES_256);
    for (let i = 0; i < ITERATIONS; i++) {
      const mac: cryptoFramework.Mac = cryptoFramework.createMac(HMAC_SHA256);
      const keyBlob: cryptoFramework.DataBlob = { data: keyMaterial };
      const hmacKey: cryptoFramework.SymKey = await symKeyGenerator.convertKey(keyBlob);
      await mac.init(hmacKey);
      await mac.update(keyBlob);
      const result: cryptoFramework.DataBlob = await mac.doFinal();
      keyMaterial = result.data;
    }
    return keyMaterial.slice(0, KEY_LENGTH);
  }

  private static async convertToSymKey(keyBytes: Uint8Array): Promise<cryptoFramework.SymKey> {
    const symKeyGenerator: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator(AES_256);
    const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
    return symKeyGenerator.convertKey(keyBlob);
  }

  private static createGcmParams(iv: Uint8Array): cryptoFramework.GcmParamsSpec {
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: new Uint8Array(AUTH_TAG_LENGTH) }
    };
    return gcmParams;
  }

  private static createGcmParamsWithAuthTag(iv: Uint8Array, authTag: Uint8Array): cryptoFramework.GcmParamsSpec {
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: authTag }
    };
    return gcmParams;
  }

  private static generateRandomBytes(length: number): Uint8Array {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    const dataBlob: cryptoFramework.DataBlob = random.generateRandomSync(length);
    return dataBlob.data;
  }

  private static concatArrays(a: Uint8Array, b: Uint8Array): Uint8Array {
    const result: Uint8Array = new Uint8Array(a.length + b.length);
    result.set(a, 0);
    result.set(b, a.length);
    return result;
  }
}
