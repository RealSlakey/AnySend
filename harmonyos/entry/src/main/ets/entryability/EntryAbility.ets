import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import { connection } from '@kit.NetworkKit';
import { SmsStore } from '../sms/SmsStore';
import { AutoConnect } from '../common/AutoConnect';
import { DeviceProfile } from '../common/DeviceProfile';
import { DeviceIdentity } from '../common/DeviceIdentity';
import { LanDiscovery } from '../common/LanDiscovery';
import { KeepAlive } from '../common/KeepAlive';

export default class EntryAbility extends UIAbility {
  private netWatchBound: boolean = false;
  private netConn: connection.NetConnection | null = null;
  private restartTimer: number = -1;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Load pairing config so the SMS tab works right after launch.
    SmsStore.getInstance().init(this.context);
    this.watchNetworkChanges();
    this.applyLaunchTarget(want);
    // Load the custom device name first, then auto-reconnect Tailscale + start
    // the receive server when a key was saved from a previous login.
    // Fire-and-forget: everything heavy runs on the worker thread, the UI
    // thread never blocks (watchdog safe).
    // The device certificate has to exist before the fingerprint is read, and
    // it is what HTTPS peers see during the TLS handshake.
    DeviceIdentity.init(this.context)
      .then(() => DeviceProfile.init(this.context))
      .then(() => {
        // Answer LocalSend multicast discovery so peers can find us.
        LanDiscovery.start();
        AutoConnect.run(this.context);
      });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyLaunchTarget(want);
  }

  /**
   * Re-join the discovery group when the network changes. The multicast socket
   * is bound to whatever interface it joined on, so switching Wi-Fi (different
   * subnet or SSID) would silently kill LAN discovery until the app restarted.
   */
  private watchNetworkChanges(): void {
    if (this.netWatchBound) {
      return;
    }
    this.netWatchBound = true;
    try {
      // NetConnection requires register() before its events fire.
      const conn = connection.createNetConnection();
      conn.register((err) => {
        if (err && err.code) {
          console.error(`EntryAbility: net register failed: ${err.code}`);
        }
      });
      conn.on('netAvailable', (handle: connection.NetHandle) => {
        this.scheduleDiscoveryRestart();
      });
      conn.on('netLost', (handle: connection.NetHandle) => {
        this.scheduleDiscoveryRestart();
      });
      this.netConn = conn;
    } catch (e) {
      console.error(`EntryAbility: network watch failed: ${JSON.stringify(e)}`);
    }
  }

  /** Debounced: one switch emits several net events in a row. */
  private scheduleDiscoveryRestart(): void {
    if (this.restartTimer >= 0) {
      clearTimeout(this.restartTimer);
    }
    this.restartTimer = setTimeout(() => {
      this.restartTimer = -1;
      LanDiscovery.stop();
      LanDiscovery.start();
    }, 800);
  }

  private unwatchNetworkChanges(): void {
    if (!this.netWatchBound) {
      return;
    }
    this.netWatchBound = false;
    if (this.restartTimer >= 0) {
      clearTimeout(this.restartTimer);
      this.restartTimer = -1;
    }
    const conn = this.netConn;
    this.netConn = null;
    if (conn !== null) {
      conn.unregister((err) => {
        if (err && err.code) {
          console.error(`EntryAbility: net unregister failed: ${err.code}`);
        }
      });
    }
  }

  /** Honor launch parameters (e.g. from the SMS notification wantAgent). */
  private applyLaunchTarget(want: Want): void {
    const params = want.parameters;
    if (params !== undefined && params !== null && params['smsTab'] !== undefined) {
      AppStorage.setOrCreate('smsTab', 0);
    }
  }

  onDestroy(): void {
    this.unwatchNetworkChanges();
    KeepAlive.stop(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error('Failed to load content: ' + JSON.stringify(err));
        return;
      }
      // First frame up: request location grant + start the continuous task
      // so the process survives backgrounding / screen-off (dialog shows
      // only on first launch).
      KeepAlive.start(this.context);
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
    const store = SmsStore.getInstance();
    store.appForeground = true;
    // Push may have been missed while backgrounded; reconcile now.
    if (store.hasHost()) {
      store.startPolling();
    }
  }

  onBackground(): void {
    SmsStore.getInstance().appForeground = false;
  }
}
