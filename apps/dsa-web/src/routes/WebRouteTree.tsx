import { lazy } from 'react';
import { Route, Routes } from 'react-router-dom';
import { Shell } from '../components/common';
import { RouteOutletBoundary } from '../components/layout/RouteBoundary';

const HomePage = /* @__PURE__ */ lazy(() => import('../pages/HomePage'));
const BacktestPage = /* @__PURE__ */ lazy(() => import('../pages/BacktestPage'));
const SettingsPage = /* @__PURE__ */ lazy(() => import('../pages/SettingsPage'));
const NotFoundPage = /* @__PURE__ */ lazy(() => import('../pages/NotFoundPage'));
const ChatPage = /* @__PURE__ */ lazy(() => import('../pages/ChatPage'));
const PortfolioPage = /* @__PURE__ */ lazy(() => import('../pages/PortfolioPage'));
const AlertsPage = /* @__PURE__ */ lazy(() => import('../pages/AlertsPage'));
const TokenUsagePage = /* @__PURE__ */ lazy(() => import('../pages/TokenUsagePage'));
const StockScreeningPage = /* @__PURE__ */ lazy(() => import('../pages/StockScreeningPage'));

const WebRouteTree = () => (
  <Routes>
    <Route
      element={(
        <Shell>
          <RouteOutletBoundary />
        </Shell>
      )}
    >
      <Route path="/" element={<HomePage />} />
      <Route path="/chat" element={<ChatPage />} />
      <Route path="/portfolio" element={<PortfolioPage />} />
      <Route path="/screening" element={<StockScreeningPage />} />
      <Route path="/backtest" element={<BacktestPage />} />
      <Route path="/alerts" element={<AlertsPage />} />
      <Route path="/usage" element={<TokenUsagePage />} />
      <Route path="/settings" element={<SettingsPage />} />
      <Route path="*" element={<NotFoundPage />} />
    </Route>
  </Routes>
);

export default WebRouteTree;
