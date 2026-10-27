// History tab: completed file transfers with full local-file management.
//
// Supported flows:
//  - tap a row            -> open the file (single-select mode: toggle selection)
//  - long-press a row     -> open / save a copy / delete record / delete record + file
//  - 选择                  -> multi-select mode with batch delete
//  - 清空                  -> clear records only, or records + received files
//  - stats card           -> disk usage, stale records, leftover files + cleanup
//
// Records are kept indefinitely (no cap), so the list is the single source of
// truth for every file this app has written.

import { common, Want, wantConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import promptAction from '@ohos.promptAction';
import { HistoryStore, TransferRecord, HistoryStats, CleanupResult } from '../common/HistoryStore';
import { Tokens } from '../common/DesignTokens';
import { CardContainer } from '../common/CardContainer';

/** Export copy buffer: 64 KB keeps memory flat for large videos. */
const COPY_CHUNK = 64 * 1024;

/** Best-effort mime type for opening a file by extension. */
function mimeOf(fileName: string): string {
  const dot = fileName.lastIndexOf('.');
  const ext = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
  const map: Record<string, string> = {
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif',
    'webp': 'image/webp', 'bmp': 'image/bmp', 'heic': 'image/heic',
    'mp4': 'video/mp4', 'mov': 'video/quicktime', 'avi': 'video/x-msvideo',
    'mkv': 'video/x-matroska',
    'mp3': 'audio/mpeg', 'm4a': 'audio/mp4a-latm', 'wav': 'audio/wav', 'flac': 'audio/flac',
    'pdf': 'application/pdf', 'txt': 'text/plain', 'html': 'text/html',
    'json': 'application/json', 'xml': 'application/xml', 'csv': 'text/csv',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'zip': 'application/zip', 'rar': 'application/vnd.rar', '7z': 'application/x-7z-compressed',
    'apk': 'application/vnd.android.package-archive'
  };
  const hit = map[ext];
  return hit !== undefined ? hit : 'application/octet-stream';
}

function formatSize(bytes: number): string {
  if (bytes >= 1024 * 1024) {
    return `${(bytes / 1048576).toFixed(1)} MB`;
  }
  if (bytes >= 1024) {
    return `${Math.floor(bytes / 1024)} KB`;
  }
  return `${bytes} B`;
}

@Component
export struct HistoryPage {
  @State records: TransferRecord[] = [];
  @State selectMode: boolean = false;
  @State selectedIds: string[] = [];
  @State usedBytes: number = 0;
  @State lostCount: number = 0;
  @State orphanCount: number = 0;
  @State statsReady: boolean = false;
  @StorageLink('historyVersion') @Watch('onHistoryChanged') historyVersion: number = 0;

  private onHistoryChanged(): void {
    this.refresh();
  }

  build() {
    Column() {
      Row() {
        if (this.selectMode) {
          Text('取消')
            .fontSize(Tokens.FONT_BODY)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: 4, right: 12, top: 8, bottom: 8 })
            .onClick(() => {
              this.exitSelect();
            })
          Text(`已选 ${this.selectedIds.length} 项`)
            .fontSize(Tokens.FONT_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
          Text('删除')
            .fontSize(Tokens.FONT_BODY)
            .fontColor(this.selectedIds.length > 0 ? $r('sys.color.brand') : $r('sys.color.font_tertiary'))
            .padding({ left: 12, right: 4, top: 8, bottom: 8 })
            .onClick(() => {
              this.confirmDeleteSelected();
            })
        } else {
          Text('历史')
            .fontSize(Tokens.FONT_H2)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          if (this.records.length > 0) {
            Text('选择')
              .fontSize(Tokens.FONT_BODY)
              .fontColor($r('sys.color.brand'))
              .padding({ left: 12, right: 8, top: 8, bottom: 8 })
              .onClick(() => {
                this.selectMode = true;
                this.selectedIds = [];
              })
          }
          if (this.records.length > 0) {
            Text('清空')
              .fontSize(Tokens.FONT_BODY)
              .fontColor($r('sys.color.brand'))
              .padding({ left: 8, right: 4, top: 8, bottom: 8 })
              .onClick(() => {
                this.confirmClear();
              })
          }
        }
      }
      .width('100%')
      .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, top: Tokens.SPACE_LG })

      if (this.records.length === 0) {
        Column({ space: Tokens.SPACE_SM }) {
          Text('暂无传输记录')
            .fontSize(Tokens.FONT_BODY)
            .fontColor($r('sys.color.font_secondary'))
          Text('收发完成的文件会显示在这里')
            .fontSize(Tokens.FONT_CAPTION)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 120 })
      } else {
        Scroll() {
          Column() {
            CardContainer() {
              Row() {
                Text(this.statsLine())
                  .fontSize(Tokens.FONT_CAPTION)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (this.hasStale()) {
                  Text('清理')
                    .fontSize(Tokens.FONT_CAPTION)
                    .fontColor($r('sys.color.brand'))
                    .padding({ left: 12, right: 2, top: 4, bottom: 4 })
                    .onClick(() => {
                      this.runCleanup();
                    })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }

            CardContainer() {
              List({ space: 2 }) {
                ForEach(this.records, (r: TransferRecord) => {
                  ListItem() {
                    this.recordRow(r)
                  }
                }, (r: TransferRecord) => r.id)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding({ left: Tokens.SPACE_LG, right: Tokens.SPACE_LG, top: Tokens.SPACE_SM, bottom: Tokens.SPACE_XL })
          .constraintSize({ maxWidth: Tokens.CONTENT_MAX_WIDTH })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  recordRow(r: TransferRecord) {
    Row({ space: Tokens.SPACE_MD }) {
      if (this.selectMode) {
        Text(this.isSelected(r.id) ? '✓' : '')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .width(22)
          .height(22)
          .textAlign(TextAlign.Center)
          .borderRadius(11)
          .backgroundColor(this.checkFill(r.id))
          .border({
            width: this.isSelected(r.id) ? 0 : 1.5,
            color: this.isSelected(r.id) ? $r('sys.color.brand') : $r('sys.color.icon_tertiary')
          })
      }
      Text(r.direction === 'receive' ? '收' : '发')
        .fontSize(Tokens.FONT_BODY)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor(r.direction === 'receive'
          ? $r('sys.color.brand')
          : $r('sys.color.icon_secondary'))
      Column() {
        Text(r.fileName)
          .fontSize(Tokens.FONT_BODY)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${r.direction === 'receive' ? '来自' : '发给'} ${r.peer} · ${formatSize(r.size)}`)
          .fontSize(Tokens.FONT_CAPTION)
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 1 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.fmtTime(r.time))
        .fontSize(Tokens.FONT_CAPTION)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .width('100%')
    .height(Tokens.TARGET_MIN + 12)
    .onClick(() => {
      if (this.selectMode) {
        this.toggleSelect(r.id);
      } else {
        this.openRecord(r);
      }
    })
    .bindContextMenu(this.recordMenu(r), ResponseType.LongPress)
  }

  @Builder
  recordMenu(r: TransferRecord) {
    Menu() {
      if (this.selectMode) {
        MenuItem({ content: this.isSelected(r.id) ? '取消选择' : '选中' })
          .onClick(() => {
            this.toggleSelect(r.id);
          })
      } else {
        MenuItem({ content: '打开' })
          .onClick(() => {
            this.openRecord(r);
          })
        if (this.canExport(r)) {
          MenuItem({ content: '保存到文件管理' })
            .onClick(() => {
              this.exportRecord(r);
            })
        }
        MenuItem({ content: '删除记录' })
          .onClick(() => {
            this.deleteRecords([r.id], false);
          })
        if (this.canDeleteFile(r)) {
          MenuItem({ content: '删除记录并删除文件' })
            .onClick(() => {
              this.deleteRecords([r.id], true);
            })
        }
      }
    }
  }

  aboutToAppear(): void {
    this.refresh();
  }

  /** Reload records, then recompute the stats card off the fresh list. */
  private refresh(): void {
    const context = getContext(this) as common.UIAbilityContext;
    HistoryStore.getAll(context).then((list: TransferRecord[]) => {
      this.records = list;
      // Drop selections of rows that no longer exist.
      const kept: string[] = [];
      for (let i = 0; i < this.selectedIds.length; i++) {
        for (let j = 0; j < list.length; j++) {
          if (list[j].id === this.selectedIds[i]) {
            kept.push(this.selectedIds[i]);
            break;
          }
        }
      }
      this.selectedIds = kept;
      if (this.selectMode && list.length === 0) {
        this.selectMode = false;
      }
      this.refreshStats(context, list);
    });
  }

  private refreshStats(context: common.UIAbilityContext, list: TransferRecord[]): void {
    if (list.length === 0) {
      this.statsReady = false;
      this.usedBytes = 0;
      this.lostCount = 0;
      this.orphanCount = 0;
      return;
    }
    HistoryStore.stats(context, list).then((s: HistoryStats) => {
      this.usedBytes = s.usedBytes;
      this.lostCount = s.lostCount;
      this.orphanCount = s.orphanCount;
      this.statsReady = true;
    });
  }

  private statsLine(): string {
    if (!this.statsReady) {
      return '正在统计…';
    }
    let text = `已接收文件占用 ${formatSize(this.usedBytes)}`;
    if (this.lostCount > 0) {
      text += ` · ${this.lostCount} 条记录的文件已丢失`;
    }
    if (this.orphanCount > 0) {
      text += ` · ${this.orphanCount} 个文件无记录`;
    }
    return text;
  }

  private hasStale(): boolean {
    return this.statsReady && (this.lostCount > 0 || this.orphanCount > 0);
  }

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  /** Fill colour of the selection dot: brand when picked, transparent when not. */
  private checkFill(id: string): ResourceColor {
    return this.isSelected(id) ? $r('sys.color.brand') : Color.Transparent;
  }

  private toggleSelect(id: string): void {
    const next: string[] = [];
    let removed = false;
    for (let i = 0; i < this.selectedIds.length; i++) {
      if (this.selectedIds[i] === id) {
        removed = true;
      } else {
        next.push(this.selectedIds[i]);
      }
    }
    if (!removed) {
      next.push(id);
    }
    this.selectedIds = next;
  }

  private exitSelect(): void {
    this.selectMode = false;
    this.selectedIds = [];
  }

  /** Only files this app received can be removed from disk. */
  private canDeleteFile(r: TransferRecord): boolean {
    const context = getContext(this) as common.UIAbilityContext;
    return HistoryStore.isAppOwned(context, r.path);
  }

  /** Sandbox files may be copied out to the user's file manager. */
  private canExport(r: TransferRecord): boolean {
    if (!this.canDeleteFile(r)) {
      return false;
    }
    try {
      // A record can outlive its file; exporting then only fails late.
      return fs.accessSync(r.path);
    } catch (e) {
      return false;
    }
  }

  private fmtTime(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const d = new Date(ms);
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  private openRecord(r: TransferRecord): void {
    try {
      // Send records keep the picker URI verbatim; only sandbox files need
      // converting from a path into a file:// URI.
      const uri = r.path.startsWith('file://') ? r.path : fileUri.getUriFromPath(r.path);
      if (!r.path.startsWith('file://') && !fs.accessSync(r.path)) {
        promptAction.showToast({ message: '文件已不存在' });
        return;
      }
      const context = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: uri,
        type: mimeOf(r.fileName),
        // Temporarily grant the target app read access to our sandbox file.
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      };
      context.startAbility(want).catch((e: BusinessError) => {
        // Surface the real error code: 16000019 = no ability matched.
        promptAction.showToast({ message: `打开失败（${e.code}）` });
        console.error(`HistoryPage openRecord failed: ${JSON.stringify(e)}`);
      });
    } catch (e) {
      promptAction.showToast({ message: '无法打开该文件' });
    }
  }

  /** Copy a sandbox file out to a location the user picks. */
  private async exportRecord(r: TransferRecord): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [r.fileName];
      const savePicker = new picker.DocumentViewPicker(context);
      const targets = await savePicker.save(opts);
      if (!targets || targets.length === 0) {
        // User cancelled the picker; nothing to report.
        return;
      }
      // The picker returns a document URI (file://docs/...), which copyFileSync
      // rejects because it only accepts sandbox paths or FDs. Copy through FDs,
      // and fall back to the path form in case the picker returned a real path.
      try {
        const src = fs.openSync(r.path, fs.OpenMode.READ_ONLY);
        const dst = fs.openSync(targets[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        try {
          const buf = new ArrayBuffer(COPY_CHUNK);
          let read = fs.readSync(src.fd, buf);
          while (read > 0) {
            fs.writeSync(dst.fd, buf, { length: read });
            read = fs.readSync(src.fd, buf);
          }
        } finally {
          fs.closeSync(src);
          fs.closeSync(dst);
        }
      } catch (fdErr) {
        const e1 = fdErr as BusinessError;
        console.warn(`HistoryPage export fd copy failed: code=${e1.code}`);
        fs.copyFileSync(r.path, targets[0]);
      }
      promptAction.showToast({ message: '已保存到文件管理' });
    } catch (e) {
      const err = e as BusinessError;
      console.error(`HistoryPage exportRecord failed: code=${err.code} msg=${err.message}`);
      promptAction.showToast({ message: `保存失败（${err.code ?? 0}）` });
    }
  }

  /** Delete records; [deleteFiles] also removes the ones this app owns. */
  private deleteRecords(ids: string[], deleteFiles: boolean): void {
    const context = getContext(this) as common.UIAbilityContext;
    HistoryStore.removeMany(context, ids, deleteFiles).then(() => {
      this.refresh();
      promptAction.showToast({ message: deleteFiles ? '记录与文件已删除' : '记录已删除' });
    });
  }

  private confirmDeleteSelected(): void {
    const count = this.selectedIds.length;
    if (count === 0) {
      promptAction.showToast({ message: '请先选择要删除的记录' });
      return;
    }
    let ownFiles = 0;
    for (let i = 0; i < this.records.length; i++) {
      if (this.isSelected(this.records[i].id) && this.canDeleteFile(this.records[i])) {
        ownFiles++;
      }
    }
    const ids: string[] = this.selectedIds.slice();
    AlertDialog.show({
      title: `删除所选 ${count} 条记录`,
      message: ownFiles > 0
        ? `其中 ${ownFiles} 条对应本机收到的文件，是否一并删除这些文件？`
        : '所选记录没有本机文件，仅删除记录。',
      primaryButton: {
        value: ownFiles > 0 ? '仅删记录' : '取消',
        action: () => {
          if (ownFiles > 0) {
            this.deleteRecords(ids, false);
            this.exitSelect();
          }
        }
      },
      secondaryButton: {
        value: ownFiles > 0 ? '连文件一起删除' : '删除记录',
        action: () => {
          this.deleteRecords(ids, ownFiles > 0);
          this.exitSelect();
        }
      }
    });
  }

  private confirmClear(): void {
    let ownFiles = 0;
    for (let i = 0; i < this.records.length; i++) {
      if (this.canDeleteFile(this.records[i])) {
        ownFiles++;
      }
    }
    const count = this.records.length;
    AlertDialog.show({
      title: '清空历史',
      message: ownFiles > 0
        ? `共 ${count} 条记录，其中 ${ownFiles} 条对应本机收到的文件。是否一并删除这些文件？`
        : `共 ${count} 条记录，没有本机文件，仅清空记录。`,
      primaryButton: {
        value: ownFiles > 0 ? '仅清记录' : '取消',
        action: () => {
          if (ownFiles > 0) {
            this.doClear(false);
          }
        }
      },
      secondaryButton: {
        value: ownFiles > 0 ? '连文件一起清空' : '清空记录',
        action: () => {
          this.doClear(ownFiles > 0);
        }
      }
    });
  }

  private doClear(deleteFiles: boolean): void {
    const context = getContext(this) as common.UIAbilityContext;
    HistoryStore.clear(context, deleteFiles).then(() => {
      this.exitSelect();
      this.refresh();
      promptAction.showToast({ message: deleteFiles ? '记录与文件已清空' : '记录已清空' });
    });
  }

  private runCleanup(): void {
    const context = getContext(this) as common.UIAbilityContext;
    HistoryStore.cleanup(context).then((res: CleanupResult) => {
      this.refresh();
      promptAction.showToast({
        message: `已清理 ${res.removedRecords} 条失效记录、${res.removedFiles} 个无记录文件`
      });
    });
  }
}
