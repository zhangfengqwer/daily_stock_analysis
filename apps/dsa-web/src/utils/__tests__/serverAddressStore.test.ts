import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { loadServerAddress, saveServerAddress } from '../serverAddressStore';

describe('serverAddressStore', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  describe('without Capacitor (web / test environment)', () => {
    it('returns an empty string when nothing is stored', async () => {
      await expect(loadServerAddress()).resolves.toBe('');
    });

    it('round-trips a saved address', async () => {
      await saveServerAddress('https://dsa.example.com');
      await expect(loadServerAddress()).resolves.toBe('https://dsa.example.com');
    });

    it('normalizes the address before storing it', async () => {
      await saveServerAddress('  https://dsa.example.com/  ');
      await expect(loadServerAddress()).resolves.toBe('https://dsa.example.com');
    });
  });

  describe('with the Capacitor Preferences plugin injected', () => {
    const stubPreferences = (value: string | null) => {
      const preferences = {
        get: vi.fn().mockResolvedValue({ value }),
        set: vi.fn().mockResolvedValue(undefined),
      };
      vi.stubGlobal('Capacitor', { Plugins: { Preferences: preferences } });
      return preferences;
    };

    it('reads through the plugin instead of localStorage', async () => {
      const preferences = stubPreferences('https://native.example.com');
      localStorage.setItem('dsa.serverAddress', 'https://should-be-ignored.example.com');

      await expect(loadServerAddress()).resolves.toBe('https://native.example.com');
      expect(preferences.get).toHaveBeenCalledWith({ key: 'dsa.serverAddress' });
    });

    it('treats a missing plugin value as unconfigured', async () => {
      stubPreferences(null);

      await expect(loadServerAddress()).resolves.toBe('');
    });

    it('writes the normalized address through the plugin', async () => {
      const preferences = stubPreferences(null);

      await saveServerAddress('  https://native.example.com/  ');

      expect(preferences.set).toHaveBeenCalledWith({
        key: 'dsa.serverAddress',
        value: 'https://native.example.com',
      });
      expect(localStorage.getItem('dsa.serverAddress')).toBeNull();
    });
  });
});
