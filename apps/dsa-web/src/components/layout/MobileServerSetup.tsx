import type React from 'react';
import { useState } from 'react';
import { useUiLanguage } from '../../contexts/UiLanguageContext';
import { checkConnection } from '../../utils/connectionCheck';
import { setApiBaseUrl } from '../../utils/runtimeConfig';
import { saveServerAddress } from '../../utils/serverAddressStore';

type MobileServerSetupProps = {
  onDone: () => void;
};

export const MobileServerSetup: React.FC<MobileServerSetupProps> = ({ onDone }) => {
  const { t } = useUiLanguage();
  const [address, setAddress] = useState('');
  const [error, setError] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async () => {
    setSubmitting(true);
    setError('');
    try {
      const result = await checkConnection(address);
      // 401 表示地址可达但未登录，属于正常情况，放行到登录流程。
      if (result.kind !== 'ok' && result.kind !== 'unauthorized') {
        setError(
          result.kind === 'invalidUrl'
            ? t('mobile.settings.resultInvalidUrl')
            : t('mobile.settings.resultUnreachable'),
        );
        return;
      }
      await saveServerAddress(address);
      setApiBaseUrl(address);
      onDone();
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div
      className="flex min-h-screen flex-col justify-center gap-4 bg-background px-6 text-foreground"
      style={{ paddingTop: 'env(safe-area-inset-top)', paddingBottom: 'env(safe-area-inset-bottom)' }}
    >
      <h1 className="text-xl font-semibold">{t('mobile.setup.title')}</h1>
      <p className="text-sm text-secondary-text">{t('mobile.setup.description')}</p>

      <label className="text-sm" htmlFor="mobile-setup-url">
        {t('mobile.settings.serverUrlLabel')}
      </label>
      <input
        id="mobile-setup-url"
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

      {error ? <p className="text-sm text-danger">{error}</p> : null}

      <button
        type="button"
        className="btn-primary py-3"
        disabled={submitting}
        onClick={() => void handleSubmit()}
      >
        {submitting ? t('mobile.settings.testing') : t('mobile.setup.submit')}
      </button>
    </div>
  );
};
