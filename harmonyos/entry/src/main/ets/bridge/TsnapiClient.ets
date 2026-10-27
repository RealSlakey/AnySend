// Main-thread RPC proxy to TsnapiWorker. Every libtsnapi.so call must go
// through here: a cgo call on the UI thread can stall the Go runtime entry
// and get the app killed by the 6 s watchdog (THREAD_BLOCK_6S).

import { worker } from '@kit.ArkTS';
import { MessageEvents } from '@ohos.worker';

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

interface Pending {
  resolve: (v: string) => void;
}

export class TsnapiClient {
  private static wk: worker.ThreadWorker | null = null;
  private static seq: number = 1;
  private static pending: Map<number, Pending> = new Map();

  /** Lazily start the worker. Returns false when workers are unavailable. */
  static ensure(): boolean {
    if (TsnapiClient.wk !== null) {
      return true;
    }
    try {
      const w = new worker.ThreadWorker('entry/ets/workers/TsnapiWorker.ets');
      w.onmessage = (e: MessageEvents) => {
        const resp = e.data as WorkerResponse;
        const p = TsnapiClient.pending.get(resp.id);
        if (p) {
          TsnapiClient.pending.delete(resp.id);
          p.resolve(resp.result);
        }
      };
      w.onerror = () => {
        TsnapiClient.failAll('worker error');
      };
      TsnapiClient.wk = w;
      return true;
    } catch (e) {
      console.error(`TsnapiClient: worker start failed: ${JSON.stringify(e)}`);
      return false;
    }
  }

  private static failAll(msg: string) {
    TsnapiClient.pending.forEach((p) => {
      p.resolve(JSON.stringify({ error: msg }));
    });
    TsnapiClient.pending.clear();
  }

  /**
   * Run one native command on the worker thread.
   * Resolves with the command's string result, or a JSON object
   * {"error": "..."} when the worker is gone.
   */
  static call(cmd: string, args: string[]): Promise<string> {
    return new Promise<string>((resolve) => {
      if (!TsnapiClient.ensure() || TsnapiClient.wk === null) {
        resolve(JSON.stringify({ error: 'worker unavailable' }));
        return;
      }
      const id = TsnapiClient.seq;
      TsnapiClient.seq = TsnapiClient.seq + 1;
      const req: WorkerRequest = { id: id, cmd: cmd, args: args };
      TsnapiClient.pending.set(id, { resolve: resolve });
      TsnapiClient.wk.postMessage(req);
    });
  }

  /** Parse helper: pull err from a {"error":...} envelope, '' when none. */
  static errorOf(result: string): string {
    try {
      const obj = JSON.parse(result) as Record<string, string>;
      if (obj && obj['error'] !== undefined) {
        return obj['error'];
      }
    } catch (e) {
      // not an envelope — normal result
    }
    return '';
  }
}
