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
        // Return all sessions (cross-device visibility for personal server)
        const sessions = await db.session.findMany({
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
        const { tag, metadata } = request.body as { tag: string; metadata: string };
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
        const { sessionId } = request.params as { sessionId: string };
        const { after_seq, limit } = request.query as { after_seq: number; limit: number };

        const session = await db.session.findFirst({
            where: { id: sessionId },
        });
        if (!session) {
            return reply.code(404).send({ error: 'Session not found' });
        }

        let messages;
        if (after_seq === 0) {
            // Default: return latest messages (most recent first, then reverse for display order)
            const latest = await db.sessionMessage.findMany({
                where: { sessionId },
                orderBy: { seq: 'desc' },
                take: limit,
            });
            messages = latest.reverse();
            return { messages, hasMore: latest.length === limit };
        } else {
            // Cursor mode: return messages after a specific seq
            const result = await db.sessionMessage.findMany({
                where: { sessionId, seq: { gt: after_seq } },
                orderBy: { seq: 'asc' },
                take: limit + 1,
            });
            const hasMore = result.length > limit;
            return { messages: result.slice(0, limit), hasMore };
        }
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
        const { sessionId } = request.params as { sessionId: string };
        const { messages } = request.body as { messages: Array<{ content: string; localId?: string }> };

        const session = await db.session.findFirst({
            where: { id: sessionId },
        });
        if (!session) {
            return reply.code(404).send({ error: 'Session not found' });
        }

        // Filter out duplicates by localId
        const newMessages = [];
        const existingResults = [];
        for (const msg of messages) {
            if (msg.localId) {
                const existing = await db.sessionMessage.findUnique({
                    where: { sessionId_localId: { sessionId, localId: msg.localId } },
                });
                if (existing) {
                    existingResults.push({ id: existing.id, seq: existing.seq, localId: existing.localId });
                    continue;
                }
            }
            newMessages.push(msg);
        }

        if (newMessages.length === 0) {
            return { messages: existingResults };
        }

        const startSeq = await allocateSessionSeqBatch(sessionId, newMessages.length);

        const created = await db.$transaction(
            newMessages.map((msg, i) =>
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
            messages: [
                ...existingResults,
                ...created.map(m => ({
                    id: m.id,
                    seq: m.seq,
                    localId: m.localId,
                })),
            ],
        };
    });

    // Delete session
    app.delete('/v1/sessions/:sessionId', {
        preHandler: authMiddleware,
    }, async (request, reply) => {
        const { sessionId } = request.params as { sessionId: string };

        const session = await db.session.findFirst({
            where: { id: sessionId },
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
        const { sessionId } = request.params as { sessionId: string };
        const { metadata, expectedVersion } = request.body as { metadata: string; expectedVersion: number };

        const result = await db.session.updateMany({
            where: {
                id: sessionId,
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
