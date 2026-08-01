import type React from 'react';
import { useEffect, useState } from 'react';
import { PageLoadingFallback } from './RouteBoundary';
import { MobileServerSetup } from './MobileServerSetup';
import { setApiBaseUrl } from '../../utils/runtimeConfig';
import { loadServerAddress } from '../../utils/serverAddressStore';

type MobileBootstrapProps = {
  children: React.ReactNode;
};

/**
 * 在挂载 AuthProvider 之前解析后端地址。
 *
 * AuthProvider 一挂载就会请求 /api/v1/auth/status。首次启动尚无服务器地址时该请求必然失败，
 * 会让 App 直接进入 loadError 分支，引导页就永远没机会渲染——所以这一层必须在 AuthProvider 之外。
 */
export const MobileBootstrap: React.FC<MobileBootstrapProps> = ({ children }) => {
  const [ready, setReady] = useState(false);
  const [needsSetup, setNeedsSetup] = useState(false);

  useEffect(() => {
    void loadServerAddress().then((stored) => {
      if (stored) {
        setApiBaseUrl(stored);
      } else {
        setNeedsSetup(true);
      }
      setReady(true);
    });
  }, []);

  if (!ready) {
    return <PageLoadingFallback />;
  }

  if (needsSetup) {
    return <MobileServerSetup onDone={() => setNeedsSetup(false)} />;
  }

  return <>{children}</>;
};
