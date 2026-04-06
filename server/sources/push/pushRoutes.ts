import { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { db } from '@/storage/db';
import { authMiddleware } from '@/auth/middleware';

export async function pushRoutes(app: FastifyInstance) {

    // Register a push token
    app.post('/v1/push-tokens', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                token: z.string(),
            }),
        },
    }, async (request) => {
        const { token } = request.body as { token: string };
        const deviceId = request.deviceId!;

        await db.pushToken.upsert({
            where: { deviceId_token: { deviceId, token } },
            create: { deviceId, token },
            update: {},
        });

        return { success: true };
    });

    // Remove a push token
    app.delete('/v1/push-tokens/:token', {
        preHandler: authMiddleware,
    }, async (request, reply) => {
        const { token } = request.params as { token: string };

        await db.pushToken.deleteMany({
            where: { deviceId: request.deviceId!, token },
        });

        return { success: true };
    });

    // List push tokens for current device
    app.get('/v1/push-tokens', {
        preHandler: authMiddleware,
    }, async (request) => {
        const tokens = await db.pushToken.findMany({
            where: { deviceId: request.deviceId! },
            select: { token: true, createdAt: true },
        });

        return { tokens };
    });

    // Register a Live Activity push token for a session
    app.post('/v1/live-activity-tokens', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                sessionId: z.string(),
                token: z.string(),
            }),
        },
    }, async (request) => {
        const { sessionId, token } = request.body as { sessionId: string; token: string };
        const deviceId = request.deviceId!;

        await db.liveActivityToken.upsert({
            where: { deviceId_sessionId: { deviceId, sessionId } },
            create: { deviceId, sessionId, token },
            update: { token },
        });

        console.log(`[LiveActivity] Registered token for session ${sessionId.substring(0,8)}`);
        return { success: true };
    });

    // Remove a Live Activity token
    app.delete('/v1/live-activity-tokens/:sessionId', {
        preHandler: authMiddleware,
    }, async (request) => {
        const { sessionId } = request.params as { sessionId: string };
        await db.liveActivityToken.deleteMany({
            where: { deviceId: request.deviceId!, sessionId },
        });
        return { success: true };
    });
}
