// User-defined device name. Shown to peers over the LocalSend protocol
// (file share alias) and in the app's own status displays.
//
// Note: the Tailscale node name is fixed at registration time in the tailnet
// control plane and is intentionally NOT affected by this setting — renaming
// a registered node would require wiping node state and re-login.

import { preferences } from '@kit.ArkData';
import { DeviceIdentity } from './DeviceIdentity';
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';

const PREFS_NAME = 'device_profile';
const KEY_NAME = 'name';
const KEY_FINGERPRINT = 'fingerprint';
const DEFAULT_NAME = 'HarmonyOS Device';

export class DeviceProfile {
  private static cachedName: string | null = null;
  private static cachedFingerprint: string | null = null;

  /** Load the saved name into the in-memory cache. Call once at app start. */
  static async init(context: common.UIAbilityContext): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
      DeviceProfile.cachedName = (await prefs.get(KEY_NAME, '')) as string;
      // Stable per-install LocalSend fingerprint, generated on first run.
      let fp = (await prefs.get(KEY_FINGERPRINT, '')) as string;
      if (fp.length === 0) {
        fp = util.generateRandomUUID();
        await prefs.put(KEY_FINGERPRINT, fp);
        await prefs.flush();
      }
      DeviceProfile.cachedFingerprint = fp;
    } catch (e) {
      DeviceProfile.cachedName = '';
      DeviceProfile.cachedFingerprint = '';
    }
  }

  /**
   * Stable per-install fingerprint advertised over LocalSend.
   *
   * Prefers the device certificate's SHA-256: HTTPS peers derive the sender's
   * identity from the certificate presented during the handshake, and only
   * accept a registration whose claimed fingerprint matches it.
   */
  static fingerprint(): string {
    const fromCert: string = DeviceIdentity.fingerprint();
    if (fromCert.length > 0) {
      return fromCert;
    }
    return DeviceProfile.cachedFingerprint ?? '';
  }

  /** The raw custom name, '' when the user has not set one. */
  static customName(): string {
    return DeviceProfile.cachedName ?? '';
  }

  /** Name other devices see: the custom name when set, otherwise the default. */
  static displayName(): string {
    const n = DeviceProfile.customName();
    return n.length > 0 ? n : DEFAULT_NAME;
  }

  static async saveName(context: common.UIAbilityContext, name: string): Promise<void> {
    const trimmed = name.trim();
    DeviceProfile.cachedName = trimmed;
    try {
      const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
      await prefs.put(KEY_NAME, trimmed);
      await prefs.flush();
    } catch (e) {
      console.error(`DeviceProfile: save name failed: ${JSON.stringify(e)}`);
    }
  }
}
