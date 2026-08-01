/// <reference types="vite/client" />

/** 构建期常量，由 vite.config.ts 的 define 注入（web 构建为 'web'，`--mode mobile` 为 'mobile'）。 */
declare const __APP_TARGET__: 'web' | 'mobile';
