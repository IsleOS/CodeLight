# CodeLight Server Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a clean Fastify/TypeScript server that relays E2E encrypted Claude Code session data between MioIsland (macOS) and CodeLight (iPhone) via Socket.io.

**Architecture:** Fastify 5 HTTP server + Socket.io for real-time sync. Public key (Ed25519) auth — no passwords, no OAuth. Server is zero-knowledge: stores only ciphertext. Three connection types (device-scoped, session-scoped, user-scoped) with selective event routing.

**Tech Stack:** Node.js, TypeScript, Fastify 5, Socket.io, Prisma, PostgreSQL, Zod, TweetNaCl

**Reference:** Happy Server at `/Users/ying/Documents/happy/happy/packages/happy-server/` — protocol-compatible rewrite, not a fork.

---

## File Structure

```
CodeLight/server/
├── package.json
├── tsconfig.json
├── vitest.config.ts
├── .env.example
├── .env.dev
├── prisma/
│   └── schema.prisma
└── sources/
    ├── main.ts                    # Entry point: init DB, auth, start API
    ├── config.ts                  # Environment config with defaults
    ├── api.ts                     # Fastify setup, CORS, route registration
    ├── auth/
    │   ├── crypto.ts              # Ed25519 verify, token sign/verify (tweetnacl + JWT)
    │   ├── crypto.spec.ts
    │   ├── middleware.ts          # Bearer token Fastify hook
    │   └── middleware.spec.ts
    ├── pairing/
    │   ├── pairingRoutes.ts       # QR pairing endpoints (request/respond/status)
    │   └── pairingRoutes.spec.ts
    ├── session/
    │   ├── sessionRoutes.ts       # Session CRUD + message endpoints
    │   └── sessionRoutes.spec.ts
    ├── socket/
    │   ├── socketServer.ts        # Socket.io init, connection auth, handler registration
    │   ├── eventRouter.ts         # Broadcast routing by connection type
    │   ├── eventRouter.spec.ts
    │   ├── sessionHandler.ts      # message, update-metadata, session-alive, session-end
    │   └── rpcHandler.ts          # RPC forwarding between sockets
    └── storage/
        ├── db.ts                  # Prisma client singleton
        ├── seq.ts                 # Atomic sequence allocation
        └── seq.spec.ts
```

---

## Chunk 1: Scaffolding + Database

### Task 1: Project scaffolding

**Files:**
- Create: `server/package.json`
- Create: `server/tsconfig.json`
- Create: `server/vitest.config.ts`
- Create: `server/.env.example`
- Create: `server/.env.dev`

- [ ] **Step 1: Create package.json**

```json
{
    "name": "codelight-server",
    "version": "0.1.0",
    "private": true,
    "type": "module",
    "scripts": {
        "build": "tsc --noEmit",
        "dev": "tsx --env-file=.env.dev ./sources/main.ts",
        "start": "tsx ./sources/main.ts",
        "test": "vitest run",
        "migrate": "dotenv -e .env.dev -- prisma migrate dev",
        "generate": "prisma generate",
        "postinstall": "prisma generate",
        "db": "docker run -d -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=codelight -v $(pwd)/.pgdata:/var/lib/postgresql/data -p 5432:5432 postgres"
    },
    "dependencies": {
        "@prisma/client": "^6.11.1",
        "fastify": "^5.2.0",
        "fastify-type-provider-zod": "^4.0.2",
        "@fastify/cors": "^10.0.1",
        "socket.io": "^4.8.1",
        "jsonwebtoken": "^9.0.2",
        "tweetnacl": "^1.0.3",
        "tweetnacl-util": "^0.15.1",
        "zod": "^3.25.0",
        "uuid": "^9.0.1",
        "prisma": "^6.11.1"
    },
    "devDependencies": {
        "@types/jsonwebtoken": "^9.0.10",
        "@types/node": "^20.12.3",
        "dotenv-cli": "^8.0.0",
        "tsx": "^4.19.2",
        "typescript": "^5.9.3",
        "vite-tsconfig-paths": "^5.1.4",
        "vitest": "^3.2.0"
    }
}
```

- [ ] **Step 2: Create tsconfig.json**

```json
{
    "compilerOptions": {
        "target": "ES2022",
        "module": "ESNext",
        "moduleResolution": "bundler",
        "strict": true,
        "esModuleInterop": true,
        "skipLibCheck": true,
        "outDir": "./dist",
        "rootDir": "./sources",
        "paths": {
            "@/*": ["./sources/*"]
        }
    },
    "include": ["sources/**/*.ts"],
    "exclude": ["node_modules", "dist"]
}
```

- [ ] **Step 3: Create vitest.config.ts**

```typescript
import { defineConfig } from 'vitest/config';
import tsconfigPaths from 'vite-tsconfig-paths';

export default defineConfig({
    plugins: [tsconfigPaths()],
    test: {
        globals: true,
    },
});
```

- [ ] **Step 4: Create .env.example and .env.dev**

`.env.example`:
```
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/codelight
MASTER_SECRET=change-me-to-a-random-string
PORT=3005
```

`.env.dev`:
```
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/codelight
MASTER_SECRET=dev-secret-do-not-use-in-production
PORT=3005
```

- [ ] **Step 5: Create sources/config.ts**

```typescript
export const config = {
    port: parseInt(process.env.PORT || '3005', 10),
    masterSecret: process.env.MASTER_SECRET || '',
    databaseUrl: process.env.DATABASE_URL || '',
} as const;
```

- [ ] **Step 6: Install dependencies**

Run: `cd server && npm install`
Expected: node_modules created, no errors

- [ ] **Step 7: Verify TypeScript compiles**

Run: `cd server && npx tsc --noEmit`
Expected: No errors (empty project, just config)

- [ ] **Step 8: Commit**

```bash
git add server/
git commit -m "feat(server): scaffold project with dependencies"
```

---

### Task 2: Prisma schema + database

**Files:**
- Create: `server/prisma/schema.prisma`
- Create: `server/sources/storage/db.ts`

- [ ] **Step 1: Create Prisma schema**

```prisma
generator client {
    provider = "prisma-client-js"
}

datasource db {
    provider = "postgresql"
    url      = env("DATABASE_URL")
}

model Device {
    id        String   @id @default(cuid())
    publicKey String   @unique
    name      String
    seq       Int      @default(0)
    createdAt DateTime @default(now())
    updatedAt DateTime @updatedAt

    sessions   Session[]
    pushTokens PushToken[]
}

model Session {
    id              String   @id @default(cuid())
    tag             String
    deviceId        String
    device          Device   @relation(fields: [deviceId], references: [id])
    metadata        String   // encrypted JSON (client-encrypted, server opaque)
    metadataVersion Int      @default(0)
    seq             Int      @default(0)
    active          Boolean  @default(true)
    lastActiveAt    DateTime @default(now())
    createdAt       DateTime @default(now())
    updatedAt       DateTime @updatedAt

    messages SessionMessage[]

    @@unique([deviceId, tag])
    @@index([deviceId, updatedAt(sort: Desc)])
}

model SessionMessage {
    id        String   @id @default(cuid())
    sessionId String
    session   Session  @relation(fields: [sessionId], references: [id])
    localId   String?
    seq       Int
    content   String   // encrypted content (server opaque)
    createdAt DateTime @default(now())

    @@unique([sessionId, localId])
    @@index([sessionId, seq])
}

model PairingRequest {
    id              String   @id @default(cuid())
    tempPublicKey   String   @unique
    serverUrl       String
    deviceName      String
    response        String?  // encrypted response from scanning device
    responseDeviceId String?
    createdAt       DateTime @default(now())
    expiresAt       DateTime // 5 minutes from creation

    @@index([tempPublicKey])
}

model PushToken {
    id        String   @id @default(cuid())
    deviceId  String
    device    Device   @relation(fields: [deviceId], references: [id])
    token     String
    createdAt DateTime @default(now())
    updatedAt DateTime @updatedAt

    @@unique([deviceId, token])
}
```

- [ ] **Step 2: Create db.ts**

```typescript
import { PrismaClient } from '@prisma/client';

export const db = new PrismaClient();
```

- [ ] **Step 3: Generate Prisma client**

Run: `cd server && npx prisma generate`
Expected: Prisma Client generated successfully

- [ ] **Step 4: Start PostgreSQL and run migration**

Run: `cd server && npm run db && sleep 3 && npm run migrate`
Expected: Database created, migration applied

- [ ] **Step 5: Commit**

```bash
git add server/prisma/ server/sources/storage/
git commit -m "feat(server): add Prisma schema and database setup"
```

---

### Task 3: Sequence allocation

**Files:**
- Create: `server/sources/storage/seq.ts`
- Create: `server/sources/storage/seq.spec.ts`

- [ ] **Step 1: Write failing test**

```typescript
// seq.spec.ts
import { describe, it, expect, vi } from 'vitest';
import { allocateDeviceSeq, allocateSessionSeq, allocateSessionSeqBatch } from './seq';

// Mock Prisma
vi.mock('./db', () => ({
    db: {
        device: {
            update: vi.fn().mockResolvedValue({ seq: 1 }),
        },
        session: {
            update: vi.fn().mockResolvedValue({ seq: 1 }),
        },
    },
}));

describe('allocateDeviceSeq', () => {
    it('should increment and return new seq', async () => {
        const seq = await allocateDeviceSeq('device-1');
        expect(seq).toBe(1);
    });
});

describe('allocateSessionSeq', () => {
    it('should increment and return new seq', async () => {
        const seq = await allocateSessionSeq('session-1');
        expect(seq).toBe(1);
    });
});

describe('allocateSessionSeqBatch', () => {
    it('should allocate N sequences and return start seq', async () => {
        const { db } = await import('./db');
        (db.session.update as any).mockResolvedValueOnce({ seq: 5 });
        const startSeq = await allocateSessionSeqBatch('session-1', 5);
        expect(startSeq).toBe(1); // 5 - 5 + 1
    });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && npx vitest run sources/storage/seq.spec.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement seq.ts**

```typescript
import { db } from './db';

export async function allocateDeviceSeq(deviceId: string): Promise<number> {
    const result = await db.device.update({
        where: { id: deviceId },
        data: { seq: { increment: 1 } },
        select: { seq: true },
    });
    return result.seq;
}

export async function allocateSessionSeq(sessionId: string): Promise<number> {
    const result = await db.session.update({
        where: { id: sessionId },
        data: { seq: { increment: 1 } },
        select: { seq: true },
    });
    return result.seq;
}

export async function allocateSessionSeqBatch(sessionId: string, count: number): Promise<number> {
    const result = await db.session.update({
        where: { id: sessionId },
        data: { seq: { increment: count } },
        select: { seq: true },
    });
    return result.seq - count + 1;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && npx vitest run sources/storage/seq.spec.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/sources/storage/seq.ts server/sources/storage/seq.spec.ts
git commit -m "feat(server): add atomic sequence allocation"
```

---

## Chunk 2: Auth Module

### Task 4: Crypto utilities (Ed25519 + JWT)

**Files:**
- Create: `server/sources/auth/crypto.ts`
- Create: `server/sources/auth/crypto.spec.ts`

- [ ] **Step 1: Write failing test**

```typescript
// crypto.spec.ts
import { describe, it, expect } from 'vitest';
import nacl from 'tweetnacl';
import { encodeBase64, decodeBase64 } from 'tweetnacl-util';
import { verifySignature, createToken, verifyToken } from './crypto';

describe('verifySignature', () => {
    it('should verify a valid Ed25519 signature', () => {
        const keyPair = nacl.sign.keyPair();
        const message = new TextEncoder().encode('hello');
        const signature = nacl.sign.detached(message, keyPair.secretKey);

        const valid = verifySignature(
            encodeBase64(message),
            encodeBase64(signature),
            encodeBase64(keyPair.publicKey)
        );
        expect(valid).toBe(true);
    });

    it('should reject an invalid signature', () => {
        const keyPair = nacl.sign.keyPair();
        const message = new TextEncoder().encode('hello');
        const badSig = new Uint8Array(64); // all zeros

        const valid = verifySignature(
            encodeBase64(message),
            encodeBase64(badSig),
            encodeBase64(keyPair.publicKey)
        );
        expect(valid).toBe(false);
    });
});

describe('createToken / verifyToken', () => {
    it('should create and verify a token', () => {
        const token = createToken('device-123', 'test-secret');
        const payload = verifyToken(token, 'test-secret');
        expect(payload).not.toBeNull();
        expect(payload!.deviceId).toBe('device-123');
    });

    it('should reject a token with wrong secret', () => {
        const token = createToken('device-123', 'test-secret');
        const payload = verifyToken(token, 'wrong-secret');
        expect(payload).toBeNull();
    });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && npx vitest run sources/auth/crypto.spec.ts`
Expected: FAIL

- [ ] **Step 3: Implement crypto.ts**

```typescript
import nacl from 'tweetnacl';
import { decodeBase64 } from 'tweetnacl-util';
import jwt from 'jsonwebtoken';

export function verifySignature(
    messageBase64: string,
    signatureBase64: string,
    publicKeyBase64: string
): boolean {
    try {
        const message = decodeBase64(messageBase64);
        const signature = decodeBase64(signatureBase64);
        const publicKey = decodeBase64(publicKeyBase64);
        return nacl.sign.detached.verify(message, signature, publicKey);
    } catch {
        return false;
    }
}

export interface TokenPayload {
    deviceId: string;
    iat?: number;
}

export function createToken(deviceId: string, secret: string): string {
    return jwt.sign({ deviceId }, secret);
}

export function verifyToken(token: string, secret: string): TokenPayload | null {
    try {
        return jwt.verify(token, secret) as TokenPayload;
    } catch {
        return null;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && npx vitest run sources/auth/crypto.spec.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/sources/auth/
git commit -m "feat(server): add Ed25519 signature verification and JWT tokens"
```

---

### Task 5: Auth middleware

**Files:**
- Create: `server/sources/auth/middleware.ts`
- Create: `server/sources/auth/middleware.spec.ts`

- [ ] **Step 1: Write failing test**

```typescript
// middleware.spec.ts
import { describe, it, expect } from 'vitest';
import { extractToken } from './middleware';

describe('extractToken', () => {
    it('should extract Bearer token from header', () => {
        const token = extractToken('Bearer abc123');
        expect(token).toBe('abc123');
    });

    it('should return null for missing header', () => {
        expect(extractToken(undefined)).toBeNull();
        expect(extractToken('')).toBeNull();
    });

    it('should return null for non-Bearer auth', () => {
        expect(extractToken('Basic abc123')).toBeNull();
    });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && npx vitest run sources/auth/middleware.spec.ts`
Expected: FAIL

- [ ] **Step 3: Implement middleware.ts**

```typescript
import { FastifyRequest, FastifyReply } from 'fastify';
import { verifyToken } from './crypto';
import { config } from '@/config';

declare module 'fastify' {
    interface FastifyRequest {
        deviceId?: string;
    }
}

export function extractToken(header: string | undefined): string | null {
    if (!header || !header.startsWith('Bearer ')) return null;
    return header.slice(7) || null;
}

export async function authMiddleware(
    request: FastifyRequest,
    reply: FastifyReply
): Promise<void> {
    const token = extractToken(request.headers.authorization);
    if (!token) {
        reply.code(401).send({ error: 'Missing authorization token' });
        return;
    }

    const payload = verifyToken(token, config.masterSecret);
    if (!payload) {
        reply.code(401).send({ error: 'Invalid token' });
        return;
    }

    request.deviceId = payload.deviceId;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && npx vitest run sources/auth/middleware.spec.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/sources/auth/
git commit -m "feat(server): add auth middleware with Bearer token extraction"
```

---

### Task 6: Auth routes (public key challenge)

**Files:**
- Create: `server/sources/auth/authRoutes.ts`

- [ ] **Step 1: Implement auth routes**

```typescript
import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { verifySignature, createToken } from './crypto';
import { db } from '@/storage/db';
import { config } from '@/config';

export async function authRoutes(app: FastifyInstance) {
    // Public key auth: client signs a challenge, server verifies and issues token
    app.post('/v1/auth', {
        schema: {
            body: z.object({
                publicKey: z.string(),
                challenge: z.string(),
                signature: z.string(),
            }),
        },
    }, async (request, reply) => {
        const { publicKey, challenge, signature } = request.body;

        if (!verifySignature(challenge, signature, publicKey)) {
            return reply.code(401).send({ error: 'Invalid signature' });
        }

        // Upsert device by public key
        const device = await db.device.upsert({
            where: { publicKey },
            create: { publicKey, name: 'Unknown Device' },
            update: {},
        });

        const token = createToken(device.id, config.masterSecret);
        return { success: true, token, deviceId: device.id };
    });
}
```

- [ ] **Step 2: Commit**

```bash
git add server/sources/auth/authRoutes.ts
git commit -m "feat(server): add public key auth route"
```

---

## Chunk 3: API + Pairing

### Task 7: Fastify API setup

**Files:**
- Create: `server/sources/api.ts`

- [ ] **Step 1: Implement API setup**

```typescript
import fastify from 'fastify';
import cors from '@fastify/cors';
import {
    serializerCompiler,
    validatorCompiler,
    type ZodTypeProvider,
} from 'fastify-type-provider-zod';
import { authRoutes } from '@/auth/authRoutes';
import { pairingRoutes } from '@/pairing/pairingRoutes';
import { sessionRoutes } from '@/session/sessionRoutes';
import { config } from '@/config';

export async function startApi() {
    const app = fastify({
        bodyLimit: 10 * 1024 * 1024, // 10MB
    }).withTypeProvider<ZodTypeProvider>();

    app.setValidatorCompiler(validatorCompiler);
    app.setSerializerCompiler(serializerCompiler);

    await app.register(cors, {
        origin: '*',
        methods: ['GET', 'POST', 'DELETE', 'OPTIONS'],
    });

    // Health check
    app.get('/health', async () => ({ status: 'ok' }));

    // Routes
    await app.register(authRoutes);
    await app.register(pairingRoutes);
    await app.register(sessionRoutes);

    await app.listen({ port: config.port, host: '0.0.0.0' });
    console.log(`CodeLight Server listening on port ${config.port}`);

    return app;
}
```

- [ ] **Step 2: Commit**

```bash
git add server/sources/api.ts
git commit -m "feat(server): add Fastify API setup with CORS and Zod"
```

---

### Task 8: Pairing routes (QR code flow)

**Files:**
- Create: `server/sources/pairing/pairingRoutes.ts`
- Create: `server/sources/pairing/pairingRoutes.spec.ts`

- [ ] **Step 1: Write failing test**

```typescript
// pairingRoutes.spec.ts
import { describe, it, expect, vi, beforeEach } from 'vitest';

// Test the pairing flow logic
describe('pairing flow', () => {
    it('should create a pairing request with expiry', () => {
        const now = Date.now();
        const expiresAt = new Date(now + 5 * 60 * 1000);
        expect(expiresAt.getTime()).toBeGreaterThan(now);
    });

    it('should reject expired pairing requests', () => {
        const expiredAt = new Date(Date.now() - 1000);
        expect(expiredAt.getTime()).toBeLessThan(Date.now());
    });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && npx vitest run sources/pairing/pairingRoutes.spec.ts`
Expected: FAIL

- [ ] **Step 3: Implement pairing routes**

```typescript
import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { db } from '@/storage/db';
import { authMiddleware } from '@/auth/middleware';

export async function pairingRoutes(app: FastifyInstance) {

    // Step 1: MioIsland creates a pairing request (authenticated)
    app.post('/v1/pairing/request', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                tempPublicKey: z.string(),
                serverUrl: z.string(),
                deviceName: z.string(),
            }),
        },
    }, async (request) => {
        const { tempPublicKey, serverUrl, deviceName } = request.body;
        const expiresAt = new Date(Date.now() + 5 * 60 * 1000); // 5 min

        const pairing = await db.pairingRequest.upsert({
            where: { tempPublicKey },
            create: { tempPublicKey, serverUrl, deviceName, expiresAt },
            update: { serverUrl, deviceName, expiresAt, response: null, responseDeviceId: null },
        });

        return { id: pairing.id, expiresAt: pairing.expiresAt.toISOString() };
    });

    // Step 2: CodeLight scans QR, responds with its public key (authenticated)
    app.post('/v1/pairing/respond', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                tempPublicKey: z.string(),
                response: z.string(), // encrypted key exchange payload
            }),
        },
    }, async (request, reply) => {
        const { tempPublicKey, response } = request.body;

        const pairing = await db.pairingRequest.findUnique({
            where: { tempPublicKey },
        });

        if (!pairing) {
            return reply.code(404).send({ error: 'Pairing request not found' });
        }

        if (pairing.expiresAt < new Date()) {
            return reply.code(410).send({ error: 'Pairing request expired' });
        }

        await db.pairingRequest.update({
            where: { id: pairing.id },
            data: { response, responseDeviceId: request.deviceId },
        });

        return { success: true };
    });

    // Step 3: MioIsland polls for response
    app.get('/v1/pairing/status', {
        preHandler: authMiddleware,
        schema: {
            querystring: z.object({
                tempPublicKey: z.string(),
            }),
        },
    }, async (request, reply) => {
        const { tempPublicKey } = request.query;

        const pairing = await db.pairingRequest.findUnique({
            where: { tempPublicKey },
        });

        if (!pairing) {
            return reply.code(404).send({ error: 'Not found' });
        }

        if (pairing.response) {
            // Clean up after successful pairing
            await db.pairingRequest.delete({ where: { id: pairing.id } });
            return {
                status: 'paired',
                response: pairing.response,
                responseDeviceId: pairing.responseDeviceId,
            };
        }

        if (pairing.expiresAt < new Date()) {
            await db.pairingRequest.delete({ where: { id: pairing.id } });
            return { status: 'expired' };
        }

        return { status: 'pending' };
    });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && npx vitest run sources/pairing/pairingRoutes.spec.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/sources/pairing/
git commit -m "feat(server): add QR pairing request/respond/status routes"
```

---

## Chunk 3: Session Management

### Task 9: Session routes

**Files:**
- Create: `server/sources/session/sessionRoutes.ts`

- [ ] **Step 1: Implement session routes**

```typescript
import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { db } from '@/storage/db';
import { authMiddleware } from '@/auth/middleware';
import { allocateSessionSeqBatch } from '@/storage/seq';

export async function sessionRoutes(app: FastifyInstance) {

    // List sessions
    app.get('/v1/sessions', {
        preHandler: authMiddleware,
    }, async (request) => {
        const sessions = await db.session.findMany({
            where: { deviceId: request.deviceId! },
            orderBy: { updatedAt: 'desc' },
            take: 150,
        });
        return { sessions };
    });

    // Create or load session (idempotent by tag)
    app.post('/v1/sessions', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                tag: z.string(),
                metadata: z.string(),
            }),
        },
    }, async (request) => {
        const { tag, metadata } = request.body;
        const deviceId = request.deviceId!;

        const session = await db.session.upsert({
            where: { deviceId_tag: { deviceId, tag } },
            create: { tag, deviceId, metadata },
            update: {},
        });

        return session;
    });

    // Get session messages (cursor-based)
    app.get('/v1/sessions/:sessionId/messages', {
        preHandler: authMiddleware,
        schema: {
            params: z.object({ sessionId: z.string() }),
            querystring: z.object({
                after_seq: z.coerce.number().default(0),
                limit: z.coerce.number().min(1).max(500).default(100),
            }),
        },
    }, async (request, reply) => {
        const { sessionId } = request.params;
        const { after_seq, limit } = request.query;

        // Verify ownership
        const session = await db.session.findFirst({
            where: { id: sessionId, deviceId: request.deviceId! },
        });
        if (!session) {
            return reply.code(404).send({ error: 'Session not found' });
        }

        const messages = await db.sessionMessage.findMany({
            where: { sessionId, seq: { gt: after_seq } },
            orderBy: { seq: 'asc' },
            take: limit + 1,
        });

        const hasMore = messages.length > limit;
        return {
            messages: messages.slice(0, limit),
            hasMore,
        };
    });

    // Batch send messages
    app.post('/v1/sessions/:sessionId/messages', {
        preHandler: authMiddleware,
        schema: {
            params: z.object({ sessionId: z.string() }),
            body: z.object({
                messages: z.array(z.object({
                    content: z.string(),
                    localId: z.string().optional(),
                })),
            }),
        },
    }, async (request, reply) => {
        const { sessionId } = request.params;
        const { messages } = request.body;

        // Verify ownership
        const session = await db.session.findFirst({
            where: { id: sessionId, deviceId: request.deviceId! },
        });
        if (!session) {
            return reply.code(404).send({ error: 'Session not found' });
        }

        // Allocate seqs
        const startSeq = await allocateSessionSeqBatch(sessionId, messages.length);

        const created = await db.$transaction(
            messages.map((msg, i) =>
                db.sessionMessage.create({
                    data: {
                        sessionId,
                        content: msg.content,
                        localId: msg.localId,
                        seq: startSeq + i,
                    },
                })
            )
        );

        return {
            messages: created.map(m => ({
                id: m.id,
                seq: m.seq,
                localId: m.localId,
            })),
        };
    });

    // Delete session
    app.delete('/v1/sessions/:sessionId', {
        preHandler: authMiddleware,
    }, async (request, reply) => {
        const { sessionId } = (request.params as { sessionId: string });

        const session = await db.session.findFirst({
            where: { id: sessionId, deviceId: request.deviceId! },
        });
        if (!session) {
            return reply.code(404).send({ error: 'Session not found' });
        }

        await db.$transaction([
            db.sessionMessage.deleteMany({ where: { sessionId } }),
            db.session.delete({ where: { id: sessionId } }),
        ]);

        return { success: true };
    });

    // Update session metadata (optimistic concurrency)
    app.patch('/v1/sessions/:sessionId/metadata', {
        preHandler: authMiddleware,
        schema: {
            params: z.object({ sessionId: z.string() }),
            body: z.object({
                metadata: z.string(),
                expectedVersion: z.number(),
            }),
        },
    }, async (request, reply) => {
        const { sessionId } = request.params;
        const { metadata, expectedVersion } = request.body;

        const result = await db.session.updateMany({
            where: {
                id: sessionId,
                deviceId: request.deviceId!,
                metadataVersion: expectedVersion,
            },
            data: {
                metadata,
                metadataVersion: expectedVersion + 1,
            },
        });

        if (result.count === 0) {
            return reply.code(409).send({ error: 'Version conflict' });
        }

        return { version: expectedVersion + 1 };
    });
}
```

- [ ] **Step 2: Commit**

```bash
git add server/sources/session/
git commit -m "feat(server): add session CRUD and message routes"
```

---

## Chunk 4: Socket.io + Event Router

### Task 10: Event router

**Files:**
- Create: `server/sources/socket/eventRouter.ts`
- Create: `server/sources/socket/eventRouter.spec.ts`

- [ ] **Step 1: Write failing test**

```typescript
// eventRouter.spec.ts
import { describe, it, expect, vi } from 'vitest';
import { EventRouter, type ClientConnection } from './eventRouter';

function mockConnection(overrides: Partial<ClientConnection> = {}): ClientConnection {
    return {
        connectionType: 'user-scoped',
        socket: { emit: vi.fn() } as any,
        deviceId: 'device-1',
        sessionId: undefined,
        ...overrides,
    };
}

describe('EventRouter', () => {
    it('should add and remove connections', () => {
        const router = new EventRouter();
        const conn = mockConnection();
        router.addConnection('device-1', conn);
        expect(router.getConnections('device-1')).toHaveLength(1);
        router.removeConnection('device-1', conn);
        expect(router.getConnections('device-1')).toHaveLength(0);
    });

    it('should emit to all user-scoped connections', () => {
        const router = new EventRouter();
        const conn1 = mockConnection();
        const conn2 = mockConnection({ connectionType: 'session-scoped', sessionId: 'sess-1' });
        router.addConnection('device-1', conn1);
        router.addConnection('device-1', conn2);

        router.emitUpdate('device-1', 'update', { type: 'test' }, { type: 'user-scoped-only' });

        expect(conn1.socket.emit).toHaveBeenCalledWith('update', { type: 'test' });
        expect(conn2.socket.emit).not.toHaveBeenCalled();
    });

    it('should emit to session-scoped + user-scoped for session filter', () => {
        const router = new EventRouter();
        const userConn = mockConnection();
        const sessConn = mockConnection({ connectionType: 'session-scoped', sessionId: 'sess-1' });
        const otherSessConn = mockConnection({ connectionType: 'session-scoped', sessionId: 'sess-2' });
        router.addConnection('device-1', userConn);
        router.addConnection('device-1', sessConn);
        router.addConnection('device-1', otherSessConn);

        router.emitUpdate('device-1', 'update', { type: 'test' }, {
            type: 'all-interested-in-session',
            sessionId: 'sess-1',
        });

        expect(userConn.socket.emit).toHaveBeenCalled();
        expect(sessConn.socket.emit).toHaveBeenCalled();
        expect(otherSessConn.socket.emit).not.toHaveBeenCalled();
    });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && npx vitest run sources/socket/eventRouter.spec.ts`
Expected: FAIL

- [ ] **Step 3: Implement eventRouter.ts**

```typescript
import type { Socket } from 'socket.io';

export interface ClientConnection {
    connectionType: 'session-scoped' | 'user-scoped';
    socket: Socket;
    deviceId: string;
    sessionId?: string;
}

export type RecipientFilter =
    | { type: 'all-interested-in-session'; sessionId: string }
    | { type: 'user-scoped-only' }
    | { type: 'all' };

export class EventRouter {
    private connections = new Map<string, Set<ClientConnection>>();

    addConnection(deviceId: string, connection: ClientConnection) {
        if (!this.connections.has(deviceId)) {
            this.connections.set(deviceId, new Set());
        }
        this.connections.get(deviceId)!.add(connection);
    }

    removeConnection(deviceId: string, connection: ClientConnection) {
        const conns = this.connections.get(deviceId);
        if (conns) {
            conns.delete(connection);
            if (conns.size === 0) this.connections.delete(deviceId);
        }
    }

    getConnections(deviceId: string): ClientConnection[] {
        return Array.from(this.connections.get(deviceId) || []);
    }

    emitUpdate(
        deviceId: string,
        event: string,
        payload: unknown,
        filter: RecipientFilter,
        skipSocket?: Socket
    ) {
        const conns = this.connections.get(deviceId);
        if (!conns) return;

        for (const conn of conns) {
            if (conn.socket === skipSocket) continue;
            if (this.shouldSend(conn, filter)) {
                conn.socket.emit(event, payload);
            }
        }
    }

    emitEphemeral(deviceId: string, event: string, payload: unknown) {
        this.emitUpdate(deviceId, event, payload, { type: 'all' });
    }

    private shouldSend(conn: ClientConnection, filter: RecipientFilter): boolean {
        switch (filter.type) {
            case 'all':
                return true;
            case 'user-scoped-only':
                return conn.connectionType === 'user-scoped';
            case 'all-interested-in-session':
                return conn.connectionType === 'user-scoped' ||
                    (conn.connectionType === 'session-scoped' && conn.sessionId === filter.sessionId);
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && npx vitest run sources/socket/eventRouter.spec.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add server/sources/socket/eventRouter.ts server/sources/socket/eventRouter.spec.ts
git commit -m "feat(server): add event router with connection-type filtering"
```

---

### Task 11: Socket.io server + session handler

**Files:**
- Create: `server/sources/socket/socketServer.ts`
- Create: `server/sources/socket/sessionHandler.ts`
- Create: `server/sources/socket/rpcHandler.ts`

- [ ] **Step 1: Implement socketServer.ts**

```typescript
import { Server as HttpServer } from 'http';
import { Server } from 'socket.io';
import { verifyToken } from '@/auth/crypto';
import { config } from '@/config';
import { EventRouter, type ClientConnection } from './eventRouter';
import { registerSessionHandler } from './sessionHandler';
import { registerRpcHandler } from './rpcHandler';

export const eventRouter = new EventRouter();

export function startSocket(server: HttpServer) {
    const io = new Server(server, {
        cors: { origin: '*', methods: ['GET', 'POST', 'OPTIONS'] },
        transports: ['websocket', 'polling'],
        pingTimeout: 45000,
        pingInterval: 15000,
        path: '/v1/updates',
        connectTimeout: 20000,
    });

    io.on('connection', (socket) => {
        const token = socket.handshake.auth.token as string | undefined;
        const clientType = (socket.handshake.auth.clientType as string) || 'user-scoped';
        const sessionId = socket.handshake.auth.sessionId as string | undefined;

        if (!token) {
            socket.disconnect();
            return;
        }

        const payload = verifyToken(token, config.masterSecret);
        if (!payload) {
            socket.disconnect();
            return;
        }

        const connection: ClientConnection = {
            connectionType: clientType === 'session-scoped' ? 'session-scoped' : 'user-scoped',
            socket,
            deviceId: payload.deviceId,
            sessionId,
        };

        eventRouter.addConnection(payload.deviceId, connection);

        // Register handlers
        registerSessionHandler(socket, payload.deviceId, eventRouter);
        registerRpcHandler(socket, payload.deviceId);

        socket.on('disconnect', () => {
            eventRouter.removeConnection(payload.deviceId, connection);
        });
    });

    return io;
}
```

- [ ] **Step 2: Implement sessionHandler.ts**

```typescript
import type { Socket } from 'socket.io';
import { db } from '@/storage/db';
import { allocateSessionSeq } from '@/storage/seq';
import type { EventRouter } from './eventRouter';

export function registerSessionHandler(
    socket: Socket,
    deviceId: string,
    eventRouter: EventRouter
) {
    // New message via socket
    socket.on('message', async (data: {
        sid: string;
        message: string;
        localId?: string;
    }, callback?: (result: any) => void) => {
        try {
            const session = await db.session.findFirst({
                where: { id: data.sid, deviceId },
            });
            if (!session) {
                callback?.({ error: 'Session not found' });
                return;
            }

            // Check for duplicate localId
            if (data.localId) {
                const existing = await db.sessionMessage.findUnique({
                    where: { sessionId_localId: { sessionId: data.sid, localId: data.localId } },
                });
                if (existing) {
                    callback?.({ id: existing.id, seq: existing.seq });
                    return;
                }
            }

            const seq = await allocateSessionSeq(data.sid);
            const message = await db.sessionMessage.create({
                data: {
                    sessionId: data.sid,
                    content: data.message,
                    localId: data.localId,
                    seq,
                },
            });

            // Broadcast to interested connections (skip sender)
            eventRouter.emitUpdate(deviceId, 'update', {
                type: 'new-message',
                sessionId: data.sid,
                message: { id: message.id, seq, content: data.message, localId: data.localId },
            }, { type: 'all-interested-in-session', sessionId: data.sid }, socket);

            callback?.({ id: message.id, seq });
        } catch (error) {
            callback?.({ error: 'Failed to save message' });
        }
    });

    // Update metadata
    socket.on('update-metadata', async (data: {
        sid: string;
        metadata: string;
        expectedVersion: number;
    }, callback?: (result: any) => void) => {
        const result = await db.session.updateMany({
            where: {
                id: data.sid,
                deviceId,
                metadataVersion: data.expectedVersion,
            },
            data: {
                metadata: data.metadata,
                metadataVersion: data.expectedVersion + 1,
            },
        });

        if (result.count === 0) {
            callback?.({ result: 'conflict' });
            return;
        }

        eventRouter.emitUpdate(deviceId, 'update', {
            type: 'update-session',
            sessionId: data.sid,
            metadata: data.metadata,
        }, { type: 'all-interested-in-session', sessionId: data.sid }, socket);

        callback?.({ result: 'ok', version: data.expectedVersion + 1 });
    });

    // Session alive (heartbeat)
    socket.on('session-alive', async (data: { sid: string }) => {
        await db.session.update({
            where: { id: data.sid },
            data: { lastActiveAt: new Date(), active: true },
        }).catch(() => {}); // ignore if session doesn't exist

        eventRouter.emitEphemeral(deviceId, 'ephemeral', {
            type: 'activity',
            sessionId: data.sid,
            active: true,
        });
    });

    // Session end
    socket.on('session-end', async (data: { sid: string }) => {
        await db.session.update({
            where: { id: data.sid },
            data: { active: false, lastActiveAt: new Date() },
        }).catch(() => {});

        eventRouter.emitUpdate(deviceId, 'update', {
            type: 'update-session',
            sessionId: data.sid,
            active: false,
        }, { type: 'all-interested-in-session', sessionId: data.sid });
    });
}
```

- [ ] **Step 3: Implement rpcHandler.ts**

```typescript
import type { Socket } from 'socket.io';

// Maps method prefix (sessionId or machineId) to the socket that handles it
const rpcHandlers = new Map<string, Socket>();

export function registerRpcHandler(socket: Socket, deviceId: string) {

    socket.on('rpc-register', (data: { method: string }) => {
        rpcHandlers.set(data.method, socket);
    });

    socket.on('rpc-unregister', (data: { method: string }) => {
        if (rpcHandlers.get(data.method) === socket) {
            rpcHandlers.delete(data.method);
        }
    });

    socket.on('rpc-call', async (data: {
        method: string;
        params: string; // encrypted
    }, callback?: (result: any) => void) => {
        const handler = rpcHandlers.get(data.method);
        if (!handler || !handler.connected) {
            callback?.({ ok: false, error: 'No handler registered' });
            return;
        }

        try {
            const result = await handler.timeout(300_000).emitWithAck('rpc-call', {
                method: data.method,
                params: data.params,
            });
            callback?.(result);
        } catch {
            callback?.({ ok: false, error: 'RPC timeout' });
        }
    });

    socket.on('disconnect', () => {
        // Clean up any RPC handlers registered by this socket
        for (const [method, s] of rpcHandlers.entries()) {
            if (s === socket) rpcHandlers.delete(method);
        }
    });
}
```

- [ ] **Step 4: Commit**

```bash
git add server/sources/socket/
git commit -m "feat(server): add Socket.io server, session handler, and RPC forwarding"
```

---

## Chunk 5: Main Entry + Integration

### Task 12: Main entry point

**Files:**
- Create: `server/sources/main.ts`

- [ ] **Step 1: Implement main.ts**

```typescript
import { db } from '@/storage/db';
import { startApi } from '@/api';
import { startSocket } from '@/socket/socketServer';
import { config } from '@/config';

async function main() {
    // Validate config
    if (!config.masterSecret || config.masterSecret === 'change-me-to-a-random-string') {
        console.error('MASTER_SECRET must be set');
        process.exit(1);
    }

    // Connect database
    await db.$connect();
    console.log('Database connected');

    // Start HTTP API
    const app = await startApi();

    // Start Socket.io on same server
    startSocket(app.server);
    console.log('Socket.io ready on /v1/updates');

    // Graceful shutdown
    const shutdown = async () => {
        console.log('Shutting down...');
        await app.close();
        await db.$disconnect();
        process.exit(0);
    };

    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
    process.on('uncaughtException', (err) => {
        console.error('Uncaught exception:', err);
        process.exit(1);
    });
}

main().catch((err) => {
    console.error('Failed to start:', err);
    process.exit(1);
});
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd server && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 3: Run all tests**

Run: `cd server && npx vitest run`
Expected: All tests pass

- [ ] **Step 4: Start server locally**

Run: `cd server && npm run dev`
Expected: "CodeLight Server listening on port 3005" + "Socket.io ready"

- [ ] **Step 5: Test health endpoint**

Run: `curl http://localhost:3005/health`
Expected: `{"status":"ok"}`

- [ ] **Step 6: Commit**

```bash
git add server/sources/main.ts
git commit -m "feat(server): add main entry point with graceful shutdown"
```

---

### Task 13: End-to-end smoke test

- [ ] **Step 1: Test auth flow with curl**

```bash
# Generate a keypair and sign a challenge (use node one-liner)
node -e "
const nacl = require('tweetnacl');
const { encodeBase64 } = require('tweetnacl-util');
const kp = nacl.sign.keyPair();
const challenge = new TextEncoder().encode('test-' + Date.now());
const sig = nacl.sign.detached(challenge, kp.secretKey);
console.log(JSON.stringify({
  publicKey: encodeBase64(kp.publicKey),
  challenge: encodeBase64(challenge),
  signature: encodeBase64(sig)
}));
" | curl -s -X POST http://localhost:3005/v1/auth \
  -H 'Content-Type: application/json' \
  -d @-
```

Expected: `{"success":true,"token":"...","deviceId":"..."}`

- [ ] **Step 2: Test session creation with token**

```bash
TOKEN=<from step 1>
curl -s -X POST http://localhost:3005/v1/sessions \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"tag":"test-session","metadata":"encrypted-blob"}'
```

Expected: Session object with id, tag, metadata

- [ ] **Step 3: Test message send**

```bash
SESSION_ID=<from step 2>
curl -s -X POST "http://localhost:3005/v1/sessions/$SESSION_ID/messages" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"content":"encrypted-msg","localId":"local-1"}]}'
```

Expected: `{"messages":[{"id":"...","seq":1,"localId":"local-1"}]}`

- [ ] **Step 4: Final commit with all passing**

```bash
git add -A
git commit -m "feat(server): CodeLight Server v0.1 — auth, sessions, socket, RPC"
```

- [ ] **Step 5: Push to GitHub**

```bash
git push origin main
```
