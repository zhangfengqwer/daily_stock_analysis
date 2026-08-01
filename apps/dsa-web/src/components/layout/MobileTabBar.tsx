import type React from 'react';
import { Home, MessageSquareQuote, Settings2 } from 'lucide-react';
import { NavLink } from 'react-router-dom';
import type { UiTextKey } from '../../i18n/uiText';
import { useUiLanguage } from '../../contexts/UiLanguageContext';
import { cn } from '../../utils/cn';

type MobileTab = {
  key: string;
  labelKey: UiTextKey;
  to: string;
  icon: React.ComponentType<{ className?: string }>;
  end: boolean;
};

// 移动端只暴露三个入口，刻意不复用 SidebarNav 的 NAV_ITEMS（那份含 8 个桌面入口）。
const MOBILE_TABS: MobileTab[] = [
  { key: 'home', labelKey: 'layout.nav.home', to: '/', icon: Home, end: true },
  { key: 'chat', labelKey: 'layout.nav.chat', to: '/chat', icon: MessageSquareQuote, end: false },
  { key: 'settings', labelKey: 'layout.nav.settings', to: '/settings', icon: Settings2, end: false },
];

export const MobileTabBar: React.FC = () => {
  const { t } = useUiLanguage();

  return (
    <nav
      aria-label={t('layout.navMenu')}
      className="fixed inset-x-0 bottom-0 z-50 border-t border-border/70 bg-card/95 backdrop-blur-md"
      style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
    >
      <ul className="flex items-stretch justify-around">
        {MOBILE_TABS.map(({ key, labelKey, to, icon: Icon, end }) => (
          <li key={key} className="flex-1">
            <NavLink
              to={to}
              end={end}
              className={({ isActive }) =>
                cn(
                  // 最小 56px 高度，保证触控目标达到可用尺寸
                  'flex min-h-[56px] flex-col items-center justify-center gap-1 text-xs transition-colors',
                  isActive ? 'text-foreground' : 'text-secondary-text',
                )
              }
            >
              <Icon className="h-5 w-5" />
              <span>{t(labelKey)}</span>
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  );
};
