// Central SMS state for HarmonyOS: pairing config (Preferences), in-memory
// message cache, periodic sync with the Android host, push handling, send
// flow and local notifications.
//
// The Android host is the source of truth; this store is a live view that
// survives across pages. Pages subscribe via onListChange/onThreadChange and
// copy data into their own @State.

import dataPreferences from '@ohos.data.preferences';
import notificationManager from '@ohos.notificationManager';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import { common } from '@kit.AbilityKit';
import { DirectNetworkLayer } from '../protocol/DirectNetworkLayer';
import { NetworkLayer } from '../protocol/NetworkLayer';
import { TailscaleNetworkLayer } from '../protocol/TailscaleNetworkLayer';
import { SmsClient } from './SmsClient';
import {
  Conversation,
  MessagesResponse,
  PushEnvelope,
  SendSmsResponse,
  SendStatus,
  SimCard,
  SmsMessage,
  SyncResponse
} from './SmsModels';

export const HOST_DEVICE_LABEL: string = 'HarmonyOS';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

function msgKey(m: SmsMessage): string {
  return `${m.type}|${m.date}|${m.body}`;
}

function sortKey(m: SmsMessage): number {
  // Placeholders (negative id) sort after the real message at the same date.
  return m.date * 10 + (m.id > 0 ? 0 : 1);
}

/** Strip spaces/dashes so "+86 138-0013-8000" matches "13800138000". */
function normAddr(a: string): string {
  return a.replace(/[\s-]/g, '');
}

export class SmsStore {
  private static inst: SmsStore | null = null;

  static getInstance(): SmsStore {
    if (SmsStore.inst === null) {
      SmsStore.inst = new SmsStore();
    }
    return SmsStore.inst;
  }

  // ---- pairing config (persisted)
  hostAddress: string = ''; // Android host, host:port
  hostName: string = '';
  token: string = '';
  lastSyncId: number = 0;

  // ---- live state
  conversations: Conversation[] = [];
  sims: SimCard[] = [];
  online: boolean = false; // last sync succeeded
  serverRunning: boolean = false; // our receive server is up
  callbackAddr: string = ''; // our reachable ip:53317 for Android push
  appForeground: boolean = false;
  currentChatThreadId: number = -1;

  private threads: Map<number, SmsMessage[]> = new Map();
  private polling: boolean = false;
  private syncing: boolean = false;
  private listListeners: Array<() => void> = [];
  private threadListeners: Map<number, Array<() => void>> = new Map();
  private prefs: dataPreferences.Preferences | null = null;
  private netDirect: DirectNetworkLayer | null = null;
  private netTs: TailscaleNetworkLayer | null = null;

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.prefs !== null) {
      return;
    }
    this.prefs = await dataPreferences.getPreferences(context, { name: 'sms_relay' });
    this.hostAddress = (await this.prefs.get('hostAddress', '') as string);
    this.hostName = (await this.prefs.get('hostName', '') as string);
    this.token = (await this.prefs.get('token', '') as string);
    this.lastSyncId = (await this.prefs.get('lastSyncId', 0) as number);
  }

  private async savePrefs(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    await this.prefs.put('hostAddress', this.hostAddress);
    await this.prefs.put('hostName', this.hostName);
    await this.prefs.put('token', this.token);
    await this.prefs.put('lastSyncId', this.lastSyncId);
    await this.prefs.flush();
  }

  hasHost(): boolean {
    return this.hostAddress.length > 0 && this.token.length > 0;
  }

  setHost(address: string, name: string, token: string): void {
    this.hostAddress = address.trim();
    this.hostName = name;
    this.token = token.trim();
    this.savePrefs();
  }

  setCallbackAddr(addr: string): void {
    this.callbackAddr = addr;
  }

  // ------------------------------------------------------------ listeners

  onListChange(cb: () => void): void {
    this.listListeners.push(cb);
  }

  offListChange(cb: () => void): void {
    const i = this.listListeners.indexOf(cb);
    if (i >= 0) {
      this.listListeners.splice(i, 1);
    }
  }

  onThreadChange(threadId: number, cb: () => void): void {
    let arr = this.threadListeners.get(threadId);
    if (!arr) {
      arr = [];
      this.threadListeners.set(threadId, arr);
    }
    arr.push(cb);
  }

  offThreadChange(threadId: number, cb: () => void): void {
    const arr = this.threadListeners.get(threadId);
    if (!arr) {
      return;
    }
    const i = arr.indexOf(cb);
    if (i >= 0) {
      arr.splice(i, 1);
    }
    if (arr.length === 0) {
      this.threadListeners.delete(threadId);
    }
  }

  private notifyListChange(): void {
    for (const cb of this.listListeners.slice()) {
      cb();
    }
  }

  private notifyThread(threadId: number): void {
    const arr = this.threadListeners.get(threadId);
    if (arr) {
      for (const cb of arr.slice()) {
        cb();
      }
    }
  }

  // -------------------------------------------------------------- network

  /** Tailscale addresses live in 100.64.0.0/10 (RFC 6598). */
  private layerFor(host: string): NetworkLayer {
    const ip = host.split(':')[0];
    const p = ip.split('.');
    if (p.length === 4 && parseInt(p[0], 10) === 100 && parseInt(p[1], 10) >= 64 && parseInt(p[1], 10) <= 127) {
      if (this.netTs === null) {
        this.netTs = new TailscaleNetworkLayer();
      }
      return this.netTs;
    }
    if (this.netDirect === null) {
      this.netDirect = new DirectNetworkLayer();
    }
    return this.netDirect;
  }

  client(): SmsClient | null {
    if (!this.hasHost()) {
      return null;
    }
    return new SmsClient(this.hostAddress, this.token, this.layerFor(this.hostAddress));
  }

  // -------------------------------------------------------------- threads

  getThread(threadId: number): SmsMessage[] {
    return this.threads.get(threadId) ?? [];
  }

  /** Fetch a thread's latest page when it is not cached yet. */
  async loadThread(threadId: number): Promise<void> {
    if (this.threads.get(threadId) !== undefined && this.threads.get(threadId)!.length > 0) {
      return;
    }
    const c = this.client();
    if (c === null) {
      return;
    }
    try {
      const text = await c.getMessages(threadId, 0, 30);
      if (text === '') {
        return;
      }
      const resp = JSON.parse(text) as MessagesResponse;
      const existing = this.threads.get(threadId) ?? [];
      const merged: SmsMessage[] = [];
      for (const m of resp.messages.concat(existing)) {
        let dup = false;
        for (const ex of merged) {
          if (msgKey(ex) === msgKey(m)) {
            dup = true;
            break;
          }
        }
        if (!dup) {
          merged.push(m);
        }
      }
      merged.sort((a, b) => sortKey(a) - sortKey(b));
      this.threads.set(threadId, merged);
      this.notifyThread(threadId);
    } catch (e) {
      // network error: leave empty; the page shows a load failure hint
    }
  }

  /** Load one older page backwards. Returns false when no more history. */
  async loadMore(threadId: number): Promise<boolean> {
    const c = this.client();
    if (c === null) {
      return false;
    }
    const list = this.threads.get(threadId) ?? [];
    let oldest = 0;
    for (const m of list) {
      if (m.id > 0 && (oldest === 0 || m.id < oldest)) {
        oldest = m.id;
      }
    }
    if (oldest === 0) {
      return false;
    }
    try {
      const text = await c.getMessages(threadId, oldest, 30);
      if (text === '') {
        return false;
      }
      const resp = JSON.parse(text) as MessagesResponse;
      let added = false;
      for (const m of resp.messages) {
        if (this.insertMessage(m)) {
          added = true;
        }
      }
      this.notifyThread(threadId);
      return added;
    } catch (e) {
      return false;
    }
  }

  /** Insert with dedup + placeholder replacement; keeps list sorted. */
  private insertMessage(m: SmsMessage): boolean {
    if (m.threadId <= 0) {
      return false;
    }
    let list = this.threads.get(m.threadId);
    if (!list) {
      list = [];
      this.threads.set(m.threadId, list);
    }
    for (const ex of list) {
      if (msgKey(ex) === msgKey(m)) {
        return false;
      }
    }
    // A real row replaces its optimistic placeholder (send flow).
    if (m.id > 0) {
      for (let i = 0; i < list.length; i++) {
        const ex = list[i];
        if (ex.id < 0 && ex.type === m.type && ex.body === m.body) {
          list.splice(i, 1);
          break;
        }
      }
    }
    list.push(m);
    list.sort((a, b) => sortKey(a) - sortKey(b));
    return true;
  }

  // ------------------------------------------------------------ sync loop

  startPolling(): void {
    if (this.polling) {
      return;
    }
    this.polling = true;
    this.pollLoop();
  }

  stopPolling(): void {
    this.polling = false;
  }

  private async pollLoop(): Promise<void> {
    while (this.polling) {
      await this.syncOnce();
      // Background: poll far less often (push still delivers new messages).
      const delay = this.online
        ? (this.appForeground ? 5000 : 20000)
        : (this.appForeground ? 8000 : 15000);
      await sleep(delay);
    }
  }

  /** One /sync roundtrip: new messages + refreshed conversations + SIMs. */
  async syncOnce(): Promise<boolean> {
    if (this.syncing || !this.hasHost()) {
      return this.online;
    }
    const c = this.client();
    if (c === null) {
      this.online = false;
      return false;
    }
    this.syncing = true;
    try {
      const text = await c.sync(this.lastSyncId, this.callbackAddr, HOST_DEVICE_LABEL);
      if (text === '') {
        this.online = false;
        this.notifyListChange();
        return false;
      }
      const resp = JSON.parse(text) as SyncResponse;
      for (const m of resp.messages) {
        this.insertMessage(m);
      }
      if (resp.maxId > this.lastSyncId) {
        this.lastSyncId = resp.maxId;
        await this.savePrefs();
      }
      // Android omits contactName in the JSON when no contact matches;
      // normalize undefined -> null before anything renders it.
      for (const conv of resp.conversations) {
        if (conv.contactName === undefined || conv.contactName === null) {
          conv.contactName = null;
        }
      }
      this.conversations = resp.conversations;
      this.sims = resp.sims;
      this.online = true;
      this.notifyListChange();
      for (const m of resp.messages) {
        this.notifyThread(m.threadId);
      }
      return true;
    } catch (e) {
      this.online = false;
      this.notifyListChange();
      return false;
    } finally {
      this.syncing = false;
    }
  }

  // ----------------------------------------------------------------- push

  /** Entry point for POST /api/sms/v1/push from the Android host. */
  onPushEnvelope(env: PushEnvelope): void {
    if (env.kind !== 'new-message') {
      return;
    }
    const m = env.message;
    const resolved = m.threadId > 0 ? m.threadId : this.findThreadIdByAddress(m.address);
    const msg: SmsMessage = {
      id: m.id,
      threadId: resolved,
      address: m.address,
      contactName: m.contactName ?? '',
      body: m.body,
      date: m.date,
      dateSent: m.dateSent,
      type: m.type,
      subId: m.subId,
      read: m.read
    };
    if (resolved > 0) {
      this.insertMessage(msg);
      this.notifyThread(resolved);
      // Don't bump the unread badge for the thread the user is reading;
      // the chat page calls markThreadRead instead (also syncs Android).
      if (!(this.appForeground && this.currentChatThreadId === resolved)) {
        for (const conv of this.conversations) {
          if (conv.threadId === resolved) {
            conv.unread += 1;
          }
        }
      }
    }
    this.notifyListChange();
    if (!this.appForeground || this.currentChatThreadId !== resolved) {
      this.publishNotification(msg);
    }
    // Pull the authoritative row (real ids, contact name) shortly after.
    setTimeout(() => {
      this.syncOnce();
    }, 1500);
  }

  private findThreadIdByAddress(address: string): number {
    const want = normAddr(address);
    for (const conv of this.conversations) {
      if (normAddr(conv.address) === want) {
        return conv.threadId;
      }
    }
    return -1;
  }

  private async publishNotification(m: SmsMessage): Promise<void> {
    const name: string = m.contactName ?? '';
    const title: string = name.length > 0 ? name : (m.address.length > 0 ? m.address : '新短信');
    // Tapping the notification opens the app on the SMS tab.
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        deviceId: '',
        bundleName: 'com.slakey.anysend',
        abilityName: 'EntryAbility',
        parameters: { smsTab: 0 }
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    let agent: WantAgent | undefined = undefined;
    try {
      agent = await wantAgent.getWantAgent(info);
    } catch (e) {
      agent = undefined;
    }
    // One notification slot per thread: newer messages replace older ones.
    const req: notificationManager.NotificationRequest = {
      id: m.threadId > 0 ? m.threadId : (Math.abs(m.id) % 1000000),
      wantAgent: agent,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: m.body,
          additionalText: '安卓短信'
        }
      }
    };
    notificationManager.publish(req).catch(() => {
    });
  }

  // ----------------------------------------------------------------- send

  /**
   * Send an SMS via the Android host with optimistic UI:
   * placeholder (sending) -> real row (sent) / failed placeholder.
   */
  async sendMessage(address: string, body: string, subId: number, threadId: number): Promise<SmsMessage | null> {
    const now = Date.now();
    const pending: SmsMessage = {
      id: -now,
      threadId: threadId,
      address: address,
      contactName: null,
      body: body,
      date: now,
      dateSent: now,
      type: 2, // MESSAGE_TYPE_SENT
      subId: subId,
      read: true,
      clientStatus: 'sending'
    };
    if (threadId > 0) {
      this.insertMessage(pending);
      this.notifyThread(threadId);
    }
    const c = this.client();
    if (c === null) {
      return this.finalizeFailure(pending, threadId, '发送失败：未配置安卓设备');
    }
    let resp: SendSmsResponse | null = null;
    try {
      const text = await c.send(address, body, subId);
      if (text !== '') {
        resp = JSON.parse(text) as SendSmsResponse;
      }
    } catch (e) {
      resp = null;
    }

    // Remove the pending placeholder from the thread view.
    this.dropPending(pending);

    if (resp !== null && resp.ok && resp.message) {
      const sent = resp.message;
      sent.clientStatus = 'sent';
      if (sent.threadId > 0) {
        this.insertMessage(sent);
        this.notifyThread(sent.threadId);
      }
      setTimeout(() => {
        this.syncOnce();
      }, 800);
      return sent;
    }

    // Failure: keep a visible failed bubble (with the failure reason).
    const failThread = threadId > 0 ? threadId : (resp?.message?.threadId ?? -1);
    const error = resp !== null ? (resp.error ?? '发送失败') : '发送失败：无法连接安卓设备';
    return this.finalizeFailure(pending, failThread, error);
  }

  /** Remove a pending placeholder from its thread view. */
  private dropPending(pending: SmsMessage): void {
    const list = this.threads.get(pending.threadId);
    if (list) {
      const i = list.indexOf(pending);
      if (i >= 0) {
        list.splice(i, 1);
      }
    }
  }

  /** Swap a pending placeholder for a visible failed bubble; returns it. */
  private finalizeFailure(pending: SmsMessage, threadId: number, error: string): SmsMessage {
    this.dropPending(pending);
    const failed: SmsMessage = {
      id: pending.id,
      threadId: threadId,
      address: pending.address,
      contactName: null,
      body: pending.body,
      date: pending.date,
      dateSent: pending.dateSent,
      type: 2,
      subId: pending.subId,
      read: true,
      clientStatus: 'failed',
      clientError: error
    };
    if (failed.threadId > 0) {
      this.insertMessage(failed);
      this.notifyThread(failed.threadId);
    }
    return failed;
  }

  /** Remove a client-side placeholder row (used by the chat-page retry). */
  removePlaceholder(threadId: number, id: number): void {
    const list = this.threads.get(threadId);
    if (!list) {
      return;
    }
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        list.splice(i, 1);
        break;
      }
    }
    this.notifyThread(threadId);
  }

  // -------------------------------------------------------------- actions

  /** Called when a chat page opens: clear unread locally and on Android. */
  async markThreadRead(threadId: number): Promise<void> {
    for (const conv of this.conversations) {
      if (conv.threadId === threadId && conv.unread > 0) {
        conv.unread = 0;
        this.notifyListChange();
        const c = this.client();
        if (c !== null) {
          c.markRead(threadId).catch(() => {
          });
        }
        return;
      }
    }
  }

  /** Delete one message locally and on the Android host. */
  async deleteMessage(threadId: number, id: number): Promise<void> {
    const list = this.threads.get(threadId);
    if (list) {
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === id) {
          list.splice(i, 1);
          break;
        }
      }
      this.notifyThread(threadId);
    }
    if (id <= 0) {
      return;
    }
    const c = this.client();
    if (c !== null) {
      c.deleteMessage(id).catch(() => {
      });
    }
    setTimeout(() => {
      this.syncOnce();
    }, 600);
  }

  /** Request notification permission (once, from Settings). */
  async requestNotification(context: common.UIAbilityContext): Promise<void> {
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (e) {
      // user declined or already requested
    }
  }
}
