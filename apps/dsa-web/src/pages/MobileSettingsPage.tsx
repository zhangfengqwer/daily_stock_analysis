import type React from 'react';
import { useCallback, useEffect, useState } from 'react';
import { useUiLanguage } from '../contexts/UiLanguageContext';
import { useAuth } from '../contexts/AuthContext';
import { checkConnection, type ConnectionResult } from '../utils/connectionCheck';
import { getApiBaseUrl, setApiBaseUrl } from '../utils/runtimeConfig';
import { loadServerAddress, saveServerAddress } from '../utils/serverAddressStore';
import { WEB_BUILD_INFO } from '../utils/constants';

const MobileSettingsPage: React.FC = () => {
  const { t } = useUiLanguage();
  const { logout } = useAuth();
  const [address, setAddress] = useState('');
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState<ConnectionResult | null>(null);

  useEffect(() => {
    void loadServerAddress().then((stored) => {
      setAddress(stored || getApiBaseUrl());
    });
  }, []);

  const handleSave = useCallback(async () => {
    await saveServerAddress(address);
    setApiBaseUrl(address);
    // 换后端等于换会话：AuthProvider 只在挂载时取一次 auth 状态，
    // 不重载的话登录态会停留在旧后端的结果上。测试环境下 jsdom 未实现 reload，故做保护。
    if (typeof window !== 'undefined' && typeof window.location.reload === 'function') {
      window.location.reload();
    }
  }, [address]);

  const handleTest = useCallback(async () => {
    setTesting(true);
    try {
      setResult(await checkConnection(address));
    } finally {
      setTesting(false);
    }
  }, [address]);

  const describeResult = (value: ConnectionResult): string => {
    switch (value.kind) {
      case 'ok':
        return t('mobile.settings.resultOk');
      case 'unauthorized':
        return t('mobile.settings.resultUnauthorized');
      case 'httpError':
        return t('mobile.settings.resultHttpError').replace('{status}', String(value.status));
      case 'timeout':
        return t('mobile.settings.resultTimeout');
      case 'invalidUrl':
        return t('mobile.settings.resultInvalidUrl');
      case 'unreachable':
        return t('mobile.settings.resultUnreachable');
    }
  };

  return (
    <div className="flex flex-col gap-6 py-4">
      <h1 className="text-lg font-semibold">{t('mobile.settings.title')}</h1>

      <section className="flex flex-col gap-3">
        <h2 className="text-sm text-secondary-text">{t('mobile.settings.serverSection')}</h2>

        <label className="flex flex-col gap-1 text-sm" htmlFor="mobile-server-url">
          {t('mobile.settings.serverUrlLabel')}
        </label>
        <input
          id="mobile-server-url"
          type="url"
          inputMode="url"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          className="w-full rounded-xl border border-border/70 bg-card px-3 py-3 text-base"
          placeholder={t('mobile.settings.serverUrlPlaceholder')}
          value={address}
          onChange={(event) => setAddress(event.target.value)}
        />

        <div className="flex gap-2">
          <button type="button" className="btn-primary flex-1 py-3" onClick={() => void handleSave()}>
            {t('mobile.settings.save')}
          </button>
          <button
            type="button"
            className="btn-secondary flex-1 py-3"
            disabled={testing}
            onClick={() => void handleTest()}
          >
            {testing ? t('mobile.settings.testing') : t('mobile.settings.testConnection')}
          </button>
        </div>

        {result ? <p className="text-sm text-secondary-text">{describeResult(result)}</p> : null}
      </section>

      <section className="flex flex-col gap-3">
        <button type="button" className="btn-secondary py-3" onClick={() => void logout()}>
          {t('mobile.settings.logout')}
        </button>
        <p className="text-xs text-secondary-text">
          {t('mobile.settings.version')} {WEB_BUILD_INFO.version}
        </p>
      </section>
    </div>
  );
};

export default MobileSettingsPage;
