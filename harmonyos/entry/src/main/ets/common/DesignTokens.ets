// Design tokens: the single source of truth for spacing, radius, type scale
// and motion durations. Colors stay semantic ($r('sys.color.*') or the
// app.color.* tokens in resources/base|dark/element/color.json) so dark mode
// flips automatically. Never inline hex in pages.

export class Tokens {
  // Spacing: multiples of 4.
  static readonly SPACE_XS: number = 4;
  static readonly SPACE_SM: number = 8;
  static readonly SPACE_MD: number = 12;
  static readonly SPACE_LG: number = 16;
  static readonly SPACE_XL: number = 24;

  // Radius: controls 12, cards 16, pills 999.
  static readonly RADIUS_CTRL: number = 12;
  static readonly RADIUS_CARD: number = 16;
  static readonly RADIUS_PILL: number = 999;

  // Type scale: aligned to system 12/14/16/20/24.
  static readonly FONT_CAPTION: number = 12;
  static readonly FONT_BODY: number = 14;
  static readonly FONT_TITLE: number = 16;
  static readonly FONT_H2: number = 20;
  static readonly FONT_H1: number = 24;

  // Touch target: 40vp minimum, 48vp recommended.
  static readonly TARGET_MIN: number = 40;
  static readonly TARGET_STD: number = 48;

  // Motion: quick micro 140ms, normal 220ms, full-screen 300ms.
  static readonly MOTION_QUICK: number = 140;
  static readonly MOTION_NORMAL: number = 220;
  static readonly MOTION_PAGE: number = 300;

  // Layout: cap content width on wide windows, centered.
  static readonly CONTENT_MAX_WIDTH: number = 600;
}
