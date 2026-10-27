// Small formatting helpers shared by the SMS pages.

import { SimCard, SmsMessage } from './SmsModels';

const AVATAR_COLORS: string[] = [
  '#0A59F1', '#E84026', '#00B34A', '#ED6F21',
  '#7B61FF', '#00B7C2', '#D83931', '#C058E4'
];

/** Deterministic avatar color for a phone number / name. */
export function avatarColor(seed: string): string {
  let h = 0;
  for (let i = 0; i < seed.length; i++) {
    h = (h * 31 + seed.charCodeAt(i)) & 0x7fffffff;
  }
  return AVATAR_COLORS[h % AVATAR_COLORS.length];
}

export function displayNameOf(address: string, contactName: string | null | undefined): string {
  if (contactName !== null && contactName !== undefined && contactName.length > 0) {
    return contactName;
  }
  return address.length > 0 ? address : '未知号码';
}

export function avatarText(name: string): string {
  return name.length > 0 ? name.substring(0, 1).toUpperCase() : '#';
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function startOfDay(ts: number): number {
  const d = new Date(ts);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** Conversation list timestamp: HH:mm today, 昨天, weekday, else date. */
export function formatListTime(ts: number): string {
  const d = new Date(ts);
  const now = new Date();
  const today = startOfDay(now.getTime());
  const day = startOfDay(ts);
  if (day === today) {
    return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  }
  if (day === today - 86400000) {
    return '昨天';
  }
  if (now.getTime() - ts < 6 * 86400000) {
    return `周${'日一二三四五六'.charAt(d.getDay())}`;
  }
  return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
}

/** Chat page day divider label. */
export function formatDayDivider(ts: number): string {
  const d = new Date(ts);
  const now = new Date();
  const today = startOfDay(now.getTime());
  const day = startOfDay(ts);
  if (day === today) {
    return '今天';
  }
  if (day === today - 86400000) {
    return '昨天';
  }
  const sameYear = d.getFullYear() === now.getFullYear();
  const base = `${d.getMonth() + 1}月${d.getDate()}日`;
  if (sameYear) {
    return `${base} 周${'日一二三四五六'.charAt(d.getDay())}`;
  }
  return `${d.getFullYear()}年${base}`;
}

/** Bubble timestamp: HH:mm. */
export function formatBubbleTime(ts: number): string {
  const d = new Date(ts);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** 'SIM1' / 'SIM2' / '' for a subscription id. */
export function simLabel(subId: number, sims: SimCard[]): string {
  for (const s of sims) {
    if (s.subscriptionId === subId) {
      return `SIM${s.slotIndex}`;
    }
  }
  return '';
}

export function simBySubId(subId: number, sims: SimCard[]): SimCard | null {
  for (const s of sims) {
    if (s.subscriptionId === subId) {
      return s;
    }
  }
  return null;
}

/** Default SIM for sending: the one the thread used, else the first. */
export function defaultSendSubId(sims: SimCard[], prefer: number): number {
  if (sims.length === 0) {
    return 0;
  }
  for (const s of sims) {
    if (s.subscriptionId === prefer) {
      return s.subscriptionId;
    }
  }
  return sims[0].subscriptionId;
}

export function isSentMessage(m: SmsMessage): boolean {
  return m.type === 2 || (m.clientStatus !== undefined);
}
