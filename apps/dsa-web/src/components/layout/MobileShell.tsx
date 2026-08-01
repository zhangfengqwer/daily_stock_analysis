import type React from 'react';
import { Outlet } from 'react-router-dom';

type MobileShellProps = {
  children?: React.ReactNode;
};

// 占位实现，Task 4 替换为带底部 tab 栏与安全区处理的版本。
export const MobileShell: React.FC<MobileShellProps> = ({ children }) => (
  <div className="min-h-screen bg-background text-foreground">
    <main className="min-h-0 min-w-0 flex-1">{children ?? <Outlet />}</main>
  </div>
);
