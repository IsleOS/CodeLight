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

    // Get notification preferences for this device. Defaults (all off for
    // completion/approval, off for error) are enforced at the schema level.
    app.get('/v1/notification-prefs', {
        preHandler: authMiddleware,
    }, async (request) => {
        const device = await db.device.findUnique({
            where: { id: request.deviceId! },
            select: {
                notifyOnCompletion: true,
                notifyOnApproval: true,
                notifyOnError: true,
            },
        });
        return device || { notifyOnCompletion: false, notifyOnApproval: false, notifyOnError: false };
    });

    // Update notification preferences. All fields optional so the client can
    // PATCH just one toggle at a time.
    app.put('/v1/notification-prefs', {
        preHandler: authMiddleware,
        schema: {
            body: z.object({
                notifyOnCompletion: z.boolean().optional(),
                notifyOnApproval: z.boolean().optional(),
                notifyOnError: z.boolean().optional(),
            }),
        },
    }, async (request) => {
        const body = request.body as {
            notifyOnCompletion?: boolean;
            notifyOnApproval?: boolean;
            notifyOnError?: boolean;
        };
        const updated = await db.device.update({
            where: { id: request.deviceId! },
            data: body,
            select: {
                notifyOnCompletion: true,
                notifyOnApproval: true,
                notifyOnError: true,
            },
        });
        return updated;
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
