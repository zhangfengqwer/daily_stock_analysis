export type AppTarget = 'web' | 'mobile';

export const APP_TARGET: AppTarget =
  typeof __APP_TARGET__ === 'undefined' ? 'web' : __APP_TARGET__;

export const IS_MOBILE_APP = APP_TARGET === 'mobile';
