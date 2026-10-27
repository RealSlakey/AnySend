// Completed-transfer history, persisted as a JSON array in preferences.
// Records feed the history tab (open / export / batch delete / clear) and are
// kept indefinitely — nothing is evicted behind the user's back, so a record's
// file can always be traced back from the list.
//
// File ownership rules:
//  - 'receive' files live under <filesDir>/Received, i.e. this app wrote them,
//    so they are safe to delete when the user asks for it.
//  - 'send' records point at the user's own source file (a picker/doc URI).
//    The history NEVER deletes those; only the record itself goes away.

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export interface TransferRecord {
  id: string;
  direction: string; // 'send' | 'receive'
  peer: string;
  fileName: string;
  size: number;
  time: number;
  path: string;
}

export interface HistoryStats {
  /** Bytes held by received files that are still on disk. */
  usedBytes: number;
  /** Records whose received file is gone (send records are never counted). */
  lostCount: number;
  /** Files in the receive folder that no record points at. */
  orphanCount: number;
  orphanBytes: number;
}

export interface CleanupResult {
  removedRecords: number;
  removedFiles: number;
}

interface OrphanScan {
  paths: string[];
  bytes: number;
}

const PREFS_NAME = 'transfer_history';
const KEY_RECORDS = 'records';

/** Bump after every mutation so open pages can refresh reactively. */
function bumpVersion(): void {
  const v = AppStorage.get<number>('historyVersion') ?? 0;
  AppStorage.setOrCreate('historyVersion', v + 1);
}

/** Folder holding everything this app received. */
function receivedDir(context: common.Context): string {
  return `${context.filesDir}/Received`;
}

export class HistoryStore {
  /** Append a record (newest first). Fire-and-forget safe: never rejects. */
  static async add(context: common.Context, record: TransferRecord): Promise<void> {
    try {
      const all = await HistoryStore.getAll(context);
      all.unshift(record);
      await HistoryStore.save(context, all);
      bumpVersion();
    } catch (e) {
      console.error(`HistoryStore.add failed: ${JSON.stringify(e)}`);
    }
  }

  static async getAll(context: common.Context): Promise<TransferRecord[]> {
    try {
      const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
      const raw = (await prefs.get(KEY_RECORDS, '')) as string;
      if (!raw || raw.length === 0) {
        return [];
      }
      const parsed = JSON.parse(raw) as TransferRecord[];
      const out: TransferRecord[] = [];
      for (let i = 0; i < parsed.length; i++) {
        const r = parsed[i];
        if (!r || typeof r.id !== 'string' || typeof r.path !== 'string') {
          continue;
        }
        out.push({
          id: r.id,
          direction: r.direction === 'send' ? 'send' : 'receive',
          peer: typeof r.peer === 'string' ? r.peer : '',
          fileName: typeof r.fileName === 'string' && r.fileName.length > 0 ? r.fileName : '未命名文件',
          size: typeof r.size === 'number' ? r.size : 0,
          time: typeof r.time === 'number' ? r.time : 0,
          path: r.path
        });
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** True when [path] points at a file this app owns and may delete. */
  static isAppOwned(context: common.Context, path: string): boolean {
    return path.startsWith(`${context.filesDir}/`);
  }

  /** Delete a set of records; [deleteFiles] also removes the app-owned files. */
  static async removeMany(context: common.Context, ids: string[], deleteFiles: boolean): Promise<void> {
    try {
      const all = await HistoryStore.getAll(context);
      const keep: TransferRecord[] = [];
      for (let i = 0; i < all.length; i++) {
        const r = all[i];
        if (ids.indexOf(r.id) >= 0) {
          if (deleteFiles && HistoryStore.isAppOwned(context, r.path)) {
            HistoryStore.unlinkQuiet(r.path);
          }
        } else {
          keep.push(r);
        }
      }
      await HistoryStore.save(context, keep);
      bumpVersion();
    } catch (e) {
      console.error(`HistoryStore.removeMany failed: ${JSON.stringify(e)}`);
    }
  }

  /** Drop every record; [deleteFiles] also removes the received files. */
  static async clear(context: common.Context, deleteFiles: boolean): Promise<void> {
    try {
      if (deleteFiles) {
        const all = await HistoryStore.getAll(context);
        for (let i = 0; i < all.length; i++) {
          if (HistoryStore.isAppOwned(context, all[i].path)) {
            HistoryStore.unlinkQuiet(all[i].path);
          }
        }
      }
      const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
      await prefs.delete(KEY_RECORDS);
      await prefs.flush();
      bumpVersion();
    } catch (e) {
      console.error(`HistoryStore.clear failed: ${JSON.stringify(e)}`);
    }
  }

  /** Space usage, plus how many records/files went stale. */
  static async stats(context: common.Context, records: TransferRecord[]): Promise<HistoryStats> {
    let usedBytes = 0;
    let lostCount = 0;
    const referenced: string[] = [];
    for (let i = 0; i < records.length; i++) {
      const r = records[i];
      if (r.direction !== 'receive') {
        // Send records point at the user's own source file: never probed,
        // never counted, never deleted.
        continue;
      }
      referenced.push(r.path);
      if (HistoryStore.exists(r.path)) {
        usedBytes += r.size;
      } else {
        lostCount++;
      }
    }
    const orphans = HistoryStore.scanOrphans(context, referenced);
    return {
      usedBytes: usedBytes,
      lostCount: lostCount,
      orphanCount: orphans.paths.length,
      orphanBytes: orphans.bytes
    };
  }

  /** Drop stale records and delete files no record points at. */
  static async cleanup(context: common.Context): Promise<CleanupResult> {
    const all = await HistoryStore.getAll(context);
    const referenced: string[] = [];
    const keep: TransferRecord[] = [];
    let removedRecords = 0;
    for (let i = 0; i < all.length; i++) {
      const r = all[i];
      if (r.direction !== 'receive') {
        keep.push(r);
        continue;
      }
      if (HistoryStore.exists(r.path)) {
        referenced.push(r.path);
        keep.push(r);
      } else {
        removedRecords++;
      }
    }
    if (removedRecords > 0) {
      await HistoryStore.save(context, keep);
      bumpVersion();
    }
    const orphans = HistoryStore.scanOrphans(context, referenced);
    for (let i = 0; i < orphans.paths.length; i++) {
      HistoryStore.unlinkQuiet(orphans.paths[i]);
    }
    return { removedRecords: removedRecords, removedFiles: orphans.paths.length };
  }

  /** Files in the receive folder that [referenced] does not account for. */
  private static scanOrphans(context: common.Context, referenced: string[]): OrphanScan {
    const paths: string[] = [];
    let bytes = 0;
    const dir = receivedDir(context);
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      // Folder not created yet: nothing to clean up.
      return { paths: paths, bytes: bytes };
    }
    for (let i = 0; i < names.length; i++) {
      const p = `${dir}/${names[i]}`;
      if (referenced.indexOf(p) >= 0) {
        continue;
      }
      paths.push(p);
      bytes += HistoryStore.sizeOf(p);
    }
    return { paths: paths, bytes: bytes };
  }

  private static exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  private static sizeOf(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }

  private static unlinkQuiet(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // File may already be gone; the record is removed regardless.
    }
  }

  private static async save(context: common.Context, records: TransferRecord[]): Promise<void> {
    const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
    await prefs.put(KEY_RECORDS, JSON.stringify(records));
    await prefs.flush();
  }

  /** Pick a collision-free path in [dir] for [fileName]: "name (1).ext". */
  static dedupePath(dir: string, fileName: string): string {
    let candidate = `${dir}/${fileName}`;
    if (!fs.accessSync(candidate)) {
      return candidate;
    }
    const dot = fileName.lastIndexOf('.');
    const base = dot > 0 ? fileName.substring(0, dot) : fileName;
    const ext = dot > 0 ? fileName.substring(dot) : '';
    let i = 1;
    while (fs.accessSync(`${dir}/${base} (${i})${ext}`)) {
      i++;
    }
    return `${dir}/${base} (${i})${ext}`;
  }
}
