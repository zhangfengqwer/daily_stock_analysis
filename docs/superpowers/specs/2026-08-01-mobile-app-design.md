# 移动端 App 设计（Capacitor / Android）

- 日期：2026-08-01
- 状态：设计已确认，待转实施计划
- 范围：把 Web 端的「每日分析报告」和「AI 对话问股」两个功能带到 Android 手机上

## 1. 背景与目标

仓库当前有三个客户端形态：

- `apps/dsa-web/`：React 19 + Vite + Tailwind 4，8 个功能页
- `apps/dsa-desktop/`：Electron 薄壳，自己在本机 spawn 一个 Python 后端（`apps/dsa-desktop/main.js:938`，`--serve-only --host 127.0.0.1`）
- 无移动端

目标是新增 Android 客户端。手机上无法 spawn Python 后端，因此桌面端那套「壳内自带后端」的模式不适用，移动端必须连远程后端。

### 已确认的前置决策

| 项 | 决策 |
| --- | --- |
| 形态 | Capacitor 打包成 Android 安装包 |
| 平台 | 仅 Android（开发机为 Windows，iOS 构建需 macOS，本期不做） |
| 后端接入 | 公网入口 + HTTPS（云服务器或 Cloudflare Tunnel / frp 内网穿透） |
| 功能范围 | 首页 / 每日分析报告、AI 对话问股，两个功能 |
| 原生推送 | 本期不做。`src/notification_sender/` 已有 ntfy / gotify / pushover 三个自带手机 App 的推送渠道，继续复用 |

## 2. 关键约束

### 2.1 对话页是 SSE 流式输出

- 前端：`apps/dsa-web/src/api/agent.ts:93` 用原生 `fetch` + `credentials: 'include'` 读流，返回 `Response` 交给调用方消费流体
- 后端：`api/v1/endpoints/agent.py:458` 返回 `StreamingResponse(media_type="text/event-stream")`

这一条否掉了 Capacitor 最常见的做法：启用 `CapacitorHttp` 原生 HTTP 层。该插件会 patch `window.fetch` 并整包缓冲响应，流式对话会退化成「长时间无响应后一次性吐出全文」。因为对话是本期两个功能之一，此路不通。

### 2.2 跨站 Cookie

Capacitor 中 WebView 的 origin 是 `https://localhost`，后端在公网域名上，属于跨站。而 session cookie 当前是 `samesite="lax"`（`api/v1/endpoints/auth.py:90`，cookie 名 `dsa_session`，见 `src/auth.py:27`），跨站请求不会携带。故障表现是登录成功但后续每个请求 401。

### 2.3 Web 构建产物目录被占用

`apps/dsa-web/vite.config.ts:117` 的 `build.outDir` 指向仓库根的 `static/`，由 FastAPI 托管。移动端构建必须走独立输出目录，否则两边互相覆盖。

### 2.4 无安全区处理

`apps/dsa-web/index.html:6` 的 viewport 没有 `viewport-fit=cover`，且全仓库没有任何 `env(safe-area-inset-*)` 处理。Android 手势导航下底部内容会被遮挡。

## 3. 方案选型

### 3.1 网络层（已选：标准 WebView + 后端放开跨站 Cookie）

| 方案 | 做法 | 结论 |
| --- | --- | --- |
| 启用 `CapacitorHttp` | 走原生网络栈，绕开 CORS 与 SameSite，后端零改动 | 否决，破坏 SSE 流式对话（见 2.1） |
| **标准 WebView + 后端放开跨站 Cookie** | `CORS_ORIGINS` 增加 `https://localhost`；cookie `samesite` 改为可配置项 | **采用** |
| 改 token / Bearer 认证 | 移动端不依赖 cookie | 否决，动的是认证契约本身，web 与 desktop 都需回归，本期不值得 |

采用理由：保住流式对话；后端改动是新增配置项而非改默认行为，符合仓库「不配置也可运行，配置后增强能力」的约定。

### 3.2 资源加载与后端地址（已选：本地打包 + 运行时可配置）

| 方案 | 做法 | 结论 |
| --- | --- | --- |
| **本地打包资源 + 运行时可配置地址** | `webDir` 指向 mobile 构建产物，首启引导填地址，存 Capacitor Preferences | **采用** |
| 本地打包 + 构建期写死 `VITE_API_URL` | 最省事 | 否决，换地址需重新出包，且违反仓库「不写死路径 / 环境差异」 |
| Capacitor `server.url` 远程加载 | 改 web 立即生效 | 否决，冷启动全靠网络，断网无法启动；退化为 PWA，Capacitor 失去意义 |

## 4. 架构设计

### 4.1 目录与构建

`apps/dsa-mobile/` 只做 Capacitor 壳，不放 UI —— 与 `dsa-desktop` 一致的模式（桌面壳同样只有 `main.js` / `preload.js`，UI 全在 `dsa-web`），符合 AGENTS.md 的目录边界约定。

```
apps/dsa-mobile/
  capacitor.config.ts   # appId / appName / webDir
  package.json          # @capacitor/{core,cli,android,preferences,keyboard}
  android/              # Capacitor 生成的 Gradle 工程
  www/                  # dsa-web 的 mobile 构建产物，gitignore
```

`capacitor.config.ts` 的确定项：

- `appId`：`com.daily-stock-analysis.mobile`（对齐桌面端的 `com.daily-stock-analysis.desktop`）
- `webDir`：`www`
- `server.androidScheme`：`https`。必须显式设定，使 WebView origin 稳定为 `https://localhost`；若为 `http`，`Secure` cookie 不会被发送，认证链路会断
- 不启用 `CapacitorHttp` / `CapacitorCookies` 插件。原因见 2.1，此处需在配置中明确注释，避免后续被当作「优化」误开

`apps/dsa-web/vite.config.ts` 按 Vite mode 切换 `outDir`，mobile 构建走 `vite build --mode mobile`：

- 默认模式：仍输出 `../../static`，行为零变化
- `mobile` 模式：输出 `../dsa-mobile/www`

平台标识通过 `vite.config.ts` 已有的 `define` 机制注入为构建期常量 `__APP_TARGET__`（与现有 `__APP_PACKAGE_VERSION__`、`__APP_BUILD_TIME__` 同一套写法），而非运行时读 `import.meta.env`——常量折叠才能让未注册的页面被 tree-shake。

`apps/dsa-web/package.json` 新增 `build:mobile` 脚本。

### 4.2 路由与导航

按构建期常量 `__APP_TARGET__` 做分支。未注册的 `lazy()` 页面会被 Vite tree-shake，APK 不会带上选股 / 持仓 / 回测等页面的代码。

| 路由 | 页面 | 来源 |
| --- | --- | --- |
| `/` | HomePage | 复用 |
| `/chat` | ChatPage | 复用 |
| `/settings` | MobileSettingsPage | 新增，极简 |
| `/login` | LoginPage | 复用，后端开启 auth 时刚性需要 |
| `*` | 重定向到 `/` | 移动端不做 NotFound 页 |

导航新增 `MobileTabBar`（底部 3 tab：首页 / 对话 / 设置），替代 `Shell` 的桌面侧边栏与移动抽屉（`apps/dsa-web/src/components/layout/Shell.tsx:40`）。移动端使用独立的 tab 定义，不复用 `SidebarNav.tsx:30` 的 `NAV_ITEMS`（那份含 8 个桌面入口）。

`MobileSettingsPage` 只包含：服务器地址、连接测试、登出、版本号。不复用现有 `SettingsPage`（984 行，含 LLM 配置、通知渠道、数据源，按桌面设计）。

### 4.3 后端地址：运行时可配置

新增 `apps/dsa-web/src/utils/runtimeConfig.ts`，暴露 `getApiBaseUrl()` / `setApiBaseUrl(url)`，默认值取现有 `API_BASE_URL`。Web 端默认仍是空字符串（同源），行为零变化。移动端在启动时从 `@capacitor/preferences` 读入并注入 `apiClient.defaults.baseURL`。

需要改造的读取点：

| 位置 | 改动 |
| --- | --- |
| `apps/dsa-web/src/utils/constants.ts:11` | 保留常量，降级为默认值 |
| `apps/dsa-web/src/api/index.ts:6` | `baseURL` 改为启动时注入 |
| `apps/dsa-web/src/api/agent.ts:90` | 流式 URL 改读 `getApiBaseUrl()` |
| `apps/dsa-web/src/api/analysis.ts:182` | 已读 `apiClient.defaults.baseURL`，自动跟随，无需改动 |

启动顺序：地址未配置则进引导页；已配置则正常进入 `AuthProvider`。

### 4.4 认证：跨站 Cookie

后端两处改动，均为新增配置项：

1. `CORS_ORIGINS` 增加 `https://localhost`。纯配置，`api/app.py:243` 已支持从环境变量追加来源。
   - 注意：`api/app.py:248` 的 `CORS_ALLOW_ALL=true` 会使 `allow_credentials=False`，与 cookie 认证互斥，移动端场景下不可启用。
2. 新增环境变量 `ADMIN_SESSION_COOKIE_SAMESITE`，默认 `lax`。`api/v1/endpoints/auth.py:90` 读取该值；取值为 `none` 时强制 `secure=True`（浏览器硬性要求）。

未设置该变量时，Web 与 Desktop 行为完全不变。

按 AGENTS.md 要求，需同步更新 `.env.example`、相关 `docs/*.md` 与 `docs/CHANGELOG.md`。

### 4.5 移动端 UI 适配

- `apps/dsa-web/index.html:6` viewport 增加 `viewport-fit=cover`
- 安全区：`MobileTabBar` 与顶部区域加 `env(safe-area-inset-*)` 内边距
- ChatPage：接入 `@capacitor/keyboard` 处理输入框被键盘顶起；流式输出期间保持贴底滚动
- HomePage：Markdown 报告的窄屏排版、代码块横向滚动

## 5. 错误处理

设置页的「连接测试」请求 `/api/v1/health`。填错地址是这个 App 最高频的故障路径，必须给出可操作的提示，而不是统一报「网络错误」。

但要明确一个平台限制：**WebView 的 `fetch` 无法区分 DNS 失败、TLS 证书错误和 CORS 拒绝**，三者一律抛 `TypeError: Failed to fetch`，出于安全设计不暴露细节。因此实际能可靠区分的只有下面四类：

| 情况 | 判定依据 | 提示方向 |
| --- | --- | --- |
| 地址格式非法 | 提交前用 `URL` 构造校验 | 需以 `http://` 或 `https://` 开头的完整地址 |
| 超时 | `AbortController` 触发 | 后端可达但无响应 |
| 收到 HTTP 响应 | 拿到 status | 按 status 区分：200 正常；401 地址对但未登录；4xx/5xx 报出具体状态码 |
| 请求未能发出 | `TypeError` | 合并提示，列出三种可能原因：地址错误 / 后端未启动 / HTTPS 证书无效。**不谎称能定位到具体某一种** |

其余：

- 401 走现有拦截器（`apps/dsa-web/src/api/index.ts`）。Capacitor 下 SPA 跑在 `https://localhost/`，`window.location.assign('/login')` 行为正常。
- 流式中断复用 ChatPage 现有逻辑，补充断网提示。

## 6. 测试策略

| 层 | 内容 |
| --- | --- |
| 后端单测 | cookie samesite 配置：默认 `lax`；设为 `none` 时强制 `secure=True` |
| 前端单测 | `runtimeConfig` 的默认值、读写、与 `apiClient.defaults.baseURL` 的同步 |
| 前端组件测试 | `MobileTabBar`、`MobileSettingsPage`（vitest 已配置） |
| 构建验证 | mobile 构建产出到 `apps/dsa-mobile/www`；确认 web 构建的 `static/` 输出未受影响 |
| 真机验证 | Android 上跑通：填地址 → 登录 → 查看每日分析报告 → 流式对话不中断 |

## 7. 风险

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| `SameSite=None` 削弱 Web 端 CSRF 防护 | 已与用户确认并接受 | 写操作均为 `application/json` POST，会触发预检；CORS 白名单是具体域名而非 `*`。该项默认关闭，仅自建者显式开启 |
| SSE 在 Android WebView 上的行为差异 | 不同 WebView 版本对流式响应的缓冲策略不同，无法靠代码审查提前排除 | 必须真机验证。这是本期最大未知项 |
| `static/` 目录冲突 | Web 与 mobile 构建产物互相覆盖 | mobile 走独立 `outDir` |
| 公网暴露后端 | 后端从局域网走向公网 | 必须开启 `ADMIN_AUTH_ENABLED`；不得启用 `CORS_ALLOW_ALL` |

## 8. 明确不在本期范围

- iOS 构建与上架
- 原生推送（FCM / APNs）与推送深链
- 选股、持仓、回测、告警中心、Token 用量、完整设置页
- 离线缓存与后台刷新
- 应用商店发布流程

## 9. 交付后需同步的文档

- `.env.example`：新增 `ADMIN_SESSION_COOKIE_SAMESITE`
- `docs/CHANGELOG.md`：`[Unreleased]` 扁平格式追加条目
- 移动端构建与安装说明（新增文档，对标 `docs/desktop-package.md`）
- `docs/DEPLOY.md` / `DEPLOY_EN.md`：公网 HTTPS 暴露与 CORS 配置说明
