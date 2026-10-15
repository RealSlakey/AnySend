import Want from '@ohos.app.ability.Want';
import UIExtensionAbility from '@ohos.app.ability.UIExtensionAbility';
import window from '@ohos.window';

/**
 * Share extension: appears in the system share sheet. Receives file URIs
 * and forwards them to the main UI for peer selection + sending.
 */
export default class ShareExtensionAbility extends UIExtensionAbility {
  onCreate(): void {
  }

  onDestroy(): void {
  }

  onSessionCreate(want: Want, session: import('@ohos.app.ability.UIExtensionContentSession').default): void {
    // Store the shared file URIs in AppStorage so the share page can read them
    const uris: string[] = want?.parameters?.['ohos.extra.param.key.contentUris'] as string[] ?? [];
    AppStorage.SetOrCreate('sharedUris', uris);

    session.loadContent('pages/Share', () => {
    });
  }

  onSessionDestroy(session: import('@ohos.app.ability.UIExtensionContentSession').default): void {
  }
}
