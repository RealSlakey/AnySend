// Keep-alive via a LOCATION-type continuous task: the system then keeps the
// process unfrozen in the background so file/SMS receiving stays alive with
// the screen off. Location permission is requested at runtime once; the
// device does not actually take GPS fixes.

import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.wantAgent';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import { common } from '@kit.AbilityKit';

export class KeepAlive {
  private static started: boolean = false;

  /** Request location grant, then start the continuous task. Idempotent. */
  static async start(context: common.UIAbilityContext): Promise<void> {
    if (KeepAlive.started) {
      return;
    }
    try {
      // 1. Runtime grant (first launch shows the system dialog; already
      //    granted requests resolve silently).
      const atManager = abilityAccessCtrl.createAtManager();
      const perms: Array<Permissions> = [
        'ohos.permission.APPROXIMATELY_LOCATION',
        'ohos.permission.LOCATION'
      ];
      await atManager.requestPermissionsFromUser(context, perms);
      // 2. Notification tap returns to the app. Inline literal: the compiler
      //    infers WantAgentInfo / Want from the API signature (the type is
      //    not exported by @ohos.wantAgent in this SDK).
      const wa = await wantAgent.getWantAgent({
        wants: [
          {
            bundleName: context.abilityInfo.bundleName,
            abilityName: 'EntryAbility'
          }
        ],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      });
      // 3. LOCATION continuous task keeps the process alive in background.
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.LOCATION,
        wa
      );
      KeepAlive.started = true;
      console.info('KeepAlive: continuous task started');
    } catch (e) {
      // Without the grant or the task the app still works, just may be
      // frozen by the system when screen is off.
      console.error(`KeepAlive.start failed: ${JSON.stringify(e)}`);
    }
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      KeepAlive.started = false;
    } catch (e) {
      // ignore
    }
  }
}
