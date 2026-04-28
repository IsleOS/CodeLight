import type { FastifyInstance } from 'fastify';

const PRIVACY_HTML = `<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy Policy — CodeLight</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         max-width: 720px; margin: 40px auto; padding: 0 20px;
         color: #1a1a1a; line-height: 1.7; }
  h1 { font-size: 28px; margin-bottom: 4px; }
  .sub { color: #888; font-size: 14px; margin-bottom: 36px; }
  h2 { font-size: 18px; margin-top: 32px; }
  p  { margin: 8px 0; }
  hr { border: none; border-top: 1px solid #eee; margin: 40px 0; }
  a  { color: #007AFF; }
</style>
</head>
<body>
<h1>Privacy Policy / 隐私政策</h1>
<p class="sub">Last updated / 最后更新：2026-04-24</p>

<h2>1. Overview / 概述</h2>
<p>CodeLight is a mobile companion for Claude Code on Mac. We are committed to protecting your privacy.
CodeLight 是 Mac 上 Claude Code 的 iPhone 伴侣 App，我们承诺保护您的隐私。</p>

<h2>2. Data We Collect / 我们收集的数据</h2>
<p>
• <strong>Device identifier</strong> — a random ID generated at first launch, used solely for pairing with your Mac.<br>
• <strong>Push notification token</strong> — used to deliver session completion and approval-request notifications.<br>
• <strong>Session messages</strong> — Claude Code conversation content relayed in real-time between your iPhone and Mac. Messages are not stored permanently; they are purged from the relay server after 5 days.
</p>
<p>
• <strong>设备标识符</strong> — 首次启动时生成的随机 ID，仅用于与您的 Mac 配对。<br>
• <strong>推送通知 Token</strong> — 用于发送会话完成和需要审批的通知。<br>
• <strong>会话消息</strong> — Claude Code 对话内容在 iPhone 与 Mac 之间实时中转，不永久存储，5 天后自动清除。
</p>

<h2>3. Data Storage &amp; Transfer / 数据存储与传输</h2>
<p>Data is relayed through our server at <code>code.7ove.online</code> (AWS Tokyo, Japan).
All connections are encrypted with TLS. Auth tokens are stored in the iOS Keychain.
数据通过 <code>code.7ove.online</code>（AWS 东京，日本）中转，全程 TLS 加密，认证 Token 存储在 iOS Keychain 中。</p>
<p>Cross-border data transfer notice (for mainland China users): conversation data is temporarily relayed through servers located in Japan.
跨境数据传输说明（中国大陆用户）：对话内容通过位于日本的服务器临时中转。</p>

<h2>4. Camera / 相机</h2>
<p>Camera access is used only for scanning QR codes during Mac pairing. No photos or videos are captured or stored.
相机仅用于配对时扫描二维码，不拍摄或存储任何照片和视频。</p>

<h2>5. Push Notifications / 推送通知</h2>
<p>Push notifications are delivered via Apple APNs. Notification content is end-to-end encrypted. You can disable notifications at any time in iOS Settings.
推送通知通过 Apple APNs 发送，通知内容端对端加密。您可以随时在 iOS 设置中关闭。</p>

<h2>6. Third-Party Services / 第三方服务</h2>
<p>We use Apple StoreKit 2 for in-app purchases and Apple APNs for push notifications. No third-party analytics SDKs are included.
我们使用 Apple StoreKit 2 处理内购，Apple APNs 推送通知。App 内不包含任何第三方分析 SDK。</p>

<h2>7. Your Rights / 您的权利</h2>
<p>You may delete your account and all associated data at any time via Settings → Reset in the app.
您可以随时通过 App 内「设置 → 重置」删除账号及所有关联数据。</p>

<h2>8. Contact / 联系我们</h2>
<p>Email: <a href="mailto:xmqywx@wdao.chat">xmqywx@wdao.chat</a></p>

<hr>
<p style="font-size:13px;color:#aaa">Open source: <a href="https://github.com/MioMioOS/CodeLight">github.com/MioMioOS/CodeLight</a></p>
</body>
</html>`;

const SUPPORT_HTML = `<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Support — CodeLight</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         max-width: 720px; margin: 40px auto; padding: 0 20px;
         color: #1a1a1a; line-height: 1.7; }
  h1 { font-size: 28px; margin-bottom: 4px; }
  .sub { color: #888; font-size: 14px; margin-bottom: 36px; }
  h2 { font-size: 18px; margin-top: 32px; }
  p  { margin: 8px 0; }
  .card { background: #f5f5f7; border-radius: 12px; padding: 20px 24px; margin: 16px 0; }
  a  { color: #007AFF; }
  code { background: #eee; padding: 2px 6px; border-radius: 4px; font-size: 14px; }
</style>
</head>
<body>
<h1>Support / 帮助中心</h1>
<p class="sub">CodeLight — iPhone companion for Claude Code</p>

<h2>Contact / 联系我们</h2>
<div class="card">
  <p>📧 Email: <a href="mailto:xmqywx@wdao.chat">xmqywx@wdao.chat</a></p>
  <p>🐛 Bug reports: <a href="https://github.com/MioMioOS/CodeLight/issues">GitHub Issues</a></p>
</div>

<h2>FAQ</h2>

<h3>Q: The app shows nothing after opening / App 打开后什么都没有</h3>
<p>CodeLight requires pairing with the <strong>MioIsland</strong> Mac companion app first.
Download MioIsland, open it on your Mac, then scan the QR code shown in MioIsland's Pairing tab.
CodeLight 需要先和 Mac 上的 <strong>MioIsland</strong> 配对才能使用。在 Mac 上安装并打开 MioIsland，然后扫描「配对」页面的二维码。</p>

<h3>Q: Camera not working for QR scan / 相机无法扫描二维码</h3>
<p>Go to iOS Settings → CodeLight → Camera, make sure camera access is enabled.
前往 iOS 设置 → CodeLight → 相机，确认已开启相机权限。</p>

<h3>Q: Sessions not syncing / 会话不同步</h3>
<p>Pull down on the session list to refresh, or go to Settings → Reconnect.
在会话列表下拉刷新，或进入设置 → 重新连接。</p>

<h3>Q: Restore purchase / 恢复购买</h3>
<p>In the subscription screen, tap "Restore Purchase" at the bottom.
在付款页面点底部「恢复购买」。</p>

<h3>Q: MioIsland download / MioIsland 下载</h3>
<p><a href="https://github.com/MioMioOS/MioIsland/releases">github.com/MioMioOS/MioIsland/releases</a></p>

<hr>
<p style="font-size:13px;color:#aaa">
  <a href="/privacy">Privacy Policy / 隐私政策</a>
</p>
</body>
</html>`;

export async function pagesRoutes(app: FastifyInstance) {
    app.get('/privacy', async (_req, reply) => {
        reply.type('text/html; charset=utf-8').send(PRIVACY_HTML);
    });

    app.get('/support', async (_req, reply) => {
        reply.type('text/html; charset=utf-8').send(SUPPORT_HTML);
    });
}
