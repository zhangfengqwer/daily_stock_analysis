import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import MobileSettingsPage from '../MobileSettingsPage';
import { UiLanguageProvider } from '../../contexts/UiLanguageContext';
import { AuthProvider } from '../../contexts/AuthContext';
import { UI_LANGUAGE_STORAGE_KEY } from '../../utils/uiLanguage';
import { getApiBaseUrl, setApiBaseUrl } from '../../utils/runtimeConfig';

vi.mock('../../utils/connectionCheck', () => ({
  checkConnection: vi.fn(),
}));

const { checkConnection } = await import('../../utils/connectionCheck');

const renderPage = () =>
  render(
    <UiLanguageProvider>
      <MemoryRouter>
        <AuthProvider>
          <MobileSettingsPage />
        </AuthProvider>
      </MemoryRouter>
    </UiLanguageProvider>,
  );

describe('MobileSettingsPage', () => {
  beforeEach(() => {
    localStorage.clear();
    window.localStorage.setItem(UI_LANGUAGE_STORAGE_KEY, 'en');
    setApiBaseUrl('');
    vi.mocked(checkConnection).mockReset();
    // 保存地址后组件会调用 location.reload()，jsdom 未实现该方法会打印 "Not implemented" 噪音。
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...window.location, reload: vi.fn() },
    });
  });

  it('uses the Android WebView-safe text color for the persisted server URL', async () => {
    localStorage.setItem('dsa.serverAddress', 'https://dsa.example.com');
    renderPage();

    expect(await screen.findByDisplayValue('https://dsa.example.com')).toHaveClass(
      'mobile-server-url-input',
    );
  });

  it('saves the entered address and applies it to the runtime config', async () => {
    const user = userEvent.setup();
    renderPage();

    const input = await screen.findByLabelText('Backend URL');
    await user.clear(input);
    await user.type(input, 'https://dsa.example.com/');
    await user.click(screen.getByRole('button', { name: 'Save' }));

    expect(await screen.findByDisplayValue('https://dsa.example.com/')).toBeInTheDocument();
    expect(getApiBaseUrl()).toBe('https://dsa.example.com');
    expect(localStorage.getItem('dsa.serverAddress')).toBe('https://dsa.example.com');
  });

  it('shows a combined cause message when the server is unreachable', async () => {
    vi.mocked(checkConnection).mockResolvedValue({ kind: 'unreachable' });
    const user = userEvent.setup();
    renderPage();

    const input = await screen.findByLabelText('Backend URL');
    await user.type(input, 'https://dsa.example.com');
    await user.click(screen.getByRole('button', { name: 'Test connection' }));

    expect(
      await screen.findByText(
        /Cannot connect\. Possible causes: wrong address, backend not running, or an invalid HTTPS certificate/,
      ),
    ).toBeInTheDocument();
  });

  it('reports the status code for a non-401 HTTP error', async () => {
    vi.mocked(checkConnection).mockResolvedValue({ kind: 'httpError', status: 502 });
    const user = userEvent.setup();
    renderPage();

    const input = await screen.findByLabelText('Backend URL');
    await user.type(input, 'https://dsa.example.com');
    await user.click(screen.getByRole('button', { name: 'Test connection' }));

    expect(await screen.findByText('Backend returned status 502')).toBeInTheDocument();
  });

  it('distinguishes 401 from an unreachable server', async () => {
    vi.mocked(checkConnection).mockResolvedValue({ kind: 'unauthorized' });
    const user = userEvent.setup();
    renderPage();

    const input = await screen.findByLabelText('Backend URL');
    await user.type(input, 'https://dsa.example.com');
    await user.click(screen.getByRole('button', { name: 'Test connection' }));

    expect(
      await screen.findByText('Server reachable, but you are not signed in'),
    ).toBeInTheDocument();
  });
});
