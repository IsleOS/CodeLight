# CodeLight — Design Spec

**Date:** 2026-04-05
**Status:** Approved
**Author:** Ying + Claude

## Overview

CodeLight is a native Swift iOS app for monitoring and controlling Claude Code sessions remotely. It works with MioIsland (macOS notch companion) and CodeLight Server (Fastify/TypeScript backend) to provide real-time session sync, E2E encrypted messaging, and iPhone Dynamic Island status display.

### Naming

| Component | Role |
|-----------|------|
| **MioIsland** | macOS notch app (existing), gains Socket.io uplink |
| **CodeLight** | iPhone app (new), native Swift + SwiftUI |
| **CodeLight Server** | Backend (new), Fastify/TypeScript, rewritten from Happy Server |

### Design Principles

- **Public key as identity** — no registration, no passwords, QR pairing exchanges keys
- **E2E encryption** — server is zero-knowledge, stores only ciphertext
- **MioIsland as sole middleware** — replaces happy-cli, serves both local notch display and remote sync
- **Protocol-compatible with Happy** — reuses SessionEnvelope format and Socket.io event protocol, but all code rewritten clean

## Architecture

```
Claude Code
    │ (hooks + JSONL file polling)
    ▼
MioIsland (macOS)
    ├─ Notch UI (existing, unchanged)
    │
    ├─ [NEW] Socket.io → CodeLight Server (E2E encrypted)
    │       ├─ Message relay (SessionEnvelope)
    │       ├─ RPC executor (bash/readFile/writeFile)
    │       └─ Status push (thinking/tool/idle)
    │
    ▼
CodeLight Server (Tencent Cloud)
    │ (Socket.io, E2E encrypted relay)
    ▼
CodeLight (iPhone)
    ├─ Session list & chat UI
    ├─ Send messages to Claude
    ├─ Model/Mode selector
    └─ Dynamic Island status
```

## Module 1: CodeLight Server

### Tech Stack

- **Runtime:** Node.js
- **Framework:** Fastify 5 + Zod validation
- **ORM:** Prisma + PostgreSQL
- **Real-time:** Socket.io
- **Cache/PubSub:** Redis

### Core Modules

| Module | Responsibility |
|--------|---------------|
| **auth** | Public key registration + signature verification |
| **pairing** | QR pairing flow: generate code → scan → exchange keys |
| **session** | Session CRUD, message storage (ciphertext), seq allocation |
| **socket** | Socket.io gateway: message relay, RPC forwarding, status push |
| **push** | APNs push notifications (direct Apple integration, no Expo) |

### Removed (vs Happy Server)

- Account registration/login → public key identity
- OAuth/JWT → signature verification
- Payment/subscription → not needed
- Feed/social → not needed
- GitHub integration → not needed
- ElevenLabs voice → not needed
- PGlite embedded mode → direct PostgreSQL only

### Data Model (3 core tables)

```prisma
model Device {
    id        String   @id @default(cuid())
    publicKey String   @unique
    name      String
    createdAt DateTime @default(now())
    updatedAt DateTime @updatedAt

    sessions       Session[]
    pushTokens     PushToken[]
}

model Session {
    id        String   @id @default(cuid())
    deviceId  String
    device    Device   @relation(fields: [deviceId], references: [id])
    metadata  String   // encrypted JSON
    createdAt DateTime @default(now())
    updatedAt DateTime @updatedAt

    messages SessionMessage[]
}

model SessionMessage {
    id        String   @id @default(cuid())
    sessionId String
    session   Session  @relation(fields: [sessionId], references: [id])
    content   String   // encrypted
    seq       Int
    createdAt DateTime @default(now())

    @@index([sessionId, seq])
}
```

### Socket.io Events (server-side)

| Event | Direction | Purpose |
|-------|-----------|---------|
| `message` | client → server | New session message (encrypted) |
| `update` | server → client | Broadcast message to interested clients |
| `rpc-call` | client → server → client | RPC request forwarding (phone → server → MioIsland) |
| `rpc-response` | client → server → client | RPC result return |
| `session-alive` | client → server | Keep-alive heartbeat |
| `status` | client → server | Session status update (thinking/tool/idle) |

## Module 2: MioIsland Additions

### New Modules (additive, no changes to existing code)

| Module | Responsibility |
|--------|---------------|
| **SocketClient** | Socket.io connection to CodeLight Server, signed auth |
| **MessageRelay** | Convert hook messages to SessionEnvelope, encrypt, push to server |
| **RPCExecutor** | Receive RPC requests from phone (bash/readFile/writeFile), execute locally, return results |
| **PairingManager** | Generate QR code, handle pairing flow (public key + encryption key exchange) |

### Shared Swift Packages (used by both MioIsland and CodeLight)

| Package | Contents |
|---------|----------|
| `CodeLightProtocol` | SessionEnvelope definitions, message format types |
| `CodeLightCrypto` | TweetNaCl encrypt/decrypt, key management |
| `CodeLightSocket` | Socket.io client wrapper, reconnection logic |

## Module 3: CodeLight iOS App

### Tech Stack

- **Language:** Swift
- **UI:** SwiftUI
- **Dynamic Island:** ActivityKit + WidgetKit
- **Storage:** Keychain (keys), UserDefaults/SwiftData (local state)
- **Networking:** socket.io-client-swift

### Pages

| Page | Function |
|------|----------|
| **PairingView** | Scan QR code to pair, shown on first launch |
| **ServerListView** | List of paired servers (multi-server support) |
| **SessionListView** | Active sessions under a server, grouped by project |
| **ChatView** | Message stream, tool result display, model/mode selector |
| **ComposeView** | Input bar with quick model/mode toggle |
| **SettingsView** | Server management, notification toggle, key management |

### ComposeView Layout

```
┌─────────────────────────────────┐
│  [Opus ▾]  [Auto ▾]            │
│  ┌───────────────────────┐ [➤] │
│  │ Input message...      │     │
│  └───────────────────────┘     │
└─────────────────────────────────┘
```

### Dynamic Island / Live Activity

| Status | Display |
|--------|---------|
| thinking | Project name + "Thinking..." |
| tool running | Project name + tool name (e.g., "Edit main.swift") |
| waiting approval | Project name + "Needs approval" |
| idle | Live Activity dismissed |

### Removed (vs Happy App)

- Registration/login → QR pairing
- Friends/social/feed → not needed
- Voice conversation → not needed
- Subscription/payment → not needed
- Full i18n → Chinese + English only
- Tauri desktop → MioIsland covers this
- Effort level → defer to later

## Module 4: Pairing & Encryption Flow

### Flow

```
MioIsland (Mac)                    CodeLight (iPhone)
     │                                    │
     ├─ Generate pairing code             │
     │  (server URL + temp pubkey         │
     │   + device name)                   │
     │                                    │
     ├─ Display QR ◄──── Scan ──────────► │
     │                                    │
     │   ─── Temp encrypted channel ───── │
     │       (Server relay)               │
     │                                    │
     ├─ Exchange permanent pubkeys ◄────► │
     ├─ Exchange session encryption  ◄──► │
     │   seed                             │
     │                                    │
     ├─ Pairing complete,                 ├─ Pairing complete,
     │  store in Keychain                 │  store in Keychain
     │                                    │
     └─ All future comms E2E encrypted ──►└─
```

### QR Code Content

```json
{
  "s": "wss://hs.wdao.chat:8443",
  "k": "<temp public key, base64>",
  "n": "Ying's Mac"
}
```

### Key Storage

- **Keychain:** device keypair (permanent), paired device public keys, session encryption seeds
- **Not stored on server:** private keys never leave the device

## Development Phases

| Phase | Scope | Deliverable |
|-------|-------|-------------|
| **Phase 0** | Merge Happy upstream + run locally | Working Happy setup as reference |
| **Phase 1** | CodeLight Server — auth, pairing, session, socket | Deployable server on Tencent Cloud |
| **Phase 2** | Shared Swift Packages — protocol, crypto, socket | Reusable SPM packages |
| **Phase 3** | MioIsland additions — socket uplink, message relay, RPC | MioIsland syncs to server |
| **Phase 4** | CodeLight App — pairing, session list, chat (read-only) | iPhone app showing sessions |
| **Phase 5** | CodeLight App — send messages, model/mode selector, RPC | Full remote control |
| **Phase 6** | Dynamic Island — Live Activity widget extension | Status on lock screen + Dynamic Island |
| **Phase 7** | APNs push notifications | Background alerts |

## Multi-Server / Multi-User

- iPhone app stores multiple server configurations (each from a separate QR pairing)
- ServerListView shows all paired servers
- Each server is independent — different keys, different sessions
- Server supports multiple devices connecting — each device identified by its public key
- One MioIsland instance connects to one server at a time (configurable)
