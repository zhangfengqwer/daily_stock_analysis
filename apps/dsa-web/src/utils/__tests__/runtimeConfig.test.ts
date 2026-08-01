import { beforeEach, describe, expect, it } from 'vitest';
import {
  getApiBaseUrl,
  normalizeApiBaseUrl,
  onApiBaseUrlChange,
  setApiBaseUrl,
} from '../runtimeConfig';

describe('runtimeConfig', () => {
  beforeEach(() => {
    setApiBaseUrl('');
  });

  it('defaults to the same-origin empty string', () => {
    expect(getApiBaseUrl()).toBe('');
  });

  it('strips trailing slashes and surrounding whitespace', () => {
    setApiBaseUrl('  https://dsa.example.com//  ');
    expect(getApiBaseUrl()).toBe('https://dsa.example.com');
  });

  it('normalizes an empty input back to same-origin', () => {
    expect(normalizeApiBaseUrl('   ')).toBe('');
  });

  it('notifies subscribers until they unsubscribe', () => {
    const seen: string[] = [];
    const unsubscribe = onApiBaseUrlChange((url) => seen.push(url));

    setApiBaseUrl('https://a.example.com');
    unsubscribe();
    setApiBaseUrl('https://b.example.com');

    expect(seen).toEqual(['https://a.example.com']);
  });

  it('keeps apiClient.defaults.baseURL in sync', async () => {
    const { default: apiClient } = await import('../../api');

    setApiBaseUrl('https://sync.example.com');

    expect(apiClient.defaults.baseURL).toBe('https://sync.example.com');
  });
});
