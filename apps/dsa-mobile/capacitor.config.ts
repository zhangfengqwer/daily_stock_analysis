import type { CapacitorConfig } from '@capacitor/cli';
import { KeyboardResize } from '@capacitor/keyboard';

const config: CapacitorConfig = {
  // Android 包名必须是合法 Java 包名，不能含连字符，
  // 因此与桌面端的 com.daily-stock-analysis.desktop 写法不同。
  appId: 'com.dailystockanalysis.mobile',
  appName: 'Daily Stock Analysis',
  webDir: 'www',
  server: {
    // 固定 WebView origin 为 https://localhost，与后端 CORS 白名单一致
    // （见 api/app.py 的 allowed_origins）。
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
