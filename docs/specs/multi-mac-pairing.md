# Multi-Mac Pairing + Remote Session Launch

**Status:** approved 2026-04-06, in progress
**Scope:** allow one iPhone to pair with multiple Mac MioIslands via short-code, manage them as a list, and remotely trigger new Claude sessions on a chosen Mac via cmux.

## Background

Current state (verified 2026-04-06):
- Server (`server/prisma/schema.prisma`) has `Device`, `DeviceLink`, `Session`, `PairingRequest` tables. The schema already supports many-to-many device linking.
- `pairingRoutes.ts` has `/v1/pairing/request` + `/respond` + `/status` endpoints that DO call `linkDevices()` — but the Mac side never invokes them. `PairPhoneView.swift` (MioIsland) generates a QR with payload `{s: serverUrl, k: "", n: deviceName}` — no `tempPublicKey`, no actual pairing request. So `DeviceLink` table is currently empty in production.
- iOS `AppState.ServerConfig` conflates "a Mac" with "a server". Each QR scan creates a new ServerConfig with the same `url` but different `name`, leading to duplicate "server" entries that are really the same backend.
- Server-side `canAccessSession()` (auth/deviceAccess.ts:34) already enforces deviceId-scoped isolation: a device can only see sessions from itself + linked devices.
- cmux supports `cmux new-session -c <cwd> [tokens...]` (CLI/cmux.swift:10194) which calls `workspace.create` + `surface.send_text`.

**Known issue, NOT in scope of this plan:** cmux uses `--settings` flag overriding `~/.claude/settings.json`, bypassing MioIsland's hooks. Sessions launched via `cmux new-session` won't automatically appear in MioIsland's session list. This is a separate task; for this plan we accept that "iPhone presses launch → Mac opens cmux window with Claude running" is the success criterion, and the resulting session may take longer to surface in the iPhone session list.

## Goals

1. Replace QR with short-code pairing (server URL + 6-char code) — easier UX, no camera
2. Support N Macs ↔ 1 iPhone via DeviceLink, each Mac uniquely identified, sessions data-isolated
3. iOS: rebuild concept model — `Backend` (singleton) + `LinkedMac[]`, navigation Macs → Sessions → Chat
4. iOS: remote-launch new session by picking a preset + project path on a chosen Mac
5. Mac MioIsland: manage launch presets, sync project paths, receive launch events, spawn cmux subprocess

## Non-goals

- P2P / LAN-direct connection (still goes through `island.wdao.chat`)
- Fixing cmux session visibility (separate task)
- iPhone-to-iPhone linking (DeviceLink supports it but we don't expose the UI)
- Renaming a paired Mac from iPhone (Mac controls its own name)

## Architecture

```
Backend (1)
  └── Linked Macs (N)
        ├── Launch Presets (per Mac)
        ├── Known Project Paths (per Mac)
        └── Sessions (per Mac, isolated by deviceId)
```

iPhone has ONE keypair → ONE deviceId on server. Each Mac has ONE keypair → ONE deviceId. DeviceLink rows form the bipartite graph. Server filters all session/preset/project queries through `canAccessSession()` style checks.

## Phase 1 — Server

### 1.1 Schema (`server/prisma/schema.prisma`)

Add to `Device`:
```prisma
kind          String         @default("ios")  // 'ios' | 'mac'
shortCode     String?        @unique          // permanent 6-char pairing code (Macs only, lazy-allocated, never rotated)
launchPresets LaunchPreset[]
knownProjects KnownProject[]
```

`PairingRequest.shortCode` was added during phase 1.2 but became unused after phase 1.5 redesign — left in place to avoid prod migration churn. Safe to drop in a future cleanup.

**ShortCode lifecycle (post-1.5):** Each Mac has ONE permanent shortCode tied 1:1 to its `Device.id`. Lazy-generated on first `POST /v1/devices/me {kind: "mac"}`, never rotated, never expires. iPhone redeems by code → server looks up Device by `shortCode` → creates DeviceLink. Pairing additional iPhones is just additional redeem calls with the same code. Restarting Mac MioIsland does NOT change the code.

Security tradeoff: anyone who learns the 6-char code can pair with that Mac forever. 30B combinations × no public listing = sufficient for personal use. Future hardening option: Mac-side approval popup for new pair attempts (out of scope).

New tables:
```prisma
model LaunchPreset {
  id        String   @id @default(cuid())
  deviceId  String
  device    Device   @relation(fields: [deviceId], references: [id])
  name      String
  command   String
  icon      String?
  sortOrder Int      @default(0)
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  @@index([deviceId, sortOrder])
}

model KnownProject {
  id         String   @id @default(cuid())
  deviceId   String
  device     Device   @relation(fields: [deviceId], references: [id])
  path       String
  name       String
  lastSeenAt DateTime @default(now())

  @@unique([deviceId, path])
  @@index([deviceId, lastSeenAt(sort: Desc)])
}
```

Migration name: `20260406_multi_mac_pairing`

### 1.2 Endpoints

All require `authMiddleware`. Link checks via `getAccessibleDeviceIds()`.

| Method | Path | Caller | Body / Query | Returns |
|---|---|---|---|---|
| ~~POST `/v1/pairing/code/create`~~ | — | removed in phase 1.5 — code now comes from `POST /v1/devices/me` (lazy-allocated, permanent) | |
| POST | `/v1/pairing/code/redeem` | iPhone | `{code}` | `{macDeviceId, name, kind}` (looks up `Device.shortCode`) |
| GET  | `/v1/pairing/links` | both | — | `[{deviceId, name, kind, createdAt}]` |
| DELETE | `/v1/pairing/links/:targetDeviceId` | iPhone | — | `{ok: true}` (also pushes `link-removed` socket event to target) |
| POST | `/v1/devices/me` | both | `{name, kind}` | `{deviceId, name, kind, shortCode}` (shortCode non-null only for kind=mac) |
| GET  | `/v1/devices/:deviceId/presets` | iPhone | — | `[Preset]` (requires link) |
| PUT  | `/v1/devices/me/presets` | Mac | `[{name, command, icon?, sortOrder}]` | `{ok: true, count}` |
| GET  | `/v1/devices/:deviceId/projects` | iPhone | `?limit=30` | `[KnownProject]` (requires link, sorted by lastSeenAt desc) |
| PUT  | `/v1/devices/me/projects` | Mac | `[{path, name}]` | `{ok: true, count}` (upsert + bump lastSeenAt) |
| POST | `/v1/sessions/launch` | iPhone | `{macDeviceId, presetId, projectPath}` | `{ok: true, dispatched: bool}` (validates link, pushes `session-launch` socket event) |

### 1.3 Socket events (server → device)

Reuse existing eventRouter with deviceId scope:
- `link-removed { sourceDeviceId }`
- `session-launch { presetId, projectPath, requestedByDeviceId }`

### 1.4 ShortCode generation

- Charset: `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no I/L/O/0/1)
- Length: 6
- Retry up to 3 on collision (PairingRequest.shortCode unique)
- TTL: 5 minutes

### 1.5 Deploy

```bash
ssh root@106.54.19.137
cd /path/to/codelight-server  # confirm path on box
git pull
npx prisma migrate deploy
pm2 restart codelight-server
```

## Phase 2 — Mac MioIsland

Branch: `feature/codelight-sync` (continue, not merged to main yet).

### 2.1 Update `PairPhoneView.swift` (keep QR, add short code)

- On Mac startup, `SyncManager` calls `POST /v1/devices/me {name, kind: "mac"}` and caches the returned `shortCode` (permanent)
- On open: read cached `shortCode` (no per-open API call needed)
- Display BOTH:
  - QR (as today, but payload changed to `{server, code}` — see below)
  - Big monospace 6-char short code beneath the QR (no countdown — it's permanent)
  - Server URL as small text under the code
  - Hint text: "this code is permanent — anyone with it can pair"
- QR payload: `{"server": "https://island.wdao.chat", "code": "X7K2M9"}` (replaces old `{s, k, n}`)
- Both QR scanning and manual code entry on iPhone hit the same `/v1/pairing/code/redeem` endpoint — single backend path
- "Paired iPhones" section: lists `GET /v1/pairing/links`, swipe to unpair

### 2.2 SyncManager additions

`ClaudeIsland/Services/Sync/SyncManager.swift`:
- On connect: `POST /v1/devices/me {kind: "mac", name: Host.current().localizedName}`
- Subscribe to `link-removed` → clean local paired-device state
- Subscribe to `session-launch` → call `LaunchService.launch(presetId, projectPath)`

### 2.3 Presets

New `ClaudeIsland/Models/LaunchPreset.swift`:
- Codable struct: `id, name, command, icon?, sortOrder`
- Persisted in UserDefaults (`launchPresets` JSON array)
- Default presets seeded on first launch:
  - `Claude (skip perms)` — `claude --dangerously-skip-permissions` — icon `sparkles`
  - `Claude + Chrome` — `claude --dangerously-skip-permissions --chrome` — icon `globe`

New `ClaudeIsland/Services/State/PresetStore.swift`:
- `@MainActor` ObservableObject
- CRUD methods, every mutation calls `PUT /v1/devices/me/presets`

New `ClaudeIsland/UI/Views/PresetSettingsView.swift`:
- Add row to NotchMenuView "Launch Presets"
- List + add/edit/delete + reorder

### 2.4 Project paths

`ClaudeIsland/Services/State/SessionStore.swift`:
- After session list updates, collect unique cwds, push to `PUT /v1/devices/me/projects`
- Optional: also scan `~/.claude/projects/` directory entries (lightweight, just dir names → reverse-decode to paths if format allows)

### 2.5 LaunchService

New `ClaudeIsland/Services/Session/LaunchService.swift`:

```swift
@MainActor
final class LaunchService {
    static let shared = LaunchService()

    func launch(presetId: String, projectPath: String) {
        guard let preset = PresetStore.shared.preset(id: presetId) else { return }
        guard FileManager.default.fileExists(atPath: projectPath) else { return }

        let cmuxPath = findCmuxBinary()  // try /opt/homebrew/bin/cmux, /usr/local/bin/cmux, $PATH
        let tokens = preset.command.split(separator: " ").map(String.init)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmuxPath)
        process.arguments = ["new-session", "-c", projectPath] + tokens
        do {
            try process.run()
        } catch {
            print("[LaunchService] Failed: \(error)")
        }
    }

    private func findCmuxBinary() -> String {
        for p in ["/opt/homebrew/bin/cmux", "/usr/local/bin/cmux", "\(NSHomeDirectory())/.local/bin/cmux"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return "/usr/bin/env"  // fallback, will fail loudly
    }
}
```

## Phase 3 — iOS CodeLight

### 3.1 Models

`app/CodeLight/Models/AppState.swift`:
- Remove `[ServerConfig] servers` + `currentServer`
- Add `Backend?` (single, persisted under `"backend"` key)
- Add `[LinkedMac] linkedMacs` (cache, refreshed from server)
- One-shot migration from `"servers"` UserDefaults key: take `servers[0]` → `Backend`, drop the rest

```swift
struct Backend: Codable, Hashable {
    var url: String
    let pairedAt: Date
}

struct LinkedMac: Codable, Identifiable, Hashable {
    let deviceId: String
    let name: String
    let kind: String  // always "mac" for now
    let createdAt: Date
    var id: String { deviceId }
}
```

### 3.2 SessionInfo extension

Server returns sessions including `ownerDeviceId` + `ownerDeviceName`. Update `SessionMetadata` (CodeLightProtocol) to decode these.

### 3.3 Pairing UI (QR + short-code, both supported)

Update `app/CodeLight/Views/PairingView.swift` to support BOTH input modes:

Top tab/segment switch: **[Scan QR] | [Enter Code]**

**Scan QR mode** (default if camera available):
- Existing QRScannerView, but parser updated to decode new payload `{server, code}`
- On scan: call `POST /v1/pairing/code/redeem` with the embedded code, using the embedded server URL
- Same success path as manual entry

**Enter Code mode**:
1. **Server URL field** (prefilled `https://island.wdao.chat`, persisted)
   - Quick-input pill row above field: `[https://] [http://] [.com] [.chat] [:3006]`
   - Tapping pill appends/prepends to text intelligently
   - Hidden after first successful pair (only shown again from Settings)
2. **6-char code field** (large monospace, autocaps, 6-char limit)
3. **Pair button** → `POST /v1/pairing/code/redeem`

Both paths converge on success → toast "Paired with {Mac name}" → refresh linkedMacs.

Backwards-compat note: old QR payloads `{s, k, n}` should be detected and rejected with a friendly "This QR is from an outdated MioIsland — please update your Mac app".

### 3.4 Navigation

`RootView`:
- No backend → `PairWithCodeView`
- Has backend → `LinkedMacsListView`

New `LinkedMacsListView` (replaces ServerListView):
- Title: "Macs"
- Header: backend host (small grey)
- List of LinkedMac rows: icon + name + "N sessions" + green/grey dot
- `+` button → `PairWithCodeView` modal (for additional Mac)
- Swipe-to-unlink → `DELETE /v1/pairing/links/:macDeviceId`
- Tap → `MacSessionListView(mac:)`

`MacSessionListView` (refactor of SessionListView):
- Filter sessions by `metadata.ownerDeviceId == mac.deviceId`
- Title = mac.name
- Top-right `+` → `LaunchSessionSheet(mac:)`
- Tap session → existing ChatView

### 3.5 LaunchSessionSheet

New `app/CodeLight/Views/LaunchSessionSheet.swift`:

Step 1 — Pick preset:
- Fetch `GET /v1/devices/:macDeviceId/presets`
- Each row: SF Symbol icon + name + command (small grey)

Step 2 — Pick project path:
- Recent projects: `GET /v1/devices/:macDeviceId/projects?limit=30`
- Section "Recent": tappable rows, name + path
- Section "Custom": text field with autofill from history

Step 3 — Launch button:
- `POST /v1/sessions/launch {macDeviceId, presetId, projectPath}`
- Dismiss + toast "Sent to {Mac name}"

### 3.6 Settings

`app/CodeLight/Views/SettingsView.swift`:
- "Backend" section: backend.url read-only + "Change" button
- "Paired Macs" section: list linkedMacs, swipe to unlink
- Remove old multi-server concept

## Phase 4 — End-to-end test

Manual checklist:
- [ ] Mac launches → registered as `kind: mac`, name correct
- [ ] Mac "Pair iPhone" → 6-char code displayed
- [ ] iPhone enters server URL + code → pair success → Mac in linkedMacs
- [ ] Mac edits presets → iPhone sees updated list
- [ ] iPhone enters Mac → only that Mac's sessions visible
- [ ] iPhone taps + → picks preset + path → Mac spawns cmux window with Claude running
- [ ] iPhone unlinks Mac → Mac receives `link-removed` event → UI updates
- [ ] Pair second Mac → linkedMacs has 2 rows
- [ ] Second iPhone (only linked to Mac1) cannot see Mac2's sessions (data isolation)

## Risks

1. **cmux session visibility** (out of scope, see Background) — first-time users will see "session launched" but session may not appear in iPhone list immediately
2. **Process spawn permissions** — Mac may need Full Disk Access or process spawn entitlement; verify in dev build
3. **shortCode collision** — 30B combinations × 5min TTL × low concurrency = effectively zero, but retry logic still needed
4. **Migration on prod** — `prisma migrate deploy` will lock tables briefly; do during low traffic
