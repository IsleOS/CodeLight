# CodeLight

iPhone companion app for Claude Code. Native SwiftUI + a small Node.js sync server. Pairs with [MioIsland](https://github.com/MioMioOS/MioIsland) on the Mac for end-to-end real-time session monitoring + Dynamic Island Live Activity.

- **Repo:** https://github.com/MioMioOS/CodeLight
- **Production server:** `https://island.wdao.chat` (Tencent Cloud `106.54.19.137`, `pm2` process `codelight-server`, port 3006)
- **Bundle IDs:** `com.codelight.app` + `com.codelight.app.widget`
- **Team ID:** `4GT6V2DUTF`

## Architecture

```
Claude Code → MioIsland (Mac) → island.wdao.chat → CodeLight (iPhone)
```

- **`server/`** — Fastify + Socket.io + Prisma/PostgreSQL, run with `npx tsx --env-file=.env ./sources/main.ts` (no build step)
- **`packages/CodeLightProtocol`** — shared Swift types (AuthRequest, SessionMetadata, etc)
- **`packages/CodeLightCrypto`** — Curve25519 sign/verify + key management
- **`packages/CodeLightSocket`** — Swift Socket.io wrapper
- **`app/`** — SwiftUI iPhone app + Widget Extension (Dynamic Island Live Activity)

## Local development

```bash
# Server
cd server
npm install
npm run dev    # if defined, otherwise: npx tsx --env-file=.env ./sources/main.ts

# Type-check the server (no emit)
cd server && npx tsc --noEmit

# Build iOS app
cd app
xcodebuild -scheme CodeLight -configuration Debug \
  -destination 'generic/platform=iOS' build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""
```

## Production deployment

The production server lives at `/var/www/codelight-server` on `root@106.54.19.137`. **It is NOT a git checkout** — files were rsynced up originally and the directory tree is owned by `501:staff` (mac user). To deploy code changes:

```bash
# 1. Rsync only the files you changed (don't rsync node_modules / .env / blobs)
cd server
rsync -av --relative \
  sources/<changed paths> \
  prisma/schema.prisma \
  prisma/migrations/<new migration dir> \
  root@106.54.19.137:/var/www/codelight-server/

# 2. Apply migrations + restart
ssh root@106.54.19.137 'cd /var/www/codelight-server && \
  npx prisma migrate deploy && \
  npx prisma generate && \
  pm2 restart codelight-server'

# 3. Verify health
ssh root@106.54.19.137 'pm2 logs codelight-server --lines 30 --nostream'
```

DB inspection:
```bash
ssh root@106.54.19.137 'cd /var/www/codelight-server && source .env && \
  psql "$DATABASE_URL" -c "SELECT ... FROM \"Device\" LIMIT 5;"'
```

## Conventions / gotchas

- **Server runs from TypeScript directly via `tsx`** — no build step. `npx tsc --noEmit` is for typecheck only.
- **`tweetnacl-util` ESM** — use `import tweetnaclUtil from 'tweetnacl-util'; const { decodeBase64 } = tweetnaclUtil;` (default import). Named imports break.
- **Socket.io Swift client** — auth token must be passed via **query params**, not `handshake.auth` (the Swift client serializes auth differently).
- **MessageRelay** must use the server's `cuid` session ID, never the local Claude session UUID.
- **Fetching latest messages** — always `ORDER BY seq DESC`, never timestamp.
- **Scroll prepend** — never use `onChange(messages.count)` for "new message at bottom" detection; check the seq of the first vs last visible message.
- **`MioIsland` JSONL scanner is permanently disabled** — it false-triggers on `cmux` subagent files and there's no clean way to distinguish them. Hooks via `~/.claude/settings.json` are the only reliable session source.
- **Prisma migrations are versioned** — to add a column, write the SQL by hand under `prisma/migrations/<timestamp>_<name>/migration.sql`. Don't use `prisma migrate dev` against production.

## Push notification model

- iOS registers an APNs token via `POST /v1/push-tokens` (per device, multiple tokens allowed)
- Server stores per-device notification preferences: master `notificationsEnabled` + 3 per-kind toggles (`notifyOnCompletion`, `notifyOnApproval`, `notifyOnError`)
- `notifyLinkedIPhones()` in `sessionHandler.ts` is the central push gate — it checks: (1) device has at least one DeviceLink, (2) master is on, (3) per-kind is on, (4) `lastSeenAt` is within `tokenExpiryDays + 1 day` (filters JWT-expired devices)
- **APNs error self-healing** — `sendPush()` returns `{ ok, status, reason, terminal }`. Tokens marked `terminal` (410 Unregistered/ExpiredToken, 400 BadDeviceToken/DeviceTokenNotForTopic) are deleted from the DB immediately. Apple's docs explicitly require this.
- **Cascade cleanup on unpair** — `DELETE /v1/pairing/links/:targetDeviceId` checks if either side has 0 remaining links and, if so, drops their PushTokens too. iOS's `AppState.reset()` calls `deleteAllPushTokens` + `unlinkDevice` for every Mac before wiping local state.

## Known issues / TODO

- APNs `.p8` key is configured but production/sandbox path picking still occasionally needs `APNS_USE_SANDBOX=true` for Xcode-signed local builds
- Permission approval RPC wiring is placeholder (UI exists, backend not yet wired)
- `cmux --settings` flag overrides `~/.claude/settings.json`, bypassing MioIsland hooks — need a different integration based on pid/tty/cwd

## Useful one-liners

```bash
# Tail production logs
ssh root@106.54.19.137 'pm2 logs codelight-server --lines 50 --nostream'

# Check pm2 process health
ssh root@106.54.19.137 'pm2 jlist | python3 -c "import sys,json,time; \
  d=json.loads(sys.stdin.read()); \
  p=[x for x in d if x[\"name\"]==\"codelight-server\"][0]; \
  print(f\"status={p[\\\"pm2_env\\\"][\\\"status\\\"]} restarts={p[\\\"pm2_env\\\"][\\\"restart_time\\\"]}\")"'

# List devices in production
ssh root@106.54.19.137 'cd /var/www/codelight-server && source .env && \
  psql "$DATABASE_URL" -c "SELECT id, name, kind, \"lastSeenAt\" FROM \"Device\" ORDER BY \"lastSeenAt\" DESC NULLS LAST LIMIT 10;"'
```
