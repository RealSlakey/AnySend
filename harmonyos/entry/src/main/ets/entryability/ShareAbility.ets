import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';

/**
 * Share ability: receives ACTION_SEND wants with file URIs and launches
 * the Share page for peer selection and sending.
 */
export default class ShareAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const uris: string[] = want?.parameters?.['ohos.extra.param.key.contentUris'] as string[] ?? [];
    AppStorage.SetOrCreate('sharedUris', uris);
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
}
