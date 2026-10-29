// Per-install device identity for HTTPS peers.
//
// Stock LocalSend runs **mutual** TLS: the server asks for a client
// certificate and fails the handshake with `certificate_required` when none is
// presented (see macos/packages/core/src/http/server/common/client_cert_verifier.rs).
// The certificate is the device identity — peers know each other by its SHA-256
// fingerprint — so skipping server validation alone is not enough: we have to
// show one of our own.
//
// LocalSend generates this with rcgen (RSA-2048, CN=LocalSend User, no SANs,
// self-signed, long validity). ArkTS has no certificate builder, only parsers,
// so the minimal X.509 v3 DER is assembled here by hand and signed through
// CryptoArchitectureKit. That is ~120 lines of DER writing, but it keeps the
// identity per-device instead of shipping one shared private key in the HAP.
//
// The result is stored as PEM under filesDir and reused forever after.

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import util from '@ohos.util';

const CERT_FILE: string = 'identity-cert.pem';
const KEY_FILE: string = 'identity-key.pem';
/** LocalSend uses this exact CN; the name carries no meaning, only the fingerprint does. */
const COMMON_NAME: string = 'LocalSend User';
const SIGN_ALG: string = 'RSA2048|PKCS1|SHA256';

export class DeviceIdentity {
  private static certFilePath: string = '';
  private static keyFilePath: string = '';
  private static certPemText: string = '';
  private static fingerprintHex: string = '';

  /**
   * Load the identity, generating it on first run. Safe to call from every
   * ability; repeated calls with an existing identity only read the PEM files.
   */
  static async init(context: common.UIAbilityContext): Promise<void> {
    if (DeviceIdentity.certPemText.length > 0) {
      return;
    }
    const certPath: string = `${context.filesDir}/${CERT_FILE}`;
    const keyPath: string = `${context.filesDir}/${KEY_FILE}`;
    try {
      if (fs.accessSync(certPath) && fs.accessSync(keyPath)) {
        const pem: string = fs.readTextSync(certPath);
        DeviceIdentity.adopt(certPath, keyPath, pem);
        return;
      }
      const created = await DeviceIdentity.generate();
      writeText(certPath, created.certPem);
      writeText(keyPath, created.keyPem);
      DeviceIdentity.adopt(certPath, keyPath, created.certPem);
      console.info(`ANYSEND identity created fingerprint=${DeviceIdentity.fingerprintHex}`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`ANYSEND identity init failed code=${err.code} msg=${err.message}`);
    }
  }

  private static adopt(certPath: string, keyPath: string, pem: string): void {
    DeviceIdentity.certFilePath = certPath;
    DeviceIdentity.keyFilePath = keyPath;
    DeviceIdentity.certPemText = pem;
    DeviceIdentity.fingerprintHex = fingerprintOfPem(pem);
  }

  /** PEM file path for rcp's ClientCertificate. '' when identity is unavailable. */
  static certPath(): string {
    return DeviceIdentity.certFilePath;
  }

  /** Private key PEM file path for rcp's ClientCertificate. */
  static keyPath(): string {
    return DeviceIdentity.keyFilePath;
  }

  /**
   * SHA-256 of the certificate DER, uppercase hex — the LocalSend fingerprint
   * format. Empty until [init] finished.
   */
  static fingerprint(): string {
    return DeviceIdentity.fingerprintHex;
  }

  private static async generate(): Promise<GeneratedIdentity> {
    const generator = cryptoFramework.createAsyKeyGenerator('RSA2048');
    const keyPair = await generator.generateKeyPair();
    const spki: Uint8Array = new Uint8Array(keyPair.pubKey.getEncodedDer('X509').data);
    const pkcs8: Uint8Array = new Uint8Array(keyPair.priKey.getEncodedDer('PKCS8').data);

    const signatureAlg: number[] = derSeq([
      derOid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]), // sha256WithRSAEncryption
      tlv(0x05, []) // NULL parameters
    ]);
    const name: number[] = derSeq([
      derSet([derSeq([derOid([0x55, 0x04, 0x03]), derUtf8(COMMON_NAME)])]) // CN=LocalSend User
    ]);

    const now: number = Date.now();
    const validity: number[] = derSeq([
      derUtcTime(new Date(now - 24 * 60 * 60 * 1000)),
      derUtcTime(new Date(now + 20 * 365 * 24 * 60 * 60 * 1000))
    ]);

    const tbs: number[] = derSeq([
      tlv(0xa0, derInt([2])), // [0] version = v3
      derInt(randomSerial()),
      signatureAlg,
      name, // issuer
      validity,
      name, // subject (self-signed)
      Array.from(spki)
    ]);

    // Sign's only API is asynchronous (init/update/sign), unlike Md.
    const signer = cryptoFramework.createSign(SIGN_ALG);
    await signer.init(keyPair.priKey);
    await signer.update({ data: new Uint8Array(tbs) });
    // sign(data) takes the payload itself; null means "use what update() fed in".
    const signature: Uint8Array = new Uint8Array((await signer.sign(null)).data);

    const certDer: number[] = derSeq([tbs, signatureAlg, tlv(0x03, [0x00, ...Array.from(signature)])]);
    const certPem: string = toPem('CERTIFICATE', new Uint8Array(certDer));
    const keyPem: string = toPem('PRIVATE KEY', pkcs8);
    return { certPem: certPem, keyPem: keyPem };
  }
}

interface GeneratedIdentity {
  certPem: string;
  keyPem: string;
}

function writeText(path: string, text: string): void {
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, text);
  } finally {
    fs.closeSync(file);
  }
}

function toPem(label: string, der: Uint8Array): string {
  const base64: string = new util.Base64Helper().encodeToStringSync(der);
  const lines: string[] = [`-----BEGIN ${label}-----`];
  for (let i = 0; i < base64.length; i += 64) {
    lines.push(base64.substring(i, Math.min(i + 64, base64.length)));
  }
  lines.push(`-----END ${label}-----`);
  return lines.join('\n') + '\n';
}

function fingerprintOfPem(pem: string): string {
  const base64: string = pem.replace('-----BEGIN CERTIFICATE-----', '')
    .replace('-----END CERTIFICATE-----', '')
    .replace(/\s/g, '');
  try {
    const der: Uint8Array = new util.Base64Helper().decodeSync(base64);
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: der });
    const digest: Uint8Array = new Uint8Array(md.digestSync().data);
    let hex = '';
    for (let i = 0; i < digest.length; i++) {
      hex += digest[i].toString(16).toUpperCase().padStart(2, '0');
    }
    return hex;
  } catch (e) {
    const err = e as BusinessError;
    console.error(`ANYSEND identity fingerprint failed code=${err.code} msg=${err.message}`);
    return '';
  }
}

function randomSerial(): number[] {
  const bytes = new Uint8Array(16);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = Math.floor(Math.random() * 256);
  }
  bytes[0] = bytes[0] & 0x7f; // keep the INTEGER positive
  return Array.from(bytes);
}

// ---------- minimal DER encoder ----------

function encodeLength(len: number): number[] {
  if (len < 0x80) {
    return [len];
  }
  const bytes: number[] = [];
  let value = len;
  while (value > 0) {
    bytes.unshift(value & 0xff);
    value = value >> 8;
  }
  return [0x80 | bytes.length, ...bytes];
}

function tlv(tag: number, body: number[]): number[] {
  return [tag, ...encodeLength(body.length), ...body];
}

function derSeq(parts: number[][]): number[] {
  const body: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    body.push(...parts[i]);
  }
  return tlv(0x30, body);
}

function derSet(parts: number[][]): number[] {
  const body: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    body.push(...parts[i]);
  }
  return tlv(0x31, body);
}

function derInt(bytes: number[]): number[] {
  const value = bytes.slice();
  while (value.length > 1 && value[0] === 0) {
    value.shift();
  }
  if ((value[0] & 0x80) !== 0) {
    value.unshift(0);
  }
  return tlv(0x02, value);
}

function derOid(content: number[]): number[] {
  return tlv(0x06, content);
}

function derUtf8(text: string): number[] {
  const buf = util.TextEncoder.create('utf-8').encodeInto(text).buffer as ArrayBuffer;
  return tlv(0x0c, Array.from(new Uint8Array(buf)));
}

function two(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function derUtcTime(date: Date): number[] {
  const text: string = `${two(date.getUTCFullYear() % 100)}${two(date.getUTCMonth() + 1)}` +
    `${two(date.getUTCDate())}${two(date.getUTCHours())}${two(date.getUTCMinutes())}` +
    `${two(date.getUTCSeconds())}Z`;
  return tlv(0x17, Array.from(text).map((c: string) => c.charCodeAt(0)));
}
