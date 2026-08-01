import type React from 'react';
import { Outlet } from 'react-router-dom';
import { MobileTabBar } from './MobileTabBar';
import { ThemeToggle } from '../theme/ThemeToggle';
import { UiLanguageToggle } from '../i18n/UiLanguageToggle';

type MobileShellProps = {
  children?: React.ReactNode;
};

export const MobileShell: React.FC<MobileShellProps> = ({ children }) => (
  <div className="min-h-screen bg-background text-foreground">
    <div
      className="sticky top-0 z-40 flex items-center justify-end gap-2 bg-background/85 px-3 py-2 backdrop-blur-md"
      style={{ paddingTop: 'calc(env(safe-area-inset-top) + 0.5rem)' }}
    >
      <UiLanguageToggle />
      <ThemeToggle />
    </div>

    {/* 底部留出 tab 栏高度 + 安全区，避免内容被遮挡 */}
    <main
      className="min-h-0 min-w-0 px-3 touch-pan-y"
      style={{ paddingBottom: 'calc(56px + env(safe-area-inset-bottom) + 1rem)' }}
    >
      {children ?? <Outlet />}
    </main>

    <MobileTabBar />
  </div>
);
