import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { systemShare } from '@kit.ShareKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TextShare } from '../common/TextShare';
import { DeviceIdentity } from '../common/DeviceIdentity';

/**
 * Share ability: receives ACTION_SEND wants with file URIs and/or plain text
 * and launches the Share page for peer selection and sending. Text records
 * are written to the cache dir as ordinary .txt files first, so the rest of
 * the pipeline only ever deals with files.
 *
 * Share Kit resolves the shared records asynchronously, so the page reads
 * 'sharedUris' through @StorageLink instead of snapshotting it on creation.
 */
export default class ShareAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Share can be the first entry point (cold start from another app), so the
    // device identity has to be ready here too — HTTPS sends need it.
    DeviceIdentity.init(this.context).then(() => this.readShared(want));
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Reused instance: refresh the payload so the open page picks up the new files.
    DeviceIdentity.init(this.context).then(() => this.readShared(want));
  }

  onDestroy(): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Share', (err) => {
      if (err.code) {
        console.error('Failed to load Share page: ' + JSON.stringify(err));
      }
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
  }

  onBackground(): void {
  }

  private readShared(want: Want): void {
    systemShare.getSharedData(want)
      .then((data: systemShare.SharedData) => this.publishSharedData(data))
      .catch((error: BusinessError) => {
        console.error(`Failed to getSharedData. Code: ${error.code}, message: ${error.message}`);
        AppStorage.setOrCreate('sharedUris', []);
      });
  }

  /** Turn every file record into a URI and every text record into a cached .txt. */
  private async publishSharedData(data: systemShare.SharedData): Promise<void> {
    const uris: string[] = [];
    const texts: string[] = [];
    const records: systemShare.SharedRecord[] = data.getRecords();
    for (let i = 0; i < records.length; i++) {
      const uri: string | undefined = records[i].uri;
      const content: string | undefined = records[i].content;
      console.info(`ANYSEND share record utd=${records[i].utd} title=${records[i].title} uri=${uri}`);
      if (uri !== undefined && uri.length > 0) {
        uris.push(uri);
      } else if (content !== undefined && content.length > 0) {
        texts.push(content);
      }
    }
    for (let i = 0; i < texts.length; i++) {
      try {
        const path = await TextShare.writeToCache(this.context, texts[i]);
        uris.push(path);
      } catch (e) {
        console.error(`ANYSEND failed to cache shared text: ${JSON.stringify(e)}`);
      }
    }
    console.info(`ANYSEND shared uris(${uris.length}): ${JSON.stringify(uris)}`);
    AppStorage.setOrCreate('sharedUris', uris);
  }
}
