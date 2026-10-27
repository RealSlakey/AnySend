// Text payload -> ordinary .txt file in the app cache, so text travels over
// the LocalSend v2 file protocol exactly like any other file.

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';

const MAX_TEXT_BYTES: number = 32 * 1024;

export class TextShare {
  static readonly MAX_BYTES: number = MAX_TEXT_BYTES;

  static utf8Bytes(text: string): Uint8Array {
    return util.TextEncoder.create('utf-8').encodeInto(text);
  }

  static isTooLong(text: string): boolean {
    // The UTF-8 byte count is never less than the string length, so this also
    // short-circuits encoding a huge clipboard string on the UI thread.
    if (text.length > MAX_TEXT_BYTES) {
      return true;
    }
    return TextShare.utf8Bytes(text).length > MAX_TEXT_BYTES;
  }

  /** Readable name: 文字-20261026-153045.txt */
  static fileName(date: Date): string {
    const two = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    const stamp = `${date.getFullYear()}${two(date.getMonth() + 1)}${two(date.getDate())}`
      + `-${two(date.getHours())}${two(date.getMinutes())}${two(date.getSeconds())}`;
    return `文字-${stamp}.txt`;
  }

  /** Write the text as UTF-8 into cacheDir and return the absolute path. */
  static async writeToCache(context: common.Context, text: string): Promise<string> {
    const base = TextShare.fileName(new Date()).replace(/\.txt$/, '');
    let path = `${context.cacheDir}/${base}.txt`;
    let suffix = 2;
    while (fs.accessSync(path)) {
      path = `${context.cacheDir}/${base}-${suffix}.txt`;
      suffix++;
    }
    const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      await fs.write(file.fd, TextShare.utf8Bytes(text).buffer as ArrayBuffer);
    } finally {
      await fs.close(file);
    }
    return path;
  }
}
