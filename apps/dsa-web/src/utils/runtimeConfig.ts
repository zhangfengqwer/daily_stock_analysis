import { API_BASE_URL } from './constants';

type Listener = (url: string) => void;

const listeners = new Set<Listener>();

let apiBaseUrl = API_BASE_URL;

/** 去掉首尾空白与尾部斜杠；空值表示走同源。 */
export function normalizeApiBaseUrl(url: string): string {
  const trimmed = url.trim();
  if (!trimmed) {
    return '';
  }
  return trimmed.replace(/\/+$/, '');
}

export function getApiBaseUrl(): string {
  return apiBaseUrl;
}

export function setApiBaseUrl(url: string): void {
  apiBaseUrl = normalizeApiBaseUrl(url);
  listeners.forEach((listener) => listener(apiBaseUrl));
}

export function onApiBaseUrlChange(listener: Listener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
