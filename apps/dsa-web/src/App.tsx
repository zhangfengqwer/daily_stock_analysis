import type React from 'react';
import { lazy, useEffect } from 'react';
import { BrowserRouter as Router, Navigate, useLocation } from 'react-router-dom';
import { ApiErrorAlert } from './components/common';
import {
  PageLoadingFallback,
  StandaloneRouteBoundary,
} from './components/layout/RouteBoundary';
import { AuthProvider, useAuth } from './contexts/AuthContext';
import { UiLanguageProvider, useUiLanguage } from './contexts/UiLanguageContext';
import { useAgentChatStore } from './stores/agentChatStore';
import { MobileBootstrap } from './components/layout/MobileBootstrap';
import MobileRouteTree from './routes/MobileRouteTree';
import WebRouteTree from './routes/WebRouteTree';
import './App.css';

const LoginPage = lazy(() => import('./pages/LoginPage'));

const AppContent: React.FC = () => {
  const location = useLocation();
  const { authEnabled, loggedIn, isLoading, loadError, refreshStatus } = useAuth();
  const { t } = useUiLanguage();

  useEffect(() => {
    useAgentChatStore.getState().setCurrentRoute(location.pathname);
  }, [location.pathname]);

  if (isLoading) {
    return <PageLoadingFallback />;
  }

  if (loadError) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-4 bg-base px-4">
        <div className="w-full max-w-lg">
          <ApiErrorAlert error={loadError} />
        </div>
        <button
          type="button"
          className="btn-primary"
          onClick={() => void refreshStatus()}
        >
          {t('common.retry')}
        </button>
      </div>
    );
  }

  if (authEnabled && !loggedIn) {
    if (location.pathname === '/login') {
      return (
        <StandaloneRouteBoundary>
          <LoginPage />
        </StandaloneRouteBoundary>
      );
    }
    const redirect = encodeURIComponent(location.pathname + location.search);
    return <Navigate to={`/login?redirect=${redirect}`} replace />;
  }

  if (location.pathname === '/login') {
    return <Navigate to="/" replace />;
  }

  // 直接比较构建期常量，使 Rollup 能折叠分支并整模块丢弃未使用的那棵路由树。
  return __APP_TARGET__ === 'mobile' ? <MobileRouteTree /> : <WebRouteTree />;
};

const App: React.FC = () => {
  const tree = (
    <AuthProvider>
      <AppContent />
    </AuthProvider>
  );

  return (
    <UiLanguageProvider>
      <Router>
        {/* 与路由树同理：直接比较构建期常量，Web 构建下 Rollup 会折叠分支并丢弃 MobileBootstrap。 */}
        {__APP_TARGET__ === 'mobile' ? <MobileBootstrap>{tree}</MobileBootstrap> : tree}
      </Router>
    </UiLanguageProvider>
  );
};

export default App;
