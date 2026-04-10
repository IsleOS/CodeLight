<div align="center">

<img src="app/CodeLight/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png" width="120" alt="Code Light icon"/>

# Code Light

### **把 Claude Code 装进口袋。** 🐱✨

**Claude Code 的原生 iPhone 伴侣 —— 灵动岛实时显示、多 Mac 配对、精准终端定位。**

[English](README.md) · [简体中文](README.zh-CN.md)

[![GitHub stars](https://img.shields.io/github/stars/IsleOS/CodeLight?style=social)](https://github.com/IsleOS/CodeLight/stargazers)
[![License](https://img.shields.io/badge/license-CC%20BY--NC%204.0-green?style=flat-square)](LICENSE.md)
[![iOS](https://img.shields.io/badge/iOS-17%2B-black?style=flat-square&logo=apple)](https://github.com/IsleOS/CodeLight/releases)
[![Swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift)](https://swift.org)
[![App Store](https://img.shields.io/badge/App_Store-下载-0D96F6?style=flat-square&logo=appstore&logoColor=white)](https://apps.apple.com/us/app/code-light/id6761744871)

</div>

---

<div align="center">

> ### 🏝️ Claude 在思考。你在吃午饭。**你会知道。**

<img src="marketing/screenshots/00-lockscreen-live-activity.jpeg" width="640" alt="Code Light 锁屏 Live Activity —— 像素猫图标、Thinking 阶段、最近用户消息和 Claude 回复预览、0:01 计时器"/>

*锁屏 Live Activity —— 像素猫陪你显示当前活跃会话、所处阶段、最近的用户消息和 Claude 的回复预览。通过 APNs 实时更新。*

</div>

<table>
<tr>
<td width="20%"><img src="marketing/screenshots/01-pair-mac-qr.png" alt="扫码或 6 位字符配对"/></td>
<td width="20%"><img src="marketing/screenshots/02-linked-macs.png" alt="一台 iPhone 配对多台 Mac"/></td>
<td width="20%"><img src="marketing/screenshots/03-mac-sessions.png" alt="活跃 / 最近 / 归档 三 tab 会话视图"/></td>
<td width="20%"><img src="marketing/screenshots/04-chat-markdown.png" alt="实时聊天 + 富文本 Markdown 渲染"/></td>
<td width="20%"><img src="marketing/screenshots/05-settings.png" alt="自托管、多服务器、完全私密"/></td>
</tr>
<tr>
<td align="center"><b>🔐 秒级配对</b><br><sub>永久 6 位字符</sub></td>
<td align="center"><b>🖥️ 一台 iPhone N 台 Mac</b><br><sub>一键切换</sub></td>
<td align="center"><b>📋 活跃·最近·归档</b><br><sub>三 tab 会话管理</sub></td>
<td align="center"><b>💬 实时聊天 + 斜杠命令</b><br><sub>富 Markdown 渲染</sub></td>
<td align="center"><b>⚙️ 自托管 · 完全私密</b><br><sub>零知识中继</sub></td>
</tr>
</table>

---

Code Light 是 Claude Code 的**原生 iPhone 伴侣**。它与 Mac 上的 [Pounce](https://github.com/IsleOS/Pounce) 配对，让你在任何地方阅读、回复、编排你的 AI 编程会话 —— 完全不用碰键盘。

> *离开座位，锁屏放下手机，去倒杯咖啡。灵动岛里的像素猫会在 Claude 需要你的瞬间告诉你 —— 直接把问题打在锁屏上，点一下就能回复。*

这是一个**出于个人兴趣**的项目，**完全免费开源**，没有任何商业目的。欢迎提 Bug、提 PR、提建议。

---

## 为什么选 Code Light？

> *"我已经在用 [Happy](https://github.com/slopus/happy) 了，为啥还要这个？"*

简单回答：Code Light 是专为 Claude Code + Mac + cmux 场景从零设计的，而且死磕 iOS 原生体验。每一个设计决策都是**"正确性和手感"优先于"跨平台覆盖"**。

<table>
<tr><td width="50%">

### 🎯 精准落到那一个终端
你发的消息会落到**你选中的那个** Claude 终端 —— 不是"我第一个找到的 Claude 窗口"。Code Light 的做法是：`ps -Ax` 找出 `claude --session-id <uuid>` 的进程 PID → 读这个进程的 `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` 环境变量 → `cmux send --workspace <ws> --surface <surf>` 精准送达。零猜测，零 cwd 模糊匹配，零误发可能。

</td><td width="50%">

### 🏝️ 灵动岛，做对了
**一个全局 Live Activity** 代表"Claude 此刻正在干什么"。阶段切换（`thinking → tool_running → waiting_approval`）通过 APNs 推送更新。长回答不会让灵动岛抖动。一个 activity 可以覆盖 N 个 session，不会撞上 iOS 的 Live Activity 并发上限。

</td></tr>
<tr><td>

### ⚡ 任何斜杠命令都能发
`/model opus`、`/cost`、`/usage`、`/clear`、`/compact` —— **任何** Claude 斜杠命令都能从手机发。Code Light 的做法是：终端先快照 → 注入命令 → 等输出稳定 → diff 前后两个快照 → 把新增的行作为合成的 `terminal_output` 消息送回手机。你看得到回复，哪怕斜杠命令根本不写入 Claude 的 JSONL。

</td><td>

### 🖥️ 一个 iPhone，多台 Mac
一台 iPhone 可以配对多台 Mac，切换只需一个点击。每台 Mac 有**永久不变的 6 位配对码** —— 不过期、不轮转、重启也不变。每台 Mac 甚至可以部署在不同的后端服务器。Session 严格按设备隔离。

</td></tr>
<tr><td>

### 🚀 远程新建会话
在手机上点 `+`，选一个**启动预设**（比如 `claude --dangerously-skip-permissions --chrome`），选一个项目路径 —— Mac 上就会立刻弹出一个新的 cmux workspace 跑那条命令。预设存在 Mac 端（你控制命令白名单），最近项目路径自动同步。

</td><td>

### 📷 真正的 iOS 原生集成
原生 SwiftUI，不是 WebView。原生 CryptoKit 的 Ed25519。原生 `PhotosPicker` + `UIImagePickerController` 做附件（支持**拍照**，不只从相册选）。全局触感反馈 —— 配对成功是满足感十足的双击，启动是硬朗的单击，破坏性操作有 warning 抖动。

</td></tr>
</table>

---

## Code Light vs Happy — 深度对比

两个 app 都让你从手机操作 Claude Code。真正的差别在哪：

| 能力 | Code Light | Happy |
|---|:---:|:---:|
| **灵动岛**（真的灵动岛，不是推送通知） | ✅ 全局阶段驱动的 Activity | ❌ |
| **多 Mac 配对**（一个 iPhone ↔ 多台 Mac） | ✅ 永久短码 | ❌ 一次一台 |
| **多后端服务器**（Mac 可在不同 server） | ✅ 扁平列表自动切换 | ❌ |
| **精准 cmux surface 定位** | ✅ UUID → PID → 环境变量 | ❌ 无终端路由 |
| **所有 Claude 斜杠命令**（`/model`、`/cost`、`/usage`…） | ✅ 并捕获输出返回 | ❌ 只能发文本 |
| **远程新建会话**（手机触发新 cmux 窗口） | ✅ Mac 端预设驱动 | ❌ |
| **高效二进制传输** | ✅ 纯文本 + Socket.io 帧 | ❌ Base64 封装 |
| **原生 Swift iOS 应用** | ✅ SwiftUI + ActivityKit | ❌ React Native / Expo |
| **富 Markdown 渲染**（代码、表格、列表、标题） | ✅ 自研 SwiftUI 渲染器 | ⚠️ 基础 |
| **终端控制键**（Esc、Ctrl+C、Enter） | ✅ 专用按钮 | ❌ |
| **图片附件**（相机 + 相册） | ✅ 两者都有 | ⚠️ 仅相册 |
| **永久配对码**（可输入而非必须扫码） | ✅ 6 位字符永久 | ❌ 只能扫 QR |
| **应用内隐私政策**（Apple 审核要求） | ✅ 中英双语 | ⚠️ 外部链接 |
| **完整中英本地化** | ✅ 含 Info.plist | ⚠️ |
| **可自托管** | ✅ | ✅ |
| **开源** | ✅ CC BY-NC 4.0（仅限学习研究，禁止商用） | ✅ |

### 深度解析 —— 为什么每一项都重要

**1. 终端定位：不是猜谜游戏**
Happy 根本没法知道一条消息应该发到哪个 cmux 窗格 —— 因为它是"包装 CLI"的思路（用 `happy claude` 代替 `claude`），只看到自己的 stdin/stdout。Code Light 的思路完全相反：Mac 上的 Pounce 看的是整个系统 —— 它知道有哪些 Claude 进程、哪些 cmux surface、它们之间通过 `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` 环境变量一一对应。一条指向 session UUID `abc12345…` 的消息会**精确落到**那个 pane。进程没了，消息干净地丢掉，绝不会误发到旁边的窗口。

**2. 二进制传输，不是 base64**
Happy 的协议把载荷用 base64 包装（他们的 session routes 里 `Buffer.from(...).toString('base64')` 遍地都是）。Base64 让每个字节膨胀 33%，而且两端都要多一次编解码。Code Light 把消息内容当成 UTF-8 纯文本走 Socket.io 帧 —— 更小、更快、代码更少。图片走独立的 `POST /v1/blobs` 上传为原生二进制，用不透明 ID 引用，不会往消息体里塞 base64 图块。

**3. 真的灵动岛**
Code Light 跑的是 ActivityKit Live Activity，在灵动岛里实时反映 Claude 的当前阶段 —— 不是三秒就消失的推送。Activity 会原地更新阶段、显示当前工具名、所有 session 完成时优雅折叠。这件事只有原生 Swift 能干净地做。React Native 做 ActivityKit 很吃力。

**4. 斜杠命令能回传**
`/model`、`/cost`、`/usage`、`/clear` 这类命令**不会**触发 Claude 的 hook 事件 —— 它们在 CLI 内部处理，输出也根本不进 JSONL。所以大多数远程客户端都看不到回复。Code Light 的 Pounce 解法是：注入前先快照 pane → 发命令 → 轮询到输出稳定 → diff 前后快照 → 把新增的行作为合成的 `terminal_output` 消息回传。手机上看起来和普通回复完全一样。

**5. 多 Mac 是真的多 Mac**
把 iPhone 配对 `MacBook Pro` 和 `Mac mini`，两台 Mac 可以在**不同的服务器**上。Code Light 把两台 Mac 放在一个列表里，按 server host 分组，当前连接的 server 标绿点。点一下不同 server 上的 Mac，后台自动重连。每台 Mac 有自己的永久 6 位 `shortCode`（永不过期），配对额外的 iPhone 只需要"输入这个码"。Session 访问权限在 server 端用 `DeviceLink` 严格隔离 —— 只配对了 Mac B 的 iPhone 看不到 Mac A 的任何 session。

**6. 远程新建会话把闭环补齐了**
在手机上点 `+`，选一个预设如 `Claude (skip perms) + Chrome`，从最近项目选一个路径，点 Launch —— Code Light 发 `POST /v1/sessions/launch`，server 给这台 Mac 的 `deviceId` 推一个 `session-launch` socket 事件，Pounce 的 `LaunchService` 跑 `cmux new-workspace --cwd <path> --command "<command>"`，一个新的 cmux workspace 就跑起来了。你全程没碰键盘。预设定义在 Mac 端（你控制允许的命令），项目路径从活跃 session 的 cwd 同步来。

---

## 功能清单

### 📱 实时 session 同步
每条消息、每次工具调用、每个思考块都流式推到手机。懒加载历史（每页 50 条，`before_seq` cursor 往上翻），断线重连后 delta 同步。

### 🏝️ 灵动岛
全局 Live Activity 支持 6 个状态（思考、工具运行、等待确认、写入、完成、空闲）。Mac 上的像素猫动画与手机状态同步。

### 💬 发消息 + 控制键
一键发送。专用 Escape / Ctrl+C 按钮。所有消息通过 surface ID 路由直达目标 cmux pane。

### ⚡ 斜杠命令带回显
`/model`、`/cost`、`/usage`、`/clear`、`/compact`、`/help` —— 任意斜杠命令，输出从终端 pane diff 出来，在聊天里以 `terminal_output` 气泡显示。

### 🖼️ 图片附件
通过 `PhotosPicker` 选相册或用相机拍新的。每条消息最多 6 张，本地 JPEG 压缩，以 blob 形式上传，在 Mac 端用 `NSPasteboard` + AppleScript `Cmd+V` 粘贴到 cmux pane。

### 🔐 短码配对（也支持扫码）
每台 Mac 的 Pounce 菜单显示一个永久 6 位码和一个 QR。手机上扫 QR 或输入 6 位码 —— 两条路径都走同一个 `/v1/pairing/code/redeem` 接口。多 Mac：再输一个码就加一台。无账号、无密码、重启不变。

### 🖥️ 多 Mac、多 server
维护一个扁平的"已配对 Mac"列表，可以横跨任意多个后端服务器。点击切换当前活跃连接。每台 Mac 在本地缓存里自带 `serverUrl`。

### 🚀 远程启动 session
启动预设在 Mac 端定义（名称、命令、图标、排序）。手机 fetch 到列表后在 sheet 里显示，触发 cmux 用选定的命令和项目路径创建新 workspace。

### 🔔 精细化推送通知
每台设备可切换：完成时通知、工具等待确认时通知、出错时通知。走 APNs 推送，Live Activity 推送走 HTTP/2。

### 🌍 完整中英双语
UI 字符串（`Localizable.xcstrings`）、权限弹窗（`InfoPlist.xcstrings`）、隐私政策 —— 全部中英双语。iOS 自动根据系统语言选。

### 🎛️ 全局触感反馈
每类交互都配了合适的反馈：tab/picker 用 selection 级别、导航用 light、按钮用 medium、提交用 rigid、配对/启动成功用 success、破坏性动作前用 warning、失败用 error。

---

## 架构一览

```
  Mac (Pounce)              后端 (自托管)                 iPhone (Code Light)
┌──────────────────┐         ┌──────────────────────┐      ┌────────────────────────┐
│ Claude Code      │         │ Fastify + Socket.io  │      │ 📱 已配对 Mac 列表      │
│ hooks + JSONL    │         │ PostgreSQL + Prisma  │      │ 💬 聊天 + Markdown     │
│                  │         │                      │      │ 🏝️ 灵动岛              │
│ Pounce       │◀───────▶│ DeviceLink 权限图    │◀────▶│ ⌨️ 发送 + 控制键        │
│  · SessionStore  │ WebSocket│ 零知识中继           │ WSS  │ 📷 拍照 + 相册          │
│  · LaunchService │  + HTTPS │ APNs 桥接 (HTTP/2)   │      │ 🚀 远程启动             │
│  · PresetStore   │         │                      │      │ 🔔 推送通知             │
└──────────────────┘         └──────────────────────┘      └────────────────────────┘
       cmux 桥接                                                  ActivityKit
       (workspace + surface 环境变量)                              WidgetKit
```

Server 端通过 `DeviceLink` 严格隔离。只配对了 Mac A 的 iPhone 看不到 Mac B 的任何 session、preset、项目或启动接口。

---

## 系统要求

- **Mac**：macOS 14+，装 [Pounce](https://github.com/IsleOS/Pounce)，装 [cmux](https://cmux.io)（终端集成必需）
- **iPhone**：iOS 17+
- **服务器**：任意装有 Node.js 20+ 和 PostgreSQL 14+ 的主机（也可以用公共 CodeLight Server）

---

## 快速开始

### 1. 部署服务器

```bash
git clone https://github.com/IsleOS/CodeLight.git
cd CodeLight/server
npm install
cp .env.example .env
# 设置 DATABASE_URL、MASTER_SECRET（64 位 hex）、PORT
npx prisma db push
npm start
```

生产环境前面套个 Nginx + TLS。`pm2 start npm --name codelight-server -- start`。

### 2. 在 Mac 上装 Pounce

按 [Pounce README](https://github.com/IsleOS/Pounce) 安装。它的 Sync 模块会自动把这台 Mac 注册到你的服务器，懒生成永久 6 位配对码。

### 3. 编译 iPhone app

```bash
cd CodeLight/app
open CodeLight.xcodeproj
```

选你的开发者 team → 连 iPhone → 按 **⌘R**。

### 4. 配对

1. Mac 上打开 Pounce 菜单 → **Pair iPhone**。你会看到 QR 和 6 位码。
2. iPhone 上输入 server 地址 + 6 位码（或扫 QR）。
3. 完事。Mac 出现在"Macs"列表里，点进去就能看到它的 session。

---

## 安全与隐私

| 层级 | 实现 |
|---|---|
| **身份** | Ed25519 密钥对（CryptoKit），每设备一对，永不导出 |
| **存储** | iOS / macOS 钥匙串 |
| **传输** | TLS 1.2+（HTTPS + WSS） |
| **配对** | 每台 Mac 一个永久 6 位 shortCode，server 端全局唯一 |
| **访问控制** | `DeviceLink` 图 —— 每个请求都过 `getAccessibleDeviceIds()` |
| **消息** | 端到端加密就绪（CryptoKit ChaChaPoly），服务器零知识中继 |
| **数据收集** | 无。无统计，无遥测，无第三方 |

详见 [Privacy Policy](PRIVACY.md)。手机 app 内也能离线查看隐私政策（Apple App Store 审核要求）。

---

## 项目结构

```
CodeLight/
├── server/              # Fastify + Socket.io + Prisma 后端
├── app/
│   ├── CodeLight/       # iPhone 主 app (SwiftUI)
│   └── CodeLightWidget/ # 灵动岛 / 锁屏 widget
├── packages/
│   ├── CodeLightProtocol/   # 共享 DTO (Codable)
│   ├── CodeLightCrypto/     # Ed25519 + ChaChaPoly
│   └── CodeLightSocket/     # Socket.io Swift 封装
└── docs/specs/          # 设计文档（多 Mac 配对等）
```

---

## 工程亮点

几个让整套系统"用起来很稳"的非显然设计决策。

### 精准的"手机 → 终端"路由
系统本来就知道的两个事实：
1. Claude Code 的 argv 里写着 `--session-id <UUID>`（`ps -Ax` 可见）
2. cmux 自动把 `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` 塞进每个 pane 的环境变量（`ps -E -p <pid>` 可读）

流程：`ps` → PID → 环境变量 → `cmux send --workspace <ws> --surface <surf>`。不做标题匹配，不做 cwd 启发式。找不到进程就干净地丢掉。

### 一个全局 Live Activity
早期给每个 session 开一个 activity，灵动岛被拉扯得乱抖，还会撞上 iOS 的并发上限。Code Light 只跑**一个**全局 activity，`ContentState` 里记 `activeSessionId`、`activeSessions`、`totalSessions`、最近的 phase。谁最新发生状态变化就占用灵动岛。切换只是 state update，不是 create/destroy。

### Phase 消息作为 activity 心跳
只有 `type: "phase"` 消息会重渲染 Live Activity。普通聊天消息不触发。这样既能压低 APNs 推送频率（苹果有预算上限），又能避免 Claude 输出长回答时灵动岛疯狂闪。

### HTTP/2 强制（APNs Live Activity）
Node 自带的 `fetch()` 走 HTTP/1.1，打 `api.push.apple.com` 会直接 `TypeError: fetch failed` —— 连个清晰报错都没有。服务器用 `node:http2` 手搓 HTTP/2 请求发 Live Activity 推送。普通 APNs alert 还能用 `fetch()`，只有 Live Activity 强制 HTTP/2。

### 60 秒 echo 去重环
手机发 → server → Pounce 粘贴到 cmux → Claude 写 JSONL → 文件监听器回看到"新用户消息" → Pounce 重新上传 → 手机收到自己刚发的消息。解法是 Mac 端保留一个 60 秒 TTL 的 `(claudeUuid, text)` 环，MessageRelay 上传前消费一次匹配项就跳过。不改 server，不做 localId 协商。

### 短期 blob 存储
图片只是**过境数据**（真正的历史在 Claude 自己的 JSONL 里），所以 blob 存储刻意做成**内存 + 磁盘，不进数据库**。三层清理：`blob-consumed` socket ack 一到就删 / 10 分钟 TTL 扫尾 / 服务器启动时整个 `blobs/` 清空。没有 Prisma 模型，没有孤儿行。

### 通过 NSPasteboard + AppleScript 粘贴图片
cmux 没有"粘图"命令。但手动 Cmd+V 能粘。所以：下载 blob → `cmux focus-panel` → AppleScript `activate` 并轮询 `NSWorkspace.frontmostApplication` 直到 cmux 真的上前台 → 往 `NSPasteboard` 同时写 NSImage + `public.jpeg` + `.tiff` 三种格式最大化兼容 → `System Events keystroke "v" using {command down}`（CGEvent fallback）→ 补正文和回车。需要辅助功能权限，权限按签名路径记录 —— 所以 Pounce 每次 rebuild 会自安装到 `/Applications/Code Island.app`，权限才不会每次都掉。

### 永久 shortCode 挂在 Device.id 上
shortCode 是 `Device` 表的字段，不是 `PairingRequest`。Mac 首次调 `POST /v1/devices/me {kind:"mac"}` 时懒分配，永不轮转。重启 Pounce 配对码不变。多个 iPhone 可以用同一个码配对同一台 Mac。

### 预设 ID 由 Mac 端生成
启动预设用 **Mac 本地 UUID** 作为 server 端主键，不用 server 的 cuid。Mac 上传时把本地 UUID 也发过去，server 原样存。手机后面发 `session-launch` 带 `presetId` 时 Mac 的本地 `PresetStore` 就能直接查到。避免了 phase 4 测试期间一个隐蔽的 "unknown presetId" bug。

---

## 路线图

- [ ] 手机端权限审批（点击同意工具执行）
- [ ] 工具结果可视化（文件 diff、终端输出）
- [ ] 聊天历史搜索
- [ ] iPad 布局
- [ ] Android 移植（社区驱动 —— 协议跨平台）

---

## 相关项目

| 项目 | 角色 |
|---|---|
| [Pounce](https://github.com/IsleOS/Pounce) | **必需** —— Mac 端桥梁 |
| [cmux](https://cmux.io) | **推荐** —— 让精准路由成为可能的终端多路复用器 |

---

## 参与贡献

Bug 报告、PR、功能建议都欢迎。

1. **报 Bug** —— [开个 issue](https://github.com/IsleOS/CodeLight/issues)
2. **提 PR** —— Fork、分支、编码、PR
3. **建议功能** —— 开一个标 `enhancement` 的 issue

---

## 联系方式

- **邮箱** —— xmqywx@gmail.com
- **Issues** —— https://github.com/IsleOS/CodeLight/issues

---

## 许可证

[CC BY-NC 4.0](LICENSE.md) —— **仅限个人学习、教育、学术和研究使用，禁止任何商业用途**。商业用途包括但不限于：销售本软件、将其打包进收费产品、用作收费服务的一部分等。

如需商业授权，请联系 xmqywx@gmail.com。
