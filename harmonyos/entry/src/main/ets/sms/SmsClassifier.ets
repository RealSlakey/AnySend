// 短信会话分类：验证码 / 已知联系人 / 未知联系人。
// 判定基于最新一条消息预览（snippet）+ 通讯录匹配结果，对齐原生短信
// App 的收件箱整理方式。验证码优先级最高，其次是通讯录命中。

import { Conversation } from './SmsModels';

export enum SmsCategory {
  ALL = 0,
  CODE = 1,
  KNOWN = 2,
  UNKNOWN = 3
}

// 触发码提取的关键词：覆盖中文常见写法与英文常见写法。
const OTP_KEYWORDS = /验证码|校验码|动态码|确认码|授权码|口令|验证碼|verification\s*code|security\s*code|activation\s*code|pass\s?code|pass\s?word|one[-\s]?time|otp\b/i;

/**
 * 从验证码短信正文中提取验证码；非验证码短信返回空串。
 * 优先匹配带分隔符的 6 位码（123 456 / 123-456），其次 4-8 位连续数字。
 */
export function extractOtp(body: string): string {
  if (!body || body.length === 0) {
    return '';
  }
  if (!OTP_KEYWORDS.test(body)) {
    return '';
  }
  const patterns: RegExp[] = [
    /([0-9]{3}[\s-]?[0-9]{3})(?![0-9])/,
    /([0-9]{4,8})(?![0-9])/
  ];
  for (let i = 0; i < patterns.length; i++) {
    const m = patterns[i].exec(body);
    if (m && m[1]) {
      return m[1].trim();
    }
  }
  return '';
}

/** 会话归属分类：验证码 > 已知联系人（通讯录命中）> 未知联系人。 */
export function classifyConversation(conv: Conversation): SmsCategory {
  if (extractOtp(conv.snippet ?? '') !== '') {
    return SmsCategory.CODE;
  }
  const name = (conv.contactName ?? '').trim();
  if (name.length > 0) {
    return SmsCategory.KNOWN;
  }
  return SmsCategory.UNKNOWN;
}
