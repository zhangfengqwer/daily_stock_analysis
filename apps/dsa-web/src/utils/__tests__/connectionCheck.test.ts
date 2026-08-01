import { afterEach, describe, expect, it, vi } from 'vitest';
import { checkConnection } from '../connectionCheck';

afterEach(() => {
  vi.unstubAllGlobals();
});

const stubFetch = (impl: typeof fetch) => vi.stubGlobal('fetch', impl);

describe('checkConnection', () => {
  it('rejects an address that is not an absolute http(s) URL', async () => {
    await expect(checkConnection('dsa.example.com')).resolves.toEqual({ kind: 'invalidUrl' });
  });

  it('reports ok on a 200 response', async () => {
    stubFetch(vi.fn().mockResolvedValue(new Response('{}', { status: 200 })) as unknown as typeof fetch);

    await expect(checkConnection('https://dsa.example.com')).resolves.toEqual({ kind: 'ok' });
  });

  it('distinguishes 401 from other HTTP errors', async () => {
    stubFetch(vi.fn().mockResolvedValue(new Response('', { status: 401 })) as unknown as typeof fetch);

    await expect(checkConnection('https://dsa.example.com')).resolves.toEqual({ kind: 'unauthorized' });
  });

  it('reports the status code for other HTTP errors', async () => {
    stubFetch(vi.fn().mockResolvedValue(new Response('', { status: 502 })) as unknown as typeof fetch);

    await expect(checkConnection('https://dsa.example.com')).resolves.toEqual({
      kind: 'httpError',
      status: 502,
    });
  });

  it('reports unreachable when the request cannot be sent', async () => {
    stubFetch(vi.fn().mockRejectedValue(new TypeError('Failed to fetch')) as unknown as typeof fetch);

    await expect(checkConnection('https://dsa.example.com')).resolves.toEqual({ kind: 'unreachable' });
  });

  it('reports timeout when the request is aborted', async () => {
    stubFetch(vi.fn().mockImplementation((_url: string, init?: RequestInit) => {
      return new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => {
          reject(new DOMException('Aborted', 'AbortError'));
        });
      });
    }) as unknown as typeof fetch);

    await expect(checkConnection('https://dsa.example.com', 10)).resolves.toEqual({ kind: 'timeout' });
  });
});
