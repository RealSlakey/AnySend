// Dedicated worker thread for every libtsnapi.so (Go cgo) call.
//
// Empirically, while tsnet is starting or serving, a cgo call from the
// HarmonyOS UI thread can stall indefinitely inside the Go runtime, which
// trips the 6 s main-thread watchdog (THREAD_BLOCK_6S) and the system kills
// the app. Running all native calls here keeps the UI thread free of cgo.
//
// Blocking operations must never run here either: this thread serializes
// every command, so one blocked call would stall them all. That is why
// accept is split into acceptStart/acceptPoll (Go runs the blocking Accept
// on a goroutine) and reads/writes carry deadlines on the Go side.

import worker, { ThreadWorkerGlobalScope, MessageEvents } from '@ohos.worker';
import tsnapi from 'libtsnapi.so';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

interface WorkerRequest {
  id: number;
  cmd: string;
  args: string[];
}

interface WorkerResponse {
  id: number;
  cmd: string;
  result: string;
}

const B64_LOOKUP: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function base64ToBytes(b64: string): Uint8Array {
  let clean: string = '';
  for (let i = 0; i < b64.length; i++) {
    const c: string = b64.charAt(i);
    if (c !== '=' && B64_LOOKUP.indexOf(c) >= 0) {
      clean += c;
    }
  }
  const outLen: number = Math.floor(clean.length * 6 / 8);
  const bytes = new Uint8Array(outLen);
  let buffer: number = 0;
  let bits: number = 0;
  let outIdx: number = 0;
  for (let i = 0; i < clean.length; i++) {
    buffer = (buffer << 6) | B64_LOOKUP.indexOf(clean.charAt(i));
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes[outIdx] = (buffer >> bits) & 0xff;
      outIdx += 1;
    }
  }
  return bytes;
}

function callNative(cmd: string, args: string[]): string {
  if (cmd === 'startAsync') {
    return `${tsnapi.startAsync(args[0], args[1], args[2])}`;
  }
  if (cmd === 'startState') {
    return tsnapi.startState();
  }
  if (cmd === 'lastError') {
    return tsnapi.lastError();
  }
  if (cmd === 'getSelfInfo') {
    return tsnapi.getSelfInfo();
  }
  if (cmd === 'getPeers') {
    return tsnapi.getPeers();
  }
  if (cmd === 'isStarted') {
    return `${tsnapi.isStarted()}`;
  }
  if (cmd === 'dial') {
    return tsnapi.dial(args[0], args[1]);
  }
  if (cmd === 'listen') {
    return tsnapi.listen(args[0], args[1]);
  }
  if (cmd === 'acceptStart') {
    return `${tsnapi.acceptStart(Number(args[0]))}`;
  }
  if (cmd === 'acceptPoll') {
    return tsnapi.acceptPoll(Number(args[0]));
  }
  if (cmd === 'forwardTcp') {
    return tsnapi.forwardTcp(Number(args[0]), args[1]);
  }
  if (cmd === 'closeForward') {
    tsnapi.closeForward(Number(args[0]));
    return '0';
  }
  if (cmd === 'read') {
    return tsnapi.read(Number(args[0]), Number(args[1]));
  }
  if (cmd === 'write') {
    const data: Uint8Array = base64ToBytes(args[1]);
    return `${tsnapi.write(Number(args[0]), data.buffer)}`;
  }
  if (cmd === 'closeConn') {
    tsnapi.closeConn(Number(args[0]));
    return '0';
  }
  if (cmd === 'closeListener') {
    tsnapi.closeListener(Number(args[0]));
    return '0';
  }
  if (cmd === 'close') {
    tsnapi.close();
    return '0';
  }
  return JSON.stringify({ error: `unknown cmd ${cmd}` });
}

workerPort.onmessage = (e: MessageEvents) => {
  const req = e.data as WorkerRequest;
  let result: string;
  try {
    result = callNative(req.cmd, req.args);
  } catch (err) {
    result = JSON.stringify({ error: `native exception: ${err}` });
  }
  const resp: WorkerResponse = { id: req.id, cmd: req.cmd, result: result };
  workerPort.postMessage(resp);
};
