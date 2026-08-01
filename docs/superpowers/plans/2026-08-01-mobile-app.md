# 移动端 App（Capacitor / Android）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Web 端的「每日分析报告」和「AI 对话问股」两个功能，通过 Capacitor 打包成可安装的 Android App，连接部署在公网 HTTPS 上的现有后端。

**Architecture:** `apps/dsa-mobile/` 只做 Capacitor 壳（对标 `apps/dsa-desktop/` 的做法，壳内不放 UI）；UI 全部复用 `apps/dsa-web/`，通过新增的 `mobile` 构建模式产出精简路由的产物。后端仅新增两个配置项以支持跨站 Cookie 认证，默认行为完全不变。

**Tech Stack:** Capacitor 7（Android）、React 19、Vite 7、TypeScript 5.9、Tailwind 4、vitest、FastAPI、pytest/unittest

## Global Constraints

- 设计依据：`docs/superpowers/specs/2026-08-01-mobile-app-design.md`。有冲突以 spec 为准。
- **不得启用 `CapacitorHttp` / `CapacitorCookies` 插件。** 它们会 patch `window.fetch` 并整包缓冲响应，破坏 `api/v1/endpoints/agent.py:458` 的 SSE 流式对话。
- **Web 与 Desktop 行为必须零变化。** 所有后端改动均为新增配置项且默认值保持现状；所有前端改动在 `__APP_TARGET__ === 'web'` 下必须与改动前等价。
- Web 构建的 `outDir` 必须仍为仓库根的 `static/`，不得改动。
- 新增配置项必须同步更新 `.env.example`（AGENTS.md 硬规则）。
- 用户可见能力变化必须更新 `docs/CHANGELOG.md` 的 `[Unreleased]`，使用扁平格式 `- [类型] 描述`，禁止新增 `### 类目标题`。
- commit message 使用英文，**不添加 `Co-Authored-By`**（AGENTS.md 硬规则）。
- **AGENTS.md 规定：未经用户明确确认，不执行 `git commit` / `git tag` / `git push`。** 各任务末尾的 commit 步骤需先向用户确认再执行。
- 后端验证优先执行 `./scripts/ci_gate.sh`；最低要求 `python -m py_compile <changed_python_files>`。
- 前端验证执行 `npm run lint` 与 `npm run build`（在 `apps/dsa-web/` 下）。
- i18n：`apps/dsa-web/src/i18n/uiText.ts` 中 `UiTextKey = keyof typeof zh`，且 `UI_TEXT: Record<UiLanguage, Record<UiTextKey, string>>`。往 `zh` 加键后不给 `en` 补同名键会直接编译报错，这是类型层面的强制约束。

---

### Task 1: 后端支持移动端跨站认证

移动端 WebView 的 origin 是 `https://localhost`，后端在公网域名上，属于跨站。当前 session cookie 是 `samesite="lax"`，跨站请求不会携带，表现为登录成功但后续全部 401。本任务让 SameSite 可配置，并把 Capacitor origin 加入 CORS 默认白名单。

**Files:**
- Modify: `api/v1/endpoints/auth.py:72-94`（`_cookie_params`）
- Modify: `api/app.py:234-241`（`allowed_origins` 默认列表）
- Modify: `.env.example:749`（在 `ADMIN_SESSION_MAX_AGE_HOURS` 之后追加）
- Test: `tests/test_auth_cookie_samesite.py`（新建）
- Test: `tests/test_api_app_cors.py`（追加用例）

**Interfaces:**
- Consumes: 无（首个任务）
- Produces: 环境变量 `ADMIN_SESSION_COOKIE_SAMESITE`，取值 `lax`（默认）/ `strict` / `none`；取值为 `none` 时 `_cookie_params()` 返回的 `secure` 强制为 `True`。CORS 默认白名单包含 `https://localhost`。

- [ ] **Step 1: 写失败测试（cookie SameSite）**

创建 `tests/test_auth_cookie_samesite.py`：

```python
# -*- coding: utf-8 -*-
"""Tests for the configurable session cookie SameSite attribute."""

import os
import sys
import unittest
from unittest.mock import MagicMock, patch

# Keep this test runnable when optional LLM runtime deps are not installed.
try:
    import litellm  # noqa: F401
except ModuleNotFoundError:
    sys.modules["litellm"] = MagicMock()

from starlette.requests import Request

from api.v1.endpoints import auth as auth_endpoint


def _make_request(scheme: str = "http") -> Request:
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/",
            "headers": [],
            "scheme": scheme,
            "server": ("testserver", 80),
            "query_string": b"",
        }
    )


class CookieSameSiteTestCase(unittest.TestCase):
    """SameSite must stay 'lax' by default and force Secure when set to 'none'."""

    def test_defaults_to_lax(self):
        with patch.dict(os.environ, {"TRUST_X_FORWARDED_FOR": "false"}, clear=False):
            os.environ.pop("ADMIN_SESSION_COOKIE_SAMESITE", None)
            params = auth_endpoint._cookie_params(_make_request())

        self.assertEqual(params["samesite"], "lax")

    def test_none_forces_secure_even_on_http_scheme(self):
        env = {
            "TRUST_X_FORWARDED_FOR": "false",
            "ADMIN_SESSION_COOKIE_SAMESITE": "none",
        }
        with patch.dict(os.environ, env, clear=False):
            params = auth_endpoint._cookie_params(_make_request(scheme="http"))

        self.assertEqual(params["samesite"], "none")
        self.assertTrue(params["secure"])

    def test_strict_is_accepted_and_does_not_force_secure(self):
        env = {
            "TRUST_X_FORWARDED_FOR": "false",
            "ADMIN_SESSION_COOKIE_SAMESITE": "Strict",
        }
        with patch.dict(os.environ, env, clear=False):
            params = auth_endpoint._cookie_params(_make_request(scheme="http"))

        self.assertEqual(params["samesite"], "strict")
        self.assertFalse(params["secure"])

    def test_invalid_value_falls_back_to_lax(self):
        env = {
            "TRUST_X_FORWARDED_FOR": "false",
            "ADMIN_SESSION_COOKIE_SAMESITE": "bogus",
        }
        with patch.dict(os.environ, env, clear=False), \
             patch.object(auth_endpoint.logger, "warning") as warning:
            params = auth_endpoint._cookie_params(_make_request())

        self.assertEqual(params["samesite"], "lax")
        warning.assert_called_once()


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
python -m pytest tests/test_auth_cookie_samesite.py -v
```

预期：`test_none_forces_secure_even_on_http_scheme`、`test_strict_is_accepted_and_does_not_force_secure`、`test_invalid_value_falls_back_to_lax` 三条 FAIL（当前 `samesite` 硬编码为 `"lax"`）；`test_defaults_to_lax` PASS。

- [ ] **Step 3: 实现 SameSite 可配置**

把 `api/v1/endpoints/auth.py:72-94` 的 `_cookie_params` 整体替换为：

```python
def _cookie_params(request: Request) -> dict:
    """Build cookie params including Secure and SameSite based on request and env."""
    secure = False
    if os.getenv("TRUST_X_FORWARDED_FOR", "false").lower() == "true":
        proto = request.headers.get("X-Forwarded-Proto", "").lower()
        secure = proto == "https"
    else:
        # Check URL scheme when not behind proxy
        secure = request.url.scheme == "https"

    # 移动端 App（Capacitor）的 WebView origin 是 https://localhost，访问公网后端属于跨站，
    # SameSite=Lax 的 Cookie 不会被携带。此项默认保持 lax，自建者按需显式放开。
    samesite = os.getenv("ADMIN_SESSION_COOKIE_SAMESITE", "lax").strip().lower()
    if samesite not in {"lax", "strict", "none"}:
        logger.warning(
            "Invalid ADMIN_SESSION_COOKIE_SAMESITE=%r, falling back to 'lax'.",
            samesite,
        )
        samesite = "lax"
    if samesite == "none":
        # 浏览器强制要求 SameSite=None 必须搭配 Secure，否则整个 Cookie 会被丢弃。
        secure = True

    try:
        max_age_hours = int(os.getenv("ADMIN_SESSION_MAX_AGE_HOURS", str(SESSION_MAX_AGE_HOURS_DEFAULT)))
    except ValueError:
        max_age_hours = SESSION_MAX_AGE_HOURS_DEFAULT
    max_age = max_age_hours * 3600

    return {
        "httponly": True,
        "samesite": samesite,
        "secure": secure,
        "path": "/",
        "max_age": max_age,
    }
```

- [ ] **Step 4: 运行测试，确认通过**

```bash
python -m pytest tests/test_auth_cookie_samesite.py -v
```

预期：4 passed。

- [ ] **Step 5: 写失败测试（CORS 默认白名单）**

在 `tests/test_api_app_cors.py` 的 `AppCorsConfigTestCase` 类中追加：

```python
    def test_capacitor_origin_is_allowed_by_default(self):
        env = {"CORS_ALLOW_ALL": "false", "CORS_ORIGINS": ""}
        with patch.dict(os.environ, env, clear=False):
            app = self._build_app()

        cors = next(m for m in app.user_middleware if m.cls is CORSMiddleware)
        self.assertIn("https://localhost", cors.kwargs["allow_origins"])
        self.assertTrue(cors.kwargs["allow_credentials"])
```

- [ ] **Step 6: 运行测试，确认失败**

```bash
python -m pytest tests/test_api_app_cors.py -v
```

预期：`test_capacitor_origin_is_allowed_by_default` FAIL，报 `'https://localhost' not found in [...]`。

- [ ] **Step 7: 把 Capacitor origin 加入默认白名单**

把 `api/app.py:234-241` 的 `allowed_origins` 替换为：

```python
    allowed_origins = [
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        # Capacitor Android WebView 的固定 origin（capacitor.config.ts 中 androidScheme: 'https'）
        "https://localhost",
    ]
```

- [ ] **Step 8: 运行测试，确认通过**

```bash
python -m pytest tests/test_api_app_cors.py tests/test_auth_cookie_samesite.py -v
```

预期：全部 passed。

- [ ] **Step 9: 更新 `.env.example`**

在 `.env.example:749`（`# ADMIN_SESSION_MAX_AGE_HOURS=24  # Session 有效期（小时）`）之后插入：

```
# ADMIN_SESSION_COOKIE_SAMESITE=lax  # Session Cookie 的 SameSite：lax（默认）/ strict / none
# 仅当使用移动端 App（Capacitor）跨站访问本后端时才需要设为 none。
# 设为 none 会强制 Secure，因此后端必须以 HTTPS 对外提供服务，否则浏览器会丢弃 Cookie。
# 注意：none 会削弱浏览器端的 CSRF 防护，请勿在未开启 ADMIN_AUTH_ENABLED 时使用。
```

- [ ] **Step 10: 回归验证**

```bash
python -m pytest tests/test_auth_api.py tests/test_auth.py tests/test_api_app_cors.py tests/test_auth_cookie_samesite.py -v
```

预期：全部 passed，确认未破坏既有认证行为。

- [ ] **Step 11: Commit（需先向用户确认）**

```bash
git add api/v1/endpoints/auth.py api/app.py .env.example tests/test_auth_cookie_samesite.py tests/test_api_app_cors.py
git commit -m "feat: make session cookie SameSite configurable for mobile clients"
```

---

### Task 2: 前端运行时后端地址（runtimeConfig）

当前 `API_BASE_URL` 是构建期常量，Web 端默认空字符串走同源。移动端需要在运行时设定后端地址。本任务引入一层运行时配置，Web 端默认值与行为保持完全不变。

**Files:**
- Create: `apps/dsa-web/src/utils/runtimeConfig.ts`
- Create: `apps/dsa-web/src/utils/__tests__/runtimeConfig.test.ts`
- Modify: `apps/dsa-web/src/api/index.ts:1-12`
- Modify: `apps/dsa-web/src/api/agent.ts:90`

**Interfaces:**
- Consumes: `API_BASE_URL` from `apps/dsa-web/src/utils/constants.ts:11`
- Produces:
  - `getApiBaseUrl(): string`
  - `setApiBaseUrl(url: string): void`
  - `onApiBaseUrlChange(listener: (url: string) => void): () => void`（返回取消订阅函数）
  - `normalizeApiBaseUrl(url: string): string`（trim + 去掉尾部斜杠）

- [ ] **Step 1: 写失败测试**

创建 `apps/dsa-web/src/utils/__tests__/runtimeConfig.test.ts`：

```typescript
import { beforeEach, describe, expect, it } from 'vitest';
import {
  getApiBaseUrl,
  normalizeApiBaseUrl,
  onApiBaseUrlChange,
  setApiBaseUrl,
} from '../runtimeConfig';

describe('runtimeConfig', () => {
  beforeEach(() => {
    setApiBaseUrl('');
  });

  it('defaults to the same-origin empty string', () => {
    expect(getApiBaseUrl()).toBe('');
  });

  it('strips trailing slashes and surrounding whitespace', () => {
    setApiBaseUrl('  https://dsa.example.com//  ');
    expect(getApiBaseUrl()).toBe('https://dsa.example.com');
  });

  it('normalizes an empty input back to same-origin', () => {
    expect(normalizeApiBaseUrl('   ')).toBe('');
  });

  it('notifies subscribers until they unsubscribe', () => {
    const seen: string[] = [];
    const unsubscribe = onApiBaseUrlChange((url) => seen.push(url));

    setApiBaseUrl('https://a.example.com');
    unsubscribe();
    setApiBaseUrl('https://b.example.com');

    expect(seen).toEqual(['https://a.example.com']);
  });

  it('keeps apiClient.defaults.baseURL in sync', async () => {
    const { default: apiClient } = await import('../../api');

    setApiBaseUrl('https://sync.example.com');

    expect(apiClient.defaults.baseURL).toBe('https://sync.example.com');
  });
});
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
cd apps/dsa-web && npx vitest run src/utils/__tests__/runtimeConfig.test.ts
```

预期：FAIL，报无法解析模块 `../runtimeConfig`。

- [ ] **Step 3: 实现 runtimeConfig**

创建 `apps/dsa-web/src/utils/runtimeConfig.ts`：

```typescript
import { API_BASE_URL } from './constants';

type Listener = (url: string) => void;

const listeners = new Set<Listener>();

let apiBaseUrl = API_BASE_URL;

/** 去掉首尾空白与尾部斜杠；空值表示走同源。 */
export function normalizeApiBaseUrl(url: string): string {
  const trimmed = url.trim();
  if (!trimmed) {
    return '';
  }
  return trimmed.replace(/\/+$/, '');
}

export function getApiBaseUrl(): string {
  return apiBaseUrl;
}

export function setApiBaseUrl(url: string): void {
  apiBaseUrl = normalizeApiBaseUrl(url);
  listeners.forEach((listener) => listener(apiBaseUrl));
}

export function onApiBaseUrlChange(listener: Listener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
```

- [ ] **Step 4: 让 apiClient 跟随运行时地址**

把 `apps/dsa-web/src/api/index.ts` 开头的 import 与 client 创建段替换为：

```typescript
import axios from 'axios';
import { getApiBaseUrl, onApiBaseUrlChange } from '../utils/runtimeConfig';
import { attachParsedApiError } from './error';

const apiClient = axios.create({
  baseURL: getApiBaseUrl(),
  timeout: 30000,
  withCredentials: true,
  headers: {
    'Content-Type': 'application/json',
  },
});

onApiBaseUrlChange((url) => {
  apiClient.defaults.baseURL = url;
});
```

其余内容（响应拦截器与 `export default apiClient`）保持不变。注意原先的 `import { API_BASE_URL } from '../utils/constants';` 已被替换，不要留下未使用的 import。

- [ ] **Step 5: 让流式对话跟随运行时地址**

把 `apps/dsa-web/src/api/agent.ts:90` 的：

```typescript
    const base = API_BASE_URL || '';
```

替换为：

```typescript
    const base = getApiBaseUrl();
```

并在该文件的 import 段中，把 `API_BASE_URL` 的引入改为 `import { getApiBaseUrl } from '../utils/runtimeConfig';`。若 `API_BASE_URL` 在该文件其他位置仍被使用则保留原 import，否则删除以免 lint 报未使用变量。

> `apps/dsa-web/src/api/analysis.ts:182` 读的是 `apiClient.defaults.baseURL`，会自动跟随，无需改动。

- [ ] **Step 6: 运行测试，确认通过**

```bash
cd apps/dsa-web && npx vitest run src/utils/__tests__/runtimeConfig.test.ts
```

预期：5 passed。

- [ ] **Step 7: 全量前端验证（确认 Web 行为未变）**

```bash
cd apps/dsa-web && npm run lint && npx vitest run && npm run build
```

预期：lint 无错误；既有测试全部通过；build 成功且产物仍输出到 `static/`。

- [ ] **Step 8: Commit（需先向用户确认）**

```bash
git add apps/dsa-web/src/utils/runtimeConfig.ts apps/dsa-web/src/utils/__tests__/runtimeConfig.test.ts apps/dsa-web/src/api/index.ts apps/dsa-web/src/api/agent.ts
git commit -m "feat(web): resolve API base URL at runtime"
```

---

### Task 3: mobile 构建模式与路由裁剪

引入构建期常量 `__APP_TARGET__`，据此切换输出目录并裁剪路由。关键点是让未使用的 6 个页面被 Rollup 整模块丢弃 —— 因此两套路由树必须放在各自的模块里，`lazy()` 调用也在模块内部，这样死分支消除后整个模块不可达即被移除。

> **实施中发现并已修正：** 仅把 `lazy()` 放进独立模块 **不足以** 触发裁剪。Rollup 把模块顶层的 `lazy(...)` 调用表达式视为副作用，因而即使该模块只在被折叠掉的死分支里用到，模块仍会被保留，其动态 import 的页面 chunk 照样产出（实测 mobile 产物仍含 BacktestPage / PortfolioPage / StockScreeningPage / AlertsPage / TokenUsagePage / SettingsPage）。
>
> 必须给每个 `lazy()` 加 `/* @__PURE__ */` 注解，声明其无副作用，Rollup 才会连模块一起丢弃。两棵路由树都要加：`WebRouteTree` 不加会让 mobile 包带上 6 个桌面页，`MobileRouteTree` 不加会让 web 包带上 `MobileSettingsPage`。

**Files:**
- Create: `apps/dsa-web/src/routes/WebRouteTree.tsx`
- Create: `apps/dsa-web/src/routes/MobileRouteTree.tsx`
- Create: `apps/dsa-web/src/appTarget.ts`
- Modify: `apps/dsa-web/src/App.tsx:1-107`
- Modify: `apps/dsa-web/vite.config.ts:92-125`
- Modify: `apps/dsa-web/vitest.config.ts`
- Modify: `apps/dsa-web/package.json`（scripts）

**Interfaces:**
- Consumes: Task 2 的 `runtimeConfig`（间接，通过 api 层）
- Produces:
  - 构建期常量 `__APP_TARGET__: 'web' | 'mobile'`
  - `apps/dsa-web/src/appTarget.ts` 导出 `APP_TARGET` 与 `IS_MOBILE_APP: boolean`
  - `WebRouteTree` / `MobileRouteTree` 两个默认导出组件
  - npm script `build:mobile`，产物输出到 `apps/dsa-mobile/www`
  - `MobileRouteTree` 引用 `MobileShell`（Task 4 提供）与 `MobileSettingsPage`（Task 5 提供）

> **依赖说明：** 本任务的 `MobileRouteTree` 依赖 Task 4 的 `MobileShell` 和 Task 5 的 `MobileSettingsPage`。为让本任务可独立验证，Step 3 先建立两个最小占位实现，Task 4 / Task 5 再替换为真实实现。占位实现必须在对应任务中被完全替换，不得残留。

- [ ] **Step 1: 建立构建期常量声明**

创建 `apps/dsa-web/src/appTarget.ts`：

```typescript
declare const __APP_TARGET__: 'web' | 'mobile' | undefined;

export type AppTarget = 'web' | 'mobile';

export const APP_TARGET: AppTarget =
  typeof __APP_TARGET__ === 'undefined' ? 'web' : __APP_TARGET__;

export const IS_MOBILE_APP = APP_TARGET === 'mobile';
```

- [ ] **Step 2: 在 vite / vitest 配置中注入常量并切换输出目录**

把 `apps/dsa-web/vite.config.ts:92-125`（`// https://vite.dev/config/` 之后的 `export default defineConfig({...})` 整段）替换为：

```typescript
// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  const isMobile = mode === 'mobile'

  return {
    define: {
      __APP_PACKAGE_VERSION__: JSON.stringify(packageJson.version ?? '0.0.0'),
      __APP_BUILD_TIME__: JSON.stringify(buildTime),
      __APP_TARGET__: JSON.stringify(isMobile ? 'mobile' : 'web'),
    },
    plugins: [
      react({
        babel: {
          plugins: [['babel-plugin-react-compiler']],
        },
      }),
    ],
    server: {
      host: '0.0.0.0',  // 允许公网访问
      port: 5173,       // 默认端口
      proxy: {
        '/api': {
          target: 'http://127.0.0.1:8000',
          changeOrigin: true,
        },
      },
    },
    build: {
      // web 模式打包到项目根目录的 static 供 FastAPI 托管；
      // mobile 模式打包到 Capacitor 壳的 www，两者不得互相覆盖。
      outDir: isMobile
        ? path.resolve(__dirname, '../dsa-mobile/www')
        : path.resolve(__dirname, '../../static'),
      emptyOutDir: true,
      rollupOptions: {
        output: {
          manualChunks: getVendorChunkName,
        },
      },
    },
  }
})
```

在 `apps/dsa-web/vitest.config.ts` 中补上同名常量，否则测试环境下该标识符不存在：

```typescript
import { configDefaults, defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  define: {
    __APP_TARGET__: JSON.stringify('web'),
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: './src/setupTests.ts',
    exclude: [...configDefaults.exclude, 'e2e/**', 'playwright.config.ts'],
  },
});
```

在 `apps/dsa-web/package.json` 的 `scripts` 中追加：

```json
    "build:mobile": "tsc -b && vite build --mode mobile",
```

- [ ] **Step 3: 建立占位组件（Task 4 / 5 会替换）**

创建 `apps/dsa-web/src/components/layout/MobileShell.tsx`：

```typescript
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
```

创建 `apps/dsa-web/src/pages/MobileSettingsPage.tsx`：

```typescript
import type React from 'react';

// 占位实现，Task 5 替换为服务器地址 / 连接测试 / 登出的真实版本。
const MobileSettingsPage: React.FC = () => <div />;

export default MobileSettingsPage;
```

- [ ] **Step 4: 抽出 Web 路由树**

创建 `apps/dsa-web/src/routes/WebRouteTree.tsx`：

```typescript
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
```

- [ ] **Step 5: 建立移动端路由树**

创建 `apps/dsa-web/src/routes/MobileRouteTree.tsx`：

```typescript
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
```

- [ ] **Step 6: 在 App.tsx 中按构建期常量分支**

把 `apps/dsa-web/src/App.tsx` 整体替换为：

```typescript
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
import MobileRouteTree from './routes/MobileRouteTree';
import WebRouteTree from './routes/WebRouteTree';
import './App.css';

const LoginPage = /* @__PURE__ */ lazy(() => import('./pages/LoginPage'));

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
  return (
    <UiLanguageProvider>
      <Router>
        <AuthProvider>
          <AppContent />
        </AuthProvider>
      </Router>
    </UiLanguageProvider>
  );
};

export default App;
```

在 `apps/dsa-web/src/appTarget.ts` 顶部已声明 `__APP_TARGET__`，但 App.tsx 直接使用该标识符需要全局声明。在 `apps/dsa-web/src/vite-env.d.ts` 追加（若该文件不存在则创建）：

```typescript
declare const __APP_TARGET__: 'web' | 'mobile';
```

同时删除 `appTarget.ts` 中重复的局部 `declare const __APP_TARGET__` 行，避免与全局声明冲突。

- [ ] **Step 7: 运行既有测试，确认 Web 行为未变**

```bash
cd apps/dsa-web && npx vitest run
```

预期：既有测试（含 `src/App.test.tsx`）全部通过。若 `App.test.tsx` 因路由树抽出而失败，按其断言调整测试对新结构的引用，不得为通过测试而改变路由行为。

- [ ] **Step 8: 验证两种构建的输出目录与裁剪效果**

```bash
cd apps/dsa-web && npm run build && npm run build:mobile
```

预期：
- `static/` 中存在 `BacktestPage` / `PortfolioPage` / `StockScreeningPage` 相关 chunk
- `apps/dsa-mobile/www/` 中**不存在**这些 chunk

用下面的命令断言裁剪确实生效：

```bash
ls apps/dsa-mobile/www/assets | grep -Ei "backtest|portfolio|screening|alerts|usage" && echo "TREE-SHAKE FAILED" || echo "TREE-SHAKE OK"
```

预期输出：`TREE-SHAKE OK`

- [ ] **Step 9: Commit（需先向用户确认）**

```bash
git add apps/dsa-web/src/appTarget.ts apps/dsa-web/src/vite-env.d.ts apps/dsa-web/src/routes apps/dsa-web/src/App.tsx apps/dsa-web/src/components/layout/MobileShell.tsx apps/dsa-web/src/pages/MobileSettingsPage.tsx apps/dsa-web/vite.config.ts apps/dsa-web/vitest.config.ts apps/dsa-web/package.json
git commit -m "feat(web): add mobile build target with trimmed route tree"
```

---

### Task 4: MobileShell 与底部 tab 导航

替换 Task 3 的占位 `MobileShell`，实现底部 3 tab 导航与安全区处理。三个 tab 的 i18n key（`layout.nav.home` / `layout.nav.chat` / `layout.nav.settings`）在 `uiText.ts` 中已存在，无需新增。

**Files:**
- Modify: `apps/dsa-web/src/components/layout/MobileShell.tsx`（替换占位实现）
- Create: `apps/dsa-web/src/components/layout/MobileTabBar.tsx`
- Create: `apps/dsa-web/src/components/layout/__tests__/MobileTabBar.test.tsx`
- Modify: `apps/dsa-web/index.html:6`

**Interfaces:**
- Consumes: Task 3 的 `MobileRouteTree`（引用 `MobileShell`）
- Produces: `MobileShell`（具名导出）、`MobileTabBar`（具名导出）

- [ ] **Step 1: 写失败测试**

创建 `apps/dsa-web/src/components/layout/__tests__/MobileTabBar.test.tsx`：

```typescript
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
```

- [ ] **Step 2: 运行测试，确认失败**

```bash
cd apps/dsa-web && npx vitest run src/components/layout/__tests__/MobileTabBar.test.tsx
```

预期：FAIL，报无法解析模块 `../MobileTabBar`。

- [ ] **Step 3: 实现 MobileTabBar**

创建 `apps/dsa-web/src/components/layout/MobileTabBar.tsx`：

```typescript
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
```

- [ ] **Step 4: 运行测试，确认通过**

```bash
cd apps/dsa-web && npx vitest run src/components/layout/__tests__/MobileTabBar.test.tsx
```

预期：3 passed。

> `NavLink` 在激活时自动设置 `aria-current="page"`，因此第 2、3 条断言无需额外实现。

- [ ] **Step 5: 用真实实现替换 MobileShell 占位**

把 `apps/dsa-web/src/components/layout/MobileShell.tsx` 整体替换为：

```typescript
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
```

- [ ] **Step 6: 开启 viewport-fit 使安全区变量生效**

把 `apps/dsa-web/index.html:6` 替换为：

```html
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
```

> 没有 `viewport-fit=cover`，`env(safe-area-inset-*)` 恒为 0，上面两处安全区处理不会起作用。

- [ ] **Step 7: 验证**

```bash
cd apps/dsa-web && npm run lint && npx vitest run && npm run build && npm run build:mobile
```

预期：lint 无错误；全部测试通过；两种构建均成功。

- [ ] **Step 8: Commit（需先向用户确认）**

```bash
git add apps/dsa-web/src/components/layout/MobileShell.tsx apps/dsa-web/src/components/layout/MobileTabBar.tsx apps/dsa-web/src/components/layout/__tests__/MobileTabBar.test.tsx apps/dsa-web/index.html
git commit -m "feat(web): add mobile shell with bottom tab navigation"
```

---

### Task 5: MobileSettingsPage 与首启引导

替换 Task 3 的占位 `MobileSettingsPage`。提供后端地址的读写与连接测试，并在地址未配置时先走引导。地址持久化用 Capacitor 的 Preferences 插件，Web / 测试环境降级到 `localStorage`。

> **实施中发现并已修正（三处）：**
>
> 1. **不能 `import('@capacitor/preferences')`**，即使包在动态 import 里、外面裹 try/catch 也不行。Vite 的 `vite:import-analysis` 在**转换阶段**就会因解析不到该包而报错，那是构建期错误，运行时的 try/catch 挡不住。改为读取 Capacitor 注入到 `window.Capacitor.Plugins.Preferences` 的插件，`dsa-web` 因此完全不依赖 Capacitor —— 这反而更贴合「壳持有 Capacitor、dsa-web 只有 UI」的架构。副产物是原生分支变得可 stub、可测，实际测试覆盖比原计划更全。
> 2. **`getWebBuildInfo()` 不存在。** `apps/dsa-web/src/utils/constants.ts` 导出的是常量 `WEB_BUILD_INFO`（用法见 `SettingsPage.tsx:747`），应使用 `WEB_BUILD_INFO.version`。
> 3. **组件测试必须显式 pin UI 语言。** jsdom 的 locale 是 `en-US`，`UiLanguageProvider` 会默认英文，中文断言会全部失败。按仓库既有约定（见 `AlertRuleForm.test.tsx:29`），在渲染前 `window.localStorage.setItem(UI_LANGUAGE_STORAGE_KEY, 'en')` 并使用英文断言。注意要放在 `localStorage.clear()` 之后。

**Files:**
- Create: `apps/dsa-web/src/utils/serverAddressStore.ts`
- Create: `apps/dsa-web/src/utils/__tests__/serverAddressStore.test.ts`
- Create: `apps/dsa-web/src/utils/connectionCheck.ts`
- Create: `apps/dsa-web/src/utils/__tests__/connectionCheck.test.ts`
- Modify: `apps/dsa-web/src/pages/MobileSettingsPage.tsx`（替换占位实现）
- Create: `apps/dsa-web/src/pages/__tests__/MobileSettingsPage.test.tsx`
- Create: `apps/dsa-web/src/components/layout/MobileBootstrap.tsx`
- Create: `apps/dsa-web/src/components/layout/MobileServerSetup.tsx`
- Modify: `apps/dsa-web/src/App.tsx`（把 `MobileBootstrap` 包在 `AuthProvider` 外层）
- Modify: `apps/dsa-web/src/i18n/uiText.ts`（`zh` 与 `en` 各补 19 个键）

**Interfaces:**
- Consumes: Task 2 的 `getApiBaseUrl` / `setApiBaseUrl` / `normalizeApiBaseUrl`
- Produces:
  - `loadServerAddress(): Promise<string>`
  - `saveServerAddress(url: string): Promise<void>`
  - `checkConnection(baseUrl: string, timeoutMs?: number): Promise<ConnectionResult>`
  - `type ConnectionResult = { kind: 'ok' } | { kind: 'unauthorized' } | { kind: 'httpError'; status: number } | { kind: 'timeout' } | { kind: 'invalidUrl' } | { kind: 'unreachable' }`

- [ ] **Step 1: 写失败测试（地址存储）**

创建 `apps/dsa-web/src/utils/__tests__/serverAddressStore.test.ts`：

```typescript
import { beforeEach, describe, expect, it } from 'vitest';
import { loadServerAddress, saveServerAddress } from '../serverAddressStore';

describe('serverAddressStore', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('returns an empty string when nothing is stored', async () => {
    await expect(loadServerAddress()).resolves.toBe('');
  });

  it('round-trips a saved address', async () => {
    await saveServerAddress('https://dsa.example.com');
    await expect(loadServerAddress()).resolves.toBe('https://dsa.example.com');
  });

  it('normalizes the address before storing it', async () => {
    await saveServerAddress('  https://dsa.example.com/  ');
    await expect(loadServerAddress()).resolves.toBe('https://dsa.example.com');
  });
});
```

- [ ] **Step 2: 写失败测试（连接检测）**

创建 `apps/dsa-web/src/utils/__tests__/connectionCheck.test.ts`：

```typescript
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
```

- [ ] **Step 3: 运行测试，确认失败**

```bash
cd apps/dsa-web && npx vitest run src/utils/__tests__/serverAddressStore.test.ts src/utils/__tests__/connectionCheck.test.ts
```

预期：两个文件均 FAIL，报无法解析模块。

- [ ] **Step 4: 实现地址存储**

创建 `apps/dsa-web/src/utils/serverAddressStore.ts`：

```typescript
import { normalizeApiBaseUrl } from './runtimeConfig';

const STORAGE_KEY = 'dsa.serverAddress';

type PreferencesLike = {
  get(options: { key: string }): Promise<{ value: string | null }>;
  set(options: { key: string; value: string }): Promise<void>;
};

// Capacitor 的 Preferences 插件只在原生环境注入；Web / 测试环境降级到 localStorage，
// 让这层存储可以脱离设备独立验证。
async function getPreferences(): Promise<PreferencesLike | null> {
  try {
    const mod = await import('@capacitor/preferences');
    return mod.Preferences;
  } catch {
    return null;
  }
}

export async function loadServerAddress(): Promise<string> {
  const preferences = await getPreferences();
  if (preferences) {
    const { value } = await preferences.get({ key: STORAGE_KEY });
    return value ?? '';
  }
  return localStorage.getItem(STORAGE_KEY) ?? '';
}

export async function saveServerAddress(url: string): Promise<void> {
  const normalized = normalizeApiBaseUrl(url);
  const preferences = await getPreferences();
  if (preferences) {
    await preferences.set({ key: STORAGE_KEY, value: normalized });
    return;
  }
  localStorage.setItem(STORAGE_KEY, normalized);
}
```

- [ ] **Step 5: 实现连接检测**

创建 `apps/dsa-web/src/utils/connectionCheck.ts`：

```typescript
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
```

- [ ] **Step 6: 运行测试，确认通过**

```bash
cd apps/dsa-web && npx vitest run src/utils/__tests__/serverAddressStore.test.ts src/utils/__tests__/connectionCheck.test.ts
```

预期：9 passed。

- [ ] **Step 7: 补 i18n 键**

在 `apps/dsa-web/src/i18n/uiText.ts` 的 `zh` 对象中追加：

```typescript
  'mobile.setup.title': '连接到你的后端',
  'mobile.setup.description': '请输入你部署的后端地址，例如 https://dsa.example.com',
  'mobile.setup.submit': '保存并继续',
  'mobile.settings.title': '设置',
  'mobile.settings.serverSection': '服务器',
  'mobile.settings.serverUrlLabel': '后端地址',
  'mobile.settings.serverUrlPlaceholder': 'https://dsa.example.com',
  'mobile.settings.save': '保存',
  'mobile.settings.testConnection': '连接测试',
  'mobile.settings.testing': '测试中…',
  'mobile.settings.resultOk': '连接正常',
  'mobile.settings.resultUnauthorized': '地址正确，但尚未登录',
  'mobile.settings.resultHttpError': '后端返回错误状态码：{status}',
  'mobile.settings.resultTimeout': '后端无响应（超时），请确认服务是否正常',
  'mobile.settings.resultInvalidUrl': '请输入以 http:// 或 https:// 开头的完整地址',
  'mobile.settings.resultUnreachable': '无法连接。可能原因：地址填错、后端未启动、或 HTTPS 证书无效',
  'mobile.settings.logout': '登出',
  'mobile.settings.version': '版本',
```

在同文件的 `en` 对象中追加同名键：

```typescript
  'mobile.setup.title': 'Connect to your backend',
  'mobile.setup.description': 'Enter the address of your deployed backend, e.g. https://dsa.example.com',
  'mobile.setup.submit': 'Save and continue',
  'mobile.settings.title': 'Settings',
  'mobile.settings.serverSection': 'Server',
  'mobile.settings.serverUrlLabel': 'Backend URL',
  'mobile.settings.serverUrlPlaceholder': 'https://dsa.example.com',
  'mobile.settings.save': 'Save',
  'mobile.settings.testConnection': 'Test connection',
  'mobile.settings.testing': 'Testing…',
  'mobile.settings.resultOk': 'Connected',
  'mobile.settings.resultUnauthorized': 'Server reachable, but you are not signed in',
  'mobile.settings.resultHttpError': 'Backend returned status {status}',
  'mobile.settings.resultTimeout': 'The backend did not respond in time',
  'mobile.settings.resultInvalidUrl': 'Enter a full URL starting with http:// or https://',
  'mobile.settings.resultUnreachable': 'Cannot connect. Possible causes: wrong address, backend not running, or an invalid HTTPS certificate',
  'mobile.settings.logout': 'Sign out',
  'mobile.settings.version': 'Version',
```

> `UiTextKey = keyof typeof zh` 且 `UI_TEXT` 是 `Record<UiLanguage, Record<UiTextKey, string>>`，漏补 `en` 会直接编译失败。

- [ ] **Step 8: 写 MobileSettingsPage 的失败测试**

创建 `apps/dsa-web/src/pages/__tests__/MobileSettingsPage.test.tsx`：

```typescript
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import MobileSettingsPage from '../MobileSettingsPage';
import { UiLanguageProvider } from '../../contexts/UiLanguageContext';
import { getApiBaseUrl } from '../../utils/runtimeConfig';

vi.mock('../../utils/connectionCheck', () => ({
  checkConnection: vi.fn(),
}));

const { checkConnection } = await import('../../utils/connectionCheck');

const renderPage = () =>
  render(
    <UiLanguageProvider>
      <MemoryRouter>
        <MobileSettingsPage />
      </MemoryRouter>
    </UiLanguageProvider>,
  );

describe('MobileSettingsPage', () => {
  beforeEach(() => {
    localStorage.clear();
    vi.mocked(checkConnection).mockReset();
    // 保存地址后组件会调用 location.reload()，jsdom 未实现该方法会打印 "Not implemented" 噪音。
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...window.location, reload: vi.fn() },
    });
  });

  it('saves the entered address and applies it to the runtime config', async () => {
    const user = userEvent.setup();
    renderPage();

    const input = await screen.findByLabelText('后端地址');
    await user.clear(input);
    await user.type(input, 'https://dsa.example.com/');
    await user.click(screen.getByRole('button', { name: '保存' }));

    await waitFor(() => {
      expect(getApiBaseUrl()).toBe('https://dsa.example.com');
    });
  });

  it('shows a combined cause message when the server is unreachable', async () => {
    vi.mocked(checkConnection).mockResolvedValue({ kind: 'unreachable' });
    const user = userEvent.setup();
    renderPage();

    const input = await screen.findByLabelText('后端地址');
    await user.type(input, 'https://dsa.example.com');
    await user.click(screen.getByRole('button', { name: '连接测试' }));

    expect(
      await screen.findByText(/无法连接。可能原因：地址填错、后端未启动、或 HTTPS 证书无效/),
    ).toBeInTheDocument();
  });

  it('reports the status code for a non-401 HTTP error', async () => {
    vi.mocked(checkConnection).mockResolvedValue({ kind: 'httpError', status: 502 });
    const user = userEvent.setup();
    renderPage();

    const input = await screen.findByLabelText('后端地址');
    await user.type(input, 'https://dsa.example.com');
    await user.click(screen.getByRole('button', { name: '连接测试' }));

    expect(await screen.findByText(/502/)).toBeInTheDocument();
  });
});
```

> 若 `@testing-library/user-event` 尚未安装，先执行 `npm install -D @testing-library/user-event` 并把它加入 `apps/dsa-web/package.json` 的 `devDependencies`。

- [ ] **Step 9: 运行测试，确认失败**

```bash
cd apps/dsa-web && npx vitest run src/pages/__tests__/MobileSettingsPage.test.tsx
```

预期：FAIL，占位组件渲染的是空 `div`，找不到 `后端地址` 输入框。

- [ ] **Step 10: 实现 MobileSettingsPage**

把 `apps/dsa-web/src/pages/MobileSettingsPage.tsx` 整体替换为：

```typescript
import type React from 'react';
import { useCallback, useEffect, useState } from 'react';
import { useUiLanguage } from '../contexts/UiLanguageContext';
import { useAuth } from '../contexts/AuthContext';
import { checkConnection, type ConnectionResult } from '../utils/connectionCheck';
import { getApiBaseUrl, setApiBaseUrl } from '../utils/runtimeConfig';
import { loadServerAddress, saveServerAddress } from '../utils/serverAddressStore';
import { getWebBuildInfo } from '../utils/constants';

const MobileSettingsPage: React.FC = () => {
  const { t } = useUiLanguage();
  const { logout } = useAuth();
  const [address, setAddress] = useState('');
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState<ConnectionResult | null>(null);

  useEffect(() => {
    void loadServerAddress().then((stored) => {
      setAddress(stored || getApiBaseUrl());
    });
  }, []);

  const handleSave = useCallback(async () => {
    await saveServerAddress(address);
    setApiBaseUrl(address);
    // 换后端等于换会话：AuthProvider 只在挂载时取一次 auth 状态，
    // 不重载的话登录态会停留在旧后端的结果上。测试环境下 jsdom 未实现 reload，故做保护。
    if (typeof window !== 'undefined' && typeof window.location.reload === 'function') {
      window.location.reload();
    }
  }, [address]);

  const handleTest = useCallback(async () => {
    setTesting(true);
    try {
      setResult(await checkConnection(address));
    } finally {
      setTesting(false);
    }
  }, [address]);

  const describeResult = (value: ConnectionResult): string => {
    switch (value.kind) {
      case 'ok':
        return t('mobile.settings.resultOk');
      case 'unauthorized':
        return t('mobile.settings.resultUnauthorized');
      case 'httpError':
        return t('mobile.settings.resultHttpError').replace('{status}', String(value.status));
      case 'timeout':
        return t('mobile.settings.resultTimeout');
      case 'invalidUrl':
        return t('mobile.settings.resultInvalidUrl');
      case 'unreachable':
        return t('mobile.settings.resultUnreachable');
    }
  };

  return (
    <div className="flex flex-col gap-6 py-4">
      <h1 className="text-lg font-semibold">{t('mobile.settings.title')}</h1>

      <section className="flex flex-col gap-3">
        <h2 className="text-sm text-secondary-text">{t('mobile.settings.serverSection')}</h2>

        <label className="flex flex-col gap-1 text-sm" htmlFor="mobile-server-url">
          {t('mobile.settings.serverUrlLabel')}
        </label>
        <input
          id="mobile-server-url"
          type="url"
          inputMode="url"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          className="w-full rounded-xl border border-border/70 bg-card px-3 py-3 text-base"
          placeholder={t('mobile.settings.serverUrlPlaceholder')}
          value={address}
          onChange={(event) => setAddress(event.target.value)}
        />

        <div className="flex gap-2">
          <button type="button" className="btn-primary flex-1 py-3" onClick={() => void handleSave()}>
            {t('mobile.settings.save')}
          </button>
          <button
            type="button"
            className="btn-secondary flex-1 py-3"
            disabled={testing}
            onClick={() => void handleTest()}
          >
            {testing ? t('mobile.settings.testing') : t('mobile.settings.testConnection')}
          </button>
        </div>

        {result ? <p className="text-sm text-secondary-text">{describeResult(result)}</p> : null}
      </section>

      <section className="flex flex-col gap-3">
        <button type="button" className="btn-secondary py-3" onClick={() => void logout()}>
          {t('mobile.settings.logout')}
        </button>
        <p className="text-xs text-secondary-text">
          {t('mobile.settings.version')} {getWebBuildInfo().version}
        </p>
      </section>
    </div>
  );
};

export default MobileSettingsPage;
```

> 实现前先确认两件事，若与实际不符则按实际调整：
> 1. `useAuth()` 是否导出 `logout`。查 `apps/dsa-web/src/contexts/AuthContext.tsx`，若名称不同（如 `signOut`）按实际名称使用。
> 2. `apps/dsa-web/src/utils/constants.ts` 导出的构建信息函数名。若不是 `getWebBuildInfo`，按实际导出名调整；该文件已定义 `WebBuildInfo` 类型。
> 3. `btn-primary` / `btn-secondary` 类名是否都存在于 `App.css` / `index.css`。`btn-primary` 已在 `App.tsx` 中使用；若无 `btn-secondary`，改用已存在的等价类名。

- [ ] **Step 11: 运行测试，确认通过**

```bash
cd apps/dsa-web && npx vitest run src/pages/__tests__/MobileSettingsPage.test.tsx
```

预期：3 passed。

- [ ] **Step 12: 接入首启引导（必须在 AuthProvider 之外）**

> **关键约束：** `AuthProvider` 挂载时立即请求 `/api/v1/auth/status`。首次启动尚无服务器地址，该请求必然失败并让 `AppContent` 进入 `loadError` 分支，引导页永远没机会渲染。因此地址解析必须发生在 `AuthProvider` 挂载**之前**，不能放在 `MobileRouteTree` 里。
>
> `MobileRouteTree.tsx` 保持 Task 3 Step 5 的无状态版本，本步不修改它。

创建 `apps/dsa-web/src/components/layout/MobileBootstrap.tsx`：

```typescript
import type React from 'react';
import { useEffect, useState } from 'react';
import { PageLoadingFallback } from './RouteBoundary';
import { MobileServerSetup } from './MobileServerSetup';
import { setApiBaseUrl } from '../../utils/runtimeConfig';
import { loadServerAddress } from '../../utils/serverAddressStore';

type MobileBootstrapProps = {
  children: React.ReactNode;
};

/**
 * 在挂载 AuthProvider 之前解析后端地址。
 * 地址为空时先渲染引导页，避免 auth 状态请求打到空 baseURL 上直接失败。
 */
export const MobileBootstrap: React.FC<MobileBootstrapProps> = ({ children }) => {
  const [ready, setReady] = useState(false);
  const [needsSetup, setNeedsSetup] = useState(false);

  useEffect(() => {
    void loadServerAddress().then((stored) => {
      if (stored) {
        setApiBaseUrl(stored);
      } else {
        setNeedsSetup(true);
      }
      setReady(true);
    });
  }, []);

  if (!ready) {
    return <PageLoadingFallback />;
  }

  if (needsSetup) {
    return <MobileServerSetup onDone={() => setNeedsSetup(false)} />;
  }

  return <>{children}</>;
};
```

修改 `apps/dsa-web/src/App.tsx` 底部的 `App` 组件，把移动端的 bootstrap 包在 `AuthProvider` 外层。用下面的版本替换现有 `App`：

```typescript
const App: React.FC = () => {
  const tree = (
    <AuthProvider>
      <AppContent />
    </AuthProvider>
  );

  return (
    <UiLanguageProvider>
      <Router>
        {__APP_TARGET__ === 'mobile' ? <MobileBootstrap>{tree}</MobileBootstrap> : tree}
      </Router>
    </UiLanguageProvider>
  );
};
```

并在 `App.tsx` 顶部补 import：

```typescript
import { MobileBootstrap } from './components/layout/MobileBootstrap';
```

> 与路由树同理：这里直接比较构建期常量，Web 构建下 Rollup 会折叠分支并把 `MobileBootstrap` 整模块丢弃。

创建 `apps/dsa-web/src/components/layout/MobileServerSetup.tsx`：

```typescript
import type React from 'react';
import { useState } from 'react';
import { useUiLanguage } from '../../contexts/UiLanguageContext';
import { checkConnection } from '../../utils/connectionCheck';
import { setApiBaseUrl } from '../../utils/runtimeConfig';
import { saveServerAddress } from '../../utils/serverAddressStore';

type MobileServerSetupProps = {
  onDone: () => void;
};

export const MobileServerSetup: React.FC<MobileServerSetupProps> = ({ onDone }) => {
  const { t } = useUiLanguage();
  const [address, setAddress] = useState('');
  const [error, setError] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async () => {
    setSubmitting(true);
    setError('');
    try {
      const result = await checkConnection(address);
      // 401 表示地址可达但未登录，属于正常情况，放行到登录流程。
      if (result.kind !== 'ok' && result.kind !== 'unauthorized') {
        setError(
          result.kind === 'invalidUrl'
            ? t('mobile.settings.resultInvalidUrl')
            : t('mobile.settings.resultUnreachable'),
        );
        return;
      }
      await saveServerAddress(address);
      setApiBaseUrl(address);
      onDone();
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div
      className="flex min-h-screen flex-col justify-center gap-4 bg-background px-6 text-foreground"
      style={{ paddingTop: 'env(safe-area-inset-top)', paddingBottom: 'env(safe-area-inset-bottom)' }}
    >
      <h1 className="text-xl font-semibold">{t('mobile.setup.title')}</h1>
      <p className="text-sm text-secondary-text">{t('mobile.setup.description')}</p>

      <label className="text-sm" htmlFor="mobile-setup-url">
        {t('mobile.settings.serverUrlLabel')}
      </label>
      <input
        id="mobile-setup-url"
        type="url"
        inputMode="url"
        autoCapitalize="none"
        autoCorrect="off"
        spellCheck={false}
        className="w-full rounded-xl border border-border/70 bg-card px-3 py-3 text-base"
        placeholder={t('mobile.settings.serverUrlPlaceholder')}
        value={address}
        onChange={(event) => setAddress(event.target.value)}
      />

      {error ? <p className="text-sm text-danger">{error}</p> : null}

      <button
        type="button"
        className="btn-primary py-3"
        disabled={submitting}
        onClick={() => void handleSubmit()}
      >
        {submitting ? t('mobile.settings.testing') : t('mobile.setup.submit')}
      </button>
    </div>
  );
};
```

> `text-danger` 若不存在于样式表，改用项目中已有的错误色类名。

- [ ] **Step 13: 全量验证**

```bash
cd apps/dsa-web && npm run lint && npx vitest run && npm run build && npm run build:mobile
```

预期：lint 无错误；全部测试通过；两种构建均成功。

- [ ] **Step 14: Commit（需先向用户确认）**

```bash
git add apps/dsa-web/src/utils/serverAddressStore.ts apps/dsa-web/src/utils/connectionCheck.ts apps/dsa-web/src/utils/__tests__ apps/dsa-web/src/pages/MobileSettingsPage.tsx apps/dsa-web/src/pages/__tests__/MobileSettingsPage.test.tsx apps/dsa-web/src/components/layout/MobileServerSetup.tsx apps/dsa-web/src/components/layout/MobileBootstrap.tsx apps/dsa-web/src/App.tsx apps/dsa-web/src/i18n/uiText.ts apps/dsa-web/package.json
git commit -m "feat(web): add mobile settings page and first-run server setup"
```

---

### Task 6: Capacitor 壳工程与首个 APK

建立 `apps/dsa-mobile/`，生成 Android 工程并产出可安装的调试包。这是第一次能在真机上验证的节点。

> **实施中发现并已修正（三处）：**
>
> 1. **实际装到的是 Capacitor 8（不是计划假设的 7），它要求 `compileSdkVersion = targetSdkVersion = 36`**（见生成的 `android/variables.gradle`，`minSdkVersion = 24`）。因此 SDK 必须装 `platforms;android-36` 与 `build-tools;36.0.0`；只装 35 会构建失败。计划原文没写具体 API level 是对的（让 npm 解析版本），但排障文档里要写明「以 `variables.gradle` 的 `compileSdkVersion` 为准」。
> 2. **`capacitor.config.ts` 需要 `apps/dsa-mobile` 本地安装 `typescript`**，否则 `npx cap add android` 直接失败：`Could not find installation of TypeScript`。需 `npm install -D typescript`。
> 3. **SDK 不要装在 `C:\Program Files (x86)` 下。** 该目录需管理员权限，`sdkmanager` 安装组件与 `mv` 均会 `Permission denied`；且路径含空格与括号，对 Gradle 是已知风险。实测可用位置：`C:\Android\Sdk`。另外 cmdline-tools 必须落在 `<sdk>\cmdline-tools\latest\`，少这一层会报 `Could not determine SDK root`。
>
> **`android/local.properties`** 需写 `sdk.dir=C\:\\Android\\Sdk`（该文件已在 `.gitignore` 中，机器相关，不入库）。

**Files:**
- Create: `apps/dsa-mobile/package.json`
- Create: `apps/dsa-mobile/capacitor.config.ts`
- Create: `apps/dsa-mobile/.gitignore`
- Create: `apps/dsa-mobile/android/`（由 `npx cap add android` 生成，需入库）
- Modify: `.gitignore`（如需忽略 `apps/dsa-mobile/www`）

**Interfaces:**
- Consumes: Task 3 的 `build:mobile` 产物（`apps/dsa-mobile/www`）
- Produces: 可安装的 `app-debug.apk`

- [ ] **Step 1: 初始化壳工程依赖**

创建 `apps/dsa-mobile/package.json`：

```json
{
  "name": "daily-stock-analysis-mobile",
  "private": true,
  "version": "0.0.0",
  "scripts": {
    "sync": "cap sync android",
    "open": "cap open android"
  }
}
```

安装依赖（让 npm 解析实际可用版本，不要手写版本号）：

```bash
cd apps/dsa-mobile && npm install @capacitor/core@latest @capacitor/android@latest @capacitor/preferences@latest @capacitor/keyboard@latest && npm install -D @capacitor/cli@latest
```

- [ ] **Step 2: 写 Capacitor 配置**

创建 `apps/dsa-mobile/capacitor.config.ts`：

```typescript
import type { CapacitorConfig } from '@capacitor/cli';
import { KeyboardResize } from '@capacitor/keyboard';

const config: CapacitorConfig = {
  // Android 包名必须是合法 Java 包名，不能含连字符，
  // 因此与桌面端的 com.daily-stock-analysis.desktop 写法不同。
  appId: 'com.dailystockanalysis.mobile',
  appName: 'Daily Stock Analysis',
  webDir: 'www',
  server: {
    // 固定 WebView origin 为 https://localhost，与后端 CORS 白名单一致。
    // 切勿改为 'http'：Secure Cookie 将不再发送，认证会整体失效。
    androidScheme: 'https',
  },
  plugins: {
    Keyboard: {
      resize: KeyboardResize.Body,
    },
  },
  // 切勿启用 CapacitorHttp / CapacitorCookies。
  // 它们会 patch window.fetch 并整包缓冲响应，破坏对话页的 SSE 流式输出
  // （见 api/v1/endpoints/agent.py 的 StreamingResponse）。
};

export default config;
```

- [ ] **Step 3: 配置 gitignore**

创建 `apps/dsa-mobile/.gitignore`：

```
node_modules/
www/
android/app/build/
android/build/
android/.gradle/
android/local.properties
android/app/src/main/assets/public/
```

> `android/` 目录本身要入库（含 `AndroidManifest.xml`、Gradle 配置等），只忽略构建产物与本地环境文件。

- [ ] **Step 4: 生成 Android 工程**

```bash
cd apps/dsa-web && npm run build:mobile
cd ../dsa-mobile && npx cap add android
```

预期：`apps/dsa-mobile/android/` 被创建；命令输出中出现 `add in ... ✔`。

> `cap add` 要求 `webDir` 已存在，所以必须先跑 `build:mobile`。

- [ ] **Step 5: 同步产物并构建 APK**

```bash
cd apps/dsa-web && npm run build:mobile
cd ../dsa-mobile && npx cap sync android
cd android && ./gradlew.bat assembleDebug
```

预期：`apps/dsa-mobile/android/app/build/outputs/apk/debug/app-debug.apk` 生成，Gradle 输出 `BUILD SUCCESSFUL`。

> 需要本机已装 Android SDK 与 JDK 17。若 Gradle 报找不到 SDK，创建 `apps/dsa-mobile/android/local.properties` 写入 `sdk.dir=<你的 Android SDK 路径>`（该文件已在 gitignore 中）。

- [ ] **Step 6: 真机验证**

把 APK 安装到 Android 手机，逐项确认：

1. 首启出现服务器地址引导页
2. 填入公网 HTTPS 地址后能通过检测并进入 App
3. 能跳转登录页并成功登录（验证跨站 Cookie 生效 —— 这一步依赖 Task 1 的 `ADMIN_SESSION_COOKIE_SAMESITE=none` 已在后端配置）
4. 首页能加载并显示每日分析报告
5. **对话页发消息后是逐字流式输出，不是等待后一次性出现**（这是本期最大未知项，必须重点确认）
6. 底部 tab 栏不被手势导航条遮挡
7. 对话页输入框在键盘弹出时不被遮挡

任一项不通过则记录现象并停止，不要跳过继续。

- [ ] **Step 7: Commit（需先向用户确认）**

```bash
git add apps/dsa-mobile
git commit -m "feat(mobile): add Capacitor Android shell"
```

---

### Task 7: 对话页与首页的移动端适配

在真机验证暴露的问题基础上收敛移动端交互。键盘处理只在原生环境生效，Web 端不受影响。

**Files:**
- Modify: `apps/dsa-web/src/pages/ChatPage.tsx`
- Modify: `apps/dsa-web/src/pages/HomePage.tsx`（仅在真机验证发现窄屏排版问题时）

**Interfaces:**
- Consumes: Task 3 的 `IS_MOBILE_APP`；Task 6 的 `@capacitor/keyboard`
- Produces: 无对外接口

- [ ] **Step 1: 在 ChatPage 接入键盘事件**

在 `apps/dsa-web/src/pages/ChatPage.tsx` 中新增一个 effect。插入位置为组件内其他 `useEffect` 之后：

```typescript
  // 原生环境下键盘弹出会压缩视口，需要把消息列表重新滚到底部。
  // Android 只派发 keyboardDidShow / keyboardDidHide，没有 will* 事件。
  useEffect(() => {
    if (!IS_MOBILE_APP) {
      return undefined;
    }

    let disposers: Array<() => void> = [];
    let cancelled = false;

    void import('@capacitor/keyboard').then(({ Keyboard }) => {
      if (cancelled) {
        return;
      }
      const handles = [
        Keyboard.addListener('keyboardDidShow', () => scrollToBottom()),
        Keyboard.addListener('keyboardDidHide', () => scrollToBottom()),
      ];
      disposers = handles.map((handle) => () => {
        void handle.then((listener) => listener.remove());
      });
    });

    return () => {
      cancelled = true;
      disposers.forEach((dispose) => dispose());
    };
  }, []);
```

需要在文件顶部补 import：

```typescript
import { IS_MOBILE_APP } from '../appTarget';
```

> 实现前先查 `ChatPage.tsx` 中现有的滚动到底部逻辑，复用它而不是新写一个。若该函数名不是 `scrollToBottom`，按实际名称调整；若它不是稳定引用，需加入 effect 依赖数组。

- [ ] **Step 2: 验证 Web 端未受影响**

```bash
cd apps/dsa-web && npx vitest run src/pages/__tests__/ChatPage.test.tsx
```

预期：既有 ChatPage 测试全部通过（`IS_MOBILE_APP` 在测试环境为 `false`，effect 直接返回）。

- [ ] **Step 3: 重新构建并真机复验**

```bash
cd apps/dsa-web && npm run build:mobile
cd ../dsa-mobile && npx cap sync android && cd android && ./gradlew.bat assembleDebug
```

安装后确认：键盘弹出时输入框可见，且流式输出期间消息列表保持贴底。

- [ ] **Step 4: 按真机结果修正首页窄屏排版**

仅在 Task 6 Step 6 或本任务复验中发现具体问题时执行。常见项：
- Markdown 报告中的表格需要包在 `overflow-x-auto` 容器内
- 代码块需要 `overflow-x-auto` 而非换行
- 卡片在 <400px 宽度下的内边距过大

每修一处，重新构建并在真机确认。不要凭空预防性改动。

- [ ] **Step 5: 全量验证**

```bash
cd apps/dsa-web && npm run lint && npx vitest run && npm run build && npm run build:mobile
```

- [ ] **Step 6: Commit（需先向用户确认）**

```bash
git add apps/dsa-web/src/pages/ChatPage.tsx apps/dsa-web/src/pages/HomePage.tsx
git commit -m "fix(web): adapt chat and home pages for mobile viewport"
```

---

### Task 8: 文档同步

按 AGENTS.md 要求补齐用户可见能力变化对应的文档。

**Files:**
- Create: `docs/mobile-package.md`
- Modify: `docs/CHANGELOG.md`（`[Unreleased]` 段）
- Modify: `docs/DEPLOY.md`
- Modify: `docs/DEPLOY_EN.md`

**Interfaces:**
- Consumes: Task 1-7 的全部产出
- Produces: 无代码接口

- [ ] **Step 1: 写移动端构建文档**

创建 `docs/mobile-package.md`，对标 `docs/desktop-package.md` 的结构，覆盖：

- 前置要求：Node 20+、Android SDK、JDK 17
- 后端准备：必须有公网 HTTPS 入口；必须设置 `ADMIN_SESSION_COOKIE_SAMESITE=none`；必须开启 `ADMIN_AUTH_ENABLED`；不得启用 `CORS_ALLOW_ALL`
- 构建步骤：`npm run build:mobile` → `npx cap sync android` → `gradlew assembleDebug`
- 安装与首启配置服务器地址
- 已知限制：仅 Android；仅首页与对话两个功能；无原生推送，手机推送继续用 ntfy / Gotify / Pushover
- 排障：登录后立即 401 → 检查 `ADMIN_SESSION_COOKIE_SAMESITE` 与 HTTPS；对话不流式 → 确认未启用 `CapacitorHttp`

先读 `docs/desktop-package.md` 确认实际章节组织再动笔，保持两份文档结构一致。

- [ ] **Step 2: 更新 CHANGELOG**

在 `docs/CHANGELOG.md` 的 `[Unreleased]` 段追加（扁平格式，每条一行，不新增 `###` 标题）：

```
- [新功能] 新增 Android 移动端 App（Capacitor），支持每日分析报告与 AI 对话问股
- [新功能] Session Cookie 的 SameSite 支持通过 ADMIN_SESSION_COOKIE_SAMESITE 配置，供移动端跨站访问使用
- [改进] CORS 默认白名单加入 https://localhost，使 Capacitor 客户端开箱可用
- [文档] 新增 docs/mobile-package.md 说明移动端构建、部署要求与排障
```

- [ ] **Step 3: 更新部署文档**

在 `docs/DEPLOY.md` 与 `docs/DEPLOY_EN.md` 中补充「移动端接入」小节：公网 HTTPS 暴露方式（云服务器 / Cloudflare Tunnel / frp）、需要设置的三个环境变量、以及 `CORS_ALLOW_ALL=true` 会使 `allow_credentials=False` 从而与 Cookie 认证互斥这一坑点。

> AGENTS.md 要求：改中英双语文档之一时需评估另一份是否同步；此处两份都要改。

- [ ] **Step 4: 校验文档与实际一致**

```bash
python scripts/check_ai_assets.py
```

并人工核对文档中出现的每个命令、文件名、环境变量名与实际代码一致。

- [ ] **Step 5: Commit（需先向用户确认）**

```bash
git add docs/mobile-package.md docs/CHANGELOG.md docs/DEPLOY.md docs/DEPLOY_EN.md
git commit -m "docs: add mobile app build and deployment guide"
```

---

## 交付说明模板

按 AGENTS.md 第 9 节，最终交付需说明：改了什么、为什么这么改、验证情况、未验证项、风险点、回滚方式。

**已知未验证项（除非真机测试完成，否则必须如实列出）：**
- SSE 流式对话在具体 Android WebView 版本上的表现
- 不同厂商 ROM 的安全区与键盘行为差异
- iOS 完全未覆盖

**回滚方式：**
- 前端：`__APP_TARGET__` 默认为 `web`，不跑 `build:mobile` 即完全不受影响
- 后端：不设置 `ADMIN_SESSION_COOKIE_SAMESITE` 即回到 `lax` 原行为；CORS 白名单多一个 `https://localhost` 可单独 revert
- 移动端：删除 `apps/dsa-mobile/` 目录不影响其他任何客户端
