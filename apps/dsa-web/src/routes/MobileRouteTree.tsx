import { lazy } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import { MobileShell } from '../components/layout/MobileShell';
import { RouteOutletBoundary } from '../components/layout/RouteBoundary';

const HomePage = /* @__PURE__ */ lazy(() => import('../pages/HomePage'));
const ChatPage = /* @__PURE__ */ lazy(() => import('../pages/ChatPage'));
const MobileSettingsPage = /* @__PURE__ */ lazy(() => import('../pages/MobileSettingsPage'));

const MobileRouteTree = () => (
  <Routes>
    <Route
      element={(
        <MobileShell>
          <RouteOutletBoundary />
        </MobileShell>
      )}
    >
      <Route path="/" element={<HomePage />} />
      <Route path="/chat" element={<ChatPage />} />
      <Route path="/settings" element={<MobileSettingsPage />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Route>
  </Routes>
);

export default MobileRouteTree;
