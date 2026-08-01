import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { describe, expect, it } from 'vitest';
import { MobileTabBar } from '../MobileTabBar';
import { UiLanguageProvider } from '../../../contexts/UiLanguageContext';

const renderAt = (path: string) =>
  render(
    <UiLanguageProvider>
      <MemoryRouter initialEntries={[path]}>
        <MobileTabBar />
      </MemoryRouter>
    </UiLanguageProvider>,
  );

describe('MobileTabBar', () => {
  it('renders exactly the three mobile destinations', () => {
    renderAt('/');

    const links = screen.getAllByRole('link');
    expect(links.map((link) => link.getAttribute('href'))).toEqual([
      '/',
      '/chat',
      '/settings',
    ]);
  });

  it('marks the active tab with aria-current', () => {
    renderAt('/chat');

    expect(screen.getByRole('link', { current: 'page' })).toHaveAttribute('href', '/chat');
  });

  it('does not mark home as active on a nested route', () => {
    renderAt('/settings');

    expect(screen.getByRole('link', { current: 'page' })).toHaveAttribute('href', '/settings');
  });
});
