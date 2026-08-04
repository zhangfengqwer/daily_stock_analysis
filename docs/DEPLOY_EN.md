# Deployment Guide

This document explains how to deploy the AI Stock Analysis System to a server.

## Deployment Options Comparison

| Option | Pros | Cons | Recommended For |
|------|------|------|----------|
| **Docker Compose** ⭐ | One-click deploy, isolated environment, easy migration, easy upgrade | Requires Docker installation | **Recommended**: Most scenarios |
| **Direct Deployment** | Simple, no extra dependencies | Environment dependencies, migration difficulties | Temporary testing |
| **Systemd Service** | System-level management, auto-start on boot | Complex configuration | Long-term stable operation |
| **Supervisor** | Process management, auto-restart | Requires additional installation | Multi-process management |

**Conclusion: Docker Compose is recommended for the fastest and most convenient migration!**

---

## Option 1: Docker Compose Deployment (Recommended)

### 1. Install Docker

```bash
# Ubuntu/Debian
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# CentOS
sudo yum install -y docker docker-compose
sudo systemctl start docker
sudo systemctl enable docker
```

### 2. Prepare Configuration Files

```bash
# Clone code (or upload code to server)
git clone <your-repo-url> /opt/stock-analyzer
cd /opt/stock-analyzer

# Copy and edit configuration file
cp .env.example .env
vim .env  # Fill in real API Keys and configuration
```

### 3. One-Click Start

```bash
# Build and start
docker-compose -f ./docker/docker-compose.yml up -d

# View logs
docker-compose -f ./docker/docker-compose.yml logs -f

# View running status
docker-compose -f ./docker/docker-compose.yml ps
```

### 4. Common Management Commands

```bash
# Stop services
docker-compose -f ./docker/docker-compose.yml down

# Restart services
docker-compose -f ./docker/docker-compose.yml restart

# Redeploy after code update
git pull
docker-compose -f ./docker/docker-compose.yml build --no-cache
docker-compose -f ./docker/docker-compose.yml up -d

# Enter container for debugging
docker-compose -f ./docker/docker-compose.yml exec -u dsa stock-analyzer bash

# Manually run analysis once
docker-compose -f ./docker/docker-compose.yml exec -u dsa stock-analyzer python main.py --no-notify
```

### 4.1 One-command Linux update

The repository-root `install.sh` updates an existing Linux Docker deployment to `main`, preserves a server-local `docker/docker-compose.yml` override, rebuilds `server`, and checks local/public health endpoints:

```bash
cd /opt/stock-analyzer
DOMAIN=vpn.zfzyy.top bash install.sh
```

The script uses its own repository directory as `PROJECT_DIR` and deploys `main` by default. `DOMAIN` is intentionally not hard-coded; when set, it enables checks for the matching Caddy site and public health endpoint. When running the script from outside the checkout, pass both values explicitly:

```bash
PROJECT_DIR=/opt/stock-analyzer DOMAIN=dsa.example.com bash /path/to/install.sh
```

Docker cache is reused by default. For a full rebuild while diagnosing cache problems:

```bash
BUILD_NO_CACHE=1 bash install.sh
```

The script does not edit `.env` or the Caddyfile. It warns about missing Android authentication settings or `flush_interval -1`. If `.env` is absent, it creates one from `.env.example`, stops, and waits for configuration before the next run.

### 5. Data Persistence

Data is automatically saved to host directories:
- `./data/` - Database files
- `./logs/` - Log files
- `./reports/` - Analysis reports

### 6. Permissions

The Docker image startup entrypoint automatically creates and fixes ownership for the mounted `./data`, `./logs`, and `./reports` directories, then drops privileges to the non-root `dsa` user (UID 1000). Normal deployments do not require manual host-side `chown` / `chmod`.

If you explicitly set `--user` / Compose `user:`, or use read-only mounts, rootless Docker, NFS, or another environment that prevents the container from fixing ownership, make sure the actual runtime user can write to these directories.

---

## Option 2: Direct Deployment

### 1. Install Python Environment

```bash
# Install Python 3.10+
sudo apt update
sudo apt install -y python3.10 python3.10-venv python3-pip

# Create virtual environment
python3.10 -m venv /opt/stock-analyzer/venv
source /opt/stock-analyzer/venv/bin/activate
```

### 2. Install Dependencies

```bash
cd /opt/stock-analyzer
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

### 3. Configure Environment Variables

```bash
cp .env.example .env
vim .env  # Fill in configuration
```

### 4. Run

```bash
# Single run
python main.py

# Scheduled task mode (foreground)
python main.py --schedule

# Background run (using nohup)
nohup python main.py --schedule > /dev/null 2>&1 &
```

---

## Option 3: Systemd Service

Create systemd service file for auto-start on boot and auto-restart:

### 1. Create Service File

```bash
sudo vim /etc/systemd/system/stock-analyzer.service
```

Contents:
```ini
[Unit]
Description=AI Stock Analysis System
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/stock-analyzer
Environment="PATH=/opt/stock-analyzer/venv/bin"
ExecStart=/opt/stock-analyzer/venv/bin/python main.py --schedule
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

### 2. Start Service

```bash
# Reload configuration
sudo systemctl daemon-reload

# Start service
sudo systemctl start stock-analyzer

# Enable auto-start on boot
sudo systemctl enable stock-analyzer

# View status
sudo systemctl status stock-analyzer

# View logs
journalctl -u stock-analyzer -f
```

---

## Configuration Guide

### Required Configuration

| Config Item | Description | How to Get |
|--------|------|----------|
| `ANSPIRE_API_KEYS` / `AIHUBMIX_KEY` / `GEMINI_API_KEY` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | Configure at least one AI model key; Anspire or AIHubMix is recommended first | Provider console |
| `STOCK_LIST` | Watchlist | Comma-separated stock codes |
| Notification channel | Configure at least one, such as WeChat Work, Feishu, Telegram, or email | Notification provider |

### Optional Configuration

| Config Item | Default | Description |
|--------|--------|------|
| `SCHEDULE_ENABLED` | `false` | Enable scheduled tasks |
| `SCHEDULE_TIME` | `18:00` | Daily execution time |
| `MARKET_REVIEW_ENABLED` | `true` | Enable market review |
| `ANSPIRE_API_KEYS` | - | Anspire LLM and news search (recommended) |
| `AIHUBMIX_KEY` | - | AIHubMix one-key multi-model access (recommended) |
| `SERPAPI_API_KEYS` | - | SerpAPI realtime financial news search (recommended) |
| `TAVILY_API_KEYS` | - | Tavily news search (optional) |
| `MINIMAX_API_KEYS` | - | MiniMax search (optional) |

---

## Mobile Client (Android App)

Connecting the Android App to this server has **different** requirements than plain Web usage. See [Mobile Packaging Guide](mobile-package.md) for the full walkthrough.

### HTTPS is mandatory

The App's WebView origin is fixed at `https://localhost`, so requests to your backend are **cross-site**. Sending cookies cross-site requires `SameSite=None`, and browsers mandate that this value be paired with `Secure` — which only takes effect over HTTPS.

Plain `http://IP:8000` therefore does not work for the App. The symptom is that **login appears to succeed and every subsequent request returns 401**.

### Required configuration

```bash
ADMIN_AUTH_ENABLED=true
ADMIN_SESSION_COOKIE_SAMESITE=none
TRUST_X_FORWARDED_FOR=true
```

> ⚠️ **After editing `.env` you must recreate the container — `restart` is not enough.** Compose injects `env_file:` values as environment variables when the container is **created**; `docker compose restart` reuses the same container and keeps the old values:
>
> ```bash
> docker compose -f ./docker/docker-compose.yml up -d --force-recreate server
> ```
>
> Verify the variables actually reached the container:
>
> ```bash
> docker compose -f ./docker/docker-compose.yml exec server printenv | grep ADMIN_
> ```
>
> Make sure no key appears **twice** in `.env` (the template already ships `ADMIN_AUTH_ENABLED=false`, so appending `=true` at the end leaves two entries and the effective value depends on parse order). Check with `grep -n '^ADMIN_AUTH_ENABLED=' .env`.

`ADMIN_SESSION_COOKIE_SAMESITE` defaults to `lax`; leaving it unset keeps Web and Desktop behavior completely unchanged. When set to `none`, the backend forces `Secure`. `https://localhost` is already in the default CORS allowlist, so `CORS_ORIGINS` needs no configuration.

> ⚠️ **Do not set `CORS_ALLOW_ALL=true`** — it forces `allow_credentials=False`, which is mutually exclusive with cookie authentication and effectively disables auth.
>
> ⚠️ `SameSite=None` weakens browser-side CSRF protection. Do not enable it while `ADMIN_AUTH_ENABLED=false`.

### Reverse proxy (Caddy example)

First bind the container to loopback only, in the `server` service of `docker/docker-compose.yml`:

```yaml
    ports:
      - "127.0.0.1:${API_PORT:-8000}:${API_PORT:-8000}"
```

`/etc/caddy/Caddyfile`:

```
dsa.your-domain.com {
	reverse_proxy 127.0.0.1:8000 {
		# The chat page streams over SSE; response buffering must be disabled
		flush_interval -1
	}
}
```

The Nginx equivalent is `proxy_buffering off;`. **Omitting this makes the chat wait a long time and then dump the whole answer at once.**

Open ports 80 and 443 in your security group (80 is needed for Let's Encrypt issuance and renewal). Port 8000 does not need to be exposed.

> **If you use Cloudflare, set this subdomain to "DNS only" (grey cloud).** The free-tier proxy buffers streaming responses and has an idle timeout of roughly 100 seconds, which can truncate long-running LLM analysis.

### Verification

```bash
curl -si -X POST https://dsa.your-domain.com/api/v1/auth/login \
  -H 'Content-Type: application/json' -d '{"password":"<your-password>"}' | grep -i set-cookie
```

The response must contain **both** `SameSite=None` and `Secure`. If either is missing, the App will 401 right after login.

---

## Proxy Configuration

If server is in mainland China, accessing Gemini API requires proxy:

### Docker Method

Edit `docker-compose.yml`:
```yaml
environment:
  - http_proxy=http://your-proxy:port
  - https_proxy=http://your-proxy:port
```

### Direct Deployment Method

Edit top of `main.py`:
```python
os.environ["http_proxy"] = "http://your-proxy:port"
os.environ["https_proxy"] = "http://your-proxy:port"
```

---

## Monitoring & Maintenance

### View Logs

```bash
# Docker method
docker-compose -f ./docker/docker-compose.yml logs -f --tail=100

# Direct deployment
tail -f /opt/stock-analyzer/logs/stock_analysis_*.log
```

### Health Check

```bash
# Check process
ps aux | grep main.py

# Check recent reports
ls -la /opt/stock-analyzer/reports/
```

### Routine Maintenance

```bash
# Clean old logs (keep 7 days)
find /opt/stock-analyzer/logs -mtime +7 -delete

# Clean old reports (keep 30 days)
find /opt/stock-analyzer/reports -mtime +30 -delete
```

---

## FAQ

### 1. Docker build failed

```bash
# Clear cache and rebuild
docker-compose -f ./docker/docker-compose.yml build --no-cache
```

### 2. API access timeout

Check proxy configuration, ensure server can access Gemini API.

### 3. Database locked

```bash
# Stop service then delete lock file
rm /opt/stock-analyzer/data/*.lock
```

### 4. Insufficient memory

Adjust memory limits in `docker-compose.yml`:
```yaml
deploy:
  resources:
    limits:
      memory: 1G
```

---

## Quick Migration

Migrate from one server to another:

```bash
# Source server: Package
cd /opt/stock-analyzer
tar -czvf stock-analyzer-backup.tar.gz .env data/ logs/ reports/

# Target server: Deploy
mkdir -p /opt/stock-analyzer
cd /opt/stock-analyzer
git clone <your-repo-url> .
tar -xzvf stock-analyzer-backup.tar.gz
docker-compose -f ./docker/docker-compose.yml up -d
```

---

## Option 4: GitHub Actions Deployment (Serverless)

**The simplest option!** No server needed, leverages GitHub's free compute resources.

### Advantages
- ✅ **Completely free** (2000 minutes/month)
- ✅ **No server needed**
- ✅ **Auto-scheduled execution**
- ✅ **Zero maintenance cost**

### Limitations
- ⚠️ Stateless (fresh environment each run)
- ⚠️ Scheduled timing may have few minutes delay
- ⚠️ Cannot provide HTTP API

### Deployment Steps

#### 1. Create GitHub Repository

```bash
# Initialize git (if not already)
cd /path/to/daily_stock_analysis
git init
git add .
git commit -m "Initial commit"

# Create GitHub repo and push
# After creating new repo on GitHub web:
git remote add origin https://github.com/your-username/daily_stock_analysis.git
git branch -M main
git push -u origin main
```

#### 2. Configure Secrets (Important!)

Go to repo page → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Add these Secrets:

| Secret Name | Description | Required |
|------------|------|------|
| `ANSPIRE_API_KEYS` | Anspire Open API Key (one key for LLM and search) | Recommended |
| `AIHUBMIX_KEY` | AIHubMix API Key (one key for multiple model families) | Recommended |
| `ANTHROPIC_API_KEY` | Anthropic API Key | Optional |
| `GEMINI_API_KEY` | Gemini AI API Key | Optional |
| `OPENAI_API_KEY` | OpenAI-compatible API Key | Optional |
| `WECHAT_WEBHOOK_URL` | WeChat Work Bot Webhook | Optional* |
| `FEISHU_WEBHOOK_URL` | Feishu Bot Webhook | Optional* |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token | Optional* |
| `TELEGRAM_CHAT_ID` | Telegram Chat ID | Optional* |
| `TELEGRAM_MESSAGE_THREAD_ID` | Telegram Topic ID | Optional* |
| `EMAIL_SENDER` | Sender email | Optional* |
| `EMAIL_PASSWORD` | Email authorization code | Optional* |
| `SERVERCHAN3_SENDKEY` | ServerChan v3 Sendkey | Optional* |
| `CUSTOM_WEBHOOK_URLS` | Custom Webhook (comma-separated for multiple) | Optional* |
| `STOCK_LIST` | Watchlist, e.g., `600519,300750` | ✅ |
| `SERPAPI_API_KEYS` | SerpAPI Key | Recommended |
| `TAVILY_API_KEYS` | Tavily Search API Key | Optional |
| `BOCHA_API_KEYS` | Bocha Search API Key | Optional |
| `BRAVE_API_KEYS` | Brave Search API Key | Optional |
| `MINIMAX_API_KEYS` | MiniMax Coding Plan Web Search | Optional |
| `TUSHARE_TOKEN` | Tushare Token | Optional |
| `GEMINI_MODEL` | Model name (default gemini-2.0-flash) | Optional |

> *Note: Configure at least one notification channel, multiple channels supported for simultaneous push

#### 3. Verify Workflow File

Ensure `.github/workflows/00-daily-analysis.yml` file exists and is committed:

```bash
git add .github/workflows/00-daily-analysis.yml
git commit -m "Add GitHub Actions workflow"
git push
```

#### 4. Manual Test Run

1. Go to repo page → **Actions** tab
2. Select **"Daily Stock Analysis"** workflow
3. Click **"Run workflow"** button
4. Select run mode:
   - `full` - Full analysis (stocks + market)
   - `market-only` - Market review only
   - `stocks-only` - Stock analysis only
5. Click green **"Run workflow"** button

#### 5. View Execution Logs

- Actions page shows run history
- Click specific run record to view detailed logs
- Analysis reports are saved as Artifacts for 30 days

### Schedule Details

Default configuration: **Monday to Friday, 18:00 Beijing Time** auto-execution

Modify time: Edit cron expression in `.github/workflows/00-daily-analysis.yml`:

```yaml
schedule:
  - cron: '0 10 * * 1-5'  # UTC time, +8 = Beijing time
```

Common cron examples:
| Expression | Description |
|--------|------|
| `'0 10 * * 1-5'` | Mon-Fri 18:00 (Beijing) |
| `'30 7 * * 1-5'` | Mon-Fri 15:30 (Beijing) |
| `'0 10 * * *'` | Daily 18:00 (Beijing) |
| `'0 2 * * 1-5'` | Mon-Fri 10:00 (Beijing) |

### Modify Watchlist

Method 1: Modify repo Secret `STOCK_LIST`

Method 2: Modify code directly then push:
```bash
# Modify .env.example or set default value in code
git commit -am "Update stock list"
git push
```

### FAQ

**Q: Why isn't the scheduled task running?**
A: GitHub Actions scheduled tasks may have 5-15 minute delays, and only trigger when repo has activity. Long periods without commits may cause workflow to be disabled.

**Q: How to view historical reports?**
A: Actions → Select run record → Artifacts → Download `analysis-reports-xxx`

**Q: Is the free quota enough?**
A: Each run takes about 2-5 minutes, 22 workdays per month = 44-110 minutes, well below the 2000 minute limit.

---

**Wishing you a smooth deployment!**
