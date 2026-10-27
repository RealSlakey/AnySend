// Persisted default share target, chosen via long-press on a device row in
// the devices tab. Prefills the direct-IP field of the share page.

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREFS_NAME = 'device_profile';
const KEY_IP = 'share_target_ip';
const KEY_NAME = 'share_target_name';

export class DefaultTargets {
  private static cachedIp: string | null = null;
  private static cachedName: string | null = null;

  /** Load once; later calls are no-ops. */
  static async load(context: common.UIAbilityContext): Promise<void> {
    if (DefaultTargets.cachedIp !== null) {
      return;
    }
    try {
      const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
      DefaultTargets.cachedIp = (await prefs.get(KEY_IP, '')) as string;
      DefaultTargets.cachedName = (await prefs.get(KEY_NAME, '')) as string;
    } catch (e) {
      DefaultTargets.cachedIp = '';
      DefaultTargets.cachedName = '';
    }
  }

  static shareIp(): string {
    return DefaultTargets.cachedIp ?? '';
  }

  static shareName(): string {
    return DefaultTargets.cachedName ?? '';
  }

  static async saveShare(context: common.UIAbilityContext, ip: string, name: string): Promise<void> {
    DefaultTargets.cachedIp = ip;
    DefaultTargets.cachedName = name;
    try {
      const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
      await prefs.put(KEY_IP, ip);
      await prefs.put(KEY_NAME, name);
      await prefs.flush();
    } catch (e) {
      console.error(`DefaultTargets: save failed: ${JSON.stringify(e)}`);
    }
  }
}
