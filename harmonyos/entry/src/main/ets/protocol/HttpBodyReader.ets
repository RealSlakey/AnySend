// Incremental HTTP request-body reader over the raw NetworkLayer socket.
//
// Memory footprint is one read buffer, regardless of body size — the previous
// in-server implementation allocated `new Uint8Array(content-length)` up
// front, so a single forged header (or just a legitimately huge file) could
// OOM-kill the app. Supports both Content-Length and chunked framing.
// Mirrors android/.../protocol/HttpBodyReader.kt — keep the two in sync.

import { NetworkLayer } from './NetworkLayer';
import { fileIo as fs } from '@kit.CoreFileKit';
import util from '@ohos.util';

export class BodyTooLargeException extends Error {
  constructor() {
    super('request body exceeds limit');
  }
}

export class HeadTooLargeException extends Error {
  constructor() {
    super('request head exceeds limit');
  }
}

export class HttpBodyReader {
  private net: NetworkLayer;
  private conn: number;
  private buf: Uint8Array;
  private pos: number = 0;
  private served: number = 0;      // Content-Length mode: bytes returned
  private chunkLeft: number = -1;  // chunked mode: bytes left in current chunk
  private done: boolean = false;
  private contentLength: number;
  private chunked: boolean;
  private maxChunkBytes: number;

  constructor(net: NetworkLayer, conn: number, leftover: Uint8Array,
    contentLength: number, chunked: boolean, maxChunkBytes: number = 1073741824) {
    this.net = net;
    this.conn = conn;
    this.buf = leftover;
    this.contentLength = contentLength;
    this.chunked = chunked;
    this.maxChunkBytes = maxChunkBytes;
  }

  /** Read up to b.length bytes; -1 at end of body. */
  async read(b: Uint8Array): Promise<number> {
    if (this.done || b.length === 0 || !(await this.fill())) {
      return -1;
    }
    let want = b.length;
    if (this.chunked) {
      want = Math.min(want, this.chunkLeft);
    } else {
      want = Math.min(want, this.contentLength - this.served);
    }
    if (want <= 0) {
      this.done = true;
      return -1;
    }
    const n = Math.min(want, this.buf.length - this.pos);
    b.set(this.buf.subarray(this.pos, this.pos + n), 0);
    this.pos += n;
    this.served += n;
    if (this.chunked) {
      this.chunkLeft -= n;
    }
    return n;
  }

  /** Read the entire body, refusing to buffer more than maxBytes. */
  async readFully(maxBytes: number): Promise<Uint8Array> {
    const parts: Uint8Array[] = [];
    let total = 0;
    const chunk = new Uint8Array(64 * 1024);
    while (true) {
      const n = await this.read(chunk);
      if (n < 0) {
        break;
      }
      total += n;
      if (total > maxBytes) {
        throw new BodyTooLargeException();
      }
      parts.push(chunk.slice(0, n));
    }
    const out = new Uint8Array(total);
    let off = 0;
    for (let i = 0; i < parts.length; i++) {
      out.set(parts[i], off);
      off += parts[i].length;
    }
    return out;
  }

  /**
   * Stream the body straight into a file descriptor. Returns bytes written.
   * Nothing larger than one 256 KB chunk is ever held in memory.
   */
  async copyToFile(fd: number): Promise<number> {
    const chunk = new Uint8Array(256 * 1024);
    let total = 0;
    while (true) {
      const n = await this.read(chunk);
      if (n < 0) {
        break;
      }
      // fs.writeSync on API 12 accepts ArrayBuffer|string only — hand it an
      // exactly-sized ArrayBuffer (slice copies, which is fine at this size).
      fs.writeSync(fd, chunk.slice(0, n).buffer as ArrayBuffer);
      total += n;
    }
    return total;
  }

  /** Guarantees at least one readable byte of payload, or sets done. */
  private async fill(): Promise<boolean> {
    while (true) {
      if (this.chunked) {
        if (this.chunkLeft === 0) {
          // The just-finished chunk's trailing CRLF comes before the next
          // size line — consume it first.
          while (this.buf.length - this.pos < 2) {
            if (!(await this.compactAndRead())) {
              return this.truncated();
            }
          }
          if (this.buf[this.pos] !== 13 || this.buf[this.pos + 1] !== 10) {
            return this.truncated();
          }
          this.pos += 2;
          this.chunkLeft = -1;
          continue;
        }
        // Chunk boundary first: buffered bytes at this point belong to the
        // next size line, not to payload.
        if (this.chunkLeft < 0) {
          const eol = findCrlf(this.buf, this.pos);
          if (eol < 0) {
            if (!(await this.compactAndRead())) {
              return this.truncated();
            }
            continue;
          }
          const line = utf8Decode(this.buf.subarray(this.pos, eol));
          const size = parseInt(line.split(';')[0].trim(), 16);
          if (isNaN(size) || size < 0 || size > this.maxChunkBytes) {
            return this.truncated();
          }
          this.pos = eol + 2;
          if (size === 0) {
            this.done = true; // final chunk; trailers ignored (conn closes)
            return false;
          }
          this.chunkLeft = size;
          continue;
        }
        if (this.pos < this.buf.length) {
          return true;
        }
        if (!(await this.compactAndRead())) {
          return this.truncated();
        }
      } else {
        if (this.served >= this.contentLength) {
          this.done = true;
          return false;
        }
        if (this.pos < this.buf.length) {
          return true;
        }
        if (!(await this.compactAndRead())) {
          return this.truncated();
        }
      }
    }
  }

  /** Slide any unread tail to the front, then pull one more read. */
  private async compactAndRead(): Promise<boolean> {
    if (this.pos > 0) {
      this.buf = this.pos < this.buf.length ? this.buf.subarray(this.pos) : new Uint8Array(0);
      this.pos = 0;
    }
    const result = await this.net.read(this.conn, 65536);
    if (result.data.byteLength === 0) {
      return false;
    }
    this.buf = appendBytes(this.buf, new Uint8Array(result.data));
    return true;
  }

  private truncated(): boolean {
    // Peer vanished mid-body or sent malformed framing: treat as EOF.
    this.done = true;
    return false;
  }
}

function findCrlf(data: Uint8Array, from: number): number {
  for (let i = from; i + 1 < data.length; i++) {
    if (data[i] === 0x0d && data[i + 1] === 0x0a) {
      return i;
    }
  }
  return -1;
}

function appendBytes(dst: Uint8Array, src: Uint8Array): Uint8Array {
  const combined = new Uint8Array(dst.length + src.length);
  combined.set(dst, 0);
  combined.set(src, dst.length);
  return combined;
}

function utf8Decode(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}
