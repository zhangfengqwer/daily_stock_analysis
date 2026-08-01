export type ConnectionResult =
  | { kind: 'ok' }
  | { kind: 'unauthorized' }
  | { kind: 'httpError'; status: number }
  | { kind: 'timeout' }
  | { kind: 'invalidUrl' }
  | { kind: 'unreachable' };

function isAbsoluteHttpUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

/**
 * 探测后端可达性。
 *
 * 注意：WebView 的 fetch 对 DNS 失败、TLS 证书错误和 CORS 拒绝一律抛 TypeError，
 * 不暴露区分信息，因此这三种情况只能统一归为 'unreachable'，由 UI 层列出可能原因。
 */
export async function checkConnection(
  baseUrl: string,
  timeoutMs = 8000,
): Promise<ConnectionResult> {
  if (!isAbsoluteHttpUrl(baseUrl)) {
    return { kind: 'invalidUrl' };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(`${baseUrl.replace(/\/+$/, '')}/api/v1/health`, {
      method: 'GET',
      credentials: 'include',
      signal: controller.signal,
    });

    if (response.ok) {
      return { kind: 'ok' };
    }
    if (response.status === 401) {
      return { kind: 'unauthorized' };
    }
    return { kind: 'httpError', status: response.status };
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') {
      return { kind: 'timeout' };
    }
    return { kind: 'unreachable' };
  } finally {
    clearTimeout(timer);
  }
}
