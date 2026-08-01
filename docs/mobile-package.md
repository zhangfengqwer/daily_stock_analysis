# 移动端打包说明 (Capacitor + Android)

## 架构说明

移动端沿用桌面端的分层方式：**壳工程不含 UI**。

- `apps/dsa-mobile/`：Capacitor 壳。只有 `capacitor.config.ts` 与 `android/` 原生工程，不写业务代码。
- `apps/dsa-web/`：全部 UI。通过新增的 `mobile` 构建模式产出精简路由的产物，输出到 `apps/dsa-mobile/www`。
- 后端：复用现有 FastAPI 服务，**必须部署在有 HTTPS 的公网入口上**（原因见下）。

与桌面端的关键差异：桌面端 Electron 会在本机 spawn 一个 Python 后端（`apps/dsa-desktop/main.js`），手机上无法这样做，因此移动端必须连远程后端。

### 功能范围

移动端只开放两个功能，导航为底部三个 tab：

| 路由 | 页面 |
| --- | --- |
| `/` | 首页 / 每日分析报告 |
| `/chat` | AI 对话问股 |
| `/settings` | 精简设置（服务器地址、连接测试、登出、版本号） |
| `/login` | 登录（后端开启认证时刚性需要） |

选股、持仓、回测、告警中心、Token 用量、完整设置页不在移动端构建内，其代码会被 Rollup 裁剪掉，不进入 APK。

---

## 一、后端准备（必读）

移动端对后端有三项**硬性**要求，不满足会直接不可用。

### 为什么必须是 HTTPS

Capacitor 中 WebView 的 origin 固定为 `https://localhost`（由 `capacitor.config.ts` 的 `androidScheme: 'https'` 决定）。后端在公网域名上，对浏览器而言属于**跨站**请求。

跨站携带 Cookie 要求 `SameSite=None`，而浏览器强制规定 `SameSite=None` 必须搭配 `Secure` —— `Secure` 只在 HTTPS 下生效。因此 HTTP 部署下手机端的表现是：**登录看起来成功，随后每个请求都返回 401**。

### 必需的 `.env` 配置

```bash
ADMIN_AUTH_ENABLED=true
ADMIN_SESSION_COOKIE_SAMESITE=none
TRUST_X_FORWARDED_FOR=true
```

- `ADMIN_SESSION_COOKIE_SAMESITE=none`：放开跨站 Cookie。默认值是 `lax`，不设置则 Web 与桌面端行为完全不变。设为 `none` 时后端会强制 `Secure`。
- `TRUST_X_FORWARDED_FOR=true`：反向代理场景下用于识别真实客户端 IP，否则登录限流会退化。适用于**单层可信反代**（Caddy/Nginx → App）。
- `CORS_ORIGINS` **无需配置**：`https://localhost` 已在 `api/app.py` 的默认白名单中。

> ⚠️ **绝对不要设 `CORS_ALLOW_ALL=true`。** 该开关会令 `allow_credentials=False`，与 Cookie 认证互斥，等同于关闭认证链路。

> ⚠️ **安全权衡：**`SameSite=None` 会削弱浏览器端的 CSRF 防护。缓解措施是所有写操作均为 `application/json` 的 POST（会触发预检），且 CORS 白名单是具体域名而非 `*`。请勿在 `ADMIN_AUTH_ENABLED=false` 时开启此项。

### Linux 服务器部署步骤

以「云服务器 + 公网 IP + 自有域名」为例。基础部署沿用 [DEPLOY.md](DEPLOY.md)，此处只列移动端相关的增量。

**1. 部署后端**

```bash
curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER
```

```bash
git clone <your-repo-url> /opt/stock-analyzer && cd /opt/stock-analyzer && cp .env.example .env
```

编辑 `.env`，填入 API Key 等常规配置，并加入上面那三项。

**2. 让后端只监听本机**

反代会在前面转发，容器端口不应直接暴露到公网。修改 `docker/docker-compose.yml` 的 `server` 服务：

```yaml
    ports:
      - "127.0.0.1:${API_PORT:-8000}:${API_PORT:-8000}"
```

```bash
docker compose -f ./docker/docker-compose.yml up -d server
```

**3. 用 Caddy 终止 TLS**

选 Caddy 而非 Nginx + certbot：证书申请、续期与 HTTP 跳转全自动。

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
```

`/etc/caddy/Caddyfile`：

```
dsa.your-domain.com {
	reverse_proxy 127.0.0.1:8000 {
		# 对话页是 SSE 流式输出，必须关闭响应缓冲，
		# 否则会憋到整段生成结束才一次性返回。
		flush_interval -1
	}
}
```

```bash
sudo systemctl reload caddy
```

**4. DNS 与防火墙**

- 添加 A 记录指向服务器公网 IP。
- **若使用 Cloudflare，该子域名建议设为「DNS only」（灰色云朵）而非代理模式。** Cloudflare 免费版代理对流式响应存在缓冲行为并有约 100 秒空闲超时，可能截断长时间的 LLM 分析，或使流式输出退化为一次性返回。代价是暴露源站 IP；若必须启用代理，需自行验证 SSE 在代理下的实际表现。
- 云服务器安全组放行 **80** 与 **443**。80 不可省略，Let's Encrypt 签发与续期需要。8000 无需放行。

**5. 验证**

```bash
curl -i https://dsa.your-domain.com/api/v1/health
```

确认 Cookie 属性（这一步最关键）：

```bash
curl -si -X POST https://dsa.your-domain.com/api/v1/auth/login \
  -H 'Content-Type: application/json' -d '{"password":"<你的密码>"}' | grep -i set-cookie
```

响应中必须**同时**出现 `SameSite=None` 与 `Secure`。缺任意一项，移动端都会在登录后立即 401。

---

## 二、构建前置条件

| 依赖 | 要求 | 说明 |
| --- | --- | --- |
| Node.js | >= 20.19.0, < 27 | 见 `apps/dsa-web/package.json` 的 `engines` |
| JDK | 17 或 21 | Gradle 与 AGP 需要 |
| Android SDK | 见下 | `platform-tools`、`platforms;android-36`、`build-tools;36.0.0` |

### Android SDK 安装注意事项

**SDK 目录不要放在 `C:\Program Files` 或 `C:\Program Files (x86)` 下**（Windows）。该位置需要管理员权限，`sdkmanager` 安装组件时会 `Permission denied`；且路径含空格与括号，对 Gradle 是已知风险来源。推荐 `C:\Android\Sdk`；Linux/macOS 推荐 `~/Android/Sdk`。

**cmdline-tools 必须位于 `<sdk>/cmdline-tools/latest/`。** 官方压缩包解压后根目录就叫 `cmdline-tools`，直接解压会少一层，导致：

```
Error: Could not determine SDK root.
Error: Either specify it explicitly with --sdk_root= or move this package into
its expected location: <sdk>\cmdline-tools\latest\
```

正确布局应为 `<sdk>/cmdline-tools/latest/bin/sdkmanager`。

**安装组件**（API level 以 `apps/dsa-mobile/android/variables.gradle` 中的 `compileSdkVersion` 为准，当前 Capacitor 8 要求 36）：

```bash
export ANDROID_HOME=~/Android/Sdk
yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses
$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --install "platform-tools" "platforms;android-36" "build-tools;36.0.0"
```

**Gradle 需要知道 SDK 路径。** 创建 `apps/dsa-mobile/android/local.properties`（该文件机器相关，已在 `.gitignore` 中，不入库）：

```properties
sdk.dir=/home/<user>/Android/Sdk
```

Windows 下需转义：`sdk.dir=C\:\\Android\\Sdk`

---

## 三、构建 APK

首次执行前需安装壳工程依赖：

```bash
cd apps/dsa-mobile && npm install
```

> `capacitor.config.ts` 是 TypeScript 配置，Capacitor CLI 要求本地存在 `typescript`，否则 `cap` 命令会直接失败并提示 `Could not find installation of TypeScript`。该依赖已在 `package.json` 的 `devDependencies` 中。

完整流程：

```bash
cd apps/dsa-web && npm run build:mobile
cd ../dsa-mobile && npx cap sync android
cd android && ./gradlew assembleDebug
```

Windows 使用 `./gradlew.bat assembleDebug`。

产物路径：

```
apps/dsa-mobile/android/app/build/outputs/apk/debug/app-debug.apk
```

> **首次构建会下载 Gradle 发行版与全部 AGP 依赖，耗时可能超过 10 分钟**，属正常现象。

### 关于构建目录

`apps/dsa-web` 的 `mobile` 模式输出到 `apps/dsa-mobile/www`，与 Web 模式的 `static/` 完全分离，两者不会互相覆盖。切勿把两个模式指向同一目录。

---

## 四、安装与首次配置

1. 将 `app-debug.apk` 传到手机并安装（需允许「安装未知来源应用」）。
2. 首次启动会进入服务器地址引导页，填入后端地址，例如 `https://dsa.your-domain.com`。
3. 地址通过连通性检测后进入应用；若后端已开启认证，会跳转登录页。
4. 之后可在「设置」tab 修改服务器地址、做连接测试或登出。修改地址并保存后应用会自动重载，以便重新获取登录态。

服务器地址持久化在 Capacitor 的 Preferences 中（Web 与测试环境降级到 `localStorage`）。

---

## 五、目录结构

```
apps/dsa-mobile/
  capacitor.config.ts   # appId / appName / webDir / androidScheme / 插件配置
  package.json          # @capacitor/{core,cli,android,preferences,keyboard} + typescript
  android/              # cap add android 生成的 Gradle 工程，入库
    variables.gradle    # compileSdkVersion / targetSdkVersion / minSdkVersion
    local.properties    # SDK 路径，机器相关，不入库
  www/                  # dsa-web 的 mobile 构建产物，不入库
```

`android/` 目录本身需要入库（含 `AndroidManifest.xml`、Gradle 配置等），仅忽略构建产物与本地环境文件。

---

## 六、已知限制

- **仅 Android。** iOS 未纳入本期范围；在 Windows 上也无法构建 iOS，需要 macOS 与 Apple Developer 账号。
- **无原生推送。** 未接入 FCM / APNs。手机推送继续使用 `src/notification_sender/` 中已有的 ntfy / Gotify / Pushover 渠道，它们各自带有手机客户端。
- **移动端只有首页与对话两个功能**，其余功能请使用 Web 或桌面端。
- **必须能访问后端。** 应用不做离线缓存，断网时无法查看历史报告。

---

## 七、常见问题

### 登录后立即 401 / 反复跳回登录页

跨站 Cookie 未生效。依次检查：

1. 后端 `.env` 是否设置 `ADMIN_SESSION_COOKIE_SAMESITE=none`
2. 后端是否通过 **HTTPS** 对外提供服务（`SameSite=None` 必须搭配 `Secure`）
3. 是否误设了 `CORS_ALLOW_ALL=true`（会导致 `allow_credentials=False`）
4. 用 `curl -si ... /api/v1/auth/login | grep -i set-cookie` 确认响应同时含 `SameSite=None` 与 `Secure`

### 对话不是逐字输出，而是等很久后一次性出现

SSE 流式响应在链路上被缓冲。依次检查：

1. `capacitor.config.ts` 中**是否误启用了 `CapacitorHttp` 或 `CapacitorCookies`**。这两个插件会 patch `window.fetch` 并整包缓冲响应，直接破坏流式对话。本项目刻意不启用它们，配置文件中有对应注释说明。
2. 反向代理是否关闭了缓冲。Caddy 需 `flush_interval -1`；Nginx 需 `proxy_buffering off;`。
3. 是否经过 Cloudflare 代理（橙色云朵）。建议改为 DNS only。

### 连接测试报「无法连接」但地址看起来没问题

WebView 的 `fetch` 对 DNS 失败、TLS 证书错误与 CORS 拒绝一律抛 `TypeError`，出于安全设计不暴露区分信息，因此应用无法定位到具体某一种原因。请在电脑上用 `curl -i <你的地址>/api/v1/health` 复现，以获取真实错误。

### `cap add android` 报 `Could not find installation of TypeScript`

在 `apps/dsa-mobile` 下执行 `npm install`，确保本地安装了 `typescript`。

### Gradle 报找不到 Android SDK

创建 `apps/dsa-mobile/android/local.properties` 并写入 `sdk.dir`，见「构建前置条件」一节。

### Gradle 报 `Could not move temporary workspace ... to immutable location`

Gradle 把 transforms 缓存的临时目录原子重命名到最终位置时失败。Windows 上的典型原因是**杀毒软件实时扫描**正在占用刚写入的文件句柄（Windows Defender 即会触发）。

先清理残留的临时目录再重试（目标目录通常并不存在，残留的是带 UUID 后缀的临时目录）：

```powershell
Remove-Item -Recurse -Force "$env:USERPROFILE\.gradle\caches\*\transforms\*-*-*-*-*"
```

若反复出现，需在**管理员权限**的 PowerShell 中为 Gradle 缓存与项目目录添加杀软排除项：

```powershell
Add-MpPreference -ExclusionPath "$env:USERPROFILE\.gradle"
Add-MpPreference -ExclusionPath "<项目绝对路径>"
Add-MpPreference -ExclusionProcess "java.exe"
```

> 排除项会降低对应目录的实时防护强度，属于开发机常规做法，请按自身安全要求评估。

### Gradle 发行版下载极慢

`gradle-wrapper.properties` 中的 `distributionUrl` 指向 `services.gradle.org`，国内访问可能只有几十 KB/s（实测 40 分钟仅下载 35MB / 214MB）。

**不要修改 `gradle-wrapper.properties`**（该文件入库，写死区域性镜像会影响所有人）。改为手动把发行版放进 wrapper 缓存：

```bash
# 目录名中的 hash 由 distributionUrl 推导，以本机实际存在的为准
D=~/.gradle/wrapper/dists/gradle-<版本>-all/<hash>
rm -f "$D"/*.zip.part "$D"/*.zip.lck
curl -L -o "$D/gradle-<版本>-all.zip" https://mirrors.cloud.tencent.com/gradle/gradle-<版本>-all.zip
```

Maven 依赖同理，镜像配置应放在**用户级** `~/.gradle/init.gradle`，而非项目内。

### Gradle 报 compileSdk 版本不匹配

以 `apps/dsa-mobile/android/variables.gradle` 中的 `compileSdkVersion` 为准，用 `sdkmanager` 安装对应的 `platforms;android-<N>` 与 `build-tools;<N>.0.0`。Capacitor 大版本升级时该值会变化。
