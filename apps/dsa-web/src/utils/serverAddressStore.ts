import { normalizeApiBaseUrl } from './runtimeConfig';

const STORAGE_KEY = 'dsa.serverAddress';

type PreferencesPlugin = {
  get(options: { key: string }): Promise<{ value: string | null }>;
  set(options: { key: string; value: string }): Promise<void>;
};

type CapacitorGlobal = {
  Capacitor?: { Plugins?: Record<string, unknown> };
};

/**
 * 取 Capacitor 在原生 WebView 中注入的 Preferences 插件。
 *
 * 这里刻意不 `import '@capacitor/preferences'`：dsa-web 不依赖 Capacitor，插件由壳工程
 * (apps/dsa-mobile) 的运行时注入。静态 import 会让 Vite 在转换阶段就因解析不到该包而失败，
 * try/catch 也挡不住——那是构建期错误而非运行时错误。
 *
 * Web 与测试环境下返回 null，调用方降级到 localStorage。
 */
function getPreferences(): PreferencesPlugin | null {
  const plugins = (globalThis as CapacitorGlobal).Capacitor?.Plugins;
  return (plugins?.Preferences as PreferencesPlugin | undefined) ?? null;
}

export async function loadServerAddress(): Promise<string> {
  const preferences = getPreferences();
  if (preferences) {
    const { value } = await preferences.get({ key: STORAGE_KEY });
    return value ?? '';
  }
  return localStorage.getItem(STORAGE_KEY) ?? '';
}

export async function saveServerAddress(url: string): Promise<void> {
  const normalized = normalizeApiBaseUrl(url);
  const preferences = getPreferences();
  if (preferences) {
    await preferences.set({ key: STORAGE_KEY, value: normalized });
    return;
  }
  localStorage.setItem(STORAGE_KEY, normalized);
}
